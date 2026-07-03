"""test_telemetry.py — unit tests for the A1 transcript parser.

Runs with: python3 -m unittest tests.test_telemetry

Fast, no I/O, no network. Exercises the shape rules that used to only
be checked by the live smoke ('pe telemetry collect' against real
transcripts) — those are integration-scale and don't fit in CI.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from telemetry import (  # noqa: E402  (path munging above)
    CENTS_PER_MTOKEN,
    UNKNOWN_MODEL_PRICES,
    _cost_cents,
    _emit_otel_span,
    _prices_for,
    parse_assistant_record,
)


def _assistant_record(
    *,
    session_id: str = "sess-1",
    uuid: str = "turn-1",
    parent: str | None = None,
    model: str = "claude-sonnet-4-6",
    input_tokens: int = 1000,
    output_tokens: int = 500,
    cache_read: int = 0,
    cache_creation: int = 0,
    stop_reason: str = "end_turn",
    timestamp: str = "2026-07-02T09:00:00Z",
) -> dict:
    return {
        "type": "assistant",
        "sessionId": session_id,
        "uuid": uuid,
        "parentUuid": parent,
        "timestamp": timestamp,
        "gitBranch": "master",
        "cwd": "/tmp/x",
        "message": {
            "model": model,
            "stop_reason": stop_reason,
            "usage": {
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "cache_read_input_tokens": cache_read,
                "cache_creation_input_tokens": cache_creation,
            },
        },
    }


class ParseAssistantRecord(unittest.TestCase):
    def test_extracts_all_fields(self):
        rec = _assistant_record(
            input_tokens=1000, output_tokens=500,
            cache_read=200, cache_creation=100,
        )
        tr = parse_assistant_record(rec)
        assert tr is not None
        self.assertEqual(tr.session_id, "sess-1")
        self.assertEqual(tr.turn_uuid, "turn-1")
        self.assertEqual(tr.model, "claude-sonnet-4-6")
        self.assertEqual(tr.input_tokens, 1000)
        self.assertEqual(tr.output_tokens, 500)
        self.assertEqual(tr.cache_read_tokens, 200)
        self.assertEqual(tr.cache_creation_tokens, 100)
        self.assertEqual(tr.stop_reason, "end_turn")
        self.assertGreater(tr.cost_cents, 0)

    def test_skips_non_assistant(self):
        for t in ("user", "tool_result", "system"):
            self.assertIsNone(parse_assistant_record({"type": t}))

    def test_skips_missing_usage(self):
        # assistant records without a usage dict aren't billable
        rec = {"type": "assistant", "message": {"model": "claude-sonnet-4-6"}}
        self.assertIsNone(parse_assistant_record(rec))

    def test_tolerates_missing_optional_fields(self):
        rec = {
            "type": "assistant",
            "message": {
                "model": "claude-sonnet-4-6",
                "usage": {"input_tokens": 10, "output_tokens": 5},
            },
        }
        tr = parse_assistant_record(rec)
        assert tr is not None
        self.assertEqual(tr.cache_read_tokens, 0)
        self.assertEqual(tr.cache_creation_tokens, 0)
        self.assertEqual(tr.session_id, "unknown")

    def test_unknown_model_yields_zero_cost(self):
        rec = _assistant_record(model="claude-mystery-2")
        tr = parse_assistant_record(rec)
        assert tr is not None
        self.assertEqual(tr.model, "claude-mystery-2")
        self.assertEqual(tr.cost_cents, 0.0)


class PricingTable(unittest.TestCase):
    def test_prefix_match_wins(self):
        prices = _prices_for("claude-sonnet-4-6")
        self.assertEqual(prices["input"], 300)
        self.assertEqual(prices["output"], 1500)

    def test_haiku_cheapest(self):
        haiku = _prices_for("claude-haiku-4-5-20251001")
        opus = _prices_for("claude-opus-4-8")
        self.assertLess(haiku["input"], opus["input"])
        self.assertLess(haiku["output"], opus["output"])

    def test_unknown_prefix_returns_zero(self):
        self.assertEqual(_prices_for("gpt-4"), UNKNOWN_MODEL_PRICES)

    def test_cache_read_much_cheaper_than_input(self):
        # Cache-read should be ~10% of input across the board. If someone
        # accidentally sets it to a higher number, the whole cost model
        # breaks (long-running sessions with heavy caching would over-bill).
        for prefix, prices in CENTS_PER_MTOKEN.items():
            with self.subTest(prefix=prefix):
                self.assertLess(
                    prices["cache_read"], prices["input"],
                    f"{prefix}: cache_read should be cheaper than input",
                )

    def test_cache_creation_more_expensive_than_input(self):
        # Regression guard: Anthropic prices cache-write at ~1.25× input
        # (writing to the 5-minute cache is deliberately more expensive
        # than a plain input token — Anthropic is offloading their own
        # cache-population cost). A reviewer once misread this as a bug
        # and proposed cache_creation == cache_read; if that "fix" ever
        # lands, cost attribution will silently under-report on cache
        # writes. This test locks the invariant in place. See the
        # comment block above CENTS_PER_MTOKEN in scripts/telemetry.py.
        for prefix, prices in CENTS_PER_MTOKEN.items():
            with self.subTest(prefix=prefix):
                self.assertGreater(
                    prices["cache_creation"], prices["input"],
                    f"{prefix}: cache_creation should be MORE expensive than "
                    "input per Anthropic's 5-min-cache pricing (~1.25× input)",
                )

    def test_cost_arithmetic(self):
        # 1M input tokens on sonnet = $3.00 = 300 cents
        cost = _cost_cents(
            {"input_tokens": 1_000_000, "output_tokens": 0,
             "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
            "claude-sonnet-4-6",
        )
        self.assertAlmostEqual(cost, 300, delta=0.01)


class OtelSpanShape(unittest.TestCase):
    def test_uses_gen_ai_conventions(self):
        rec = _assistant_record()
        tr = parse_assistant_record(rec)
        assert tr is not None
        span = _emit_otel_span(tr)
        attrs = span["attributes"]
        # OTel GenAI required attributes
        self.assertEqual(attrs["gen_ai.system"], "anthropic")
        self.assertEqual(attrs["gen_ai.request.model"], "claude-sonnet-4-6")
        self.assertIn("gen_ai.usage.input_tokens", attrs)
        self.assertIn("gen_ai.usage.output_tokens", attrs)

    def test_carries_trace_and_span_ids(self):
        rec = _assistant_record(session_id="S", uuid="T", parent="P")
        tr = parse_assistant_record(rec)
        assert tr is not None
        span = _emit_otel_span(tr)
        self.assertEqual(span["trace_id"], "S")
        self.assertEqual(span["span_id"], "T")
        self.assertEqual(span["parent_span_id"], "P")

    def test_cost_surfaced_as_custom_attribute(self):
        rec = _assistant_record(input_tokens=1_000_000)
        tr = parse_assistant_record(rec)
        assert tr is not None
        span = _emit_otel_span(tr)
        self.assertGreater(span["attributes"]["8colors.cost_cents"], 0)


if __name__ == "__main__":
    unittest.main()
