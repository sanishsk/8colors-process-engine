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

# Fallback for an unpriced model. The comment here used to read "0 cost —
# surfaces the miss", and nothing surfaced anything: `pe telemetry summary`
# printed $0.00 beside 1390 turns of claude-opus-5 with no warning, so the
# most expensive model in the ledger read as free. A price table that silently
# returns zero is worse than no price table, because a zero looks like an
# answer. cmd_summary now names every unpriced model and its turn count.
#
# Prices are NOT guessed here. A wrong number is indistinguishable from a
# right one at a glance, and this feeds budget decisions. Add the real
# per-Mtoken cents from the pricing page, or set them per project under
# `telemetry.prices.<model-prefix>` in .process-engine.yaml.
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


def _parse_since(value: str | None) -> tuple[dt.datetime | None, int]:
    """(cutoff, exit_code). exit_code is 2 when the flag was malformed."""
    if not value:
        return None, 0
    try:
        return dt.datetime.fromisoformat(value).replace(tzinfo=dt.timezone.utc), 0
    except ValueError:
        print(f"ERROR: --since must be YYYY-MM-DD (got {value!r})", file=sys.stderr)
        return None, 2


def _before_cutoff(timestamp: str | None, cutoff: dt.datetime | None) -> bool:
    if cutoff is None or not timestamp:
        return False
    try:
        return dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00")) < cutoff
    except ValueError:
        # Keep the record — a bad timestamp is not a reason to drop usage data.
        return False


def _existing_span_ids(trace_path: Path) -> set[str]:
    if not trace_path.exists():
        return set()
    return {
        span["span_id"]
        for span in _iter_transcript(trace_path)
        if span.get("span_id")
    }


def _collect_one_transcript(
    tp: Path, traces_dir: Path, ledger, seen: set[str],
    cutoff: dt.datetime | None,
) -> tuple[int, int, int]:
    """Append one transcript's new turns. Returns (added, dedup, pre_since)."""
    trace_path = traces_dir / f"{tp.stem}.jsonl"
    traces_seen = _existing_span_ids(trace_path)
    added = dedup = pre_since = 0

    with trace_path.open("a", encoding="utf-8") as tf:
        for rec in _iter_transcript(tp):
            turn = parse_assistant_record(rec)
            if turn is None:
                continue
            if turn.turn_uuid in seen:
                dedup += 1
                continue
            if _before_cutoff(turn.timestamp, cutoff):
                pre_since += 1
                continue
            ledger.write(json.dumps(turn.to_dict()) + "\n")
            seen.add(turn.turn_uuid)
            added += 1
            if turn.turn_uuid not in traces_seen:
                tf.write(json.dumps(_emit_otel_span(turn)) + "\n")
                # L1 completion: child spans per tool_use in the record.
                for child in _emit_tool_use_child_spans(rec, turn):
                    if child["span_id"] and child["span_id"] not in traces_seen:
                        tf.write(json.dumps(child) + "\n")
                        traces_seen.add(child["span_id"])
    return added, dedup, pre_since


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

    cutoff, rc = _parse_since(args.since)
    if rc:
        return rc

    pe_dir = project / ".pe"
    pe_dir.mkdir(exist_ok=True)
    telemetry_path = pe_dir / "telemetry.jsonl"
    traces_dir = pe_dir / "traces"
    traces_dir.mkdir(exist_ok=True)

    seen = _load_seen_uuids(telemetry_path)
    added = dedup = pre_since = 0
    with telemetry_path.open("a", encoding="utf-8") as ledger:
        for tp in sorted(transcript_dir.glob("*.jsonl")):
            a, d, s = _collect_one_transcript(tp, traces_dir, ledger, seen, cutoff)
            added += a; dedup += d; pre_since += s

    print(
        f"[telemetry] added {added} record(s); skipped {dedup} dedup, "
        f"{pre_since} pre-since",
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

    since_dt, rc = _parse_since(args.since)
    if rc:
        return rc

    per_session: dict[str, Agg] = {}
    per_model: dict[str, Agg] = {}
    grand = Agg()

    for rec in _iter_transcript(telemetry_path):
        if _before_cutoff(rec.get("timestamp"), since_dt):
            continue
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
    _print_per_model(per_model)
    _print_per_session(per_session)
    print(
        f"Grand total: {grand.turns} turns  "
        f"{grand.input_tokens:,} input  {grand.output_tokens:,} output  "
        f"{grand.cache_read_tokens:,} cache-read  "
        f"${grand.cost_cents/100:.2f}"
    )
    _print_where_the_tokens_went(grand)
    return 0


@dataclass
class Agg:
    """Token + cost totals for one slice of the ledger."""
    turns: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_creation_tokens: int = 0
    cost_cents: float = 0.0
    models: dict[str, int] = field(default_factory=dict)


def _print_per_session(per_session: dict) -> None:
    print("Per-session (top 10 by cost):")
    ranked = sorted(
        per_session.items(), key=lambda kv: kv[1].cost_cents, reverse=True
    )[:10]
    print(f"  {'session':<40} {'turns':>7} {'cost ($)':>10}  models")
    for session_id, agg in ranked:
        mods = ", ".join(f"{m}={n}" for m, n in sorted(agg.models.items()))
        print(f"  {session_id:<40} {agg.turns:>7} {agg.cost_cents/100:>10.2f}  {mods}")
    print()


def _print_per_model(per_model: dict) -> None:
    """Per-model totals, including the cache columns.

    cache-read and cache-creation were computed and then not printed, so the
    table showed input and output — 88 and 968 tokens per turn on the ledger
    this was written against — and hid the 356,681 tokens per turn of context
    replay that is the actual bill. You cannot reduce what the tool built to
    show you cost does not show.
    """
    print("Per-model totals:")
    print(
        f"  {'model':<26} {'turns':>6} {'input':>10} {'output':>11} "
        f"{'cache-read':>14} {'cache-write':>12} {'cost ($)':>9}"
    )
    unpriced = []
    for m in sorted(per_model):
        a = per_model[m]
        flag = ""
        if a.cost_cents == 0 and (a.output_tokens or a.cache_read_tokens):
            unpriced.append((m, a.turns))
            flag = " *"
        print(
            f"  {m:<26} {a.turns:>6} {a.input_tokens:>10,} "
            f"{a.output_tokens:>11,} {a.cache_read_tokens:>14,} "
            f"{a.cache_creation_tokens:>12,} {a.cost_cents/100:>9.2f}{flag}"
        )
    if unpriced:
        print()
        print("  * NOT $0 — UNPRICED. These models are missing from")
        print("    CENTS_PER_MTOKEN in scripts/telemetry.py, so their cost is")
        print("    reported as zero and the totals below UNDERSTATE the bill:")
        for m, turns in unpriced:
            print(f"      {m}  ({turns:,} turns)")
    print()


def _print_where_the_tokens_went(grand) -> None:
    """The breakdown that says which lever is worth pulling.

    Input-side tokens are billed at different rates — a cache read costs about
    a tenth of a fresh read, a cache write about a quarter more — so raw token
    counts rank the levers wrongly. These weights are the published ratios,
    not prices, and hold regardless of which model ran.
    """
    if not grand.turns:
        return
    read_w, write_w = 0.10, 1.25
    weighted = {
        "context replayed (cache read)": grand.cache_read_tokens * read_w,
        "context written (cache create)": grand.cache_creation_tokens * write_w,
        "new input": float(grand.input_tokens),
        "output (what was generated)": float(grand.output_tokens),
    }
    total = sum(weighted.values()) or 1.0
    print()
    print("Where the tokens go (input-side weighted to billing ratios):")
    for label, value in sorted(weighted.items(), key=lambda kv: -kv[1]):
        print(f"  {label:<32} {value/total:>6.1%}   {value:>14,.0f} tok-equivalent")
    print()
    print(f"  Per turn, averaged over {grand.turns:,} turns:")
    print(f"    context replayed  {grand.cache_read_tokens/grand.turns:>10,.0f} tokens")
    print(f"    generated         {grand.output_tokens/grand.turns:>10,.0f} tokens")
    print()
    print("  Generation is the small number. Writing terser code cuts the")
    print("  bottom row; cutting what is re-read every turn cuts the top one.")
    print("  `pe telemetry context` inventories what that prefix is made of.")


# ─── context cost (T1, v0.52.0) ──────────────────────────────────────────
#
# The measurement that motivates this command: on a 2,231-turn ledger,
# 356,681 tokens of context were replayed per turn against 968 generated.
# Context replay plus cache writes was 97.8% of input-side billed-equivalent
# tokens; generation was 2.0%. Any effort spent writing terser code is
# working on the 2%.
#
# Not all context is equal, and the difference decides where effort pays:
#
#   PER TURN   CLAUDE.md and the rules files it pulls in are re-read on
#              every single turn of every session. One kilobyte cut here is
#              cut thousands of times.
#   ON DEMAND  agents/, commands/ and skills/ load only when invoked.
#              Trimming a 6 KB agent saves 6 KB on the turns that spawn it
#              and nothing on the rest — worth doing, worth not confusing
#              with the row above.
#
# Bytes-per-token is an estimate (~4 for English prose and markdown). It is
# labelled as one everywhere it is printed, because a made-up precise number
# is worse than an honest approximate one.
CHARS_PER_TOKEN = 4

# hooks/claude-md-size.sh's own thresholds, so one number does not drift
# from the other.
CLAUDE_MD_WARN_BYTES = 12_000
CLAUDE_MD_FAIL_BYTES = 20_000


def _md_files(root: Path, *globs: str) -> list[tuple[Path, int]]:
    out: list[tuple[Path, int]] = []
    for pattern in globs:
        for path in sorted(root.glob(pattern)):
            if path.is_file():
                try:
                    out.append((path, path.stat().st_size))
                except OSError:
                    continue
    return out


def _per_turn_prefix(project: Path, home: Path) -> list[tuple[Path, int]]:
    """Files re-read on every turn: the CLAUDE.md chain and its rules."""
    found = _md_files(project, "CLAUDE.md", ".claude/CLAUDE.md")
    found += _md_files(project, ".claude/rules/*.md", ".claude/rules/**/*.md")
    found += _md_files(home, "CLAUDE.md")
    found += _md_files(home, "rules/*.md", "rules/**/*.md")
    seen: set[Path] = set()
    unique = []
    for path, size in found:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        unique.append((path, size))
    return sorted(unique, key=lambda ps: -ps[1])


def _on_demand(project: Path) -> list[tuple[str, int, int]]:
    """(label, file count, total bytes) for context loaded only when used."""
    groups = [
        ("agents", (".claude/agents/*.md",)),
        ("commands", (".claude/commands/*.md",)),
        ("skills", (".claude/skills/*/SKILL.md",)),
        ("workflows", (".claude/workflows/*.js",)),
    ]
    out = []
    for label, globs in groups:
        files = _md_files(project, *globs)
        if files:
            out.append((label, len(files), sum(size for _, size in files)))
    return out


def _ledger_turns(project: Path) -> tuple[int, int]:
    """(turns, total cache-read tokens) from this project's ledger."""
    path = project / ".pe" / "telemetry.jsonl"
    if not path.exists():
        return 0, 0
    turns = replayed = 0
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        turns += 1
        replayed += rec.get("cache_read_tokens", 0) or 0
    return turns, replayed


def _print_replay_reconciliation(prefix_tokens: int, turns: int, replayed: int) -> None:
    """Set the file inventory against what was actually re-read.

    This is the part that stops the command being misleading. On the ledger
    it was written against the CLAUDE.md chain came to ~7,187 tokens per turn
    while measured replay was ~356,681 — so those files are 2% of what is
    re-read, and trimming them cannot be the answer to a context bill.

    The remaining 98% is the conversation itself plus the system prompt and
    tool definitions: every turn re-reads every previous turn, so cost grows
    with the square of session length. That is not a file anyone can trim.
    It is a reason to finish work in shorter sessions, compact earlier, and
    push bounded work into subagents whose context does not accumulate into
    the main thread.
    """
    if not turns or not replayed:
        return
    per_turn = replayed / turns
    share = (prefix_tokens / per_turn) if per_turn else 0
    print()
    print("MEASURED — what was actually re-read, from .pe/telemetry.jsonl")
    print(f"  {per_turn:>12,.0f} tok/turn replayed (mean over {turns:,} turns)")
    print(f"  {prefix_tokens:>12,} tok/turn of that is the files listed above "
          f"({share:.1%})")
    print(f"  {per_turn - prefix_tokens:>12,.0f} tok/turn is conversation history, "
          "the system prompt and tool definitions")
    if share < 0.25:
        print()
        print("  The files are the small share. The rest grows with the")
        print("  conversation — every turn re-reads every previous turn — so it")
        print("  is not trimmed by editing anything. Shorter sessions, earlier")
        print("  compaction, and pushing bounded work into subagents (whose")
        print("  context does not accumulate here) move this number; terser")
        print("  prose in CLAUDE.md does not.")


def _print_prefix_inventory(prefix: list, prefix_bytes: int, project: Path) -> None:
    print("PER TURN — re-read on every turn of every session")
    if not prefix:
        print("  (no CLAUDE.md or rules files found)")
    for path, size in prefix:
        try:
            shown = path.relative_to(project)
        except ValueError:
            shown = path
        print(f"  {size/1024:>8.1f} KB  ~{size//CHARS_PER_TOKEN:>7,} tok  {shown}")
    print(f"  {'─'*8}")
    print(
        f"  {prefix_bytes/1024:>8.1f} KB  ~{prefix_bytes//CHARS_PER_TOKEN:>7,} tok  "
        "TOTAL, every turn"
    )


def _warn_oversized_claude_md(prefix: list) -> None:
    """Same thresholds as hooks/claude-md-size.sh, so the two cannot drift."""
    over = [(p, sz) for p, sz in prefix
            if p.name == "CLAUDE.md" and sz > CLAUDE_MD_WARN_BYTES]
    if not over:
        return
    print()
    for path, size in over:
        verdict = "OVER HARD LIMIT" if size > CLAUDE_MD_FAIL_BYTES else "over WARN"
        print(
            f"  ! {path}: {size/1024:.1f} KB — {verdict} "
            f"({CLAUDE_MD_WARN_BYTES//1000}/{CLAUDE_MD_FAIL_BYTES//1000} KB, "
            "hooks/claude-md-size.sh)"
        )


def cmd_context(args: argparse.Namespace) -> int:
    """Inventory the context that is paid for, ranked by what it costs."""
    project = Path(args.project).resolve()
    home = Path(args.claude_home).expanduser() if args.claude_home else Path.home() / ".claude"

    prefix = _per_turn_prefix(project, home)
    prefix_bytes = sum(size for _, size in prefix)
    turns, replayed = _ledger_turns(project)

    print(f"context cost — {project}")
    print()
    _print_prefix_inventory(prefix, prefix_bytes, project)
    if turns:
        cumulative = (prefix_bytes // CHARS_PER_TOKEN) * turns
        print(
            f"\n  Over the {turns:,} turns in this project's ledger that is "
            f"~{cumulative:,} tokens\n  of prefix alone, re-read."
        )
    _print_replay_reconciliation(prefix_bytes // CHARS_PER_TOKEN, turns, replayed)

    _warn_oversized_claude_md(prefix)

    print()
    print("ON DEMAND — loaded only when invoked, not part of the per-turn prefix")
    demand = _on_demand(project)
    if not demand:
        print("  (none installed here)")
    for label, count, size in demand:
        print(f"  {size/1024:>8.1f} KB  ~{size//CHARS_PER_TOKEN:>7,} tok  "
              f"{label} ({count} file{'s' if count != 1 else ''})")
    print()
    print("File token counts are estimates at ~4 chars/token; the MEASURED")
    print("block above is exact, read from the ledger.")
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

    x = sub.add_parser(
        "context",
        help="Inventory the context paid for per turn vs on demand",
    )
    x.add_argument("--project", default=".")
    x.add_argument("--claude-home", default=None,
                   help="Override Claude Code home (default: ~/.claude)")
    x.set_defaults(func=cmd_context)

    return p


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
