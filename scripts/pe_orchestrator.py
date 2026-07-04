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
import re
import subprocess
import tomllib
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# A4 (v0.42.0): validate --agent flag matches a bare identifier before
# resolving to agents/<name>.md. Mirrors agent_runner._AGENT_NAME_RE.
_AGENT_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")

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
    # sys.executable, not "python3" — parent and child must not resolve to
    # different interpreters via $PATH (stock macOS python3 is 3.9)
    cmd = [sys.executable, str(pe_gate)]
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

    # 4.5. Fail-safe: a FAIL verdict must never resolve to "continue".
    # failure_class="none" is only meaningful on PASS/WARN; a gate that
    # emits FAIL+none (schema-valid but contradictory) gets a human,
    # not a green light — otherwise FAIL+none+CRITICAL findings would
    # sail through (falsified the graduation signoff's no-fallback claim).
    if action == "continue":
        return RouterDecision(
            action="halt_to_human",
            from_tier=current_worker_tier,
            to_tier=None,
            rule_matched=f"fail_verdict_contradiction:{failure_class}",
            rule_source=rule_source,
            notes=(
                f"verdict=FAIL but failure_class={failure_class!r} routes to "
                "'continue' — contradictory envelope, halting fail-safe"
            ),
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


class PolicyError(Exception):
    """Raised when a policy file is missing a required key (P2.11)."""


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
    try:
        per_slot = breaker_policy["per_slot"]
        cumulative = breaker_policy["cumulative"]
        slot_cap = per_slot["slot_iteration_cap"]
    except KeyError as e:
        # P2.11: previously bubbled as a bare KeyError with no
        # context — hard to debug when the policy TOML got a typo.
        # Convert to a structured PolicyError caught by cmd_decide.
        raise PolicyError(
            f"breaker policy missing required key: {e.args[0]!r} "
            f"(check policy/circuit_breaker.toml)"
        ) from e
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
        except (json.JSONDecodeError, OSError) as exc:
            # This sidecar is the breaker's primary safety ledger — a
            # silent reset would zero it invisibly. Preserve the corrupt
            # content for forensics and warn loudly before starting fresh.
            corrupt_path = cumulative_state_path.with_suffix(".json.corrupt")
            try:
                corrupt_path.write_bytes(cumulative_state_path.read_bytes())
            except OSError:
                pass
            print(
                f"WARNING: breaker sidecar {cumulative_state_path} is "
                f"unreadable ({exc}); preserved to {corrupt_path} and "
                "resetting cumulative token totals to 0",
                file=sys.stderr,
            )

    # Add this envelope's gate cost, if reported.
    # P2.11: cache_read tokens billed at ~10% of full read cost by
    # Anthropic. Counting them at full weight silently overcharged
    # the gate-tokens budget and would trip the breaker early on
    # cache-heavy runs. Weight is policy-configurable
    # (breaker.cumulative.cache_read_weight); default 0.1.
    if envelope and "cost" in envelope:
        cost = envelope["cost"]
        in_tokens = cost.get("input_tokens", 0) or 0
        out_tokens = cost.get("output_tokens", 0) or 0
        cache_tokens = cost.get("cache_read_tokens", 0) or 0
        cache_weight = cumulative.get("cache_read_weight", 0.1)
        gate_cum += int(in_tokens + out_tokens + cache_tokens * cache_weight)

    worker_budget: str | int | float = cumulative.get(
        "worker_tokens_budget", "inf"
    )
    gate_budget: str | int | float = cumulative.get("gate_tokens_budget", "inf")

    # Iteration cap check
    iteration_trip = iteration >= slot_cap

    # Token budget checks (only when budgets are numeric).
    # P2.11: previously `isinstance(int)` only — a float in the TOML
    # (e.g. 20000000.0) silently disabled enforcement. Accept int and
    # float; reject bool (which is a subclass of int).
    def _is_numeric_budget(v: Any) -> bool:
        return isinstance(v, (int, float)) and not isinstance(v, bool)

    worker_trip = _is_numeric_budget(worker_budget) and worker_cum >= worker_budget
    gate_trip = _is_numeric_budget(gate_budget) and gate_cum >= gate_budget

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
    # Atomic replace — a kill mid-write must not corrupt the safety ledger.
    tmp_path = cumulative_state_path.with_suffix(".json.tmp")
    tmp_path.write_text(json.dumps(data, indent=2))
    tmp_path.replace(cumulative_state_path)


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

    # P2.11: previously accepted an all-null payload silently. Now
    # validates required keys + enum. Reconciliation records without
    # merge_commit / ultimate_outcome are meaningless for downstream
    # analysis and must be rejected at write time.
    if not isinstance(payload, dict):
        print("ERROR: reconciliation payload must be a JSON object.", file=sys.stderr)
        return 4
    required = ("merge_commit", "ultimate_outcome")
    missing = [k for k in required if payload.get(k) in (None, "")]
    if missing:
        print(
            f"ERROR: reconciliation payload missing required keys: {missing} "
            "(both merge_commit and ultimate_outcome are load-bearing).",
            file=sys.stderr,
        )
        return 4
    valid_outcomes = {"success", "merged", "reverted", "abandoned", "pending"}
    if payload["ultimate_outcome"] not in valid_outcomes:
        print(
            f"ERROR: ultimate_outcome must be one of {sorted(valid_outcomes)} "
            f"(got {payload['ultimate_outcome']!r}).",
            file=sys.stderr,
        )
        return 4

    reconciliation = {
        "slot_id": slot_id,
        "ts": datetime.now(timezone.utc).isoformat(),
        "merge_commit": payload["merge_commit"],
        "ultimate_outcome": payload["ultimate_outcome"],
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
    # P2.11: campaign scope. Cumulative state was pinned to a single
    # file per project — cross-campaign runs contaminated each other's
    # budgets forever. Now the sidecar path includes an optional
    # --campaign-id suffix; default "default" preserves the old path
    # for backwards compat.
    campaign_id = getattr(args, "campaign_id", None) or "default"
    if campaign_id == "default":
        cumulative_state_path = decisions_path.parent / "breaker-cumulative.json"
    else:
        cumulative_state_path = (
            decisions_path.parent / f"breaker-cumulative-{campaign_id}.json"
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
        # P2.11: structured policy-missing-key error → exit 4 with
        # actionable message instead of raw KeyError traceback.
        print(f"ERROR: {e}", file=sys.stderr)
        return 4
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

    # A4 auto-escalation loop (v0.42.0). Runs only when both
    # --enforce and --auto-execute are set. Reads the initial decision
    # and, if it's an escalation, invokes the same agent at the next
    # tier with the FAIL envelope as brief, then re-parses + re-routes
    # until: continue (PASS/WARN) → 0; halt_to_human → 1; breaker trip
    # → 5; max iterations reached → 6; agent invocation failure → 7.
    #
    # See tests/test_a4_loop.py for the decision-tree coverage. This
    # path is the §9 watchpoint — untested against real Claude
    # invocations until first-fire evidence lands.
    if getattr(args, "auto_execute", False):
        if not getattr(args, "enforce", False):
            print(
                "ERROR: --auto-execute requires --enforce (A4 loop is not a shadow op).",
                file=sys.stderr,
            )
            return 2
        if not getattr(args, "agent", None):
            print(
                "ERROR: --auto-execute requires --agent <name> (which agent to invoke on escalation).",
                file=sys.stderr,
            )
            return 2
        # v0.42.0 reviewer HIGH: validate --agent points at an actual
        # agents/<name>.md before engaging the loop. Otherwise the first
        # escalation would spawn `pe agent run <bogus>` which exits
        # non-zero, and the operator sees a misleading A4_EXIT_AGENT_FAIL
        # (7) instead of a clear "unknown agent" message.
        agent_path = ENGINE_DIR / "agents" / f"{args.agent}.md"
        if not _AGENT_NAME_RE.match(args.agent) or not agent_path.is_file():
            print(
                f"ERROR: --auto-execute --agent {args.agent!r} — agent file not found at {agent_path}. "
                "Pass a bare agent name (e.g. `code-reviewer`) matching agents/<name>.md.",
                file=sys.stderr,
            )
            return 2
        return _run_a4_loop(
            args=args,
            initial_record=record,
            initial_decision=decision,
            initial_breaker=breaker_state,
            decisions_path=decisions_path,
            cumulative_state_path=cumulative_state_path,
            routing_policy=routing_policy,
            breaker_policy=breaker_policy,
        )
    return 0


# ─── A4 auto-escalation loop (v0.42.0) ─────────────────────────────────────


# A4 exit codes (added to the existing 0/1/2/4 set from cmd_decide):
A4_EXIT_CONTINUE = 0   # loop halted on PASS/WARN
A4_EXIT_HALT_HUMAN = 1  # loop halted on halt_to_human decision
A4_EXIT_BREAKER = 5     # breaker tripped mid-loop
A4_EXIT_MAX_ITER = 6    # iteration cap reached without resolution
A4_EXIT_AGENT_FAIL = 7  # `pe agent run` subprocess non-zero or missing artefact


# The invoker is factored out so tests can inject a deterministic
# escalation trajectory without spawning `claude -p`. Production
# callers use `_default_invoker`, which shells out to
# `pe agent run --brief - --out <path>`.
def _default_invoker(
    agent_name: str,
    brief: str,
    next_tier: str,
    envelope_out_path: Path,
    runs_root: Path,
) -> int:
    """Invoke `pe agent run` and require it emit an envelope at envelope_out_path."""
    pe_cli = ENGINE_DIR / "scripts" / "pe"
    argv = [
        str(pe_cli),
        "agent",
        "run",
        agent_name,
        "--brief",
        "-",
        "--out",
        str(envelope_out_path),
        "--model",
        next_tier,
    ]
    envelope_out_path.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        argv,
        input=brief,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        print(
            f"[a4] pe agent run exit {proc.returncode}: {proc.stderr.strip()}",
            file=sys.stderr,
        )
    return proc.returncode


# Test-only override. See tests/test_a4_loop.py.
_INVOKER_OVERRIDE: Any = None


def _build_escalation_brief(
    envelope: dict[str, Any] | None,
    prior_iteration: int,
    next_tier: str,
) -> str:
    """Compose the escalation brief handed to the next-tier agent.

    Deterministic shape so the receiving agent can parse it if needed.
    Not a template — the operator can override by wrapping the CLI, but
    the default is honest about what the loop is doing.
    """
    findings = (envelope or {}).get("findings") or []
    summary_lines = [
        "# A4 auto-escalation brief",
        "",
        f"You are being escalated to tier `{next_tier}` because the "
        f"previous attempt (iteration {prior_iteration}) FAILed with "
        "`failure_class = worker_quality` on the gate envelope below.",
        "",
        f"Gate: `{(envelope or {}).get('gate_name', 'unknown')}`",
        f"Verdict: `{(envelope or {}).get('verdict', 'FAIL')}`",
        f"Findings ({len(findings)}):",
        "",
    ]
    for i, f in enumerate(findings[:20], 1):
        if isinstance(f, dict):
            sev = f.get("severity", "?")
            rule = f.get("rule", "?")
            msg = str(f.get("message", "")).strip().splitlines()
            first = msg[0] if msg else ""
            summary_lines.append(f"{i}. [{sev}] `{rule}` — {first}")
    if len(findings) > 20:
        summary_lines.append(f"… +{len(findings) - 20} more findings")
    summary_lines.extend(
        [
            "",
            "Address the CRITICAL and HIGH findings. Emit a new gate ",
            "envelope that will be parsed by `pe gate parse`. The A4 ",
            "loop will re-route on the new envelope.",
        ]
    )
    return "\n".join(summary_lines)


def _run_a4_loop(
    *,
    args: argparse.Namespace,
    initial_record: "ShadowDecisionRecord",
    initial_decision: RouterDecision,
    initial_breaker: BreakerState,
    decisions_path: Path,
    cumulative_state_path: Path,
    routing_policy: dict[str, Any],
    breaker_policy: dict[str, Any],
) -> int:
    """Iterate: escalate → invoke agent → re-parse → re-route → repeat.

    Iterations are 1-indexed. The loop halts when
    ``current_iteration >= max_iterations`` BEFORE the next escalation
    invocation — so ``iteration=1`` + ``max_iterations=2`` allows one
    escalation (iteration 2 emitted). ``max_iterations=1`` would halt
    immediately with A4_EXIT_MAX_ITER if the first decision is
    escalate_one_tier.
    """
    max_iterations = int(getattr(args, "max_iterations", 5) or 5)
    ladder = routing_policy["ladder"]["tiers"]

    print(
        "[a4] auto-escalation loop ENGAGED — enforced=true, "
        "agent="
        f"{args.agent}. §9 watchpoint: tested=false until first-fire "
        "review lands. Decisions log: "
        f"{decisions_path}",
        file=sys.stderr,
    )

    current_decision = initial_decision
    current_envelope: dict[str, Any] | None = initial_record.envelope
    current_tier = args.current_tier
    current_iteration = args.iteration
    current_breaker = initial_breaker

    # Emit a per-run trajectory log so operators can inspect what
    # happened without joining decisions.jsonl by slot_id.
    trajectory_dir = decisions_path.parent / "a4-runs" / initial_record.decision_id
    trajectory_dir.mkdir(parents=True, exist_ok=True)
    trajectory_path = trajectory_dir / "trajectory.jsonl"

    def _append_trajectory(entry: dict[str, Any]) -> None:
        with trajectory_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")

    _append_trajectory(
        {
            "ts": datetime.now(timezone.utc).isoformat(),
            "kind": "loop_start",
            "slot_id": args.slot_id,
            "starting_iteration": current_iteration,
            "starting_tier": current_tier,
            "max_iterations": max_iterations,
            "initial_decision": asdict(current_decision),
        }
    )

    invoker = _INVOKER_OVERRIDE or _default_invoker
    runs_root = decisions_path.parent / "a4-runs"

    while True:
        # Halt: breaker
        if current_breaker.breaker_would_trip:
            print(
                f"[a4] loop-halt: breaker tripped ({current_breaker.trip_reason})",
                file=sys.stderr,
            )
            _append_trajectory(
                {"ts": datetime.now(timezone.utc).isoformat(), "kind": "halt", "reason": "breaker", "trip": current_breaker.trip_reason}
            )
            return A4_EXIT_BREAKER

        action = current_decision.action

        # Halt: PASS/WARN
        if action == "continue":
            print(
                f"[a4] loop-continue: verdict resolved after iteration {current_iteration}",
                file=sys.stderr,
            )
            _append_trajectory(
                {"ts": datetime.now(timezone.utc).isoformat(), "kind": "halt", "reason": "continue", "final_iteration": current_iteration}
            )
            return A4_EXIT_CONTINUE

        # Halt: halt_to_human
        if action == "halt_to_human":
            print(
                f"[a4] loop-halt: halt_to_human at iteration {current_iteration} (rule={current_decision.rule_matched})",
                file=sys.stderr,
            )
            _append_trajectory(
                {"ts": datetime.now(timezone.utc).isoformat(), "kind": "halt", "reason": "halt_to_human", "rule": current_decision.rule_matched}
            )
            return A4_EXIT_HALT_HUMAN

        # Any other action shouldn't happen, but be explicit.
        if action != "escalate_one_tier":
            print(
                f"[a4] loop-halt: unexpected action {action!r}",
                file=sys.stderr,
            )
            return A4_EXIT_HALT_HUMAN

        # Halt: iteration cap
        if current_iteration >= max_iterations:
            print(
                f"[a4] loop-halt: max_iterations={max_iterations} reached without resolution",
                file=sys.stderr,
            )
            _append_trajectory(
                {"ts": datetime.now(timezone.utc).isoformat(), "kind": "halt", "reason": "max_iterations", "cap": max_iterations}
            )
            return A4_EXIT_MAX_ITER

        # Escalate.
        next_tier = current_decision.to_tier
        if not next_tier or next_tier not in ladder:
            print(
                f"[a4] loop-halt: escalation to unknown tier {next_tier!r}",
                file=sys.stderr,
            )
            return A4_EXIT_HALT_HUMAN

        brief = _build_escalation_brief(current_envelope, current_iteration, next_tier)

        new_iteration = current_iteration + 1
        new_envelope_path = runs_root / initial_record.decision_id / f"iter-{new_iteration}-envelope.json"

        _append_trajectory(
            {
                "ts": datetime.now(timezone.utc).isoformat(),
                "kind": "invoke",
                "iteration": new_iteration,
                "from_tier": current_tier,
                "to_tier": next_tier,
                "agent": args.agent,
                "envelope_out": str(new_envelope_path),
            }
        )

        try:
            rc = invoker(
                args.agent,
                brief,
                next_tier,
                new_envelope_path,
                runs_root,
            )
        except Exception as e:  # noqa: BLE001 — invoker path is best-effort
            print(f"[a4] loop-halt: agent invocation raised: {e}", file=sys.stderr)
            _append_trajectory(
                {"ts": datetime.now(timezone.utc).isoformat(), "kind": "halt", "reason": "invoker_exception", "error": str(e)}
            )
            return A4_EXIT_AGENT_FAIL

        if rc != 0 or not new_envelope_path.exists():
            print(
                f"[a4] loop-halt: agent invocation failed (rc={rc}, artefact_present={new_envelope_path.exists()})",
                file=sys.stderr,
            )
            _append_trajectory(
                {"ts": datetime.now(timezone.utc).isoformat(), "kind": "halt", "reason": "invoker_nonzero", "rc": rc, "artefact_present": new_envelope_path.exists()}
            )
            return A4_EXIT_AGENT_FAIL

        # Re-parse + re-route on the new envelope.
        gate_exit, new_envelope, _raw = parse_envelope_via_pe_gate(
            new_envelope_path, bare=args.bare
        )
        current_decision = route(
            envelope=new_envelope or {},
            gate_exit_code=gate_exit,
            current_worker_tier=next_tier,
            routing_policy=routing_policy,
        )
        try:
            current_breaker = compute_breaker_state(
                iteration=new_iteration,
                slot_kind=args.slot_kind,
                envelope=new_envelope,
                breaker_policy=breaker_policy,
                cumulative_state_path=cumulative_state_path,
            )
        except PolicyError as e:
            print(f"[a4] loop-halt: breaker policy error: {e}", file=sys.stderr)
            return A4_EXIT_HALT_HUMAN
        update_cumulative_state(current_breaker, cumulative_state_path)

        new_record = ShadowDecisionRecord(
            decision_id=str(uuid.uuid4()),
            ts=datetime.now(timezone.utc).isoformat(),
            slot_id=args.slot_id,
            slot_kind=args.slot_kind,
            iteration=new_iteration,
            gate_name=(new_envelope or {}).get("gate_name", "unknown"),
            envelope=new_envelope or {},
            router_decision=asdict(current_decision),
            breaker_state_at_decision=asdict(current_breaker),
            enforced=True,
        )
        append_decision(new_record, decisions_path)

        _append_trajectory(
            {
                "ts": datetime.now(timezone.utc).isoformat(),
                "kind": "post_invoke",
                "iteration": new_iteration,
                "gate_exit": gate_exit,
                "decision": asdict(current_decision),
                "breaker": asdict(current_breaker),
            }
        )

        current_envelope = new_envelope
        current_tier = next_tier
        current_iteration = new_iteration


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
    def _positive_int(val: str) -> int:
        # P2.11: iteration must be >= 1. Previously accepted 0 and
        # negative values, which silently disabled the iteration cap
        # check downstream (iter >= slot_cap was never true).
        n = int(val)
        if n < 1:
            raise argparse.ArgumentTypeError(
                f"iteration must be >= 1 (got {n})"
            )
        return n

    d.add_argument("--iteration", type=_positive_int, required=True, help="Iteration number within the slot (1-indexed)")
    d.add_argument(
        "--campaign-id",
        default=None,
        help=(
            "P2.11: campaign scope for the cumulative breaker sidecar. "
            "Different campaigns get separate budget accounting. Omit "
            "or pass 'default' to preserve the pre-P2.11 single-file "
            "behaviour."
        ),
    )
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
    d.add_argument(
        "--auto-execute",
        action="store_true",
        help=(
            "A4 (v0.42.0): close the execution loop. When the decision "
            "is escalate_one_tier, invoke `pe agent run <agent> --model "
            "<next-tier>` with the FAIL envelope as brief, re-parse the "
            "emitted envelope, and re-route. Bounded by --max-iterations "
            "and the breaker. Requires --enforce + --agent. §9 watchpoint: "
            "tested=false against real Claude invocations until first-fire "
            "review lands."
        ),
    )
    d.add_argument(
        "--agent",
        default=None,
        help=(
            "A4: agent to invoke on escalation (loaded from agents/<name>.md). "
            "Required with --auto-execute."
        ),
    )
    d.add_argument(
        "--max-iterations",
        type=int,
        default=5,
        help="A4: hard cap on escalation iterations (default 5).",
    )
    d.set_defaults(func=cmd_decide)

    r = sub.add_parser("reconcile", help="Join shadow decisions for a slot to actual outcome")
    r.add_argument("--slot-id", required=True)
    r.add_argument("--decisions-log", default=".pe/decisions.jsonl")
    r.add_argument(
        "--reconciliations-log", default=".pe/reconciliations.jsonl"
    )
    r.set_defaults(func=cmd_reconcile)

    # P2.11: `pe shadow reset` — remove the cumulative breaker sidecar
    # for a campaign. Idempotent (no error if the file doesn't exist).
    def _cmd_reset(args_: argparse.Namespace) -> int:
        decisions_path = Path(args_.decisions_log)
        campaign_id = args_.campaign_id or "default"
        if campaign_id == "default":
            sidecar = decisions_path.parent / "breaker-cumulative.json"
        else:
            sidecar = (
                decisions_path.parent
                / f"breaker-cumulative-{campaign_id}.json"
            )
        if sidecar.exists():
            sidecar.unlink()
            print(f"✓ removed {sidecar}", file=sys.stderr)
        else:
            print(
                f"✓ {sidecar} already absent (idempotent)",
                file=sys.stderr,
            )
        return 0

    rs = sub.add_parser(
        "reset",
        help="Remove the breaker cumulative sidecar for a campaign (idempotent).",
    )
    rs.add_argument("--decisions-log", default=".pe/decisions.jsonl")
    rs.add_argument(
        "--campaign-id",
        default=None,
        help="Campaign scope; omit for the default (pre-P2.11) file.",
    )
    rs.set_defaults(func=_cmd_reset)

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
