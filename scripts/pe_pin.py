#!/usr/bin/env python3
"""pe_pin — A8 per-project engine version pinning.

Today the symlink install model has no version pin — every adopter
rides HEAD on `pe upgrade`. That was fine for two adopters but is
migration debt for a widening beta: an accidental breaking change
in the engine's HEAD would propagate to every downstream project
without warning.

A8 introduces a per-project pin file at `<project>/.claude/.engine-pin.json`:

    {
      "engine_version": "0.33.0",
      "engine_sha":     "bc67143aa8…",
      "installed_at":   "2026-07-03T14:22:11Z",
      "install_mode":   "symlink",
      "engine_path":    "/Users/…/8colors-process-engine"
    }

`pe install` writes this at install time. `pe pin show|verify|bump`
lets an adopter INSPECT and RECONCILE the pin against the engine's
current state.

Subcommands:

    pe pin show [--project PATH]
        Print the pin file contents + drift status (does the pinned
        version match the engine's current VERSION? does the pinned
        SHA still exist in the engine's git history?).
        Exit 0 always (informational).

    pe pin verify [--project PATH]
        Exit 0 if the pin still matches the engine's current
        VERSION + SHA. Exit 1 if the engine has drifted forward
        (pinned version < engine version). Exit 2 if the pin file
        is missing / corrupt.
        Suitable for CI: fail the build if the adopter's local
        engine is ahead of the pinned version.

    pe pin bump [--to VERSION] [--project PATH]
        Reconcile the pin to the engine's current VERSION + SHA
        (or to --to VERSION if that tag is checked out). Rewrites
        the pin file with fresh timestamps. Does NOT re-run install
        — the operator is expected to `pe install` right after,
        which will co-write the same pin.

Read-only guarantees: `pe pin show` and `pe pin verify` never mutate
anything. `pe pin bump` writes the pin file and nothing else.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

PIN_FILENAME = ".claude/.engine-pin.json"


def _now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _resolve_engine_dir(explicit: str | None) -> Path:
    if explicit:
        p = Path(explicit).resolve()
        if not (p / "VERSION").exists():
            raise SystemExit(f"engine dir missing VERSION: {p}")
        return p
    env = os.environ.get("ENGINE_DIR")
    if env and (Path(env) / "VERSION").exists():
        return Path(env).resolve()
    here = Path(__file__).resolve().parent.parent
    if (here / "VERSION").exists():
        return here
    raise SystemExit(
        "cannot resolve engine dir. Pass --engine PATH or set ENGINE_DIR."
    )


def _read_engine_version(engine: Path) -> str:
    return (engine / "VERSION").read_text().strip()


def _read_engine_sha(engine: Path) -> str | None:
    """Return the engine repo's current HEAD sha, or None if not a git tree."""
    try:
        out = subprocess.run(
            ["git", "-C", str(engine), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


def _sha_exists(engine: Path, sha: str) -> bool:
    try:
        out = subprocess.run(
            ["git", "-C", str(engine), "cat-file", "-e", sha],
            capture_output=True,
            timeout=5,
        )
        return out.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def read_pin(project: Path) -> dict | None:
    path = project / PIN_FILENAME
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def write_pin(project: Path, data: dict) -> Path:
    path = project / PIN_FILENAME
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    return path


def _version_tuple(v: str) -> tuple[int, ...]:
    """`0.33.0` → (0, 33, 0). Non-numeric parts sort to -1.

    Pre-release tags like `0.33.0-rc1` end up as (0, 33, -1) — i.e.
    the RC sorts *before* the corresponding release (0.33.0-rc1 <
    0.33.0), which matches semver ordering intent. Fully alphanumeric
    tags fall back the same way and won't crash the drift check.
    """
    out: list[int] = []
    for part in v.split("."):
        try:
            out.append(int(part))
        except ValueError:
            out.append(-1)
    return tuple(out)


def _drift_status(pin: dict, engine_version: str, engine_sha: str | None,
                  engine: Path) -> tuple[str, str]:
    """Return (verdict, human message).

    verdict is one of: pinned | engine_ahead | engine_behind | sha_orphan |
    sha_missing | ok_no_git.
    """
    pinned_version = pin.get("engine_version", "")
    pinned_sha = pin.get("engine_sha")

    if engine_sha is None:
        return "ok_no_git", (
            f"engine at {engine} is not a git tree; pin recorded version="
            f"{pinned_version} but SHA drift cannot be verified"
        )

    pv = _version_tuple(pinned_version)
    ev = _version_tuple(engine_version)

    if pinned_sha and pinned_sha == engine_sha and pinned_version == engine_version:
        return "pinned", (
            f"pin matches engine exactly (version={engine_version}, "
            f"sha={engine_sha[:8]}…)"
        )

    if pinned_sha and not _sha_exists(engine, pinned_sha):
        return "sha_orphan", (
            f"pinned SHA {pinned_sha[:8]}… is no longer reachable from the "
            f"engine's git tree — force-push or rewrite happened. Run "
            f"`pe pin bump` to re-anchor at the current HEAD ({engine_sha[:8]}…)."
        )

    if ev > pv:
        return "engine_ahead", (
            f"engine has moved forward: pin={pinned_version} "
            f"(sha {pinned_sha[:8] if pinned_sha else '?'}…) vs "
            f"engine={engine_version} (sha {engine_sha[:8]}…). Run "
            f"`pe pin bump` after reviewing the CHANGELOG delta."
        )

    if ev < pv:
        return "engine_behind", (
            f"engine is BEHIND the pinned version: pin={pinned_version} "
            f"vs engine={engine_version}. Run `git pull` in the engine "
            f"repo before continuing — the pin was written against a "
            f"newer engine than what's on disk."
        )

    # Same version but different SHA — usually means the version was
    # never tagged and the working tree changed. Report drift.
    return "sha_orphan", (
        f"pin version matches but SHA drifted (pin sha "
        f"{pinned_sha[:8] if pinned_sha else '?'}… vs engine "
        f"{engine_sha[:8]}…). Untagged intra-version change."
    )


def cmd_show(args: argparse.Namespace) -> int:
    project = Path(args.project).resolve()
    engine = _resolve_engine_dir(args.engine)
    pin = read_pin(project)
    if pin is None:
        print(f"pe pin — no pin file at {project / PIN_FILENAME}")
        print("  Adopter was installed before A8, or the file was removed.")
        print("  Run `pe pin bump` after your next `pe install` to create it.")
        return 0
    engine_version = _read_engine_version(engine)
    engine_sha = _read_engine_sha(engine)
    verdict, msg = _drift_status(pin, engine_version, engine_sha, engine)

    if args.json:
        payload = {
            "project": str(project),
            "engine": str(engine),
            "pin": pin,
            "engine_current": {
                "version": engine_version,
                "sha": engine_sha,
            },
            "drift_verdict": verdict,
            "message": msg,
        }
        print(json.dumps(payload, indent=2))
    else:
        print(f"pe pin — {project}")
        print(f"  pinned version: {pin.get('engine_version', '?')}")
        pinned_sha = pin.get("engine_sha") or "(none — non-git install)"
        print(f"  pinned SHA:     {pinned_sha}")
        print(f"  installed at:   {pin.get('installed_at', '?')}")
        print(f"  install mode:   {pin.get('install_mode', '?')}")
        print("")
        print(f"  engine on disk: v{engine_version} "
              f"({engine_sha[:8] + '…' if engine_sha else 'no git'})")
        print(f"  drift verdict:  {verdict}")
        print(f"  {msg}")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    project = Path(args.project).resolve()
    engine = _resolve_engine_dir(args.engine)
    pin = read_pin(project)
    if pin is None:
        print(
            f"pe pin verify: no pin file at {project / PIN_FILENAME}",
            file=sys.stderr,
        )
        return 2
    engine_version = _read_engine_version(engine)
    engine_sha = _read_engine_sha(engine)
    verdict, msg = _drift_status(pin, engine_version, engine_sha, engine)

    if verdict in ("pinned", "ok_no_git"):
        if not args.quiet:
            print(f"pe pin verify: OK ({msg})")
        return 0
    print(f"pe pin verify: DRIFT — {verdict}: {msg}", file=sys.stderr)
    return 1


def cmd_bump(args: argparse.Namespace) -> int:
    project = Path(args.project).resolve()
    if not project.is_dir():
        print(f"pe pin bump: project not found: {project}", file=sys.stderr)
        return 2
    engine = _resolve_engine_dir(args.engine)
    engine_version = _read_engine_version(engine)
    engine_sha = _read_engine_sha(engine)

    target_version = args.to or engine_version
    if target_version != engine_version:
        print(
            f"pe pin bump: --to {target_version} does not match engine's "
            f"VERSION file ({engine_version}). Check out the target tag in "
            f"the engine repo first, then re-run.",
            file=sys.stderr,
        )
        return 2

    existing = read_pin(project) or {}
    data = {
        "engine_version": engine_version,
        "engine_sha": engine_sha,
        "installed_at": _now_utc(),
        "install_mode": existing.get("install_mode", "symlink"),
        "engine_path": str(engine),
        "previous_version": existing.get("engine_version"),
        "previous_sha": existing.get("engine_sha"),
    }
    path = write_pin(project, data)
    print(f"pe pin bump: pin updated → {path}")
    print(f"  version: {existing.get('engine_version', '(new)')} → {engine_version}")
    if engine_sha:
        prev_sha = existing.get("engine_sha")
        print(f"  sha:     {prev_sha[:8] + '…' if prev_sha else '(new)'} → {engine_sha[:8]}…")
    return 0


def _common_opts(p: argparse.ArgumentParser) -> None:
    p.add_argument("--project", default=".", help="project root (default cwd)")
    p.add_argument("--engine", help="engine repo path (default: auto-resolve)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pe pin")
    sub = parser.add_subparsers(dest="subcmd", required=True)

    p_show = sub.add_parser("show", help="print pin file + drift status")
    _common_opts(p_show)
    p_show.add_argument("--json", action="store_true", help="machine-readable output")
    p_show.set_defaults(func=cmd_show)

    p_verify = sub.add_parser("verify", help="exit 1 if engine has drifted from pin")
    _common_opts(p_verify)
    p_verify.add_argument("--quiet", action="store_true", help="suppress OK output")
    p_verify.set_defaults(func=cmd_verify)

    p_bump = sub.add_parser("bump", help="rewrite pin to engine's current version + SHA")
    _common_opts(p_bump)
    p_bump.add_argument("--to", help="only accept engine's VERSION if it equals this")
    p_bump.set_defaults(func=cmd_bump)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
