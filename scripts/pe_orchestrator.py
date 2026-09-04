#!/usr/bin/env python3
"""
pe_orchestrator.py — Phase 3 shadow-mode router + breaker (CLI).

Reads an E1 gate envelope (file or stdin), consults the routing
policy + breaker policy, and emits a SHADOW DECISION to
.pe/decisions.jsonl. Does NOT enforce; the actual worker / human
pipeline continues as today.

Invoked via `pe shadow decide` and `pe shadow reconcile`.

This file is now the argv layer only. The decisions live in pe_routing
and the A4 loop in pe_escalation — see pe_routing.py's header for why it
was split. Both are re-exported below, because this module's names are
the ones docs, tests and `pe shadow` already reference; moving code is
not a reason to break an import that works.

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

import sys

if sys.version_info < (3, 11):
    sys.exit(
        "pe shadow requires Python 3.11+ (tomllib); found "
        f"{sys.version_info.major}.{sys.version_info.minor} at {sys.executable}.\n"
        "Fix: install a newer Python (e.g. `brew install python@3.12`) or run "
        "via a 3.11+ interpreter explicitly."
    )

import argparse
import json
import uuid
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

# Re-exported, not merely imported: `import pe_orchestrator as orch` then
# `orch.route(...)` is how the tests and docs address these, and the split
# is meant to be invisible to them.
from pe_routing import (  # noqa: E402,F401
    _AGENT_NAME_RE,
    BreakerState,
    DEFAULT_BREAKER_POLICY,
    DEFAULT_ROUTING_POLICY,
    ENGINE_DIR,
    GATE_EXIT_FAIL_ESCALATABLE,
    GATE_EXIT_FAIL_NON_ESCALATABLE,
    GATE_EXIT_PASS,
    GATE_EXIT_SCHEMA_ERROR,
    GATE_EXIT_WARN,
    PolicyError,
    RouterDecision,
    ShadowDecisionRecord,
    append_decision,
    compute_breaker_state,
    load_policy,
    parse_envelope_via_pe_gate,
    reconcile,
    route,
    update_cumulative_state,
)
# Test-only invoker override. Lives here rather than in pe_escalation
# because this is the module the tests address, and a module global cannot
# be re-exported — assigning `orch._INVOKER_OVERRIDE` would never reach
# pe_escalation's copy. cmd_decide reads it and passes it down.
_INVOKER_OVERRIDE = None

from pe_escalation import (  # noqa: E402,F401
    A4_EXIT_AGENT_FAIL,
    A4_EXIT_BREAKER,
    A4_EXIT_CONTINUE,
    A4_EXIT_HALT_HUMAN,
    A4_EXIT_MAX_ITER,
    _build_escalation_brief,
    _default_invoker,
    _run_a4_loop,
)


# ─── CLI ───────────────────────────────────────────────────────────────────


def _cumulative_state_path(decisions_path: Path, campaign_id: str | None) -> Path:
    """Where the breaker's token ledger lives, scoped to a campaign.

    It used to be one file per project, so cross-campaign runs contaminated
    each other's budgets permanently. campaign_id="default" keeps the old
    path, so existing ledgers are unaffected.
    """
    campaign_id = campaign_id or "default"
    if campaign_id == "default":
        return decisions_path.parent / "breaker-cumulative.json"
    return decisions_path.parent / f"breaker-cumulative-{campaign_id}.json"


def _check_auto_execute_args(args: argparse.Namespace) -> int | None:
    """Validate the A4 loop's preconditions. Returns an exit code, or None.

    The agent-file check matters more than it looks: without it the first
    escalation spawns `pe agent run <bogus>`, which exits non-zero, and the
    operator sees A4_EXIT_AGENT_FAIL (7) instead of "unknown agent".
    """
    if not getattr(args, "enforce", False):
        return _usage_error(
            "--auto-execute requires --enforce (A4 loop is not a shadow op)."
        )
    if not getattr(args, "agent", None):
        return _usage_error(
            "--auto-execute requires --agent <name> "
            "(which agent to invoke on escalation)."
        )
    agent_path = ENGINE_DIR / "agents" / f"{args.agent}.md"
    if not _AGENT_NAME_RE.match(args.agent) or not agent_path.is_file():
        return _usage_error(
            f"--auto-execute --agent {args.agent!r} — agent file not found at "
            f"{agent_path}. Pass a bare agent name (e.g. `code-reviewer`) "
            "matching agents/<name>.md."
        )
    return None


def _usage_error(message: str) -> int:
    print(f"ERROR: {message}", file=sys.stderr)
    return 2


def _load_decide_inputs(
    args: argparse.Namespace,
) -> tuple[int, dict[str, Any], dict[str, Any], dict[str, Any] | None] | int:
    """Read the envelope and both policies. Returns an exit code on failure."""
    envelope_path = Path(args.envelope)
    if not envelope_path.exists():
        return _usage_error(f"envelope file not found: {envelope_path}")
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
    return gate_exit, routing_policy, breaker_policy, envelope


def _decide_summary(
    record: ShadowDecisionRecord, decision: RouterDecision,
    breaker_state: BreakerState, enforced: bool,
) -> dict[str, Any]:
    return {
        "decision_id": record.decision_id,
        "action": decision.action,
        "from_tier": decision.from_tier,
        "to_tier": decision.to_tier,
        "rule_matched": decision.rule_matched,
        "breaker_would_trip": breaker_state.breaker_would_trip,
        "trip_reason": breaker_state.trip_reason,
        "enforced": enforced,
    }


def _build_record(
    args: argparse.Namespace, envelope: dict[str, Any] | None,
    decision: RouterDecision, breaker_state: BreakerState, enforced: bool,
) -> ShadowDecisionRecord:
    return ShadowDecisionRecord(
        decision_id=str(uuid.uuid4()),
        ts=datetime.now(timezone.utc).isoformat(),
        slot_id=args.slot_id,
        slot_kind=args.slot_kind,
        iteration=args.iteration,
        gate_name=(envelope or {}).get("gate_name", "unknown"),
        envelope=envelope or {},
        router_decision=asdict(decision),
        breaker_state_at_decision=asdict(breaker_state),
        enforced=enforced,
    )


def _maybe_run_a4(
    *, args: argparse.Namespace, record: ShadowDecisionRecord,
    decision: RouterDecision, breaker_state: BreakerState,
    decisions_path: Path, cumulative_state_path: Path,
    routing_policy: dict[str, Any], breaker_policy: dict[str, Any],
) -> int:
    """The A4 auto-escalation loop (v0.42.0), gated on its preconditions.

    Exit codes: continue (PASS/WARN) → 0; halt_to_human → 1; breaker trip →
    5; max iterations → 6; agent invocation failure → 7. See
    tests/test_a4_loop.py. This path is the §9 watchpoint — untested against
    real Claude invocations until first-fire evidence lands.
    """
    bad_args = _check_auto_execute_args(args)
    if bad_args is not None:
        return bad_args
    return _run_a4_loop(
        invoker=_INVOKER_OVERRIDE,
        args=args,
        initial_record=record,
        initial_decision=decision,
        initial_breaker=breaker_state,
        decisions_path=decisions_path,
        cumulative_state_path=cumulative_state_path,
        routing_policy=routing_policy,
        breaker_policy=breaker_policy,
    )


def cmd_decide(args: argparse.Namespace) -> int:
    loaded = _load_decide_inputs(args)
    if isinstance(loaded, int):
        return loaded
    gate_exit, routing_policy, breaker_policy, envelope = loaded

    decision = route(
        envelope=envelope or {},
        gate_exit_code=gate_exit,
        current_worker_tier=args.current_tier,
        routing_policy=routing_policy,
    )

    decisions_path = Path(args.decisions_log)
    cumulative_state_path = _cumulative_state_path(
        decisions_path, getattr(args, "campaign_id", None)
    )

    try:
        breaker_state = compute_breaker_state(
            iteration=args.iteration,
            slot_kind=args.slot_kind,
            envelope=envelope,
            breaker_policy=breaker_policy,
            cumulative_state_path=cumulative_state_path,
        )
    except PolicyError as e:
        # Structured policy-missing-key error → exit 4 with an actionable
        # message, rather than a raw KeyError traceback.
        print(f"ERROR: {e}", file=sys.stderr)
        return 4
    update_cumulative_state(breaker_state, cumulative_state_path)

    enforced = bool(getattr(args, "enforce", False))
    record = _build_record(args, envelope, decision, breaker_state, enforced)
    append_decision(record, decisions_path)
    print(json.dumps(
        _decide_summary(record, decision, breaker_state, enforced), indent=2,
    ))

    if not getattr(args, "auto_execute", False):
        return 0
    return _maybe_run_a4(
        args=args, record=record, decision=decision,
        breaker_state=breaker_state, decisions_path=decisions_path,
        cumulative_state_path=cumulative_state_path,
        routing_policy=routing_policy, breaker_policy=breaker_policy,
    )



def cmd_reconcile(args: argparse.Namespace) -> int:
    return reconcile(
        slot_id=args.slot_id,
        decisions_path=Path(args.decisions_log),
        reconciliations_path=Path(args.reconciliations_log),
    )


# The long option help lives here rather than inline. build_parser was 136
# lines and roughly two thirds of it was prose wrapped in add_argument calls,
# which hid the actual shape of the CLI inside its own documentation.
_HELP = {
    "bare":
        "Treat --envelope as raw JSON (fixture mode). Default is transcript "
        "mode — E1.d cross-check enforced. Use for tests only; real agent "
        "emissions go through transcripts.",
    "campaign_id":
        "Campaign scope for the cumulative breaker sidecar. Different "
        "campaigns get separate budget accounting. Omit or pass 'default' "
        "to preserve the pre-P2.11 single-file behaviour.",
    "enforce":
        "Phase 3 GRADUATED 2026-06-28: mark the decision record as "
        "enforced=true. The operator pipeline commits to acting on the "
        "router's decision (halt / escalate / continue) rather than just "
        "logging it. Required for §9 watchpoint first-fire detection — the "
        "M=3 enforce-mode review depends on `enforced == true` rows. "
        "Default (shadow mode) remains False for backwards-compat and so "
        "test fixtures stay non-enforcing.",
    "auto_execute":
        "A4 (v0.42.0): close the execution loop. When the decision is "
        "escalate_one_tier, invoke `pe agent run <agent> --model "
        "<next-tier>` with the FAIL envelope as brief, re-parse the emitted "
        "envelope, and re-route. Bounded by --max-iterations and the "
        "breaker. Requires --enforce + --agent. §9 watchpoint: tested=false "
        "against real Claude invocations until first-fire review lands.",
    "agent":
        "A4: agent to invoke on escalation (loaded from agents/<name>.md). "
        "Required with --auto-execute.",
}


def _positive_int(val: str) -> int:
    """iteration must be >= 1.

    It previously accepted 0 and negatives, which silently disabled the
    iteration cap downstream — `iteration >= slot_cap` was never true.
    """
    n = int(val)
    if n < 1:
        raise argparse.ArgumentTypeError(f"iteration must be >= 1 (got {n})")
    return n


def _cmd_reset(args: argparse.Namespace) -> int:
    """Remove the cumulative breaker sidecar for a campaign. Idempotent."""
    sidecar = _cumulative_state_path(
        Path(args.decisions_log), getattr(args, "campaign_id", None)
    )
    if sidecar.exists():
        sidecar.unlink()
        print(f"✓ removed {sidecar}", file=sys.stderr)
    else:
        print(f"✓ {sidecar} already absent (idempotent)", file=sys.stderr)
    return 0


def _add_decide_parser(sub: Any) -> None:
    d = sub.add_parser(
        "decide", help="Emit a shadow routing decision for a gate envelope",
    )
    d.add_argument("--envelope", required=True,
                   help="Path to gate envelope or transcript file")
    d.add_argument("--slot-id", required=True)
    d.add_argument("--slot-kind", default=None)
    d.add_argument("--iteration", type=_positive_int, required=True,
                   help="Iteration number within the slot (1-indexed)")
    d.add_argument("--campaign-id", default=None, help=_HELP["campaign_id"])
    d.add_argument("--current-tier", required=True,
                   choices=["haiku", "sonnet", "opus"])
    d.add_argument("--routing-policy", default=str(DEFAULT_ROUTING_POLICY))
    d.add_argument("--breaker-policy", default=str(DEFAULT_BREAKER_POLICY))
    d.add_argument("--decisions-log", default=".pe/decisions.jsonl")
    d.add_argument("--bare", action="store_true", help=_HELP["bare"])
    d.add_argument("--enforce", action="store_true", help=_HELP["enforce"])
    d.add_argument("--auto-execute", action="store_true",
                   help=_HELP["auto_execute"])
    d.add_argument("--agent", default=None, help=_HELP["agent"])
    d.add_argument("--max-iterations", type=int, default=5,
                   help="A4: hard cap on escalation iterations (default 5).")
    d.set_defaults(func=cmd_decide)


def _add_reconcile_parser(sub: Any) -> None:
    r = sub.add_parser(
        "reconcile", help="Join shadow decisions for a slot to actual outcome",
    )
    r.add_argument("--slot-id", required=True)
    r.add_argument("--decisions-log", default=".pe/decisions.jsonl")
    r.add_argument("--reconciliations-log", default=".pe/reconciliations.jsonl")
    r.set_defaults(func=cmd_reconcile)


def _add_reset_parser(sub: Any) -> None:
    rs = sub.add_parser(
        "reset",
        help="Remove the breaker cumulative sidecar for a campaign (idempotent).",
    )
    rs.add_argument("--decisions-log", default=".pe/decisions.jsonl")
    rs.add_argument("--campaign-id", default=None,
                    help="Campaign scope; omit for the default (pre-P2.11) file.")
    rs.set_defaults(func=_cmd_reset)


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
    _add_decide_parser(sub)
    _add_reconcile_parser(sub)
    _add_reset_parser(sub)
    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
