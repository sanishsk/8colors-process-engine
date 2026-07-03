#!/usr/bin/env python3
"""pe_new.py — A6 project scaffolder + reusable domain module dropper.

Two surfaces:

    pe new <name> [--stack python-flask|generic] [--dir <parent>]
                  [--tagline "one-liner"] [--no-install]
        Scaffolds a fresh project directory from templates/scaffold/<stack>/,
        substitutes {{PROJECT_NAME}}/{{PROJECT_SLUG}}/{{PROJECT_TAGLINE}}
        placeholders, initializes git, then runs `pe install` on the new
        directory unless --no-install is passed.

    pe module add <module-name> [--project <path>]
        Materializes a reusable domain module (currently only
        `api-credentials`) into the project's modules/ tree. Never
        overwrites existing files — reports "skipped" for each collision.

Design principles
-----------------

* **Templates carry .template suffix** ONLY for files that would
  otherwise conflict with the project's own tooling scanning them
  (e.g. `.gitignore.template` → written as `.gitignore`). This keeps
  the engine repo's own linters from tripping on scaffolded content.
* **No overwrite.** `pe new` refuses to run if the target directory
  is non-empty. `pe module add` refuses to overwrite individual files.
* **Deterministic.** Zero API cost. Template drop + placeholder
  substitution + git init. `project-kickstarter` agent is the
  interactive / reasoning complement (already exists).
* **Post-scaffold `pe install` runs automatically** so the new project
  boots with all agents / hooks / skills wired.

Exit codes
----------

    0  success
    1  target directory exists and is non-empty (`pe new`) OR module
       already fully materialized (`pe module add`)
    2  invalid args
    3  unknown stack / module name
    4  template dir missing (broken engine install)
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ENGINE_DIR = Path(__file__).resolve().parent.parent
SCAFFOLD_DIR = ENGINE_DIR / "templates" / "scaffold"
DOMAIN_MODULES_DIR = ENGINE_DIR / "templates" / "domain-modules"

# Names of files that ship with a .template suffix so they don't
# execute / lint inside the engine repo. The suffix is stripped on
# materialization.
TEMPLATE_SUFFIX = ".template"

# Files that need placeholder substitution. Everything else is copied
# byte-for-byte.
_PLACEHOLDER_RE = re.compile(r"\{\{(PROJECT_NAME|PROJECT_SLUG|PROJECT_TAGLINE)\}\}")

# Files in the scaffold whose bare name should become dot-prefixed at
# materialization time (e.g. `gitignore.template` → `.gitignore`).
_DOTFILE_MAP = {
    "gitignore": ".gitignore",
    "env.example": ".env.example",
}


def _slugify(name: str) -> str:
    """Lowercase + hyphenate → project-slug shape."""
    s = re.sub(r"[^a-zA-Z0-9]+", "-", name).strip("-").lower()
    return s or "project"


def _substitute(text: str, name: str, slug: str, tagline: str) -> str:
    def _repl(m: re.Match) -> str:
        key = m.group(1)
        if key == "PROJECT_NAME":
            return name
        if key == "PROJECT_SLUG":
            return slug
        if key == "PROJECT_TAGLINE":
            return tagline
        return m.group(0)
    return _PLACEHOLDER_RE.sub(_repl, text)


def _dst_name(src_name: str) -> str:
    """Compute the materialized filename from the template's name."""
    # Strip the .template suffix if present.
    if src_name.endswith(TEMPLATE_SUFFIX):
        src_name = src_name[: -len(TEMPLATE_SUFFIX)]
    # Dotfile map (kept out of the template dir so ls shows them).
    return _DOTFILE_MAP.get(src_name, src_name)


# Directory names to skip entirely — Python bytecode caches, VCS
# metadata, etc. A defensive walker is cheaper than re-cleaning every
# template dir after a rogue `pytest` run leaves __pycache__ behind
# (regression from v0.25.0 reviewer: a stray __pycache__ in a template
# would break `pe module add` with UnicodeDecodeError).
_SKIP_DIRS = {"__pycache__", ".git", ".pytest_cache", ".mypy_cache", ".ruff_cache", "node_modules"}

# Extensions we always copy byte-for-byte (no placeholder substitution).
# Everything else is treated as text with `read_text(encoding='utf-8')`.
_BINARY_EXTS = {".pyc", ".pyo", ".so", ".dylib", ".dll", ".whl", ".zip",
                ".tar", ".gz", ".jpg", ".jpeg", ".png", ".gif", ".ico",
                ".pdf", ".woff", ".woff2", ".ttf", ".otf"}


def _copy_tree(src: Path, dst: Path, name: str, slug: str, tagline: str,
               skip_existing: bool = False) -> tuple[int, int]:
    """Copy src → dst recursively with placeholder substitution.

    Skips __pycache__/.git/etc; copies known binary extensions
    byte-for-byte without substitution; substitutes placeholders in
    everything else. Returns (files_written, files_skipped).
    """
    written = 0
    skipped = 0
    for root, dirs, files in os.walk(src):
        # Prune skipped dirs before descent (mutates os.walk's list).
        dirs[:] = [d for d in dirs if d not in _SKIP_DIRS]
        rel = Path(root).relative_to(src)
        target_dir = dst / rel
        target_dir.mkdir(parents=True, exist_ok=True)
        for f in files:
            src_file = Path(root) / f
            out_name = _dst_name(f)
            out_path = target_dir / out_name
            if skip_existing and out_path.exists():
                print(f"  ⏭  skipped (exists): {out_path.relative_to(dst)}", file=sys.stderr)
                skipped += 1
                continue
            # Binary files: copy verbatim, no substitution.
            if src_file.suffix.lower() in _BINARY_EXTS:
                shutil.copy2(src_file, out_path)
                written += 1
                continue
            body = src_file.read_text(encoding="utf-8")
            body = _substitute(body, name, slug, tagline)
            out_path.write_text(body, encoding="utf-8")
            written += 1
    return written, skipped


# ─── pe new ─────────────────────────────────────────────────────────────


def cmd_new(args: argparse.Namespace) -> int:
    if not args.name:
        print("ERROR: project name required", file=sys.stderr)
        return 2

    parent = Path(args.dir).resolve() if args.dir else Path.cwd()
    slug = _slugify(args.name)
    target = parent / slug

    if target.exists() and any(target.iterdir()):
        print(
            f"ERROR: {target} exists and is not empty.\n"
            f"  Refusing to scaffold over existing files.",
            file=sys.stderr,
        )
        return 1

    stack_dir = SCAFFOLD_DIR / args.stack
    if not stack_dir.is_dir():
        available = ", ".join(sorted(p.name for p in SCAFFOLD_DIR.iterdir() if p.is_dir()))
        print(
            f"ERROR: unknown stack {args.stack!r}. Available: {available}",
            file=sys.stderr,
        )
        return 3

    target.mkdir(parents=True, exist_ok=True)
    tagline = args.tagline or f"{args.name} — a {args.stack} project."

    print(f"→ Scaffolding {args.name} ({args.stack}) into {target}")
    written, _ = _copy_tree(stack_dir, target, args.name, slug, tagline)
    print(f"✓ wrote {written} file(s)")

    # git init — best-effort, non-fatal on missing git.
    if shutil.which("git"):
        try:
            subprocess.run(
                ["git", "init", "-q", "-b", "main"],
                cwd=target,
                check=True,
                stdout=subprocess.DEVNULL,
            )
            print("✓ initialized git (branch main)")
        except subprocess.CalledProcessError:
            print("⚠ git init failed — you can run it manually later", file=sys.stderr)
    else:
        print("⚠ git not on PATH — skipping git init", file=sys.stderr)

    # Post-scaffold pe install.
    if not args.no_install:
        pe = ENGINE_DIR / "scripts" / "pe"
        print(f"→ Running pe install")
        try:
            subprocess.run([str(pe), "install", str(target)], check=True)
        except subprocess.CalledProcessError as e:
            print(f"⚠ pe install exited {e.returncode} — engine wiring may be incomplete",
                  file=sys.stderr)
            return 0  # scaffold itself succeeded

    print(f"\n✓ {args.name} scaffolded at {target}")
    print(f"\nNext steps:")
    if args.stack == "python-flask":
        print(f"  cd {target}")
        print(f"  python3.11 -m venv .venv && source .venv/bin/activate")
        print(f"  pip install -e '.[dev]'")
        print(f"  cp .env.example .env  # then fill in real values")
        print(f"  pytest -q             # confirm smoke test passes")
    else:
        print(f"  cd {target}")
        print(f"  # Set up your language/framework of choice")
    print(f"  # Restart Claude Code in the new directory to load agents")
    return 0


# ─── pe module add ──────────────────────────────────────────────────────


def cmd_module_add(args: argparse.Namespace) -> int:
    module_dir = DOMAIN_MODULES_DIR / args.module
    if not module_dir.is_dir():
        available = ", ".join(sorted(p.name for p in DOMAIN_MODULES_DIR.iterdir() if p.is_dir()))
        print(
            f"ERROR: unknown module {args.module!r}. Available: {available}",
            file=sys.stderr,
        )
        return 3

    project = Path(args.project).resolve() if args.project else Path.cwd()
    if not project.is_dir():
        print(f"ERROR: project dir does not exist: {project}", file=sys.stderr)
        return 2

    # Modules materialize under modules/<module-name>/.
    target = project / "modules" / args.module.replace("-", "_")
    target.mkdir(parents=True, exist_ok=True)

    print(f"→ Materializing module {args.module!r} into {target}")
    written, skipped = _copy_tree(
        module_dir, target,
        name=args.module, slug=args.module, tagline=args.module,
        skip_existing=True,
    )
    if written == 0 and skipped > 0:
        print(f"⚠ nothing written — all {skipped} file(s) already exist", file=sys.stderr)
        return 1
    print(f"✓ wrote {written} file(s), skipped {skipped} existing file(s)")

    # Point the operator at the module's README.
    readme = target / "README.md"
    if readme.is_file():
        print(f"\nRead {readme.relative_to(project)} for post-materialization steps:")
        print(f"  * deps to add to pyproject.toml")
        print(f"  * env-var setup (CREDENTIALS_MASTER_KEY, etc.)")
        print(f"  * blueprint registration in run.py")
        print(f"  * migration application")
    return 0


# ─── argparse ───────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="pe new",
        description="A6 — scaffold a fresh project + drop reusable modules.",
    )
    sub = p.add_subparsers(dest="sub", required=True)

    n = sub.add_parser("scaffold", help="Scaffold a fresh project directory")
    n.add_argument("name", help="Project display name (e.g. 'Acme Invoices')")
    n.add_argument("--stack", default="python-flask",
                   help="Stack template (default: python-flask)")
    n.add_argument("--dir", help="Parent directory (default: cwd)")
    n.add_argument("--tagline", help="One-line project tagline")
    n.add_argument("--no-install", action="store_true",
                   help="Skip auto pe install after scaffold")
    n.set_defaults(func=cmd_new)

    m = sub.add_parser("module", help="Manage reusable domain modules")
    msub = m.add_subparsers(dest="msub", required=True)
    ma = msub.add_parser("add", help="Materialize a module into a project")
    ma.add_argument("module", help="Module name (e.g. api-credentials)")
    ma.add_argument("--project", help="Project dir (default: cwd)")
    ma.set_defaults(func=cmd_module_add)

    return p


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
