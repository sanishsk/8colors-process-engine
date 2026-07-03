#!/usr/bin/env python3
"""agent_runner.py — headless invocation of an engine agent via `claude -p` (A4).

The engine has 19 specialist agents defined as `agents/<name>.md` files
with YAML frontmatter (name, model, tools) + a body that is the system
prompt. Until now they were invokable only interactively (by the
operator selecting the agent in Claude Code) or via the shadow router
recording what it WOULD do. A4 closes that gap: this module wraps
`claude -p` so any caller — the gate-efficacy eval harness, the
shadow orchestrator's auto-escalation loop, a hook script — can invoke
an agent by name with a brief and get back a structured result.

Design principles
-----------------

- **Feature-detected.** If the `claude` CLI is not on PATH, exit 3
  with a clear message. Callers (eval harness, orchestrator) must
  treat this as a clean SKIP, not a failure.
- **No side effects outside `.pe/runs/`.** The agent's response goes
  to stdout (default) or `--out <file>`. A structured run record is
  written to `.pe/runs/<timestamp>-<agent>-<short-id>/run.json` for
  post-mortem + telemetry ingestion.
- **Robust JSON parsing.** `claude -p --output-format json` returns a
  shape that has evolved across releases. This module extracts what
  it can (result text, session_id, model, usage) and keeps the raw
  JSON in the run record so schema drift is visible, not silently
  swallowed.
- **Cost + token accounting.** Same units as A1's `TurnRecord` so the
  run records can be joined against `.pe/telemetry.jsonl` later. The
  actual pricing comes from `scripts/telemetry.py::_cost_cents`.
- **NO auto-escalation, NO orchestrator wiring in this file.** This
  is the primitive. The orchestrator wiring (`worker_quality FAIL →
  invoke next tier`) is a caller of this primitive and lives in
  `scripts/pe_orchestrator.py` in a follow-up release.

Usage
-----

    pe agent run <agent-name> [--brief <file>|--brief -] [--out <path>]
                              [--model <override>] [--timeout <s>]
                              [--dry-run]

    - `--brief -` reads from stdin
    - `--brief <file>` reads from a file
    - Default: agent output printed to stdout
    - `--out <path>` writes agent output to that path instead
    - `--dry-run` prints the assembled invocation without running

Exit codes
----------

    0  success
    1  agent exited non-zero (see stderr)
    2  invalid args
    3  claude CLI not on PATH (feature-detected skip)
    4  agent .md file missing or unparseable
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from dataclasses import dataclass, field
from pathlib import Path

# Import cost table from A1 for consistent pricing across runs + telemetry.
_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
try:
    from telemetry import _cost_cents  # noqa: E402
except ImportError:
    # Feature-detected fallback: agent_runner still works without cost.
    def _cost_cents(usage: dict, model: str) -> float:
        return 0.0


ENGINE_DIR = _HERE.parent
AGENTS_DIR = ENGINE_DIR / "agents"


# ─── agent spec loading ─────────────────────────────────────────────────

@dataclass(frozen=True)
class AgentSpec:
    """One agent's frontmatter + body, extracted from agents/<name>.md."""

    name: str
    model: str  # 'sonnet' / 'opus' / 'haiku' / full model id
    tools: tuple[str, ...]
    effort: str  # 'low' / 'medium' / 'high' / '' if absent
    system_prompt: str  # body after frontmatter


_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def _parse_frontmatter(text: str) -> tuple[dict[str, str], str]:
    """Return (frontmatter_dict, body). Shallow YAML — key: value per line.

    Supports quoted strings, unquoted strings, JSON-array values.
    Raises ValueError if the file has no frontmatter block.
    """
    m = _FRONTMATTER_RE.match(text)
    if not m:
        raise ValueError("agent file has no YAML frontmatter block")
    front_text = m.group(1)
    body = text[m.end():]
    fm: dict[str, str] = {}
    for line in front_text.splitlines():
        if not line.strip() or line.strip().startswith("#"):
            continue
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        fm[key.strip()] = val.strip()
    return fm, body


def _parse_tools(raw: str) -> tuple[str, ...]:
    """Frontmatter tools can be JSON array or unquoted comma-list."""
    raw = raw.strip()
    if not raw:
        return ()
    if raw.startswith("["):
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, list):
                return tuple(str(t) for t in parsed)
        except json.JSONDecodeError:
            pass
    # fallback: strip quotes and comma-split
    return tuple(t.strip().strip('"').strip("'") for t in raw.split(",") if t.strip())


_AGENT_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


def load_agent_spec(agent_name: str, agents_dir: Path = AGENTS_DIR) -> AgentSpec:
    """Load and parse an agent .md file. Raises FileNotFoundError / ValueError.

    Rejects agent_name containing path separators or `..` — not because
    the engine crosses a privilege boundary (it's a local dev tool run
    by the operator against their own machine), but because those
    characters signal a typo, not a legitimate agent reference. Prevents
    stray `pe agent run ../something` from silently resolving to files
    outside `agents/`.
    """
    if not _AGENT_NAME_RE.match(agent_name or ""):
        raise FileNotFoundError(
            f"invalid agent name: {agent_name!r} — expected a bare identifier "
            "matching [A-Za-z0-9_.-]+ (no slashes, no ..)"
        )
    agent_path = agents_dir / f"{agent_name}.md"
    if not agent_path.is_file():
        raise FileNotFoundError(f"agent not found: {agent_path}")
    text = agent_path.read_text(encoding="utf-8")
    fm, body = _parse_frontmatter(text)
    return AgentSpec(
        name=fm.get("name") or agent_name,
        model=fm.get("model") or "sonnet",
        tools=_parse_tools(fm.get("tools", "")),
        effort=fm.get("effort", "").strip('"').strip("'"),
        system_prompt=body,
    )


# ─── subprocess invocation ──────────────────────────────────────────────

def build_argv(spec: AgentSpec, *, model_override: str | None = None) -> list[str]:
    """Assemble the `claude -p` invocation for this agent.

    The system prompt goes via `--append-system-prompt` (not
    `--system-prompt`) as a deliberate safety choice: `--system-prompt`
    REPLACES Claude Code's default system prompt, which contains tool-
    policy rules and safety guardrails. If an agent persona later
    instructs Claude to ignore those (accidentally or via prompt
    injection through the brief), replacing the default would leave no
    defence in depth. `--append-system-prompt` STACKS the persona on
    top: the safety layer stays active, the agent adds domain focus.

    The brief is passed on stdin, not argv — avoids the OS argv-length
    ceiling and keeps the invocation shape independent of brief size.
    """
    model = model_override or spec.model
    argv = [
        "claude",
        "-p",
        "--output-format", "json",
        "--model", model,
        "--append-system-prompt", spec.system_prompt,
    ]
    if spec.tools:
        argv.extend(["--allowedTools", " ".join(spec.tools)])
    return argv


@dataclass
class RunResult:
    """Structured result of one headless agent invocation."""

    exit_code: int
    output_text: str  # the assistant's final response (best-effort extract)
    raw_json: dict  # the full JSON blob returned by claude -p
    session_id: str | None
    model_used: str | None
    input_tokens: int
    output_tokens: int
    cache_read_tokens: int
    cache_creation_tokens: int
    cost_cents: float
    duration_ms: int | None
    stderr: str

    def to_dict(self) -> dict:
        return {
            "exit_code": self.exit_code,
            "output_text": self.output_text,
            "raw_json": self.raw_json,
            "session_id": self.session_id,
            "model_used": self.model_used,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cache_read_tokens": self.cache_read_tokens,
            "cache_creation_tokens": self.cache_creation_tokens,
            "cost_cents": round(self.cost_cents, 4),
            "duration_ms": self.duration_ms,
            "stderr": self.stderr,
        }


def _primary_model_from_modelusage(raw: dict) -> str | None:
    """Pick the primary model from a `modelUsage` breakdown.

    Real `claude -p --output-format json` output puts a per-model
    breakdown under `modelUsage` (mixed model IDs like
    `claude-sonnet-4-6` + `claude-haiku-4-5-*` because Claude Code
    routes short tool calls to haiku while the main run stays on
    sonnet). Pick the model with the most output tokens as the
    "primary" — that's the one that emitted the response.

    Returns None if `modelUsage` is missing or empty.
    """
    mu = raw.get("modelUsage")
    if not isinstance(mu, dict) or not mu:
        return None
    best_id, best_out = None, -1
    for model_id, stats in mu.items():
        if not isinstance(stats, dict):
            continue
        out = stats.get("outputTokens") or 0
        if out > best_out:
            best_id, best_out = model_id, out
    return best_id


def parse_result(
    stdout: str, stderr: str, exit_code: int, requested_model: str
) -> RunResult:
    """Best-effort extract of RunResult from `claude -p --output-format json`.

    The real shape (verified against Claude Code 1.x, 2026-07):
      * assistant text under `result`
      * `session_id`, `duration_ms` at top level
      * `usage` dict with input_tokens / output_tokens /
        cache_read_input_tokens / cache_creation_input_tokens
      * `modelUsage` dict — per-model breakdown (may mix haiku+sonnet
        when Claude Code routes short tool calls). Keys are real
        model IDs; each value has `costUSD` for that model.
      * `total_cost_usd` at top level — the authoritative cost from
        Claude itself. USE THIS when present instead of deriving from
        the price table — the derived path misses cache-write pricing
        edge cases and gets stale as Anthropic ships new models.
      * NO top-level `model` key (this was the v0.21.0 bug — the
        parser fell back to the requested alias like "sonnet", which
        then missed the price table's `claude-sonnet-*` prefix).

    Missing keys default to safe zeros — raw_json carries the full
    blob so schema drift is inspectable in
    `.pe/runs/<slug>/run.json`.
    """
    raw: dict = {}
    output_text = stdout
    if stdout.strip():
        try:
            raw = json.loads(stdout)
            if isinstance(raw, dict):
                # extract text
                output_text = (
                    raw.get("result")
                    or raw.get("response")
                    or raw.get("text")
                    or stdout
                )
        except json.JSONDecodeError:
            # Not JSON — treat the whole stdout as the response text.
            raw = {"_raw_stdout": stdout}

    usage = raw.get("usage") if isinstance(raw, dict) else None
    if not isinstance(usage, dict):
        usage = {}

    # Model resolution: real ID from modelUsage → legacy `model` top-level
    # → requested alias fallback. First two are authoritative; last
    # keeps the persisted record populated even against pre-1.x output.
    model_used = (
        _primary_model_from_modelusage(raw)
        or (raw.get("model") if isinstance(raw, dict) else None)
        or requested_model
    )

    # Cost: prefer authoritative total_cost_usd (converted to cents)
    # when Claude reports it; fall back to derived cost otherwise.
    total_cost_usd = raw.get("total_cost_usd") if isinstance(raw, dict) else None
    if isinstance(total_cost_usd, (int, float)):
        cost_cents = float(total_cost_usd) * 100.0
    else:
        cost_cents = _cost_cents(usage, model_used)

    return RunResult(
        exit_code=exit_code,
        output_text=output_text if isinstance(output_text, str) else str(output_text),
        raw_json=raw if isinstance(raw, dict) else {},
        session_id=raw.get("session_id") if isinstance(raw, dict) else None,
        model_used=model_used,
        input_tokens=int(usage.get("input_tokens") or 0),
        output_tokens=int(usage.get("output_tokens") or 0),
        cache_read_tokens=int(usage.get("cache_read_input_tokens") or 0),
        cache_creation_tokens=int(usage.get("cache_creation_input_tokens") or 0),
        cost_cents=cost_cents,
        duration_ms=int(raw.get("duration_ms")) if isinstance(raw, dict) and raw.get("duration_ms") is not None else None,
        stderr=stderr,
    )


def run_agent(
    spec: AgentSpec,
    brief: str,
    *,
    model_override: str | None = None,
    timeout_s: int = 600,
) -> RunResult:
    """Invoke `claude -p` with the agent's persona + brief."""
    argv = build_argv(spec, model_override=model_override)
    try:
        proc = subprocess.run(  # noqa: S603 — argv is programmatically built
            argv,
            input=brief,
            capture_output=True,
            text=True,
            timeout=timeout_s,
            check=False,
        )
    except FileNotFoundError as e:
        raise ClaudeNotOnPathError(str(e)) from e
    return parse_result(proc.stdout, proc.stderr, proc.returncode, model_override or spec.model)


class ClaudeNotOnPathError(RuntimeError):
    """Raised when the `claude` binary is not on PATH — feature-detected skip."""


# ─── run persistence ────────────────────────────────────────────────────

def _run_slug(agent_name: str) -> str:
    ts = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    short = uuid.uuid4().hex[:8]
    return f"{ts}-{agent_name}-{short}"


def persist_run(
    project_root: Path, agent_name: str, brief: str, result: RunResult
) -> Path:
    """Write .pe/runs/<slug>/{brief.md, run.json, output.txt}."""
    runs_dir = project_root / ".pe" / "runs"
    runs_dir.mkdir(parents=True, exist_ok=True)
    slug_dir = runs_dir / _run_slug(agent_name)
    slug_dir.mkdir(exist_ok=True)
    (slug_dir / "brief.md").write_text(brief, encoding="utf-8")
    (slug_dir / "run.json").write_text(
        json.dumps({"agent": agent_name, **result.to_dict()}, indent=2),
        encoding="utf-8",
    )
    (slug_dir / "output.txt").write_text(result.output_text, encoding="utf-8")
    return slug_dir


# ─── CLI ────────────────────────────────────────────────────────────────

def _read_brief(brief_arg: str) -> str:
    if brief_arg == "-":
        return sys.stdin.read()
    p = Path(brief_arg)
    if not p.is_file():
        raise FileNotFoundError(f"brief file not found: {brief_arg}")
    return p.read_text(encoding="utf-8")


def cmd_run(args: argparse.Namespace) -> int:
    try:
        spec = load_agent_spec(args.agent)
    except (FileNotFoundError, ValueError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 4

    try:
        brief = _read_brief(args.brief) if args.brief else ""
    except FileNotFoundError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if args.dry_run:
        argv = build_argv(spec, model_override=args.model)
        # Redact the system prompt for the dry-run summary — the file is
        # 500+ lines and belongs in the persisted run record, not stdout.
        redacted = [a if a != spec.system_prompt else f"<{len(spec.system_prompt)} chars of system prompt>" for a in argv]
        print("dry-run invocation:")
        for a in redacted:
            print(f"  {a!r}")
        print(f"\nbrief ({len(brief)} chars):")
        print(brief[:500] + ("..." if len(brief) > 500 else ""))
        return 0

    if shutil.which("claude") is None:
        print(
            "SKIP: `claude` CLI not on PATH — install Claude Code to enable "
            "`pe agent run` (feature-detected skip)",
            file=sys.stderr,
        )
        return 3

    try:
        result = run_agent(
            spec, brief, model_override=args.model, timeout_s=args.timeout
        )
    except ClaudeNotOnPathError as e:
        print(f"SKIP: {e}", file=sys.stderr)
        return 3

    project_root = Path.cwd()
    slug_dir = persist_run(project_root, args.agent, brief, result)

    if args.out:
        Path(args.out).write_text(result.output_text, encoding="utf-8")
    else:
        sys.stdout.write(result.output_text)
        if not result.output_text.endswith("\n"):
            sys.stdout.write("\n")

    print(
        f"[agent-run] {args.agent} model={result.model_used} "
        f"tokens_in={result.input_tokens} tokens_out={result.output_tokens} "
        f"cost_cents={result.cost_cents:.2f} run={slug_dir.name}",
        file=sys.stderr,
    )
    return result.exit_code


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="pe agent",
        description="Headless invocation of engine agents via `claude -p` (A4).",
    )
    sub = p.add_subparsers(dest="sub", required=True)

    r = sub.add_parser("run", help="Invoke an agent headlessly with a brief")
    r.add_argument("agent", help="Agent name (matches agents/<name>.md)")
    r.add_argument("--brief", help="Brief file path, or '-' for stdin")
    r.add_argument("--out", help="Write agent output to this file instead of stdout")
    r.add_argument("--model", help="Override the agent's default model (sonnet/opus/haiku or full ID)")
    r.add_argument("--timeout", type=int, default=600, help="Subprocess timeout in seconds (default 600)")
    r.add_argument("--dry-run", action="store_true", help="Print assembled invocation without executing")
    r.set_defaults(func=cmd_run)

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
