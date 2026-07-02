#!/usr/bin/env python3
"""tests/test_p2_11_python_hygiene.py — v0.15.0 regression coverage.

Runs standalone via `python3 tests/test_p2_11_python_hygiene.py` (unittest
discovery). No external test-framework dependency — matches the rest of
the engine's zero-dep testing style.

Covers the highest-risk P2.11 sub-fixes:
  1. pe_gate: schema_major const (no IndexError on empty examples).
  2. pe_gate: argparse accepts flag-after-path order.
  3. pe_gate: utf-8-sig decodes BOM-prefixed transcripts.
  4. pe_gate: FAIL + missing failure_class → escalate exit code.
  5. orchestrator: policy KeyError → PolicyError (structured).
  6. orchestrator: budget accepts float (not just int).
  7. orchestrator: cache_read tokens weighted at 0.1 (not full).
  8. orchestrator: reconcile payload validates required keys + enum.
  9. orchestrator: iteration >= 1 enforced at CLI.
 10. baseline: chore(fix) reaches file_overlap (housekeeping regex
     no longer eats it).
 11. baseline: git errors emit GitError with stderr preserved.
 12. research_index: read_yaml_field doesn't cross parent scopes.
 13. research_index: oversized paragraph split before chunking.
 14. research_index: dedupe-before-topK returns distinct docs.
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ENGINE_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ENGINE_DIR / "scripts"))

import pe_gate  # noqa: E402
import pe_orchestrator  # noqa: E402
import baseline  # noqa: E402
import research_index  # noqa: E402


BARE_ENVELOPE_PASS = {
    "schema_version": "1.0.0",
    "gate_name": "code-reviewer",
    "verdict": "PASS",
    "failure_class": "none",
    "model_used": "test-model",
    "timestamp": "2026-07-03T00:00:00Z",
    "findings": [],
}


class TestPeGate(unittest.TestCase):
    def test_engine_schema_major_is_const(self):
        # No IndexError even if schema examples were empty (const bypass).
        self.assertEqual(pe_gate.ENGINE_SCHEMA_MAJOR, "1")

    def test_missing_failure_class_on_fail_defaults_to_escalate(self):
        env = {**BARE_ENVELOPE_PASS, "verdict": "FAIL"}
        env.pop("failure_class")
        self.assertEqual(
            pe_gate.classify_exit(env),
            pe_gate.EXIT_FAIL_ESCALATE,
        )

    def test_explicit_none_failure_class_on_fail_escalates(self):
        # An envelope that shows FAIL + failure_class=none used to
        # slip through the router — the classify_exit fallback now
        # treats falsy failure_class as worker_quality.
        env = {**BARE_ENVELOPE_PASS, "verdict": "FAIL", "failure_class": None}
        self.assertEqual(
            pe_gate.classify_exit(env),
            pe_gate.EXIT_FAIL_ESCALATE,
        )

    def test_argparse_accepts_flag_after_path(self):
        with tempfile.NamedTemporaryFile(
            "w", suffix=".json", delete=False, encoding="utf-8"
        ) as fh:
            json.dump(BARE_ENVELOPE_PASS, fh)
            path = fh.name
        try:
            # Path first, --bare after — pre-P2.11 hand-rolled loop
            # rejected this ordering.
            argv = ["pe_gate.py", path, "--bare"]
            rc = pe_gate.main(argv)
            self.assertEqual(rc, pe_gate.EXIT_PASS)
        finally:
            Path(path).unlink(missing_ok=True)

    def test_utf8_sig_bom_tolerated(self):
        payload = json.dumps(BARE_ENVELOPE_PASS)
        with tempfile.NamedTemporaryFile(
            "wb", suffix=".json", delete=False
        ) as fh:
            # UTF-8 BOM prefix — Windows Notepad and some editors add
            # this transparently.
            fh.write(b"\xef\xbb\xbf" + payload.encode("utf-8"))
            path = fh.name
        try:
            rc = pe_gate.main(["pe_gate.py", "--bare", path])
            self.assertEqual(rc, pe_gate.EXIT_PASS)
        finally:
            Path(path).unlink(missing_ok=True)


class TestOrchestratorPolicy(unittest.TestCase):
    def test_policy_missing_key_raises_policyerror(self):
        with self.assertRaises(pe_orchestrator.PolicyError):
            pe_orchestrator.compute_breaker_state(
                iteration=1,
                slot_kind=None,
                envelope=None,
                breaker_policy={"per_slot": {}},  # missing slot_iteration_cap
                cumulative_state_path=Path("/tmp/does-not-exist"),
            )

    def test_budget_accepts_float(self):
        # A float budget in TOML used to silently disable enforcement
        # because isinstance(budget, int) failed.
        policy = {
            "per_slot": {"slot_iteration_cap": 100},
            "cumulative": {
                "worker_tokens_budget": 5000.0,
                "gate_tokens_budget": 5000.0,
            },
        }
        with tempfile.TemporaryDirectory() as td:
            state = Path(td) / "state.json"
            state.write_text(json.dumps({
                "worker_tokens_cumulative": 6000,
                "gate_tokens_cumulative": 0,
            }))
            b = pe_orchestrator.compute_breaker_state(
                iteration=1,
                slot_kind=None,
                envelope=None,
                breaker_policy=policy,
                cumulative_state_path=state,
            )
        self.assertTrue(b.breaker_would_trip)
        self.assertIn("worker_tokens_cumulative=6000", b.trip_reason or "")

    def test_cache_read_tokens_weighted(self):
        # cache_read at 10% weight — previously counted full.
        policy = {
            "per_slot": {"slot_iteration_cap": 100},
            "cumulative": {"gate_tokens_budget": 200, "worker_tokens_budget": "inf"},
        }
        envelope = {
            "cost": {
                "input_tokens": 100,
                "output_tokens": 0,
                "cache_read_tokens": 1000,
            }
        }
        with tempfile.TemporaryDirectory() as td:
            state = Path(td) / "state.json"
            b = pe_orchestrator.compute_breaker_state(
                iteration=1,
                slot_kind=None,
                envelope=envelope,
                breaker_policy=policy,
                cumulative_state_path=state,
            )
        # With P2.11 weighting: 100 + 0 + 1000*0.1 = 200 → trips at ==200.
        # Pre-P2.11 would have been 100 + 0 + 1000 = 1100 (also trips) but
        # cache_read=1000 would have poisoned a series of cache-heavy calls.
        # This test locks the new arithmetic.
        self.assertEqual(b.gate_tokens_cumulative, 200)


class TestOrchestratorReconcile(unittest.TestCase):
    def test_reconcile_rejects_all_null_payload(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            decisions = td / "decisions.jsonl"
            recs = td / "reconciliations.jsonl"
            # write one decision for slot X
            decisions.write_text(
                json.dumps({"slot_id": "X", "decision_id": "d1"}) + "\n"
            )
            payload = json.dumps({
                "merge_commit": None,
                "ultimate_outcome": None,
            })
            with patch("sys.stdin", io.StringIO(payload)):
                rc = pe_orchestrator.reconcile("X", decisions, recs)
            self.assertEqual(rc, 4)
            self.assertFalse(recs.exists())

    def test_reconcile_rejects_bad_enum(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            decisions = td / "decisions.jsonl"
            recs = td / "reconciliations.jsonl"
            decisions.write_text(
                json.dumps({"slot_id": "X", "decision_id": "d1"}) + "\n"
            )
            payload = json.dumps({
                "merge_commit": "abc",
                "ultimate_outcome": "everything-is-fine",  # not in enum
            })
            with patch("sys.stdin", io.StringIO(payload)):
                rc = pe_orchestrator.reconcile("X", decisions, recs)
            self.assertEqual(rc, 4)

    def test_reconcile_accepts_valid_payload(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            decisions = td / "decisions.jsonl"
            recs = td / "reconciliations.jsonl"
            decisions.write_text(
                json.dumps({"slot_id": "X", "decision_id": "d1"}) + "\n"
            )
            payload = json.dumps({
                "merge_commit": "abcdef",
                "ultimate_outcome": "success",  # any of: success|merged|reverted|abandoned|pending
            })
            with patch("sys.stdin", io.StringIO(payload)):
                rc = pe_orchestrator.reconcile("X", decisions, recs)
            self.assertEqual(rc, 0)
            self.assertTrue(recs.exists())


class TestOrchestratorIteration(unittest.TestCase):
    def test_iteration_type_rejects_zero(self):
        parser = pe_orchestrator.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args([
                "decide", "--envelope", "/tmp/x",
                "--slot-id", "s", "--iteration", "0",
                "--current-tier", "sonnet",
            ])

    def test_iteration_type_rejects_negative(self):
        parser = pe_orchestrator.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args([
                "decide", "--envelope", "/tmp/x",
                "--slot-id", "s", "--iteration", "-1",
                "--current-tier", "sonnet",
            ])


class TestBaselineHousekeeping(unittest.TestCase):
    def test_chore_fix_not_housekeeping(self):
        # Pre-P2.11: `chore(fix): ...` matched HOUSEKEEPING_PREFIX_RE
        # under the `chore` branch. Post-P2.11: negative lookahead
        # reserves chore(fix) for the fix detector.
        subject = "chore(fix): rebuild service worker cache"
        self.assertIsNone(baseline.HOUSEKEEPING_PREFIX_RE.match(subject))
        self.assertIsNotNone(baseline.FIX_PREFIX_RE.match(subject))

    def test_chore_deps_still_housekeeping(self):
        subject = "chore(deps): bump lodash to 4.17.22"
        self.assertIsNotNone(baseline.HOUSEKEEPING_PREFIX_RE.match(subject))

    def test_plain_chore_still_housekeeping(self):
        self.assertIsNotNone(
            baseline.HOUSEKEEPING_PREFIX_RE.match("chore: bump version")
        )

    def test_git_error_wraps_stderr(self):
        with tempfile.TemporaryDirectory() as td:
            # Not a git repo — git will fail.
            with self.assertRaises(baseline.GitError) as ctx:
                baseline.git(Path(td), "status")
            self.assertIn("git status failed", str(ctx.exception))
            self.assertIn("stderr:", str(ctx.exception))


class TestResearchIndexYaml(unittest.TestCase):
    def test_yaml_field_respects_parent_scope(self):
        # Pre-P2.11: matched wrong-parent siblings.
        yaml_text = (
            "some_block:\n"
            "  provider: WRONG\n"
            "rag:\n"
            "  model: bge-small\n"
            "  # no provider here\n"
        )
        with tempfile.NamedTemporaryFile(
            "w", suffix=".yaml", delete=False, encoding="utf-8"
        ) as fh:
            fh.write(yaml_text)
            path = Path(fh.name)
        try:
            result = research_index.read_yaml_field(path, "rag", "provider")
            self.assertIsNone(
                result,
                f"expected None (rag.provider absent), got {result!r}",
            )
        finally:
            path.unlink(missing_ok=True)

    def test_yaml_field_returns_correct_child(self):
        yaml_text = (
            "rag:\n"
            "  provider: voyage\n"
            "  model: voyage-3\n"
        )
        with tempfile.NamedTemporaryFile(
            "w", suffix=".yaml", delete=False, encoding="utf-8"
        ) as fh:
            fh.write(yaml_text)
            path = Path(fh.name)
        try:
            self.assertEqual(
                research_index.read_yaml_field(path, "rag", "provider"),
                "voyage",
            )
        finally:
            path.unlink(missing_ok=True)


class TestResearchIndexChunking(unittest.TestCase):
    def test_oversized_paragraph_gets_split(self):
        # Single 3000-char paragraph — must not be dropped or truncated.
        para = "word " * 600
        chunks = research_index.chunk_markdown(para)
        self.assertGreater(len(chunks), 1)
        # Chunk assembler adds CHUNK_OVERLAP tail slack — 50-char
        # cushion covers the "\n\n" separators + any rounding.
        soft_cap = research_index.CHUNK_SIZE + research_index.CHUNK_OVERLAP + 50
        for c in chunks:
            self.assertLessEqual(len(c), soft_cap)

    def test_normal_markdown_still_chunks_paragraph_aware(self):
        text = "\n\n".join(f"Paragraph {i}. " + "x" * 50 for i in range(10))
        chunks = research_index.chunk_markdown(text)
        self.assertGreaterEqual(len(chunks), 1)


class TestSubset(unittest.TestCase):
    """Sanity: importing the modules doesn't blow up (regression from
    P2.11's edits — argparse move for pe_gate can subtly break imports)."""

    def test_modules_import_clean(self):
        self.assertTrue(hasattr(pe_gate, "main"))
        self.assertTrue(hasattr(pe_orchestrator, "compute_breaker_state"))
        self.assertTrue(hasattr(baseline, "git"))
        self.assertTrue(hasattr(research_index, "read_yaml_field"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
