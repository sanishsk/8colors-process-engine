#!/usr/bin/env python3
"""telemetry.py — parse Claude Code session transcripts into structured
usage records (A1) + OTel-shaped local traces (L1) + cost attribution
per session/model (L4).

The engine's circuit breaker in `pe_orchestrator.py` reads budgets from
`policy/circuit_breaker.toml`. Those budgets were hardcoded `"inf"`
because there was no way to measure real per-slot token spend — the
agent-emitted `envelope.cost` field is self-reported and unreliable
(sometimes fabricated, often omitted). This module fixes that gap by
reading the authoritative source: Claude Code's own session transcripts
at `~/.claude/projects/<project-slug>/<session>.jsonl`, where every
assistant record carries a real `message.usage` dict with input /
output / cache-creation / cache-read token counts + `message.model`.

Design principles
-----------------

- **Read-only.** Never mutates the transcript files. Writes to
  `.pe/telemetry.jsonl` (structured records) and
  `.pe/traces/<session-id>.jsonl` (OTel spans) in the project directory.
- **Feature-detected.** If no transcripts exist (fresh machine, CI
  runner without a Claude Code install), emits nothing and exits 0 —
  the breaker falls back to shadow-mode with `"inf"` budgets like
  before.
- **Local-first (L1 principle).** Emits OTel-shaped spans as JSONL to
  the project directory. Does NOT ship to any external observability
  SaaS. If the operator later wants Langfuse/Arize/Grafana, they can
  tail the file and forward it — plumbing not policy.
- **Cost attribution (L4).** Per-model per-session token totals feed
  into a summary the retro agent can consume. Anthropic pricing is
  hard-coded in the CENTS_PER_MTOKEN table below; update as prices
  change (or wire to an external price feed later).

Usage
-----

    pe telemetry collect [--project <path>] [--since <YYYY-MM-DD>]
    pe telemetry summary  [--project <path>] [--since <YYYY-MM-DD>]

`collect` scans every transcript in
`~/.claude/projects/<project-slug>/*.jsonl`, extracts assistant records
with a `message.usage` dict, and writes:
  - `<project>/.pe/telemetry.jsonl` (append-only, one line per
    assistant turn, deduped by `uuid`)
  - `<project>/.pe/traces/<session-id>.jsonl` (OTel spans per session)

`summary` reads `.pe/telemetry.jsonl` and prints per-session totals +
cost estimates.

Exit codes
----------

    0  success (may have processed zero records if no transcripts)
    2  invalid args / project not a git repo
    3  transcript directory not found (informational — not an error)
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# ─── Anthropic pricing (cents per 1M tokens, USD) ─────────────────────
# Snapshot: 2026-07-02, from https://www.anthropic.com/pricing (verify
# quarterly; last verified 2026-07-02). L4 cost attribution uses these.
#
# Anthropic's prompt-caching pricing model (5-minute TTL cache):
#   cache_read       = 0.1× input   (~10% — cheap cache hit)
#   cache_creation   = 1.25× input  (writing to the cache costs more
#                                    than a plain input token — this
#                                    is NOT a bug; verify against
#                                    anthropic.com/pricing before
#                                    "correcting" it)
# So per-Mtoken cents for Sonnet: input=300, cache_read=30, cache_creation=375.
# `test_cache_creation_more_expensive_than_input` in test_telemetry.py
# locks this invariant in place.

CENTS_PER_MTOKEN: dict[str, dict[str, int]] = {
    # model prefix → {input, output, cache_read, cache_creation}
    # Order matters — first prefix match wins. Add newer models above older ones.
    "claude-opus-4-8": {"input": 1500, "output": 7500, "cache_read": 150, "cache_creation": 1875},
    "claude-opus-4-7": {"input": 1500, "output": 7500, "cache_read": 150, "cache_creation": 1875},
    "claude-opus-4-5": {"input": 1500, "output": 7500, "cache_read": 150, "cache_creation": 1875},
    "claude-sonnet-5": {"input": 300, "output": 1500, "cache_read": 30, "cache_creation": 375},
    "claude-sonnet-4-6": {"input": 300, "output": 1500, "cache_read": 30, "cache_creation": 375},
    "claude-haiku-4-5": {"input": 80, "output": 400, "cache_read": 8, "cache_creation": 100},
    "claude-haiku-4":   {"input": 80, "output": 400, "cache_read": 8, "cache_creation": 100},
}

# fallback if the model is unknown (0 cost — surfaces the miss)
UNKNOWN_MODEL_PRICES = {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}


def _project_slug(project_path: Path) -> str:
    """Match Claude Code's directory encoding: absolute path with / → -."""
    return str(project_path.resolve()).replace("/", "-")


def _transcript_dir(project_path: Path, claude_home: Path | None = None) -> Path:
    home = claude_home or Path.home() / ".claude" / "projects"
    return home / _project_slug(project_path)


def _prices_for(model: str) -> dict[str, int]:
    for prefix, prices in CENTS_PER_MTOKEN.items():
        if model.startswith(prefix):
            return prices
    return UNKNOWN_MODEL_PRICES


def _cost_cents(usage: dict[str, Any], model: str) -> float:
    """Compute cost in cents from a message.usage dict."""
    prices = _prices_for(model)
    in_tok = usage.get("input_tokens", 0) or 0
    out_tok = usage.get("output_tokens", 0) or 0
    cr_tok = usage.get("cache_read_input_tokens", 0) or 0
    cc_tok = usage.get("cache_creation_input_tokens", 0) or 0
    return (
        (in_tok / 1_000_000) * prices["input"]
        + (out_tok / 1_000_000) * prices["output"]
        + (cr_tok / 1_000_000) * prices["cache_read"]
        + (cc_tok / 1_000_000) * prices["cache_creation"]
    )


@dataclass
class TurnRecord:
    """One assistant turn extracted from the transcript.

    Written to `.pe/telemetry.jsonl` as JSON per line.
    """

    session_id: str
    turn_uuid: str
    parent_uuid: str | None
    timestamp: str  # ISO 8601
    model: str
    input_tokens: int
    output_tokens: int
    cache_read_tokens: int
    cache_creation_tokens: int
    cost_cents: float
    git_branch: str = ""
    cwd: str = ""
    stop_reason: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "turn_uuid": self.turn_uuid,
            "parent_uuid": self.parent_uuid,
            "timestamp": self.timestamp,
            "model": self.model,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cache_read_tokens": self.cache_read_tokens,
            "cache_creation_tokens": self.cache_creation_tokens,
            "cost_cents": round(self.cost_cents, 4),
            "git_branch": self.git_branch,
            "cwd": self.cwd,
            "stop_reason": self.stop_reason,
        }


def parse_assistant_record(rec: dict[str, Any]) -> TurnRecord | None:
    """Extract a TurnRecord from a Claude Code transcript assistant record.

    Returns None if the record is not an assistant record or has no
    usage data.
    """
    if rec.get("type") != "assistant":
        return None
    msg = rec.get("message") or {}
    if not isinstance(msg, dict):
        return None
    usage = msg.get("usage")
    if not isinstance(usage, dict):
        return None
    model = msg.get("model") or "unknown"
    return TurnRecord(
        session_id=rec.get("sessionId", "unknown"),
        turn_uuid=rec.get("uuid", ""),
        parent_uuid=rec.get("parentUuid"),
        timestamp=rec.get("timestamp", ""),
        model=model,
        input_tokens=usage.get("input_tokens", 0) or 0,
        output_tokens=usage.get("output_tokens", 0) or 0,
        cache_read_tokens=usage.get("cache_read_input_tokens", 0) or 0,
        cache_creation_tokens=usage.get("cache_creation_input_tokens", 0) or 0,
        cost_cents=_cost_cents(usage, model),
        git_branch=rec.get("gitBranch", ""),
        cwd=rec.get("cwd", ""),
        stop_reason=msg.get("stop_reason"),
    )


def _iter_transcript(path: Path):
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _load_seen_uuids(telemetry_path: Path) -> set[str]:
    """Dedupe key — replay the file to skip already-recorded turns."""
    seen: set[str] = set()
    if not telemetry_path.exists():
        return seen
    for rec in _iter_transcript(telemetry_path):
        u = rec.get("turn_uuid")
        if u:
            seen.add(u)
    return seen


def _emit_otel_span(record: TurnRecord) -> dict[str, Any]:
    """L1: OTel-shaped span for one assistant turn.

    Follows OTel GenAI conventions: `gen_ai.system`, `gen_ai.request.model`,
    `gen_ai.usage.input_tokens`, etc.
    """
    return {
        "trace_id": record.session_id,
        "span_id": record.turn_uuid,
        "parent_span_id": record.parent_uuid,
        "name": f"chat {record.model}",
        "start_time": record.timestamp,
        "attributes": {
            "gen_ai.system": "anthropic",
            "gen_ai.request.model": record.model,
            "gen_ai.usage.input_tokens": record.input_tokens,
            "gen_ai.usage.output_tokens": record.output_tokens,
            "gen_ai.usage.cache_read_tokens": record.cache_read_tokens,
            "gen_ai.usage.cache_creation_tokens": record.cache_creation_tokens,
            "gen_ai.response.finish_reasons": [record.stop_reason] if record.stop_reason else [],
            "8colors.cost_cents": round(record.cost_cents, 4),
            "8colors.git_branch": record.git_branch,
            "8colors.cwd": record.cwd,
        },
    }


def _emit_tool_use_child_spans(rec: dict[str, Any], parent: TurnRecord) -> list[dict[str, Any]]:
    """L1 completion (v0.25.1): child spans per tool_use, parented at
    the assistant turn's span.

    Real assistant records carry a `content: [...]` array whose items
    can be `{type: "text", ...}` or `{type: "tool_use", id, name, input}`.
    Every tool_use is one child span under the assistant turn — the
    span tree needed to answer "where did this slot spend its time".

    Tool cost is not per-tool-billable in Anthropic's model (the whole
    turn is one bill), so children get no cost attribute — only the
    tool name + tool_use_id for correlation with the follow-up
    `tool_result` user record.
    """
    msg = rec.get("message") or {}
    content = msg.get("content")
    if not isinstance(content, list):
        return []
    spans: list[dict[str, Any]] = []
    for item in content:
        if not isinstance(item, dict) or item.get("type") != "tool_use":
            continue
        tool_id = item.get("id") or ""
        tool_name = item.get("name") or "unknown"
        spans.append({
            "trace_id": parent.session_id,
            "span_id": tool_id,
            "parent_span_id": parent.turn_uuid,
            "name": f"tool {tool_name}",
            "start_time": parent.timestamp,
            "attributes": {
                "gen_ai.tool.name": tool_name,
                "gen_ai.tool.call_id": tool_id,
                "8colors.parent_model": parent.model,
            },
        })
    return spans


def cmd_collect(args: argparse.Namespace) -> int:
    project = Path(args.project).resolve()
    if not (project / ".git").exists():
        print(f"ERROR: {project} is not a git repository", file=sys.stderr)
        return 2

    claude_home = Path(args.claude_home).expanduser() if args.claude_home else None
    transcript_dir = _transcript_dir(project, claude_home)

    if not transcript_dir.is_dir():
        print(
            f"[telemetry] no transcripts at {transcript_dir} — "
            "nothing to collect (feature-detected skip)",
            file=sys.stderr,
        )
        return 0

    since_dt: dt.datetime | None = None
    if args.since:
        try:
            since_dt = dt.datetime.fromisoformat(args.since).replace(tzinfo=dt.timezone.utc)
        except ValueError:
            print(f"ERROR: --since must be YYYY-MM-DD (got {args.since!r})", file=sys.stderr)
            return 2

    pe_dir = project / ".pe"
    pe_dir.mkdir(exist_ok=True)
    telemetry_path = pe_dir / "telemetry.jsonl"
    traces_dir = pe_dir / "traces"
    traces_dir.mkdir(exist_ok=True)

    seen = _load_seen_uuids(telemetry_path)
    added = 0
    skipped_dedup = 0
    skipped_since = 0

    with telemetry_path.open("a", encoding="utf-8") as ledger:
        for tp in sorted(transcript_dir.glob("*.jsonl")):
            session_id = tp.stem
            trace_path = traces_dir / f"{session_id}.jsonl"
            traces_seen: set[str] = set()
            if trace_path.exists():
                for span in _iter_transcript(trace_path):
                    sid = span.get("span_id")
                    if sid:
                        traces_seen.add(sid)

            with trace_path.open("a", encoding="utf-8") as tf:
                for rec in _iter_transcript(tp):
                    turn = parse_assistant_record(rec)
                    if turn is None:
                        continue
                    if turn.turn_uuid in seen:
                        skipped_dedup += 1
                        continue
                    if since_dt is not None and turn.timestamp:
                        try:
                            ts = dt.datetime.fromisoformat(
                                turn.timestamp.replace("Z", "+00:00")
                            )
                            if ts < since_dt:
                                skipped_since += 1
                                continue
                        except ValueError:
                            pass  # keep — don't drop records over a bad timestamp
                    ledger.write(json.dumps(turn.to_dict()) + "\n")
                    seen.add(turn.turn_uuid)
                    added += 1
                    if turn.turn_uuid not in traces_seen:
                        tf.write(json.dumps(_emit_otel_span(turn)) + "\n")
                        # L1 completion: child spans per tool_use in
                        # the assistant record's content array.
                        for child in _emit_tool_use_child_spans(rec, turn):
                            if child["span_id"] and child["span_id"] not in traces_seen:
                                tf.write(json.dumps(child) + "\n")
                                traces_seen.add(child["span_id"])

    print(
        f"[telemetry] added {added} record(s); skipped {skipped_dedup} dedup, "
        f"{skipped_since} pre-since",
        file=sys.stderr,
    )
    print(f"[telemetry] ledger:  {telemetry_path}", file=sys.stderr)
    print(f"[telemetry] traces:  {traces_dir}/", file=sys.stderr)
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    project = Path(args.project).resolve()
    telemetry_path = project / ".pe" / "telemetry.jsonl"
    if not telemetry_path.exists():
        print(f"[telemetry] no ledger at {telemetry_path} — run `pe telemetry collect` first", file=sys.stderr)
        return 0

    since_dt: dt.datetime | None = None
    if args.since:
        try:
            since_dt = dt.datetime.fromisoformat(args.since).replace(tzinfo=dt.timezone.utc)
        except ValueError:
            print(f"ERROR: --since must be YYYY-MM-DD (got {args.since!r})", file=sys.stderr)
            return 2

    # Aggregate per-session per-model
    @dataclass
    class Agg:
        turns: int = 0
        input_tokens: int = 0
        output_tokens: int = 0
        cache_read_tokens: int = 0
        cache_creation_tokens: int = 0
        cost_cents: float = 0.0
        models: dict[str, int] = field(default_factory=dict)

    per_session: dict[str, Agg] = {}
    per_model: dict[str, Agg] = {}
    grand = Agg()

    for rec in _iter_transcript(telemetry_path):
        if since_dt is not None and rec.get("timestamp"):
            try:
                ts = dt.datetime.fromisoformat(
                    rec["timestamp"].replace("Z", "+00:00")
                )
                if ts < since_dt:
                    continue
            except ValueError:
                pass
        s = rec.get("session_id", "?")
        m = rec.get("model", "?")
        for agg in (per_session.setdefault(s, Agg()), per_model.setdefault(m, Agg()), grand):
            agg.turns += 1
            agg.input_tokens += rec.get("input_tokens", 0)
            agg.output_tokens += rec.get("output_tokens", 0)
            agg.cache_read_tokens += rec.get("cache_read_tokens", 0)
            agg.cache_creation_tokens += rec.get("cache_creation_tokens", 0)
            agg.cost_cents += rec.get("cost_cents", 0.0)
        per_session[s].models[m] = per_session[s].models.get(m, 0) + 1

    print(f"telemetry summary — {project}")
    if since_dt:
        print(f"  since: {since_dt.date()}")
    print()
    print("Per-model totals:")
    print(f"  {'model':<32} {'turns':>7} {'input':>12} {'output':>12} {'cost ($)':>10}")
    for m in sorted(per_model):
        a = per_model[m]
        print(
            f"  {m:<32} {a.turns:>7} {a.input_tokens:>12,} "
            f"{a.output_tokens:>12,} {a.cost_cents/100:>10.2f}"
        )
    print()
    print("Per-session (top 10 by cost):")
    ranked = sorted(per_session.items(), key=lambda x: x[1].cost_cents, reverse=True)[:10]
    print(f"  {'session':<40} {'turns':>7} {'cost ($)':>10}  models")
    for s, a in ranked:
        mods = ", ".join(f"{m}={n}" for m, n in sorted(a.models.items()))
        print(f"  {s:<40} {a.turns:>7} {a.cost_cents/100:>10.2f}  {mods}")
    print()
    print(
        f"Grand total: {grand.turns} turns  "
        f"{grand.input_tokens:,} input  {grand.output_tokens:,} output  "
        f"{grand.cache_read_tokens:,} cache-read  "
        f"${grand.cost_cents/100:.2f}"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="pe telemetry",
        description="Parse Claude Code transcripts into structured telemetry (A1/L1/L4).",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("collect", help="Scan transcripts + append to .pe/telemetry.jsonl + emit traces")
    c.add_argument("--project", default=".")
    c.add_argument("--since", default=None, help="ISO date YYYY-MM-DD (skip records earlier than this)")
    c.add_argument("--claude-home", default=None, help="Override Claude Code home (default: ~/.claude/projects)")
    c.set_defaults(func=cmd_collect)

    s = sub.add_parser("summary", help="Show per-session per-model totals + estimated cost")
    s.add_argument("--project", default=".")
    s.add_argument("--since", default=None)
    s.set_defaults(func=cmd_summary)

    return p


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
