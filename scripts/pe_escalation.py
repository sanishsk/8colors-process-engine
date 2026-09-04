#!/usr/bin/env python3
"""
pe_escalation.py — the A4 auto-escalation loop (v0.42.0).

Drives a gate envelope through successive tiers until it passes, the
breaker trips, a human is required, or the iteration cap is hit. Depends
on pe_routing for every decision it makes and owns none of them itself.

Split out of pe_orchestrator.py in v0.52.0 — see pe_routing.py's header
for why. The only thing that had to move with it was the exit-code block,
which pe_orchestrator re-exports so `pe shadow` keeps its published
codes.
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
import subprocess
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from pe_routing import (  # noqa: E402
    BreakerState,
    ENGINE_DIR,
    PolicyError,
    RouterDecision,
    ShadowDecisionRecord,
    append_decision,
    compute_breaker_state,
    parse_envelope_via_pe_gate,
    route,
    update_cumulative_state,
)


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


# The invoker arrives as a parameter rather than as a module global.
# It used to be `_INVOKER_OVERRIDE`, set on pe_orchestrator by the tests and
# read here — which worked only while both lived in one file. A global
# assigned in one module and read in another is not a seam that survives a
# split, and it fails silently: the loop simply used the real invoker,
# shelled out to `pe agent run`, and returned A4_EXIT_AGENT_FAIL. Passing it
# in makes the dependency visible and keeps `orch._INVOKER_OVERRIDE` working,
# because cmd_decide now reads that from its OWN module and hands it over.


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


class _Trajectory:
    """Per-run log so an operator can see what happened without joining
    decisions.jsonl by slot_id.

    It also owns halting. Every halt in this loop was the same three lines
    — print to stderr, append a record, return an exit code — written out
    eight times, and two of the eight forgot the middle one: a halt on an
    unexpected action or an unknown tier left no trace in the trajectory at
    all. Giving halt a name fixes those two by construction.
    """

    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._path = path

    def append(self, kind: str, **fields: Any) -> None:
        entry = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "kind": kind,
            **fields,
        }
        with self._path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")

    def halt(self, code: int, message: str, **fields: Any) -> int:
        print(f"[a4] {message}", file=sys.stderr)
        self.append("halt", **fields)
        return code


def _a4_check_halt(run: "_A4Run", st: "_A4State") -> int | None:
    """Every reason to stop before invoking anything. None = keep going.

    Iterations are 1-indexed, and the cap is checked BEFORE the next
    escalation invocation — so iteration=1 with max_iterations=2 allows one
    escalation (iteration 2 emitted), while max_iterations=1 halts
    immediately with A4_EXIT_MAX_ITER if the first decision is
    escalate_one_tier.
    """
    decision, breaker, traj = st.decision, st.breaker, run.traj
    iteration, max_iterations = st.iteration, run.max_iterations
    if breaker.breaker_would_trip:
        return traj.halt(
            A4_EXIT_BREAKER,
            f"loop-halt: breaker tripped ({breaker.trip_reason})",
            reason="breaker", trip=breaker.trip_reason,
        )
    action = decision.action
    if action == "continue":
        return traj.halt(
            A4_EXIT_CONTINUE,
            f"loop-continue: verdict resolved after iteration {iteration}",
            reason="continue", final_iteration=iteration,
        )
    if action == "halt_to_human":
        return traj.halt(
            A4_EXIT_HALT_HUMAN,
            f"loop-halt: halt_to_human at iteration {iteration} "
            f"(rule={decision.rule_matched})",
            reason="halt_to_human", rule=decision.rule_matched,
        )
    if action != "escalate_one_tier":
        # Should not happen; being explicit beats falling through.
        return traj.halt(
            A4_EXIT_HALT_HUMAN, f"loop-halt: unexpected action {action!r}",
            reason="unexpected_action", action=action,
        )
    if iteration >= max_iterations:
        return traj.halt(
            A4_EXIT_MAX_ITER,
            f"loop-halt: max_iterations={max_iterations} reached without "
            "resolution",
            reason="max_iterations", cap=max_iterations,
        )
    return None


def _a4_invoke(
    *, invoker: Any, agent: str, brief: str, next_tier: str,
    from_tier: str, iteration: int, envelope_path: Path, runs_root: Path,
    traj: _Trajectory,
) -> int | None:
    """Run the next-tier agent. Returns an exit code on failure, else None."""
    traj.append(
        "invoke", iteration=iteration, from_tier=from_tier, to_tier=next_tier,
        agent=agent, envelope_out=str(envelope_path),
    )
    try:
        rc = invoker(agent, brief, next_tier, envelope_path, runs_root)
    except Exception as e:  # noqa: BLE001 — invoker path is best-effort
        return traj.halt(
            A4_EXIT_AGENT_FAIL, f"loop-halt: agent invocation raised: {e}",
            reason="invoker_exception", error=str(e),
        )
    if rc != 0 or not envelope_path.exists():
        return traj.halt(
            A4_EXIT_AGENT_FAIL,
            f"loop-halt: agent invocation failed (rc={rc}, "
            f"artefact_present={envelope_path.exists()})",
            reason="invoker_nonzero", rc=rc,
            artefact_present=envelope_path.exists(),
        )
    return None


def _a4_reroute(
    *, args: argparse.Namespace, envelope_path: Path, next_tier: str,
    iteration: int, routing_policy: dict[str, Any],
    breaker_policy: dict[str, Any], cumulative_state_path: Path,
    decisions_path: Path, traj: _Trajectory,
) -> tuple[RouterDecision, BreakerState, dict[str, Any] | None]:
    """Re-parse the new envelope, re-route it, re-check the breaker, record.

    Raises PolicyError if the breaker policy is malformed; the caller turns
    that into a halt.
    """
    gate_exit, envelope, _raw = parse_envelope_via_pe_gate(
        envelope_path, bare=args.bare
    )
    decision = route(
        envelope=envelope or {},
        gate_exit_code=gate_exit,
        current_worker_tier=next_tier,
        routing_policy=routing_policy,
    )
    breaker = compute_breaker_state(
        iteration=iteration,
        slot_kind=args.slot_kind,
        envelope=envelope,
        breaker_policy=breaker_policy,
        cumulative_state_path=cumulative_state_path,
    )
    update_cumulative_state(breaker, cumulative_state_path)

    append_decision(
        ShadowDecisionRecord(
            decision_id=str(uuid.uuid4()),
            ts=datetime.now(timezone.utc).isoformat(),
            slot_id=args.slot_id,
            slot_kind=args.slot_kind,
            iteration=iteration,
            gate_name=(envelope or {}).get("gate_name", "unknown"),
            envelope=envelope or {},
            router_decision=asdict(decision),
            breaker_state_at_decision=asdict(breaker),
            enforced=True,
        ),
        decisions_path,
    )
    traj.append(
        "post_invoke", iteration=iteration, gate_exit=gate_exit,
        decision=asdict(decision), breaker=asdict(breaker),
    )
    return decision, breaker, envelope


@dataclass
class _A4State:
    """What changes each time round the loop."""
    decision: RouterDecision
    breaker: BreakerState
    envelope: dict[str, Any] | None
    tier: str
    iteration: int


@dataclass
class _A4Run:
    """What does not change: the policies, paths and knobs for one run.

    Bundled because the loop body needs eleven of them and threading eleven
    parameters through is how a 221-line function stays a 221-line function.
    """
    args: argparse.Namespace
    ladder: list[str]
    max_iterations: int
    invoker: Any
    run_dir: Path
    runs_root: Path
    routing_policy: dict[str, Any]
    breaker_policy: dict[str, Any]
    cumulative_state_path: Path
    decisions_path: Path
    traj: _Trajectory

    @classmethod
    def build(cls, *, args, decision_id, decisions_path,
              cumulative_state_path, routing_policy, breaker_policy,
              invoker) -> "_A4Run":
        runs_root = decisions_path.parent / "a4-runs"
        run_dir = runs_root / decision_id
        return cls(
            args=args,
            ladder=routing_policy["ladder"]["tiers"],
            max_iterations=int(getattr(args, "max_iterations", 5) or 5),
            invoker=invoker or _default_invoker,
            run_dir=run_dir,
            runs_root=runs_root,
            routing_policy=routing_policy,
            breaker_policy=breaker_policy,
            cumulative_state_path=cumulative_state_path,
            decisions_path=decisions_path,
            traj=_Trajectory(run_dir / "trajectory.jsonl"),
        )


def _a4_escalate_once(run: _A4Run, st: _A4State) -> int | None:
    """One escalation: invoke the next tier, re-route what comes back.

    Mutates `st` on success. Returns an exit code to stop the loop, or None
    to go round again.
    """
    next_tier = st.decision.to_tier
    if not next_tier or next_tier not in run.ladder:
        return run.traj.halt(
            A4_EXIT_HALT_HUMAN,
            f"loop-halt: escalation to unknown tier {next_tier!r}",
            reason="unknown_tier", tier=next_tier,
        )

    new_iteration = st.iteration + 1
    envelope_path = run.run_dir / f"iter-{new_iteration}-envelope.json"

    failed = _a4_invoke(
        invoker=run.invoker, agent=run.args.agent,
        brief=_build_escalation_brief(st.envelope, st.iteration, next_tier),
        next_tier=next_tier, from_tier=st.tier, iteration=new_iteration,
        envelope_path=envelope_path, runs_root=run.runs_root, traj=run.traj,
    )
    if failed is not None:
        return failed

    try:
        st.decision, st.breaker, st.envelope = _a4_reroute(
            args=run.args, envelope_path=envelope_path, next_tier=next_tier,
            iteration=new_iteration, routing_policy=run.routing_policy,
            breaker_policy=run.breaker_policy,
            cumulative_state_path=run.cumulative_state_path,
            decisions_path=run.decisions_path, traj=run.traj,
        )
    except PolicyError as e:
        return run.traj.halt(
            A4_EXIT_HALT_HUMAN, f"loop-halt: breaker policy error: {e}",
            reason="breaker_policy_error", error=str(e),
        )

    st.tier = next_tier
    st.iteration = new_iteration
    return None


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
    invoker: Any = None,
) -> int:
    """Iterate: escalate → invoke agent → re-parse → re-route → repeat.

    See _a4_check_halt for the iteration-cap semantics.
    """
    run = _A4Run.build(
        args=args, decision_id=initial_record.decision_id,
        decisions_path=decisions_path,
        cumulative_state_path=cumulative_state_path,
        routing_policy=routing_policy, breaker_policy=breaker_policy,
        invoker=invoker,
    )
    st = _A4State(
        decision=initial_decision, breaker=initial_breaker,
        envelope=initial_record.envelope, tier=args.current_tier,
        iteration=args.iteration,
    )

    print(
        "[a4] auto-escalation loop ENGAGED — enforced=true, "
        f"agent={args.agent}. §9 watchpoint: tested=false until first-fire "
        f"review lands. Decisions log: {decisions_path}",
        file=sys.stderr,
    )
    run.traj.append(
        "loop_start", slot_id=args.slot_id, starting_iteration=st.iteration,
        starting_tier=st.tier, max_iterations=run.max_iterations,
        initial_decision=asdict(st.decision),
    )

    while True:
        stop = _a4_check_halt(run, st)
        if stop is not None:
            return stop
        stop = _a4_escalate_once(run, st)
        if stop is not None:
            return stop
