"""test_agent_runner.py — unit tests for A4 headless agent invocation.

Runs standalone via `python3 tests/test_agent_runner.py`. Zero external
deps — never actually shells out to `claude`; the subprocess call site
is exercised via a monkeypatch that records the argv and returns a
canned JSON blob.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from agent_runner import (  # noqa: E402
    AgentSpec,
    ClaudeNotOnPathError,
    _parse_frontmatter,
    _parse_tools,
    build_argv,
    load_agent_spec,
    parse_result,
    persist_run,
    run_agent,
)


AGENT_MD = """---
name: test-agent
description: Test agent for the runner unit tests.
tools: ["Read", "Grep", "Bash"]
model: sonnet
effort: medium
memory: project
---

# Test agent

You are a test agent. Emit an envelope. Nothing else.
"""


class Frontmatter(unittest.TestCase):
    def test_extracts_all_fields(self):
        fm, body = _parse_frontmatter(AGENT_MD)
        self.assertEqual(fm["name"], "test-agent")
        self.assertEqual(fm["model"], "sonnet")
        self.assertEqual(fm["effort"], "medium")
        self.assertIn("You are a test agent", body)

    def test_missing_frontmatter_raises(self):
        with self.assertRaises(ValueError):
            _parse_frontmatter("# no frontmatter here\n")

    def test_tools_json_array(self):
        self.assertEqual(_parse_tools('["Read", "Grep"]'), ("Read", "Grep"))

    def test_tools_comma_list(self):
        self.assertEqual(_parse_tools("Read, Grep, Bash"), ("Read", "Grep", "Bash"))

    def test_tools_empty(self):
        self.assertEqual(_parse_tools(""), ())


class LoadAgentSpec(unittest.TestCase):
    def test_reads_engine_agent(self):
        # smoke against a real engine agent — asserts we can parse the
        # actual files, not just synthetic fixtures.
        spec = load_agent_spec("security-reviewer")
        self.assertEqual(spec.name, "security-reviewer")
        self.assertEqual(spec.model, "sonnet")
        self.assertIn("Read", spec.tools)
        self.assertGreater(len(spec.system_prompt), 100)

    def test_missing_agent_raises(self):
        with self.assertRaises(FileNotFoundError):
            load_agent_spec("no-such-agent-xyz")

    def test_defaults_model_when_missing(self):
        # write a synthetic file to a tmp agents_dir
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "no-model.md").write_text(
                "---\nname: no-model\ndescription: x\n---\nbody\n"
            )
            spec = load_agent_spec("no-model", agents_dir=d)
            self.assertEqual(spec.model, "sonnet")  # default fallback

    def test_rejects_slash_in_name(self):
        # Typo protection — bare filenames only. Not a security boundary
        # (local dev tool), but `pe agent run agents/foo` should be a
        # clear "no" instead of silently resolving to agents/agents/foo.md.
        with self.assertRaises(FileNotFoundError):
            load_agent_spec("agents/foo")

    def test_rejects_double_dot_in_name(self):
        with self.assertRaises(FileNotFoundError):
            load_agent_spec("../secret")

    def test_rejects_empty_name(self):
        with self.assertRaises(FileNotFoundError):
            load_agent_spec("")

    def test_accepts_hyphen_and_underscore(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "code-reviewer_v2.md").write_text(
                "---\nname: x\nmodel: sonnet\n---\nbody\n"
            )
            spec = load_agent_spec("code-reviewer_v2", agents_dir=d)
            self.assertEqual(spec.model, "sonnet")


class BuildArgv(unittest.TestCase):
    def _spec(self, tools=("Read", "Grep"), model="sonnet"):
        return AgentSpec(
            name="t", model=model, tools=tools, effort="", system_prompt="SP"
        )

    def test_includes_claude_p_json(self):
        argv = build_argv(self._spec())
        self.assertEqual(argv[0], "claude")
        self.assertIn("-p", argv)
        self.assertIn("json", argv)

    def test_model_override_wins(self):
        argv = build_argv(self._spec(model="sonnet"), model_override="opus")
        i = argv.index("--model")
        self.assertEqual(argv[i + 1], "opus")

    def test_system_prompt_via_append(self):
        argv = build_argv(self._spec())
        self.assertIn("--append-system-prompt", argv)
        i = argv.index("--append-system-prompt")
        self.assertEqual(argv[i + 1], "SP")

    def test_tools_omitted_when_empty(self):
        argv = build_argv(self._spec(tools=()))
        self.assertNotIn("--allowedTools", argv)

    def test_tools_joined_space_separated(self):
        argv = build_argv(self._spec(tools=("Read", "Grep", "Bash")))
        i = argv.index("--allowedTools")
        self.assertEqual(argv[i + 1], "Read Grep Bash")


class ParseResult(unittest.TestCase):
    def test_extracts_from_well_formed_json(self):
        raw = {
            "result": "hello",
            "session_id": "s-123",
            "model": "claude-sonnet-4-6",
            "duration_ms": 1500,
            "usage": {
                "input_tokens": 100,
                "output_tokens": 50,
                "cache_read_input_tokens": 200,
                "cache_creation_input_tokens": 10,
            },
        }
        r = parse_result(json.dumps(raw), "", 0, "sonnet")
        self.assertEqual(r.output_text, "hello")
        self.assertEqual(r.session_id, "s-123")
        self.assertEqual(r.model_used, "claude-sonnet-4-6")
        self.assertEqual(r.input_tokens, 100)
        self.assertEqual(r.output_tokens, 50)
        self.assertEqual(r.cache_read_tokens, 200)
        self.assertEqual(r.cache_creation_tokens, 10)
        self.assertEqual(r.duration_ms, 1500)
        self.assertGreater(r.cost_cents, 0)

    def test_falls_back_to_raw_on_non_json(self):
        r = parse_result("plain text response\n", "", 0, "sonnet")
        self.assertEqual(r.output_text, "plain text response\n")
        # raw_json carries the stdout so drift is inspectable
        self.assertIn("_raw_stdout", r.raw_json)

    def test_missing_usage_zero_costs(self):
        r = parse_result(json.dumps({"result": "hi"}), "", 0, "sonnet")
        self.assertEqual(r.input_tokens, 0)
        self.assertEqual(r.output_tokens, 0)
        self.assertEqual(r.cost_cents, 0.0)

    def test_captures_stderr(self):
        r = parse_result("{}", "some warning\n", 0, "sonnet")
        self.assertEqual(r.stderr, "some warning\n")

    def test_falls_back_to_result_when_response_missing(self):
        # Older claude releases used 'result', newer might use 'response'.
        # Confirm both paths — 'result' takes precedence.
        r = parse_result(json.dumps({"response": "resp-key"}), "", 0, "sonnet")
        self.assertEqual(r.output_text, "resp-key")


class RunAgent(unittest.TestCase):
    def test_subprocess_missing_raises_typed_error(self):
        spec = AgentSpec(name="t", model="sonnet", tools=(), effort="", system_prompt="")
        with patch("subprocess.run", side_effect=FileNotFoundError("claude")):
            with self.assertRaises(ClaudeNotOnPathError):
                run_agent(spec, "brief")

    def test_returns_parsed_result_on_success(self):
        spec = AgentSpec(name="t", model="sonnet", tools=(), effort="", system_prompt="")
        canned = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({"result": "ok", "usage": {"input_tokens": 1}}),
            stderr="",
        )
        with patch("subprocess.run", return_value=canned):
            r = run_agent(spec, "brief")
        self.assertEqual(r.exit_code, 0)
        self.assertEqual(r.output_text, "ok")
        self.assertEqual(r.input_tokens, 1)

    def test_forwards_nonzero_exit(self):
        spec = AgentSpec(name="t", model="sonnet", tools=(), effort="", system_prompt="")
        canned = subprocess.CompletedProcess(args=[], returncode=2, stdout="{}", stderr="oops")
        with patch("subprocess.run", return_value=canned):
            r = run_agent(spec, "brief")
        self.assertEqual(r.exit_code, 2)
        self.assertEqual(r.stderr, "oops")


class PersistRun(unittest.TestCase):
    def test_writes_all_three_files(self):
        from agent_runner import RunResult
        r = RunResult(
            exit_code=0, output_text="hello", raw_json={"result": "hello"},
            session_id="s", model_used="sonnet",
            input_tokens=1, output_tokens=2,
            cache_read_tokens=0, cache_creation_tokens=0,
            cost_cents=0.01, duration_ms=100, stderr="",
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            slug = persist_run(root, "test-agent", "the brief", r)
            self.assertTrue((slug / "brief.md").is_file())
            self.assertTrue((slug / "run.json").is_file())
            self.assertTrue((slug / "output.txt").is_file())
            self.assertEqual((slug / "brief.md").read_text(), "the brief")
            self.assertEqual((slug / "output.txt").read_text(), "hello")
            payload = json.loads((slug / "run.json").read_text())
            self.assertEqual(payload["agent"], "test-agent")
            self.assertEqual(payload["exit_code"], 0)


if __name__ == "__main__":
    unittest.main()
