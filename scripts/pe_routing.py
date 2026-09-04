#!/usr/bin/env python3
"""
pe_routing.py — Phase 3 routing and circuit-breaker decisions.

The decision layer of `pe shadow`: envelope ingestion, the routing rules,
the breaker accounting, the shadow-log writers and reconciliation. Pure
with respect to the CLI — nothing here parses argv or spawns an agent —
which is what lets both pe_orchestrator (the CLI) and pe_escalation (the
A4 loop) depend on it without a cycle.

Split out of pe_orchestrator.py in v0.52.0. That file was 1202 lines
against the engine's own 800-line budget, exempted by name in
tests/test_size_budget_repo.sh's KNOWN_OVER list — the engine holding
adopters to a rule it had stopped applying to its own largest module.
The cut follows the layering that was already there: decisions here, the
loop that drives them in pe_escalation, argv in pe_orchestrator.

Stdlib only. Python 3.11+ (tomllib).

See docs/PHASE_3_ESCALATION_ROUTER.md for the design and the graduation
criteria. This file is the runtime; that doc is the contract.
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


# `route` was 173 lines: a chain of numbered guard clauses, each building and
# returning a RouterDecision. The numbering was doing the work a function name
# should — the order these fire in IS the policy, and it was legible only by
# reading all 173 lines in sequence. Each clause is now a named rule returning
# `RouterDecision | None`, and `route` is the order they run in.


def _decision(action, tier, src, rule, notes=None, to_tier=None) -> RouterDecision:
    return RouterDecision(
        action=action,
        from_tier=tier,
        to_tier=to_tier,
        rule_matched=rule,
        rule_source=src,
        notes=notes,
    )


def _route_confidence(
    envelope: dict[str, Any], verdict: str, tier: str,
    policy: dict[str, Any], src: str,
) -> RouterDecision | None:
    """Fires before failure_class on ANY verdict.

    The point is "I do not trust this gate's read, bring in a human", which
    is not a claim about what the gate concluded.
    """
    cfg = policy.get("confidence_override", {})
    threshold = cfg.get("threshold")
    confidence = envelope.get("confidence")
    if threshold is None or confidence is None or confidence >= threshold:
        return None
    return _decision(
        cfg.get("action_below_threshold", "halt_to_human"), tier, src,
        f"confidence_below_{threshold}",
        f"envelope confidence={confidence} < {threshold}",
    )


def _route_severity_floor(
    envelope: dict[str, Any], verdict: str, tier: str,
    policy: dict[str, Any], src: str,
) -> RouterDecision | None:
    """Verdict-blind severity floor.

    Fires BEFORE PASS/WARN→continue so a WARN carrying HIGH findings halts
    rather than silently advancing. Mirrors the consumer project's commit
    policy (HIGH = address-or-skip-documented). Added 2026-06-26 after slot
    1M.3.224b surfaced the gap on real shadow data — see policy receipt +
    brief §10.2.
    """
    cfg = policy.get("severity_override", {})
    block = set(cfg.get("block_severities", []))
    if not block or verdict not in ("PASS", "WARN"):
        return None
    blocking = [
        f for f in (envelope.get("findings") or [])
        if isinstance(f, dict) and f.get("severity") in block
    ]
    if not blocking:
        return None
    sevs = ",".join(sorted({f.get("severity") for f in blocking}))
    return _decision(
        cfg.get("action_on_match", "halt_to_human"), tier, src,
        f"severity_floor:{sevs}",
        f"verdict={verdict} but {len(blocking)} finding(s) at "
        f"blocking severity ({sevs})",
    )


def _route_pass_warn(
    envelope: dict[str, Any], verdict: str, tier: str,
    policy: dict[str, Any], src: str,
) -> RouterDecision | None:
    if verdict not in ("PASS", "WARN"):
        return None
    return _decision(
        "continue", tier, src, "none", f"verdict={verdict}", to_tier=tier,
    )


def _route_escalate(
    failure_class: str, tier: str, ladder: list[str],
    terminal_rules: dict[str, Any], src: str,
) -> RouterDecision:
    """Step one rung up the ladder, or halt because there is no next rung.

    The terminal case is caught HERE, in the policy layer, rather than by the
    breaker: top-tier worker_quality has nowhere to escalate to.
    """
    try:
        idx = ladder.index(tier)
    except ValueError:
        return _decision(
            "halt_to_human", tier, src, f"unknown_tier:{tier}",
            f"current_worker_tier={tier!r} not in ladder {ladder!r}",
        )
    if idx >= len(ladder) - 1:
        return _decision(
            terminal_rules.get("top_tier_worker_quality", "halt_to_human"),
            tier, src, "top_tier_worker_quality",
            f"already at top tier ({tier}); ladder exhausted — terminal halt",
        )
    return _decision(
        "escalate_one_tier", tier, src,
        f"{failure_class} -> escalate_one_tier", to_tier=ladder[idx + 1],
    )


def _route_failure_class(
    envelope: dict[str, Any], tier: str, policy: dict[str, Any], src: str,
) -> RouterDecision:
    """The FAIL path: look the failure_class up in the policy."""
    failure_class = envelope.get("failure_class", "none")
    action = policy["rules"].get(failure_class)

    if action is None:
        cfg = policy.get("unknown", {"action": "halt_to_human"})
        return _decision(
            cfg["action"], tier, src, f"unknown:{failure_class}",
            f"failure_class={failure_class!r} not in policy",
        )

    # Fail-safe: a FAIL verdict must never resolve to "continue".
    # failure_class="none" is only meaningful on PASS/WARN; a gate that emits
    # FAIL+none (schema-valid but contradictory) gets a human, not a green
    # light — otherwise FAIL+none+CRITICAL findings would sail through, which
    # falsified the graduation signoff's no-fallback claim.
    if action == "continue":
        return _decision(
            "halt_to_human", tier, src,
            f"fail_verdict_contradiction:{failure_class}",
            f"verdict=FAIL but failure_class={failure_class!r} routes to "
            "'continue' — contradictory envelope, halting fail-safe",
        )

    if action == "escalate_one_tier":
        return _route_escalate(
            failure_class, tier, policy["ladder"]["tiers"],
            policy.get("terminal_rules", {}), src,
        )

    return _decision(action, tier, src, f"{failure_class} -> {action}")


# The order below IS the policy. Read it as the rule list it is.
_ROUTE_RULES = (_route_confidence, _route_severity_floor, _route_pass_warn)


def route(
    envelope: dict[str, Any],
    gate_exit_code: int,
    current_worker_tier: str,
    routing_policy: dict[str, Any],
) -> RouterDecision:
    """Pure function: envelope + tier + policy → decision."""
    src = (
        "policy/failure_class_routing.toml "
        f"v{routing_policy.get('policy_version', '?')}"
    )
    tier = current_worker_tier

    # Schema-error short-circuit: the envelope is unusable, so no rule that
    # reads its fields can run.
    if gate_exit_code == GATE_EXIT_SCHEMA_ERROR or envelope is None:
        cfg = routing_policy.get("schema_error", {"action": "halt_to_human"})
        return _decision(
            cfg["action"], tier, src, "schema_error",
            "`pe gate parse` exit 4 — envelope failed schema validation",
        )

    verdict = envelope.get("verdict", "FAIL")
    for rule in _ROUTE_RULES:
        decision = rule(envelope, verdict, tier, routing_policy, src)
        if decision is not None:
            return decision

    return _route_failure_class(envelope, tier, routing_policy, src)


# ─── circuit breaker (shadow accounting) ───────────────────────────────────


class PolicyError(Exception):
    """Raised when a policy file is missing a required key (P2.11)."""


def _read_cumulative_tokens(path: Path) -> tuple[int, int]:
    """Read the breaker's token ledger, preserving it if unreadable.

    This sidecar is the breaker's primary safety ledger, so a silent reset
    would zero it invisibly. A corrupt file is copied aside for forensics
    and the reset is announced.
    """
    if not path.exists():
        return 0, 0
    try:
        data = json.loads(path.read_text())
        return (
            data.get("worker_tokens_cumulative", 0),
            data.get("gate_tokens_cumulative", 0),
        )
    except (json.JSONDecodeError, OSError) as exc:
        corrupt_path = path.with_suffix(".json.corrupt")
        try:
            corrupt_path.write_bytes(path.read_bytes())
        except OSError:
            pass
        print(
            f"WARNING: breaker sidecar {path} is unreadable ({exc}); "
            f"preserved to {corrupt_path} and resetting cumulative token "
            "totals to 0",
            file=sys.stderr,
        )
        return 0, 0


def _envelope_gate_cost(envelope: dict[str, Any] | None, cache_weight: float) -> int:
    """This envelope's contribution to the gate-token budget.

    cache_read tokens are billed by Anthropic at roughly 10% of a full read.
    Counting them at full weight silently overcharged the budget and tripped
    the breaker early on cache-heavy runs, so the weight is policy-
    configurable (breaker.cumulative.cache_read_weight); default 0.1.
    """
    if not envelope or "cost" not in envelope:
        return 0
    cost = envelope["cost"]
    return int(
        (cost.get("input_tokens", 0) or 0)
        + (cost.get("output_tokens", 0) or 0)
        + (cost.get("cache_read_tokens", 0) or 0) * cache_weight
    )


def _is_numeric_budget(v: Any) -> bool:
    """A budget enforces only if it is a real number.

    This was `isinstance(v, int)`, so a float in the TOML (20000000.0)
    silently disabled enforcement. bool is excluded because it subclasses
    int.
    """
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _slot_iteration_cap(
    breaker_policy: dict[str, Any], slot_kind: str | None
) -> tuple[int, dict[str, Any]]:
    try:
        per_slot = breaker_policy["per_slot"]
        cumulative = breaker_policy["cumulative"]
        slot_cap = per_slot["slot_iteration_cap"]
    except KeyError as e:
        # Previously bubbled as a bare KeyError with no context, which was
        # hard to debug when the policy TOML had a typo. cmd_decide catches
        # PolicyError.
        raise PolicyError(
            f"breaker policy missing required key: {e.args[0]!r} "
            f"(check policy/circuit_breaker.toml)"
        ) from e
    overrides = per_slot.get("overrides", {})
    if slot_kind and slot_kind in overrides:
        slot_cap = overrides[slot_kind]
    return slot_cap, cumulative


def _trip_reason(
    iteration: int, slot_cap: int,
    worker_cum: int, worker_budget: Any,
    gate_cum: int, gate_budget: Any,
) -> str | None:
    """First tripwire to fire, in priority order, or None."""
    if iteration >= slot_cap:
        return f"slot_iteration_cap={slot_cap} reached at iter={iteration}"
    if _is_numeric_budget(worker_budget) and worker_cum >= worker_budget:
        return (
            f"worker_tokens_cumulative={worker_cum} ≥ budget={worker_budget}"
        )
    if _is_numeric_budget(gate_budget) and gate_cum >= gate_budget:
        return f"gate_tokens_cumulative={gate_cum} ≥ budget={gate_budget}"
    return None


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
    slot_cap, cumulative = _slot_iteration_cap(breaker_policy, slot_kind)
    worker_cum, gate_cum = _read_cumulative_tokens(cumulative_state_path)
    gate_cum += _envelope_gate_cost(
        envelope, cumulative.get("cache_read_weight", 0.1)
    )

    worker_budget: str | int | float = cumulative.get(
        "worker_tokens_budget", "inf"
    )
    gate_budget: str | int | float = cumulative.get("gate_tokens_budget", "inf")

    trip_reason = _trip_reason(
        iteration, slot_cap, worker_cum, worker_budget, gate_cum, gate_budget,
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


class ReconcileError(Exception):
    """Carries the exit code the CLI should return alongside the message."""

    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def _decisions_for_slot(slot_id: str, decisions_path: Path) -> list[dict[str, Any]]:
    if not decisions_path.exists():
        raise ReconcileError(2, f"no decisions file at {decisions_path}")
    found: list[dict[str, Any]] = []
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
                found.append(rec)
    if not found:
        raise ReconcileError(2, f"no decisions found for slot_id={slot_id!r}")
    return found


_VALID_OUTCOMES = {"success", "merged", "reverted", "abandoned", "pending"}


def _read_reconciliation_payload(stdin_text: str) -> dict[str, Any]:
    """Parse and validate the operator's payload.

    This used to accept an all-null payload silently. A reconciliation
    without merge_commit or ultimate_outcome is meaningless to every
    downstream analysis, so it is rejected at write time rather than
    discovered later as a hole in the data.
    """
    if not stdin_text:
        raise ReconcileError(4, "empty stdin — pipe a reconciliation JSON object in.")
    try:
        payload = json.loads(stdin_text)
    except json.JSONDecodeError as e:
        raise ReconcileError(4, f"stdin is not valid JSON: {e}") from e
    if not isinstance(payload, dict):
        raise ReconcileError(4, "reconciliation payload must be a JSON object.")

    missing = [k for k in ("merge_commit", "ultimate_outcome")
               if payload.get(k) in (None, "")]
    if missing:
        raise ReconcileError(
            4,
            f"reconciliation payload missing required keys: {missing} "
            "(both merge_commit and ultimate_outcome are load-bearing).",
        )
    if payload["ultimate_outcome"] not in _VALID_OUTCOMES:
        raise ReconcileError(
            4,
            f"ultimate_outcome must be one of {sorted(_VALID_OUTCOMES)} "
            f"(got {payload['ultimate_outcome']!r}).",
        )
    return payload


def reconcile(slot_id: str, decisions_path: Path, reconciliations_path: Path) -> int:
    """
    Read all decisions for a slot, prompt operator (or accept --json
    payload via stdin) to record actual outcome + correctness notes,
    and write to reconciliations.jsonl.

    Returns exit code: 0 success, 2 nothing-to-reconcile, 4 I/O error.
    """
    try:
        decisions = _decisions_for_slot(slot_id, decisions_path)
        print(
            f"Found {len(decisions)} decision(s) for slot {slot_id}. Reading "
            "reconciliation payload from stdin (JSON object with keys: "
            "merge_commit, ultimate_outcome, actual_iterations_used, "
            "actual_tier_progression, router_correctness)…",
            file=sys.stderr,
        )
        payload = _read_reconciliation_payload(sys.stdin.read().strip())
    except ReconcileError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return e.code

    reconciliation = {
        "slot_id": slot_id,
        "ts": datetime.now(timezone.utc).isoformat(),
        "merge_commit": payload["merge_commit"],
        "ultimate_outcome": payload["ultimate_outcome"],
        "actual_iterations_used": payload.get("actual_iterations_used"),
        "actual_tier_progression": payload.get("actual_tier_progression"),
        "router_decisions": [d["decision_id"] for d in decisions],
        "router_correctness": payload.get("router_correctness", {}),
    }

    reconciliations_path.parent.mkdir(parents=True, exist_ok=True)
    with reconciliations_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(reconciliation, sort_keys=True) + "\n")
    print(
        f"✓ Reconciliation written for slot {slot_id} "
        f"({len(decisions)} decisions joined).",
        file=sys.stderr,
    )
    return 0
