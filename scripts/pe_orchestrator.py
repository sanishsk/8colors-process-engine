#!/usr/bin/env python3
"""
pe_orchestrator.py — Phase 3 shadow-mode router + breaker.

Reads an E1 gate envelope (file or stdin), consults the routing
policy + breaker policy, and emits a SHADOW DECISION to
.pe/decisions.jsonl. Does NOT enforce; the actual worker / human
pipeline continues as today.

Invoked via `pe shadow decide` and `pe shadow reconcile`.

Stdlib only. Python 3.11+ (tomllib).

See docs/PHASE_3_ESCALATION_ROUTER.md for the design and the
graduation criteria. This file is the runtime; that doc is the
contract.

Exit codes:
  0  decision recorded successfully (action may be any of escalate /
     halt / continue — exit 0 means "the recording succeeded")
  2  CLI usage error
  4  envelope parse or policy load error
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tomllib
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ENGINE_DIR = Path(__file__).resolve().parent.parent
DEFAULT_ROUTING_POLICY = ENGINE_DIR / "policy" / "failure_class_routing.toml"
DEFAULT_BREAKER_POLICY = ENGINE_DIR / "policy" / "circuit_breaker.toml"

# `pe gate parse` exit codes — see scripts/pe_gate.py.
GATE_EXIT_PASS = 0
GATE_EXIT_FAIL_ESCALATABLE = 1
GATE_EXIT_FAIL_NON_ESCALATABLE = 2
GATE_EXIT_WARN = 3
GATE_EXIT_SCHEMA_ERROR = 4


# ─── data classes ──────────────────────────────────────────────────────────


@dataclass
class RouterDecision:
    action: str  # "escalate_one_tier" | "halt_to_human" | "continue"
    from_tier: str | None
    to_tier: str | None
    rule_matched: str
    rule_source: str  # which policy file + version
    notes: str | None = None


@dataclass
class BreakerState:
    slot_iterations_used: int
    slot_iteration_cap: int
    worker_tokens_cumulative: int | None
    gate_tokens_cumulative: int | None
    cumulative_worker_budget: str | int  # may be "inf" pre-E2.1
    cumulative_gate_budget: str | int
    breaker_would_trip: bool
    trip_reason: str | None


@dataclass
class ShadowDecisionRecord:
    decision_id: str
    ts: str
    slot_id: str
    slot_kind: str | None
    iteration: int
    gate_name: str
    envelope: dict[str, Any]
    router_decision: dict[str, Any]
    breaker_state_at_decision: dict[str, Any]
    enforced: bool = False


# ─── policy loading ────────────────────────────────────────────────────────


def load_policy(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"policy file not found: {path}")
    with path.open("rb") as f:
        return tomllib.load(f)


# ─── envelope ingestion ────────────────────────────────────────────────────


def parse_envelope_via_pe_gate(
    envelope_path: Path, bare: bool = False
) -> tuple[int, dict[str, Any] | None, str]:
    """
    Invoke `pe gate parse` on the envelope path. Returns
    (exit_code, parsed_envelope_dict_or_None, raw_stdout).

    Why subprocess instead of importing pe_gate: the orchestrator must
    not couple to pe_gate's internal API. The CLI contract (E1.d) is
    the stable surface.

    Default mode is transcript (E1.d-enforced cross-check). `--bare`
    is for fixture testing only; real-agent emissions go through the
    transcript path.
    """
    pe_gate = ENGINE_DIR / "scripts" / "pe_gate.py"
    cmd = ["python3", str(pe_gate)]
    if bare:
        cmd.append("--bare")
    cmd.append(str(envelope_path))
    proc = subprocess.run(cmd, capture_output=True, text=True)
    parsed: dict[str, Any] | None = None
    # pe_gate writes the parsed JSON to stdout in all modes where a
    # parse succeeded; exit 4 means the envelope failed schema or
    # cross-check validation (E1.d).
    try:
        parsed = json.loads(proc.stdout)
    except json.JSONDecodeError:
        parsed = None
    return proc.returncode, parsed, proc.stdout


# ─── routing ───────────────────────────────────────────────────────────────


def route(
    envelope: dict[str, Any],
    gate_exit_code: int,
    current_worker_tier: str,
    routing_policy: dict[str, Any],
) -> RouterDecision:
    """Pure function: envelope + tier + policy → decision."""
    ladder = routing_policy["ladder"]["tiers"]
    rules = routing_policy["rules"]
    terminal_rules = routing_policy.get("terminal_rules", {})
    confidence_cfg = routing_policy.get("confidence_override", {})
    schema_error_cfg = routing_policy.get("schema_error", {"action": "halt_to_human"})
    unknown_cfg = routing_policy.get("unknown", {"action": "halt_to_human"})
    policy_version = routing_policy.get("policy_version", "?")

    rule_source = f"policy/failure_class_routing.toml v{policy_version}"

    # 1. Schema-error short-circuit (envelope unusable).
    if gate_exit_code == GATE_EXIT_SCHEMA_ERROR or envelope is None:
        return RouterDecision(
            action=schema_error_cfg["action"],
            from_tier=current_worker_tier,
            to_tier=None,
            rule_matched="schema_error",
            rule_source=rule_source,
            notes="`pe gate parse` exit 4 — envelope failed schema validation",
        )

    failure_class = envelope.get("failure_class", "none")
    verdict = envelope.get("verdict", "FAIL")
    confidence = envelope.get("confidence")

    # 2. Confidence override fires *before* failure_class on any
    # verdict — the whole point is "I don't trust this gate's read,
    # bring in a human."
    threshold = confidence_cfg.get("threshold")
    if (
        threshold is not None
        and confidence is not None
        and confidence < threshold
    ):
        return RouterDecision(
            action=confidence_cfg.get(
                "action_below_threshold", "halt_to_human"
            ),
            from_tier=current_worker_tier,
            to_tier=None,
            rule_matched=f"confidence_below_{threshold}",
            rule_source=rule_source,
            notes=f"envelope confidence={confidence} < {threshold}",
        )

    # 2.5. Severity-override — verdict-blind severity floor. Fires
    # BEFORE PASS/WARN→continue so a WARN-with-HIGH-findings envelope
    # halts rather than silently advancing. Mirrors the consumer
    # project's commit policy (HIGH = address-or-skip-documented).
    # Added 2026-06-26 after slot 1M.3.224b surfaced the gap on real
    # shadow data — see policy receipt + brief §10.2.
    severity_cfg = routing_policy.get("severity_override", {})
    block_severities = set(severity_cfg.get("block_severities", []))
    if block_severities and verdict in ("PASS", "WARN"):
        findings = envelope.get("findings") or []
        blocking = [
            f for f in findings
            if isinstance(f, dict) and f.get("severity") in block_severities
        ]
        if blocking:
            blocking_sevs = sorted({f.get("severity") for f in blocking})
            return RouterDecision(
                action=severity_cfg.get("action_on_match", "halt_to_human"),
                from_tier=current_worker_tier,
                to_tier=None,
                rule_matched=(
                    f"severity_floor:{','.join(blocking_sevs)}"
                ),
                rule_source=rule_source,
                notes=(
                    f"verdict={verdict} but {len(blocking)} finding(s) at "
                    f"blocking severity ({','.join(blocking_sevs)})"
                ),
            )

    # 3. PASS / WARN → continue.
    if verdict in ("PASS", "WARN"):
        return RouterDecision(
            action="continue",
            from_tier=current_worker_tier,
            to_tier=current_worker_tier,
            rule_matched="none",
            rule_source=rule_source,
            notes=f"verdict={verdict}",
        )

    # 4. FAIL — look up the failure_class.
    action = rules.get(failure_class)
    if action is None:
        return RouterDecision(
            action=unknown_cfg["action"],
            from_tier=current_worker_tier,
            to_tier=None,
            rule_matched=f"unknown:{failure_class}",
            rule_source=rule_source,
            notes=f"failure_class={failure_class!r} not in policy",
        )

    # 5. Terminal-tier rule: top-tier worker_quality has nowhere to
    # escalate. Caught HERE in the policy layer, not by the breaker.
    if action == "escalate_one_tier":
        try:
            idx = ladder.index(current_worker_tier)
        except ValueError:
            return RouterDecision(
                action="halt_to_human",
                from_tier=current_worker_tier,
                to_tier=None,
                rule_matched=f"unknown_tier:{current_worker_tier}",
                rule_source=rule_source,
                notes=(
                    f"current_worker_tier={current_worker_tier!r} not in "
                    f"ladder {ladder!r}"
                ),
            )

        if idx >= len(ladder) - 1:
            terminal_action = terminal_rules.get(
                "top_tier_worker_quality", "halt_to_human"
            )
            return RouterDecision(
                action=terminal_action,
                from_tier=current_worker_tier,
                to_tier=None,
                rule_matched="top_tier_worker_quality",
                rule_source=rule_source,
                notes=(
                    f"already at top tier ({current_worker_tier}); "
                    "ladder exhausted — terminal halt"
                ),
            )

        return RouterDecision(
            action="escalate_one_tier",
            from_tier=current_worker_tier,
            to_tier=ladder[idx + 1],
            rule_matched=f"{failure_class} -> escalate_one_tier",
            rule_source=rule_source,
        )

    # 6. Halt — straight through.
    return RouterDecision(
        action=action,
        from_tier=current_worker_tier,
        to_tier=None,
        rule_matched=f"{failure_class} -> {action}",
        rule_source=rule_source,
    )


# ─── circuit breaker (shadow accounting) ───────────────────────────────────


def compute_breaker_state(
    iteration: int,
    slot_kind: str | None,
    envelope: dict[str, Any] | None,
    breaker_policy: dict[str, Any],
    cumulative_state_path: Path,
) -> BreakerState:
    """
    Compute the would-trip state. Does not write enforcement.
    Cumulative state is read from a sidecar JSON to keep the
    accounting honest across slots in a campaign.
    """
    per_slot = breaker_policy["per_slot"]
    cumulative = breaker_policy["cumulative"]

    slot_cap = per_slot["slot_iteration_cap"]
    overrides = per_slot.get("overrides", {})
    if slot_kind and slot_kind in overrides:
        slot_cap = overrides[slot_kind]

    # Read cumulative token totals (sidecar)
    worker_cum = 0
    gate_cum = 0
    if cumulative_state_path.exists():
        try:
            data = json.loads(cumulative_state_path.read_text())
            worker_cum = data.get("worker_tokens_cumulative", 0)
            gate_cum = data.get("gate_tokens_cumulative", 0)
        except (json.JSONDecodeError, OSError):
            # Corrupted sidecar — treat as fresh.
            pass

    # Add this envelope's gate cost, if reported.
    if envelope and "cost" in envelope:
        cost = envelope["cost"]
        in_tokens = cost.get("input_tokens", 0) or 0
        out_tokens = cost.get("output_tokens", 0) or 0
        cache_tokens = cost.get("cache_read_tokens", 0) or 0
        gate_cum += in_tokens + out_tokens + cache_tokens

    worker_budget: str | int = cumulative.get(
        "worker_tokens_budget", "inf"
    )
    gate_budget: str | int = cumulative.get("gate_tokens_budget", "inf")

    # Iteration cap check
    iteration_trip = iteration >= slot_cap
    # Token budget checks (only when budgets are integers)
    worker_trip = (
        isinstance(worker_budget, int) and worker_cum >= worker_budget
    )
    gate_trip = isinstance(gate_budget, int) and gate_cum >= gate_budget

    trip_reason: str | None = None
    if iteration_trip:
        trip_reason = (
            f"slot_iteration_cap={slot_cap} reached at iter={iteration}"
        )
    elif worker_trip:
        trip_reason = (
            f"worker_tokens_cumulative={worker_cum} ≥ "
            f"budget={worker_budget}"
        )
    elif gate_trip:
        trip_reason = (
            f"gate_tokens_cumulative={gate_cum} ≥ budget={gate_budget}"
        )

    return BreakerState(
        slot_iterations_used=iteration,
        slot_iteration_cap=slot_cap,
        worker_tokens_cumulative=(worker_cum if worker_cum else None),
        gate_tokens_cumulative=(gate_cum if gate_cum else None),
        cumulative_worker_budget=worker_budget,
        cumulative_gate_budget=gate_budget,
        breaker_would_trip=bool(trip_reason),
        trip_reason=trip_reason,
    )


# ─── shadow-log I/O ────────────────────────────────────────────────────────


def append_decision(record: ShadowDecisionRecord, decisions_path: Path) -> None:
    decisions_path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(asdict(record), sort_keys=True) + "\n"
    with decisions_path.open("a", encoding="utf-8") as f:
        f.write(line)


def update_cumulative_state(
    breaker_state: BreakerState, cumulative_state_path: Path
) -> None:
    cumulative_state_path.parent.mkdir(parents=True, exist_ok=True)
    data: dict[str, Any] = {}
    if cumulative_state_path.exists():
        try:
            data = json.loads(cumulative_state_path.read_text())
        except (json.JSONDecodeError, OSError):
            data = {}
    data["worker_tokens_cumulative"] = (
        breaker_state.worker_tokens_cumulative or 0
    )
    data["gate_tokens_cumulative"] = (
        breaker_state.gate_tokens_cumulative or 0
    )
    data["last_updated"] = datetime.now(timezone.utc).isoformat()
    cumulative_state_path.write_text(json.dumps(data, indent=2))


# ─── reconciliation ────────────────────────────────────────────────────────


def reconcile(slot_id: str, decisions_path: Path, reconciliations_path: Path) -> int:
    """
    Read all decisions for a slot, prompt operator (or accept --json
    payload via stdin) to record actual outcome + correctness notes,
    and write to reconciliations.jsonl.

    Returns exit code: 0 success, 2 nothing-to-reconcile, 4 I/O error.
    """
    if not decisions_path.exists():
        print(
            f"ERROR: no decisions file at {decisions_path}",
            file=sys.stderr,
        )
        return 2

    decisions_for_slot: list[dict[str, Any]] = []
    with decisions_path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("slot_id") == slot_id:
                decisions_for_slot.append(rec)

    if not decisions_for_slot:
        print(
            f"ERROR: no decisions found for slot_id={slot_id!r}",
            file=sys.stderr,
        )
        return 2

    print(
        f"Found {len(decisions_for_slot)} decision(s) for slot "
        f"{slot_id}. Reading reconciliation payload from stdin "
        f"(JSON object with keys: merge_commit, ultimate_outcome, "
        f"actual_iterations_used, actual_tier_progression, "
        f"router_correctness)…",
        file=sys.stderr,
    )

    stdin_text = sys.stdin.read().strip()
    if not stdin_text:
        print(
            "ERROR: empty stdin — pipe a reconciliation JSON object in.",
            file=sys.stderr,
        )
        return 4

    try:
        payload = json.loads(stdin_text)
    except json.JSONDecodeError as e:
        print(f"ERROR: stdin is not valid JSON: {e}", file=sys.stderr)
        return 4

    reconciliation = {
        "slot_id": slot_id,
        "ts": datetime.now(timezone.utc).isoformat(),
        "merge_commit": payload.get("merge_commit"),
        "ultimate_outcome": payload.get("ultimate_outcome"),
        "actual_iterations_used": payload.get("actual_iterations_used"),
        "actual_tier_progression": payload.get("actual_tier_progression"),
        "router_decisions": [
            d["decision_id"] for d in decisions_for_slot
        ],
        "router_correctness": payload.get("router_correctness", {}),
    }

    reconciliations_path.parent.mkdir(parents=True, exist_ok=True)
    with reconciliations_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(reconciliation, sort_keys=True) + "\n")
    print(
        f"✓ Reconciliation written for slot {slot_id} "
        f"({len(decisions_for_slot)} decisions joined).",
        file=sys.stderr,
    )
    return 0


# ─── CLI ───────────────────────────────────────────────────────────────────


def cmd_decide(args: argparse.Namespace) -> int:
    envelope_path = Path(args.envelope)
    if not envelope_path.exists():
        print(f"ERROR: envelope file not found: {envelope_path}", file=sys.stderr)
        return 2

    try:
        routing_policy = load_policy(Path(args.routing_policy))
        breaker_policy = load_policy(Path(args.breaker_policy))
    except FileNotFoundError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 4

    gate_exit, envelope, _raw = parse_envelope_via_pe_gate(
        envelope_path, bare=args.bare
    )
    if envelope is None and gate_exit != GATE_EXIT_SCHEMA_ERROR:
        print(
            "ERROR: pe gate parse returned no parseable envelope "
            f"(exit {gate_exit})",
            file=sys.stderr,
        )
        return 4

    decision = route(
        envelope=envelope or {},
        gate_exit_code=gate_exit,
        current_worker_tier=args.current_tier,
        routing_policy=routing_policy,
    )

    decisions_path = Path(args.decisions_log)
    cumulative_state_path = decisions_path.parent / "breaker-cumulative.json"

    breaker_state = compute_breaker_state(
        iteration=args.iteration,
        slot_kind=args.slot_kind,
        envelope=envelope,
        breaker_policy=breaker_policy,
        cumulative_state_path=cumulative_state_path,
    )
    update_cumulative_state(breaker_state, cumulative_state_path)

    record = ShadowDecisionRecord(
        decision_id=str(uuid.uuid4()),
        ts=datetime.now(timezone.utc).isoformat(),
        slot_id=args.slot_id,
        slot_kind=args.slot_kind,
        iteration=args.iteration,
        gate_name=(envelope or {}).get("gate_name", "unknown"),
        envelope=envelope or {},
        router_decision=asdict(decision),
        breaker_state_at_decision=asdict(breaker_state),
        enforced=bool(getattr(args, "enforce", False)),
    )
    append_decision(record, decisions_path)

    summary = {
        "decision_id": record.decision_id,
        "action": decision.action,
        "from_tier": decision.from_tier,
        "to_tier": decision.to_tier,
        "rule_matched": decision.rule_matched,
        "breaker_would_trip": breaker_state.breaker_would_trip,
        "trip_reason": breaker_state.trip_reason,
        "enforced": bool(getattr(args, "enforce", False)),
    }
    print(json.dumps(summary, indent=2))
    return 0


def cmd_reconcile(args: argparse.Namespace) -> int:
    return reconcile(
        slot_id=args.slot_id,
        decisions_path=Path(args.decisions_log),
        reconciliations_path=Path(args.reconciliations_log),
    )


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="pe shadow",
        description=(
            "Phase 3 shadow-mode router + breaker. Records what the "
            "router WOULD do; does not enforce. See "
            "docs/PHASE_3_ESCALATION_ROUTER.md."
        ),
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("decide", help="Emit a shadow routing decision for a gate envelope")
    d.add_argument("--envelope", required=True, help="Path to gate envelope or transcript file")
    d.add_argument("--slot-id", required=True)
    d.add_argument("--slot-kind", default=None)
    d.add_argument("--iteration", type=int, required=True, help="Iteration number within the slot (1-indexed)")
    d.add_argument("--current-tier", required=True, choices=["haiku", "sonnet", "opus"])
    d.add_argument("--routing-policy", default=str(DEFAULT_ROUTING_POLICY))
    d.add_argument("--breaker-policy", default=str(DEFAULT_BREAKER_POLICY))
    d.add_argument("--decisions-log", default=".pe/decisions.jsonl")
    d.add_argument(
        "--bare",
        action="store_true",
        help=(
            "Treat --envelope as raw JSON (fixture mode). Default is "
            "transcript mode — E1.d cross-check enforced. Use for tests "
            "only; real agent emissions go through transcripts."
        ),
    )
    d.add_argument(
        "--enforce",
        action="store_true",
        help=(
            "Phase 3 GRADUATED 2026-06-28: mark the decision record "
            "as enforced=true. The operator pipeline commits to acting "
            "on the router's decision (halt / escalate / continue) "
            "rather than just logging it. Required for §9 watchpoint "
            "first-fire detection — the M=3 enforce-mode review "
            "depends on `enforced == true` rows. Default (shadow mode) "
            "remains False for backwards-compat + so test fixtures "
            "stay non-enforcing."
        ),
    )
    d.set_defaults(func=cmd_decide)

    r = sub.add_parser("reconcile", help="Join shadow decisions for a slot to actual outcome")
    r.add_argument("--slot-id", required=True)
    r.add_argument("--decisions-log", default=".pe/decisions.jsonl")
    r.add_argument(
        "--reconciliations-log", default=".pe/reconciliations.jsonl"
    )
    r.set_defaults(func=cmd_reconcile)

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
