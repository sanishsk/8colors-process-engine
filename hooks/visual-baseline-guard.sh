#!/usr/bin/env bash
# visual-baseline-guard — D3 reference-must-exist gate (v0.45.0).
#
# The advisory half of D3. `templates/e2e/visual-baseline.spec.ts.template`
# is the RUNTIME mechanism — Playwright captures + diffs snapshots. This
# hook catches the STATIC gap: an edit lands on a flagship page template
# but no locked reference PNG exists for it. Without the reference the
# Playwright spec has nothing to compare against, and the "match the
# locked reference, never make-it-professional" rule is silently
# unenforceable.
#
# Opt-in per adopter:
#   - Absence of docs/design/reference/README.md → gate inert.
#     (The D3 reference-lock library is engine-side; the README landing
#     in the adopter is the opt-in signal.)
#
# When active:
#   1. For each staged flagship-page template file, look up its slug
#      from .process-engine.yaml → visual_baseline.flagship_pages.
#   2. If no reference PNG exists at
#      <reference_dir>/<slug>.png (default docs/design/reference/),
#      emit a WARN — commit proceeds.
#   3. NEVER a hard FAIL: the plan calls this a designer-approval loop,
#      not an automation gate. WARN keeps the signal visible without
#      blocking the operator.
#
# Runs on:
#   - Pre-commit for staged UI files.
#   - PostToolUse for Write/Edit/MultiEdit on the same paths (silent
#     on Bash).
#
# Config (.process-engine.yaml):
#   visual_baseline.enabled: true|false     (default: true when
#                                            docs/design/reference/README.md
#                                            is present in the project)
#   visual_baseline.flagship_pages: []      (list of slugs — MUST match
#                                            the PAGES_TO_LOCK slugs in
#                                            the Playwright spec)
#   visual_baseline.reference_dir: <path>   (default:
#                                            docs/design/reference)
#   visual_baseline.template_glob_prefix: <path>
#                                           (default: templates —
#                                            change if your project's
#                                            template root is elsewhere,
#                                            e.g. app/, pages/)
#
# Bypass: PE_SKIP_VISUAL_BASELINE=1 git commit ...

set -euo pipefail

if [ "${PE_SKIP_VISUAL_BASELINE:-0}" = "1" ]; then
    echo "[visual-baseline-guard] skipped (PE_SKIP_VISUAL_BASELINE=1)" >&2
    exit 0
fi

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ENGINE_DIR/scripts/_yaml.sh" ]; then
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/scripts/_yaml.sh"
fi

# Opt-in signal — the D3 README landing in the adopter is what turns
# this hook on. Absence keeps it inert without noise.
if [ ! -f "docs/design/reference/README.md" ]; then
    exit 0
fi

CONFIG=".process-engine.yaml"
enabled="true"
reference_dir="docs/design/reference"
template_prefix="templates"

if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get visual_baseline.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    v=$(yaml_get visual_baseline.reference_dir "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && reference_dir="$v"
    v=$(yaml_get visual_baseline.template_glob_prefix "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && template_prefix="$v"
fi

if [ "$enabled" != "true" ]; then
    exit 0
fi

# ─── PostToolUse vs pre-commit mode detection ───────────────────────
MODE="pre-commit"
STDIN_JSON=""
if [ ! -t 0 ]; then
    STDIN_JSON="$(cat 2>/dev/null || true)"
    if [ -n "$STDIN_JSON" ] && printf '%s' "$STDIN_JSON" | grep -q '"tool_name"'; then
        MODE="posttooluse"
    fi
fi

# ─── Determine target files ─────────────────────────────────────────
TARGET_FILES=""

if [ "$MODE" = "pre-commit" ]; then
    TARGET_FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
        | grep -E '\.(html|jinja|jinja2|tsx|jsx|vue|svelte)$' \
        || true)
elif [ "$MODE" = "posttooluse" ]; then
    tool_name=$(printf '%s' "$STDIN_JSON" \
        | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -1 \
        | sed -E 's/.*"tool_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    case "$tool_name" in
        Write|Edit|MultiEdit) ;;
        *) exit 0 ;;
    esac
    file_path=$(printf '%s' "$STDIN_JSON" \
        | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -1 \
        | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    if [ -n "$file_path" ] && \
       printf '%s' "$file_path" \
         | grep -qE '\.(html|jinja|jinja2|tsx|jsx|vue|svelte)$' && \
       [ -f "$file_path" ]; then
        TARGET_FILES="$file_path"
    fi
fi

if [ -z "$TARGET_FILES" ]; then
    exit 0
fi

# ─── Delegate the flagship-slug + reference check to Python ─────────
# List of flagship slugs comes from the config's list-under-list block.
# yaml_get can't split lists, so python parses the block directly.
export PE_VBG_FILES="$TARGET_FILES"
python3 - "$reference_dir" "$template_prefix" "$CONFIG" <<'PY'
"""D3 visual-baseline-guard core.

Contract:
  - Load flagship_pages list from .process-engine.yaml (may be empty).
  - For each target template file, match its filename slug against the
    flagship list. If the template's slug appears in flagship_pages,
    check that <reference_dir>/<slug>.png exists. Missing → WARN.
"""

import os
import re
import sys
from pathlib import Path

reference_dir = Path(sys.argv[1])
template_prefix = sys.argv[2]  # informational only right now
config_file = Path(sys.argv[3])

files = [line for line in os.environ.get("PE_VBG_FILES", "").splitlines() if line]

# ─── Load flagship_pages list ───────────────────────────────────────
flagship_slugs: list[str] = []
if config_file.is_file():
    cfg_lines = config_file.read_text(encoding="utf-8", errors="replace").splitlines()
    in_section = False
    in_list = False
    for line in cfg_lines:
        stripped = line.strip()
        if re.match(r"^visual_baseline\s*:\s*$", stripped):
            in_section = True
            continue
        if in_section:
            if re.match(r"^\S", line):
                in_section = False
                in_list = False
                continue
            if re.match(r"^\s*flagship_pages\s*:\s*$", line):
                in_list = True
                continue
            if in_list:
                m = re.match(r"^\s*-\s*['\"]?([^'\"]+)['\"]?\s*$", line)
                if m:
                    flagship_slugs.append(m.group(1).strip())
                    continue
                if re.match(r"^\s*\S", line) and not line.lstrip().startswith("-"):
                    in_list = False

if not flagship_slugs:
    # No flagship pages declared — nothing to guard.
    sys.exit(0)

flagship_set = set(flagship_slugs)

warned = 0
for f in files:
    path = Path(f)
    slug = path.stem  # basename without extension
    # Also try slug from parent-directory + stem for pages like
    # `templates/marketing/hero.html` → slug candidates "hero" and
    # "marketing" — either match counts.
    candidates = {slug}
    if path.parent.name:
        candidates.add(path.parent.name)
    hits = candidates & flagship_set
    if not hits:
        continue
    matched_slug = sorted(hits)[0]
    # v0.45.0 reviewer HIGH: the operator owns .process-engine.yaml but
    # the least-privilege posture is to reject slugs that would escape
    # the reference dir. Prevents a stray `../` in flagship_pages from
    # probing the filesystem outside `docs/design/reference/`.
    if "/" in matched_slug or "\\" in matched_slug or ".." in matched_slug:
        print(
            f"[visual-baseline-guard] SKIP {path}: flagship slug "
            f"{matched_slug!r} contains path separators or '..' — reject.",
            file=sys.stderr,
        )
        continue
    ref_path = (reference_dir / f"{matched_slug}.png").resolve()
    ref_root = reference_dir.resolve()
    try:
        ref_path.relative_to(ref_root)
    except ValueError:
        print(
            f"[visual-baseline-guard] SKIP {path}: resolved reference "
            f"path {ref_path} escapes reference_dir {ref_root} — reject.",
            file=sys.stderr,
        )
        continue
    if not ref_path.is_file():
        print(
            f"[visual-baseline-guard] WARN {path}: flagship page slug "
            f"'{matched_slug}' is edited but no locked reference exists at "
            f"{ref_path}. D3 signal — either capture the baseline via "
            "`npx playwright test visual-baseline.spec.ts --update-snapshots` "
            "and commit the emitted PNGs, or remove the slug from "
            "visual_baseline.flagship_pages in .process-engine.yaml.",
            file=sys.stderr,
        )
        warned += 1

if warned > 0:
    print(
        f"\n[visual-baseline-guard] {warned} flagship page(s) edited without a locked reference — advisory only, commit proceeds.",
        file=sys.stderr,
    )
    print(
        "Bypass: PE_SKIP_VISUAL_BASELINE=1 git commit ...",
        file=sys.stderr,
    )

# Advisory only — always exit 0.
sys.exit(0)
PY
