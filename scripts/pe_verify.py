#!/usr/bin/env python3
"""pe_verify — S4 supply-chain integrity check.

Compares SHA-256 of every load-bearing engine file against a
checked-in MANIFEST.sha256 at repo root. Divergence = local
modification OR upstream poisoning; either way, exit non-zero.

Load-bearing surfaces (rescanned on every release):

    agents/*.md
    commands/*.md
    skills/**/*.md
    hooks/*.sh
    hooks/hooks.json
    scripts/pe
    scripts/pe_*.py
    plugin.json
    VERSION

Adopters run `pe verify` from their project dir; the tool resolves
the engine dir from the argv, env (`ENGINE_DIR`), or auto-locates
via the installed hook paths in `.claude/settings.json`. It then
hashes each surface in the ENGINE dir and compares against
`ENGINE/MANIFEST.sha256`.

Modes:
    (default)      verify — compare on-disk hashes vs MANIFEST, exit
                   non-zero on any divergence.
    --update       regenerate MANIFEST.sha256 (release-time only —
                   run right before `git commit && git tag`).
    --json         emit machine-readable output (for CI + hooks).
    --engine <p>   override the engine dir explicitly.

Exit codes:
    0   all files match the manifest
    1   at least one file diverges (or is missing/extra)
    2   engine dir not resolvable, manifest missing, or usage error
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

# Load-bearing surface patterns, relative to engine root.
# Order matters only for stable manifest output.
SURFACE_GLOBS: tuple[str, ...] = (
    "agents/*.md",
    "commands/*.md",
    "skills/**/*.md",
    "hooks/*.sh",
    "hooks/hooks.json",
    "scripts/pe",
    # Everything `scripts/pe` and the hooks source at runtime. `pe` was a
    # single 1506-line file when this tuple was written, so "scripts/pe" was
    # the whole CLI. v0.51.8 split it into scripts/_cmd_*.sh and left the
    # manifest behind: the dispatcher stayed checksummed while the ~1400
    # lines it sources — every command body — became invisible to
    # `pe verify`. A manifest that covers the entry point and not the code
    # it runs verifies almost nothing.
    "scripts/_*.sh",
    "scripts/pe_*.py",
    # /gate-review is executable gate logic that decides what reaches
    # .claude/gates/last-gate.json, and it ships with the plugin.
    "workflows/*.js",
    "plugin.json",
    "VERSION",
)

MANIFEST_NAME = "MANIFEST.sha256"


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _resolve_engine(explicit: str | None) -> Path:
    if explicit:
        p = Path(explicit).resolve()
        if not p.is_dir():
            raise SystemExit(f"engine dir not found: {p}")
        return p

    env = os.environ.get("ENGINE_DIR") or os.environ.get("PE_ENGINE_DIR")
    if env:
        p = Path(env).resolve()
        if p.is_dir():
            return p

    # Try locating from this script's own path (assumes we're the
    # engine's pe_verify.py running in-tree).
    here = Path(__file__).resolve().parent.parent
    if (here / "hooks" / "hooks.json").exists():
        return here

    # Adopter path: read .claude/settings.json and extract an engine
    # dir from a hook command path. We reject symlinked hook paths so
    # a malicious settings.json can't redirect the checksum target.
    cwd = Path.cwd()
    settings = cwd / ".claude" / "settings.json"
    if settings.exists():
        try:
            data = json.loads(settings.read_text())
        except Exception:
            data = {}
        for section in ("PreToolUse", "PostToolUse", "Stop"):
            for entry in data.get("hooks", {}).get(section, []) or []:
                for h in entry.get("hooks", []) or []:
                    cmd = h.get("command", "")
                    marker = "/hooks/"
                    if marker not in cmd:
                        continue
                    raw = Path(cmd.split(marker, 1)[0])
                    if raw.is_symlink() or not raw.is_dir():
                        continue
                    candidate = raw.resolve()
                    if candidate.is_symlink():
                        continue
                    if (candidate / "hooks" / "hooks.json").exists():
                        return candidate

    raise SystemExit(
        "cannot resolve engine dir. Pass --engine <path>, set "
        "ENGINE_DIR, or run from within the engine's own tree."
    )


def _enumerate_surfaces(engine: Path) -> list[Path]:
    seen: set[Path] = set()
    for pattern in SURFACE_GLOBS:
        for match in engine.glob(pattern):
            if match.is_file():
                seen.add(match.resolve())
    return sorted(seen)


def _compute_manifest(engine: Path) -> dict[str, str]:
    manifest: dict[str, str] = {}
    for path in _enumerate_surfaces(engine):
        rel = str(path.relative_to(engine))
        manifest[rel] = _sha256_file(path)
    return manifest


def _load_manifest(engine: Path) -> dict[str, str]:
    manifest_path = engine / MANIFEST_NAME
    if not manifest_path.exists():
        raise SystemExit(
            f"missing manifest at {manifest_path}. Run "
            f"`pe verify --update` from the engine repo to create it."
        )
    out: dict[str, str] = {}
    for line in manifest_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # Two-column: <hex-sha>  <relpath>
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        digest, rel = parts[0], parts[1].lstrip("*")  # strip GNU marker
        out[rel] = digest
    return out


def _write_manifest(engine: Path, manifest: dict[str, str]) -> Path:
    manifest_path = engine / MANIFEST_NAME
    lines = [
        "# MANIFEST.sha256 — 8colors-process-engine load-bearing surfaces.",
        "# Regenerated at release time via `pe verify --update`.",
        "# Format: <sha256> <relative path>",
        "",
    ]
    for rel, digest in sorted(manifest.items()):
        lines.append(f"{digest}  {rel}")
    manifest_path.write_text("\n".join(lines) + "\n")
    return manifest_path


def _diff(
    on_disk: dict[str, str],
    manifest: dict[str, str],
) -> tuple[list[tuple[str, str, str]], list[str], list[str]]:
    """Return (changed, missing, extra).

    changed: files present in both but with different hashes.
    missing: files in the manifest but not on disk.
    extra:   files on disk that aren't in the manifest.
    """
    changed: list[tuple[str, str, str]] = []
    for rel, expected in manifest.items():
        actual = on_disk.get(rel)
        if actual is None:
            continue
        if actual != expected:
            changed.append((rel, expected, actual))
    missing = sorted(set(manifest) - set(on_disk))
    extra = sorted(set(on_disk) - set(manifest))
    return sorted(changed), missing, extra


def _human_report(engine: Path, changed, missing, extra) -> None:
    print(f"pe verify — engine at {engine}")
    print("")
    if not (changed or missing or extra):
        print("  ✓ manifest clean — no divergence detected.")
        return
    if changed:
        print(f"  ✗ {len(changed)} file(s) DIVERGED from manifest:")
        for rel, expected, actual in changed:
            print(f"    - {rel}")
            print(f"        expected {expected[:12]}…")
            print(f"        actual   {actual[:12]}…")
    if missing:
        print(f"  ✗ {len(missing)} file(s) MISSING (in manifest, not on disk):")
        for rel in missing:
            print(f"    - {rel}")
    if extra:
        print(f"  ⚠ {len(extra)} file(s) NEW (on disk, not in manifest):")
        for rel in extra:
            print(f"    - {rel}")
        print("")
        print("  New files are advisory only — regenerate the manifest")
        print("  at release time with `pe verify --update`.")


def _json_report(engine: Path, changed, missing, extra) -> None:
    payload = {
        "engine": str(engine),
        "verdict": "PASS" if not (changed or missing) else "FAIL",
        "changed": [
            {"path": p, "expected": e, "actual": a}
            for p, e, a in changed
        ],
        "missing": missing,
        "extra": extra,
    }
    print(json.dumps(payload, indent=2))


def _run_update(engine: Path, as_json: bool) -> int:
    """Regenerate MANIFEST.sha256. Release-time only, doubly gated.

    Split out of main() because main() was 68 lines and the size gate
    blocks per-function overages without an escape hatch — deliberately,
    since "the function is long for a good reason" is what every long
    function says. The two refusals below are the whole reason this path
    is not a one-liner, and they read better with a name on them.
    """
    # --update rewrites the ground truth. In an adopter tree, a
    # compromised agent could run `pe verify --update` to whitewash its
    # own poisoning. Gate on an explicit env var AND require the caller
    # to be inside the engine's own tree (the engine repo itself, not an
    # install target).
    if os.environ.get("PE_VERIFY_ALLOW_UPDATE") != "1":
        raise SystemExit(
            "pe verify --update is release-time only. Set "
            "PE_VERIFY_ALLOW_UPDATE=1 to acknowledge you are "
            "regenerating the manifest in the engine repo."
        )
    script_home = Path(__file__).resolve().parent.parent
    if engine.resolve() != script_home:
        raise SystemExit(
            f"pe verify --update refuses to overwrite a manifest "
            f"outside the engine source tree.\n"
            f"  script parent: {script_home}\n"
            f"  engine target: {engine}\n"
            "If you really need to regenerate an adopter manifest, "
            "run this script from that engine's own scripts/ dir."
        )

    manifest = _compute_manifest(engine)
    path = _write_manifest(engine, manifest)
    if as_json:
        print(json.dumps({
            "action": "update",
            "manifest": str(path),
            "entries": len(manifest),
        }, indent=2))
    else:
        print(f"pe verify --update — wrote {len(manifest)} entries to")
        print(f"  {path}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="pe verify")
    parser.add_argument("--engine", help="path to engine repo")
    parser.add_argument(
        "--update",
        action="store_true",
        help="regenerate MANIFEST.sha256 (release-time only)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit machine-readable JSON",
    )
    args = parser.parse_args(argv)

    engine = _resolve_engine(args.engine)

    if args.update:
        return _run_update(engine, args.json)

    on_disk = _compute_manifest(engine)
    manifest = _load_manifest(engine)
    changed, missing, extra = _diff(on_disk, manifest)

    if args.json:
        _json_report(engine, changed, missing, extra)
    else:
        _human_report(engine, changed, missing, extra)

    if changed or missing:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
