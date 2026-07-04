"""test_a4_loop.py — A4 auto-escalation loop coverage (v0.42.0).

The loop lives in pe_orchestrator.py::_run_a4_loop and is exercised
via `pe shadow decide --auto-execute --enforce --agent <name>`.
These tests swap in a deterministic invoker so no `claude -p`
subprocess is spawned — the trajectory is scripted, and the loop's
decisions are what's under test.

Runs standalone via `python3 tests/test_a4_loop.py`. Zero external
deps.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import pe_orchestrator as orch  # noqa: E402


def _write_envelope(path: Path, verdict: str, failure_class: str, findings=None) -> None:
    envelope = {
        "schema_version": "1.0.0",
        "gate_name": "code-reviewer",
        "verdict": verdict,
        "failure_class": failure_class,
        "confidence": 0.9,
        "model_used": "claude-sonnet-4-6",
        "tier": "sonnet",
        "timestamp": "2026-07-04T00:00:00Z",
        "summary": "test fixture",
        "findings": findings or [],
    }
    path.write_text(json.dumps(envelope))


def _make_args(*, envelope_path: Path, agent: str = "code-reviewer", enforce=True, auto_execute=True, current_tier="haiku", iteration=1, max_iterations=5, slot_kind="reviewer") -> argparse.Namespace:
    return argparse.Namespace(
        envelope=str(envelope_path),
        slot_id="test-slot-1",
        slot_kind=slot_kind,
        iteration=iteration,
        current_tier=current_tier,
        routing_policy=str(orch.DEFAULT_ROUTING_POLICY),
        breaker_policy=str(orch.DEFAULT_BREAKER_POLICY),
        decisions_log=str(envelope_path.parent / ".pe" / "decisions.jsonl"),
        bare=True,
        enforce=enforce,
        auto_execute=auto_execute,
        agent=agent,
        max_iterations=max_iterations,
        campaign_id="test",
    )


class ScriptedInvoker:
    """Records calls + emits pre-scripted envelopes to trigger a trajectory."""

    def __init__(self, script: list[dict]):
        self.script = list(script)
        self.calls: list[dict] = []

    def __call__(self, agent_name, brief, next_tier, envelope_out_path, runs_root):
        self.calls.append(
            {
                "agent": agent_name,
                "next_tier": next_tier,
                "envelope_out": str(envelope_out_path),
                "brief_len": len(brief),
            }
        )
        if not self.script:
            raise AssertionError("scripted invoker exhausted")
        step = self.script.pop(0)
        if step.get("rc", 0) != 0:
            return step["rc"]
        if step.get("emit_envelope", True):
            _write_envelope(
                envelope_out_path,
                verdict=step["verdict"],
                failure_class=step["failure_class"],
                findings=step.get("findings", []),
            )
        return 0


class A4LoopTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.cwd_saved = Path.cwd()
        # Run from a tempdir so .pe/ side effects don't pollute the repo
        import os
        os.chdir(self.tmp_path)

    def tearDown(self):
        import os
        os.chdir(self.cwd_saved)
        orch._INVOKER_OVERRIDE = None
        self.tmp.cleanup()

    def test_escalate_then_pass_returns_0(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "worker_quality", findings=[{"severity": "HIGH", "rule": "x", "message": "y"}])

        orch._INVOKER_OVERRIDE = ScriptedInvoker(
            [{"verdict": "PASS", "failure_class": "none"}]
        )
        args = _make_args(envelope_path=env)
        rc = orch.cmd_decide(args)
        self.assertEqual(rc, orch.A4_EXIT_CONTINUE)
        self.assertEqual(len(orch._INVOKER_OVERRIDE.calls), 1)
        self.assertEqual(orch._INVOKER_OVERRIDE.calls[0]["next_tier"], "sonnet")

    def test_escalate_twice_then_pass(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "worker_quality")

        orch._INVOKER_OVERRIDE = ScriptedInvoker(
            [
                {"verdict": "FAIL", "failure_class": "worker_quality"},
                {"verdict": "PASS", "failure_class": "none"},
            ]
        )
        args = _make_args(envelope_path=env)
        rc = orch.cmd_decide(args)
        self.assertEqual(rc, orch.A4_EXIT_CONTINUE)
        self.assertEqual(len(orch._INVOKER_OVERRIDE.calls), 2)
        # Escalation ladder: haiku → sonnet → opus.
        self.assertEqual(orch._INVOKER_OVERRIDE.calls[0]["next_tier"], "sonnet")
        self.assertEqual(orch._INVOKER_OVERRIDE.calls[1]["next_tier"], "opus")

    def test_halt_to_human_on_task_underspecified(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "task_underspecified")

        # No invoker calls expected — first decision is halt.
        orch._INVOKER_OVERRIDE = ScriptedInvoker([])
        args = _make_args(envelope_path=env)
        rc = orch.cmd_decide(args)
        self.assertEqual(rc, orch.A4_EXIT_HALT_HUMAN)
        self.assertEqual(len(orch._INVOKER_OVERRIDE.calls), 0)

    def test_max_iterations_reached(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "worker_quality")

        # Every escalation keeps FAILing worker_quality → cap fires.
        orch._INVOKER_OVERRIDE = ScriptedInvoker(
            [{"verdict": "FAIL", "failure_class": "worker_quality"}] * 10
        )
        # iteration=1 + max_iterations=2 → escalate once (iter 2 reached)
        args = _make_args(envelope_path=env, iteration=1, max_iterations=2)
        rc = orch.cmd_decide(args)
        self.assertEqual(rc, orch.A4_EXIT_MAX_ITER)

    def test_top_tier_terminal_halts(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "worker_quality")

        # Start at top tier → first decision is halt_to_human via
        # top_tier_worker_quality terminal rule. No invocation.
        orch._INVOKER_OVERRIDE = ScriptedInvoker([])
        args = _make_args(envelope_path=env, current_tier="opus")
        rc = orch.cmd_decide(args)
        self.assertEqual(rc, orch.A4_EXIT_HALT_HUMAN)
        self.assertEqual(len(orch._INVOKER_OVERRIDE.calls), 0)

    def test_agent_invoker_nonzero_returns_agent_fail(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "worker_quality")

        orch._INVOKER_OVERRIDE = ScriptedInvoker([{"rc": 3, "emit_envelope": False}])
        args = _make_args(envelope_path=env)
        rc = orch.cmd_decide(args)
        self.assertEqual(rc, orch.A4_EXIT_AGENT_FAIL)

    def test_requires_enforce_flag(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "worker_quality")

        args = _make_args(envelope_path=env, enforce=False)
        rc = orch.cmd_decide(args)
        self.assertEqual(rc, 2)

    def test_requires_agent_flag(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "worker_quality")

        args = _make_args(envelope_path=env, agent="")
        rc = orch.cmd_decide(args)
        self.assertEqual(rc, 2)

    def test_rejects_bogus_agent_name(self):
        """v0.42.0 reviewer HIGH: --agent must resolve to agents/<name>.md."""
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "worker_quality")

        args = _make_args(envelope_path=env, agent="does-not-exist-xyz")
        rc = orch.cmd_decide(args)
        self.assertEqual(rc, 2)

    def test_rejects_path_traversal_agent_name(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "worker_quality")

        args = _make_args(envelope_path=env, agent="../etc/passwd")
        rc = orch.cmd_decide(args)
        self.assertEqual(rc, 2)

    def test_trajectory_written(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "worker_quality")

        orch._INVOKER_OVERRIDE = ScriptedInvoker(
            [{"verdict": "PASS", "failure_class": "none"}]
        )
        args = _make_args(envelope_path=env)
        orch.cmd_decide(args)

        # Trajectory file exists under .pe/a4-runs/<decision_id>/
        runs_root = self.tmp_path / ".pe" / "a4-runs"
        self.assertTrue(runs_root.exists())
        run_dirs = list(runs_root.iterdir())
        self.assertEqual(len(run_dirs), 1)
        traj = run_dirs[0] / "trajectory.jsonl"
        self.assertTrue(traj.exists())
        lines = [json.loads(line) for line in traj.read_text().splitlines() if line]
        kinds = [entry["kind"] for entry in lines]
        self.assertIn("loop_start", kinds)
        self.assertIn("invoke", kinds)
        self.assertIn("halt", kinds)

    def test_pass_initial_returns_0_without_invoking(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "PASS", "none")

        orch._INVOKER_OVERRIDE = ScriptedInvoker([])
        args = _make_args(envelope_path=env)
        rc = orch.cmd_decide(args)
        self.assertEqual(rc, orch.A4_EXIT_CONTINUE)
        self.assertEqual(len(orch._INVOKER_OVERRIDE.calls), 0)

    def test_decisions_jsonl_records_escalations(self):
        env = self.tmp_path / "initial.json"
        _write_envelope(env, "FAIL", "worker_quality")

        orch._INVOKER_OVERRIDE = ScriptedInvoker(
            [
                {"verdict": "FAIL", "failure_class": "worker_quality"},
                {"verdict": "PASS", "failure_class": "none"},
            ]
        )
        args = _make_args(envelope_path=env)
        orch.cmd_decide(args)

        decisions_path = self.tmp_path / ".pe" / "decisions.jsonl"
        lines = [json.loads(line) for line in decisions_path.read_text().splitlines() if line]
        # 1 initial + 2 escalation records
        self.assertEqual(len(lines), 3)
        # All escalation records marked enforced
        enforced = [r for r in lines if r.get("enforced")]
        self.assertEqual(len(enforced), 3)


class BuildEscalationBriefTests(unittest.TestCase):
    def test_names_tier_and_gate(self):
        env = {
            "gate_name": "security-reviewer",
            "verdict": "FAIL",
            "findings": [{"severity": "CRITICAL", "rule": "sql_injection", "message": "raw f-string in query"}],
        }
        brief = orch._build_escalation_brief(env, prior_iteration=1, next_tier="sonnet")
        self.assertIn("tier `sonnet`", brief)
        self.assertIn("security-reviewer", brief)
        self.assertIn("sql_injection", brief)

    def test_caps_findings_at_20(self):
        env = {
            "gate_name": "x",
            "verdict": "FAIL",
            "findings": [{"severity": "LOW", "rule": f"r{i}", "message": "m"} for i in range(25)],
        }
        brief = orch._build_escalation_brief(env, prior_iteration=1, next_tier="opus")
        self.assertIn("+5 more findings", brief)


if __name__ == "__main__":
    unittest.main(verbosity=2)
