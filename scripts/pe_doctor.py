#!/usr/bin/env python3
"""pe_doctor — does this project actually RUN the engine's hooks?

`pe verify` is a supply-chain check: it proves the engine's files on disk
match MANIFEST.sha256. It is silent about whether any of them execute.
Those are different questions, and a project can pass the first while
failing the second completely.

The incident that motivated this (Origyn, 2026-09-04):

    .pre-commit-config.yaml         listed 10 engine hooks
    .git/hooks/pre-commit           -> ../../scripts/pre-commit.sh
    pre-commit (framework)          installed and on PATH
    hooks actually executed         0

The project had hand-rolled its own pre-commit script and symlinked it
into .git/hooks. That silently replaced the framework's dispatcher, so
every hook in .pre-commit-config.yaml became decoration. Among them was
claude-md-size.sh, which blocks a CLAUDE.md over 20,000 bytes. The
project's CLAUDE.md reached 80,437 bytes — four times the engine's own
hard limit — while the guard against exactly that sat configured and
unreachable.

Nobody was careless. The failure is invisible by construction: both
mechanisms are named "pre-commit", both look installed, and the one
that runs never mentions the one that doesn't.

Checks
------
  1  .git/hooks/pre-commit exists at all
  2  if .pre-commit-config.yaml lists engine hooks, the framework's
     dispatcher is what .git/hooks/pre-commit actually invokes
  3  .pre-commit-config.yaml is tracked by git (untracked config is
     config nobody reviews, shares, or gets on a fresh clone)
  4  every engine hook path referenced from .claude/settings.json and
     .pre-commit-config.yaml resolves to a file that exists
  5  the engine dir the project points at is the one `pe` resolves

Exit codes
----------
  0   every check passed (warnings may still be printed)
  1   at least one check FAILED — hooks are configured but cannot run
  2   usage error / project dir not resolvable
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

FRAMEWORK_MARKERS = ("pre-commit.run", "pre_commit", "INSTALL_PYTHON", "pre-commit run")
HOOK_REF = re.compile(r"(?:[\w./~{}-]*/)?hooks/([a-z0-9_-]+\.sh)")


class Result:
    def __init__(self) -> None:
        self.rows: list[tuple[str, str, str]] = []
        self.failed = False

    def add(self, status: str, name: str, detail: str) -> None:
        self.rows.append((status, name, detail))
        if status == "FAIL":
            self.failed = True


def _git(project: Path, *args: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", str(project), *args],
            capture_output=True, text=True, timeout=10,
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def _read(p: Path) -> str:
    try:
        return p.read_text(errors="replace")
    except Exception:
        return ""


def _check_git_hook(r: Result, githooks: Path, cfg_hooks: list[str]) -> None:
    """1 — is there a pre-commit hook at all?"""
    if githooks.exists():
        r.add("OK", "git hook present",
              str(githooks.readlink()) if githooks.is_symlink() else "regular file")
    elif cfg_hooks:
        r.add("FAIL", "git hook present",
              f".pre-commit-config.yaml lists {len(cfg_hooks)} engine hook(s) "
              "but .git/hooks/pre-commit does not exist — run `pre-commit install`")
    else:
        r.add("WARN", "git hook present",
              "no .git/hooks/pre-commit; nothing gates commits in this project")


def _check_bypass(r: Result, githooks: Path, cfg_hooks: list[str]) -> None:
    """2 — THE BYPASS. Config lists engine hooks, but the installed hook is
    not the framework's dispatcher, so none of them run."""
    if not (cfg_hooks and githooks.exists()):
        return
    if any(m in _read(githooks) for m in FRAMEWORK_MARKERS):
        r.add("OK", "engine hooks reachable",
              f"{len(cfg_hooks)} hook(s) via the pre-commit framework")
        return
    target = ""
    if githooks.is_symlink():
        try:
            target = os.readlink(githooks)
        except OSError:
            target = ""
    shown = ", ".join(cfg_hooks[:4]) + ("…" if len(cfg_hooks) > 4 else "")
    r.add("FAIL", "engine hooks reachable",
          f".pre-commit-config.yaml configures {len(cfg_hooks)} engine hook(s) "
          f"({shown}) but .git/hooks/pre-commit is a project script"
          + (f" -> {target}" if target else "")
          + " and never invokes them. They are decoration. "
            "Either run `pre-commit install` (and fold the project script in as a "
            "local hook), or delete .pre-commit-config.yaml so it stops implying "
            "a guard that is not there.")


def _check_tracked(r: Result, project: Path, cfg: Path) -> None:
    """3 — untracked config is config nobody reviews or clones."""
    if not cfg.exists():
        return
    if _git(project, "ls-files", "--error-unmatch", ".pre-commit-config.yaml"):
        r.add("OK", "config tracked", ".pre-commit-config.yaml is in git")
    else:
        r.add("WARN", "config tracked",
              ".pre-commit-config.yaml is untracked — it will not reach a fresh "
              "clone, a teammate, or CI, and no review ever sees it change")


def _check_paths(r: Result, project: Path, engine: Path | None,
                 cfg_hooks: list[str], settings: Path) -> None:
    """4 — every referenced hook file exists."""
    refs: list[tuple[str, str]] = [(".pre-commit-config.yaml", h) for h in cfg_hooks]
    for m in re.finditer(r'"command"\s*:\s*"([^"]+)"', _read(settings)):
        if "/hooks/" in m.group(1):
            refs.append((".claude/settings.json", m.group(1)))
    if not refs:
        return
    missing = []
    for source, ref in refs:
        cand = ref
        if not cand.startswith("/"):
            cand = (str(engine / "hooks" / cand) if engine and "/" not in cand
                    else str((project / ref.lstrip("./")).resolve()))
        cand = cand.replace("{{ENGINE_DIR}}", str(engine) if engine else "").split()[0]
        if cand and not Path(cand).exists():
            missing.append(f"{source} → {ref}")
    if missing:
        r.add("FAIL", "hook paths resolve",
              f"{len(missing)} referenced hook file(s) do not exist: "
              + "; ".join(missing[:3]) + ("…" if len(missing) > 3 else ""))
    else:
        r.add("OK", "hook paths resolve", f"{len(refs)} reference(s) all exist")


def _check_engine(r: Result, engine: Path | None) -> None:
    """5 — the engine this project points at."""
    if not engine:
        r.add("WARN", "engine resolved",
              "could not resolve an engine dir; pass --engine or set ENGINE_DIR")
    elif (engine / "hooks" / "hooks.json").exists():
        ver = _read(engine / "VERSION").strip() or "unknown"
        r.add("OK", "engine resolved", f"{engine} (v{ver})")
    else:
        r.add("FAIL", "engine resolved",
              f"{engine} has no hooks/hooks.json — not an engine checkout")


def check_project(project: Path, engine: Path | None) -> Result:
    r = Result()
    githooks = project / ".git" / "hooks" / "pre-commit"
    cfg = project / ".pre-commit-config.yaml"
    cfg_text = _read(cfg)
    cfg_hooks = sorted(set(HOOK_REF.findall(cfg_text))) if cfg_text else []

    _check_git_hook(r, githooks, cfg_hooks)
    _check_bypass(r, githooks, cfg_hooks)
    _check_tracked(r, project, cfg)
    _check_paths(r, project, engine, cfg_hooks, project / ".claude" / "settings.json")
    _check_engine(r, engine)
    return r


def resolve_engine(explicit: str | None, project: Path) -> Path | None:
    for cand in (explicit, os.environ.get("ENGINE_DIR")):
        if cand and (Path(cand) / "hooks" / "hooks.json").exists():
            return Path(cand).resolve()
    settings = _read(project / ".claude" / "settings.json")
    for m in re.finditer(r'"command"\s*:\s*"([^"]+)/hooks/[^"]+"', settings):
        p = Path(m.group(1))
        if (p / "hooks" / "hooks.json").exists():
            return p.resolve()
    here = Path(__file__).resolve().parent.parent
    if (here / "hooks" / "hooks.json").exists():
        return here
    return None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="pe doctor",
        description="Check that this project actually RUNS the engine's hooks "
                    "(pe verify only proves the files are unmodified).")
    ap.add_argument("project", nargs="?", default=".", help="project dir (default: cwd)")
    ap.add_argument("--engine", help="engine dir override")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args(argv)

    project = Path(args.project).resolve()
    if not project.is_dir():
        print(f"ERROR: not a directory: {project}", file=sys.stderr)
        return 2

    engine = resolve_engine(args.engine, project)
    res = check_project(project, engine)

    if args.json:
        print(json.dumps({
            "project": str(project),
            "engine": str(engine) if engine else None,
            "ok": not res.failed,
            "checks": [{"status": s, "name": n, "detail": d} for s, n, d in res.rows],
        }, indent=2))
        return 1 if res.failed else 0

    icon = {"OK": "✓", "WARN": "⚠", "FAIL": "✗"}
    print(f"pe doctor — {project}")
    for status, name, detail in res.rows:
        print(f"  {icon[status]} {name:24} {detail}")
    if res.failed:
        print("\n  Hooks are configured but cannot run. A guard that does not "
              "execute is\n  worse than none, because it is relied on.")
    return 1 if res.failed else 0


if __name__ == "__main__":
    sys.exit(main())
