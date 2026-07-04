#!/usr/bin/env python3
"""pe_recall — A7 cross-session agent memory (retrieval half).

`pe recall <query>` scans .pe/decisions.jsonl (and .pe/reconciliations.jsonl
when present) for slots whose signal tokens overlap the query.  Returns
the top-K matching slot summaries so an agent picking up a new slot can
see "this looks 40% similar to slot 1M.3; that approach hit worker_quality
FAIL then PASS in 2 iterations."

The retrieval is deliberately dep-free (stdlib only):

- Tokenization: alphanumeric + `.` / `-` / `_` runs, lowercased.
  Slot IDs like "1M.3", SHAs like "b6c566e", failure classes like
  "worker_quality", error names like "ImportError" all survive intact.
- Similarity: Jaccard over token multisets. `intersection / union`.
  Robust to query length and doesn't require embeddings — this is the
  right shape for structured decision records, not free text.
- Aggregation: multiple decisions for the same slot collapse into one
  trajectory summary (verdict order + iteration count + final outcome).

Contract with the agent that consumes this:

    pe recall <query>                    Human-readable summary (default)
    pe recall <query> --json             JSON payload for programmatic reads
    pe recall <query> --limit N          Top-N slots (default 5)
    pe recall <query> --project <path>   Scan a different project dir
    pe recall <query> --min-score S      Suppress matches under S (0..1)

Exit codes:
    0   at least one match
    1   no matches above the threshold
    2   corpus missing / usage error

The tool is READ-ONLY. It never writes to the decisions log — that's
the shadow-decide path's job.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


_SUBTOKEN_SEP_RE = re.compile(r"[._-]+")


def _tokenize(text: str) -> list[str]:
    """Alphanumeric-plus-punctuation-preserving tokenizer.

    Keeps slot IDs (`1M.3`), SHAs (`b6c566e`), snake_case (`worker_quality`),
    dotted paths (`modules.billing.money`) as atomic tokens so exact-token
    queries land — AND ALSO emits sub-tokens split on `.`, `_`, `-` so that
    `placeholder` matches a rule named `sql-placeholder-style`. Both
    representations coexist in the token set; scoring against `all_tokens`
    picks up whichever the query supplies.

    Lowercases everything so `WorkerQuality` matches `worker_quality`.
    """
    tokens: list[str] = []
    for atomic in TOKEN_RE.findall(text or ""):
        low = atomic.lower()
        tokens.append(low)
        # Emit sub-tokens only when a punctuation separator is present.
        # Length-1 sub-tokens are noise (a bare digit or letter fragment)
        # and would flood the token set — skip them.
        if _SUBTOKEN_SEP_RE.search(low):
            for sub in _SUBTOKEN_SEP_RE.split(low):
                if len(sub) > 1:
                    tokens.append(sub)
    return tokens


@dataclass
class SlotSummary:
    slot_id: str
    slot_kind: str | None
    decision_count: int = 0
    verdict_trajectory: list[str] = field(default_factory=list)
    gate_names: set[str] = field(default_factory=set)
    failure_classes: set[str] = field(default_factory=set)
    routers_seen: set[str] = field(default_factory=set)
    reconciliation_outcome: str | None = None
    reconciliation_notes: str | None = None
    all_tokens: set[str] = field(default_factory=set)
    first_ts: str | None = None
    last_ts: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "slot_id": self.slot_id,
            "slot_kind": self.slot_kind,
            "iterations": self.decision_count,
            "verdict_trajectory": self.verdict_trajectory,
            "gate_names": sorted(self.gate_names),
            "failure_classes": sorted(self.failure_classes),
            "router_actions": sorted(self.routers_seen),
            "reconciliation_outcome": self.reconciliation_outcome,
            "reconciliation_notes": self.reconciliation_notes,
            "first_seen": self.first_ts,
            "last_seen": self.last_ts,
        }


def _iter_jsonl(path: Path) -> Iterable[dict[str, Any]]:
    if not path.exists():
        return
    with path.open(encoding="utf-8") as f:
        for lineno, raw in enumerate(f, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                yield json.loads(raw)
            except json.JSONDecodeError as exc:
                # A single bad row shouldn't blind the whole recall,
                # but silent skips would hide real data loss from the
                # operator. Warn on stderr so `pe recall … 2>&1` shows
                # the drop while stdout stays parseable for --json.
                preview = raw[:80].replace("\n", " ")
                print(
                    f"pe recall: WARNING skipped malformed line "
                    f"{path}:{lineno} ({exc.msg}): {preview}…",
                    file=sys.stderr,
                )
                continue


def _collect_decision_tokens(rec: dict[str, Any]) -> list[str]:
    """Extract signal tokens from one decision record.

    Concatenates the load-bearing fields (slot_id, gate_name,
    envelope.failure_class, envelope.verdict, router action + rule).
    Also pulls `notes`, envelope.summary, and finding metadata
    (rule / file / message + suggestion capped) — the semantic signal
    operators actually query for lives inside findings[], not just the
    verdict metadata. Bodies can be long, so we cap per-field.
    """
    parts: list[str] = []
    for key in ("slot_id", "slot_kind", "gate_name"):
        v = rec.get(key)
        if isinstance(v, str):
            parts.append(v)
    env = rec.get("envelope") or {}
    if isinstance(env, dict):
        for key in ("verdict", "failure_class"):
            v = env.get(key)
            if isinstance(v, str):
                parts.append(v)
        # Notes / summary / short-strings — cap per field. The summary
        # is the reviewer's one-line synthesis; usually the highest-
        # signal-per-token in the whole envelope.
        for key in ("notes", "model_used", "gate_name", "summary"):
            v = env.get(key)
            if isinstance(v, str):
                parts.append(v[:400])
        # Findings — the actual semantic content operators search for.
        # Cap at first 20 findings + first 200 chars per message so a
        # runaway envelope can't blow the token set.
        findings = env.get("findings")
        if isinstance(findings, list):
            for f in findings[:20]:
                if not isinstance(f, dict):
                    continue
                for k in ("severity", "rule", "file"):
                    v = f.get(k)
                    if isinstance(v, str):
                        parts.append(v)
                for k in ("message", "suggestion"):
                    v = f.get(k)
                    if isinstance(v, str):
                        parts.append(v[:200])
    router = rec.get("router_decision") or {}
    if isinstance(router, dict):
        for key in ("action", "rule_matched", "rule_source"):
            v = router.get(key)
            if isinstance(v, str):
                parts.append(v)
    tokens: list[str] = []
    for p in parts:
        tokens.extend(_tokenize(p))
    return tokens


def _apply_decision(summary: SlotSummary, rec: dict[str, Any]) -> None:
    summary.decision_count += 1
    ts = rec.get("ts")
    if isinstance(ts, str):
        if summary.first_ts is None or ts < summary.first_ts:
            summary.first_ts = ts
        if summary.last_ts is None or ts > summary.last_ts:
            summary.last_ts = ts
    env = rec.get("envelope") or {}
    if isinstance(env, dict):
        v = env.get("verdict")
        if isinstance(v, str):
            summary.verdict_trajectory.append(v)
        fc = env.get("failure_class")
        if isinstance(fc, str):
            summary.failure_classes.add(fc)
    gate = rec.get("gate_name")
    if isinstance(gate, str):
        summary.gate_names.add(gate)
    router = rec.get("router_decision") or {}
    if isinstance(router, dict):
        a = router.get("action")
        if isinstance(a, str):
            summary.routers_seen.add(a)
    for t in _collect_decision_tokens(rec):
        summary.all_tokens.add(t)


def _apply_reconciliation(summary: SlotSummary, rec: dict[str, Any]) -> None:
    outcome = rec.get("actual_outcome") or rec.get("outcome")
    if isinstance(outcome, str):
        summary.reconciliation_outcome = outcome
    notes = rec.get("correctness_notes") or rec.get("notes")
    if isinstance(notes, str):
        summary.reconciliation_notes = notes[:400]
    for t in _tokenize(str(outcome or "") + " " + str(notes or "")):
        summary.all_tokens.add(t)


def load_corpus(project_root: Path) -> dict[str, SlotSummary]:
    """Return {slot_id: SlotSummary}."""
    dec_path = project_root / ".pe" / "decisions.jsonl"
    rec_path = project_root / ".pe" / "reconciliations.jsonl"
    slots: dict[str, SlotSummary] = {}

    for rec in _iter_jsonl(dec_path):
        slot_id = rec.get("slot_id")
        if not isinstance(slot_id, str) or not slot_id:
            continue
        s = slots.get(slot_id)
        if s is None:
            s = SlotSummary(slot_id=slot_id, slot_kind=rec.get("slot_kind"))
            slots[slot_id] = s
        _apply_decision(s, rec)

    for rec in _iter_jsonl(rec_path):
        slot_id = rec.get("slot_id")
        if not isinstance(slot_id, str):
            continue
        s = slots.get(slot_id)
        if s is None:
            # Reconciliation without a matching decision — rare, but
            # keep the record so pattern retrieval still surfaces it.
            s = SlotSummary(slot_id=slot_id, slot_kind=None)
            slots[slot_id] = s
        _apply_reconciliation(s, rec)

    return slots


def _jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    inter = len(a & b)
    if inter == 0:
        return 0.0
    return inter / len(a | b)


def _coverage(query_tokens: set[str], slot_tokens: set[str]) -> float:
    """Fraction of the query tokens that appear in the slot's token set.

    Coverage answers the operator's actual question — "how many of MY
    query terms did this slot mention?" — better than Jaccard, which
    penalises small queries against large slots. Jaccard on a 1-token
    query vs a 359-token slot maxes out at 1/359 ≈ 0.003, dropping every
    real match below the default min_score threshold. Coverage is 1.0 in
    that same case: the single query token is fully covered.
    """
    if not query_tokens:
        return 0.0
    return len(query_tokens & slot_tokens) / len(query_tokens)


def rank(
    slots: dict[str, SlotSummary],
    query: str,
    limit: int,
    min_score: float,
) -> list[tuple[SlotSummary, float]]:
    """Score each slot by query-coverage, tie-break by Jaccard, then by recency.

    Score is coverage (fraction of query tokens found in the slot).
    Jaccard is used only to break ties among slots with equal coverage —
    a smaller, more focused slot beats a large catch-all when both cover
    the query equally.
    """
    query_tokens = set(_tokenize(query))
    if not query_tokens:
        return []
    scored: list[tuple[SlotSummary, float, float]] = []
    for slot in slots.values():
        cov = _coverage(query_tokens, slot.all_tokens)
        if cov < min_score:
            continue
        tie = _jaccard(query_tokens, slot.all_tokens)
        scored.append((slot, cov, tie))
    scored.sort(
        key=lambda triple: (
            -triple[1],
            -triple[2],
            triple[0].last_ts or "",
            triple[0].slot_id,
        )
    )
    return [(s, cov) for s, cov, _tie in scored[:limit]]


def _format_trajectory(trajectory: list[str]) -> str:
    if not trajectory:
        return "(no verdicts)"
    # Collapse PASS-runs to "PASS×3" style, keeping switches visible.
    out: list[str] = []
    prev = None
    run = 0
    for v in trajectory:
        if v == prev:
            run += 1
            continue
        if prev is not None:
            out.append(f"{prev}" if run == 1 else f"{prev}×{run}")
        prev = v
        run = 1
    if prev is not None:
        out.append(f"{prev}" if run == 1 else f"{prev}×{run}")
    return " → ".join(out)


def _human_report(hits: list[tuple[SlotSummary, float]], query: str) -> None:
    if not hits:
        print(f"pe recall — no matches for '{query}'.")
        return
    print(f"pe recall — top {len(hits)} match(es) for '{query}':")
    print("")
    for slot, score in hits:
        pct = f"{score * 100:.0f}%"
        print(f"  {slot.slot_id} ({pct} similar)")
        if slot.slot_kind:
            print(f"      kind: {slot.slot_kind}")
        print(f"      iterations: {slot.decision_count}")
        print(f"      trajectory: {_format_trajectory(slot.verdict_trajectory)}")
        if slot.failure_classes:
            print(f"      failure classes: {', '.join(sorted(slot.failure_classes))}")
        if slot.routers_seen:
            print(f"      router actions: {', '.join(sorted(slot.routers_seen))}")
        if slot.reconciliation_outcome:
            print(f"      reconciled outcome: {slot.reconciliation_outcome}")
        if slot.reconciliation_notes:
            print(f"      notes: {slot.reconciliation_notes}")
        print("")


def _json_report(hits: list[tuple[SlotSummary, float]], query: str) -> None:
    payload = {
        "query": query,
        "match_count": len(hits),
        "matches": [
            {"score": round(score, 4), **slot.to_dict()}
            for slot, score in hits
        ],
    }
    print(json.dumps(payload, indent=2))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="pe recall")
    parser.add_argument("query", nargs="+", help="signal tokens / pattern to look for")
    parser.add_argument(
        "--project",
        default=".",
        help="project root (defaults to cwd). Reads .pe/decisions.jsonl.",
    )
    parser.add_argument("--limit", type=int, default=5, help="max matches (default 5)")
    parser.add_argument(
        "--min-score",
        type=float,
        default=0.01,
        help="suppress matches below this Jaccard score (0..1, default 0.01)",
    )
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args(argv)

    project_root = Path(args.project).resolve()
    if not project_root.is_dir():
        print(f"ERROR: project root not found: {project_root}", file=sys.stderr)
        return 2

    slots = load_corpus(project_root)
    if not slots:
        print(
            f"pe recall — no decisions corpus at {project_root}/.pe/decisions.jsonl. "
            "Nothing to recall until shadow-decide starts logging.",
            file=sys.stderr,
        )
        return 1

    query = " ".join(args.query)
    hits = rank(slots, query, limit=args.limit, min_score=args.min_score)

    if args.json:
        _json_report(hits, query)
    else:
        _human_report(hits, query)

    return 0 if hits else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
