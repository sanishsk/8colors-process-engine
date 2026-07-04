#!/usr/bin/env bash
# motion-lint — deterministic motion-craft gate (D6, v0.39.0).
#
# The mechanical half of D6. Design-critic's ceiling-mode Creativity
# dimension judges motion-has-purpose (the 20% only a reviewer can
# see). This hook catches the 80% a regex can catch:
#
#   1. Motion added anywhere in the diff (CSS @keyframes / animation:,
#      Tailwind animate-* / transition-* / motion-*, GSAP / Motion /
#      ScrollTrigger imports + calls).
#   2. No `prefers-reduced-motion` guard anywhere in the file OR in a
#      project-declared global-guard file.
#
#   → BLOCK the commit. Every animation MUST respect
#   prefers-reduced-motion (WCAG 2.3.3 + real ADA lawsuit surface).
#
# Also warns (advisory, doesn't block):
#
#   3. Effect-stacking heuristic — too many distinct animation signals
#      in one file (default cap: 10). The #1 amateur design tell.
#
# Runs on:
#   - Pre-commit for staged UI files (.html/.jinja/.jinja2/.tsx/.jsx/
#     .vue/.svelte/.css/.scss)
#   - PostToolUse for the same paths (advisory, immediate feedback)
#
# Config (.process-engine.yaml):
#   motion_gate.enabled: true|false          (default true)
#   motion_gate.strict:  true|false          (default false — effect-
#                                             stacking is advisory even
#                                             in strict mode; it's a
#                                             judgment call for the
#                                             design-critic to escalate)
#   motion_gate.global_guard_file: <path>    (default empty — if set +
#                                             file exists + contains a
#                                             prefers-reduced-motion
#                                             guard, per-file guards
#                                             are not required)
#   motion_gate.effect_stack_cap: 10         (WARN threshold)
#
# Bypass: PE_SKIP_MOTION_LINT=1 git commit ...

set -euo pipefail

if [ "${PE_SKIP_MOTION_LINT:-0}" = "1" ]; then
    echo "[motion-lint] skipped (PE_SKIP_MOTION_LINT=1)" >&2
    exit 0
fi

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ENGINE_DIR/scripts/_yaml.sh" ]; then
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/scripts/_yaml.sh"
fi

CONFIG=".process-engine.yaml"
enabled="true"
strict="false"
global_guard_file=""
effect_stack_cap="10"

if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get motion_gate.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    v=$(yaml_get motion_gate.strict "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && strict="$v"
    v=$(yaml_get motion_gate.global_guard_file "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && global_guard_file="$v"
    v=$(yaml_get motion_gate.effect_stack_cap "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && effect_stack_cap="$v"
fi

if [ "$enabled" != "true" ]; then
    exit 0
fi

# ─── PostToolUse vs pre-commit mode detection ───────────────────────
# The hook is invoked from two paths: (a) git pre-commit stage in
# `.pre-commit-config.yaml` — no stdin JSON, staged files come from
# `git diff --cached`; and (b) Claude Code PostToolUse — an event JSON
# on stdin, single edited file path. Both paths go through the same
# body; only the file-list source differs.
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
    # Staged UI files.
    TARGET_FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
        | grep -E '\.(html|jinja|jinja2|tsx|jsx|vue|svelte|css|scss)$' \
        || true)
elif [ "$MODE" = "posttooluse" ]; then
    # Single file from the PostToolUse event. Only trigger for the
    # code-writing tools (Write / Edit / MultiEdit) so a Bash read
    # doesn't spawn the check.
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
         | grep -qE '\.(html|jinja|jinja2|tsx|jsx|vue|svelte|css|scss)$' && \
       [ -f "$file_path" ]; then
        TARGET_FILES="$file_path"
    fi
fi

if [ -z "$TARGET_FILES" ]; then
    exit 0
fi

# ─── Motion detection + guard check + effect-stacking ───────────────
# Delegated to Python so the regex logic + per-file guard resolution
# is testable. Keeping the shell wrapper thin.
#
# File list passed via env var (newline-separated) so filenames with
# spaces survive intact — argv word-splitting would silently drop them
# and defeat the WCAG guard (real-world bypass, not theoretical).
export PE_MOTION_LINT_FILES="$TARGET_FILES"
python3 - "$strict" "$MODE" "$global_guard_file" "$effect_stack_cap" <<'PY'
"""D6 motion-lint core.

Contract:
  - Detect motion signals per file.
  - If motion signals > 0 AND no prefers-reduced-motion guard in this
    file AND no global guard file → BLOCK (fail count += 1).
  - If motion signal count > effect_stack_cap → WARN.
  - Config-driven strictness only elevates effect-stack from WARN to
    BLOCK; the guard-missing check is ALWAYS a BLOCK (WCAG hard
    requirement).
"""

import os
import re
import sys
from pathlib import Path

strict, mode, global_guard_file, cap_str = sys.argv[1:5]
strict = strict.lower() == "true"
# Newline-separated list from the shell wrapper — preserves filenames
# with spaces, which unquoted argv expansion would silently break.
files = [
    line for line in os.environ.get("PE_MOTION_LINT_FILES", "").splitlines() if line
]
try:
    effect_stack_cap = int(cap_str)
except ValueError:
    effect_stack_cap = 10

# ─── Motion signal patterns ─────────────────────────────────────────
# Each pattern is (regex, human_label). Grouped by stack so the
# report can name the family that triggered.
#
# NOTE: `transition-colors` is a Tailwind class used for hover
# color-state feedback and generally shouldn't require a
# reduced-motion guard on its own (color change is not motion for the
# WCAG purpose). We match the general `transition-` family though —
# if a color-only transition is the only motion, adopters can wrap it
# in a project-local exception via the global guard file.
CSS_MOTION_PATTERNS = [
    (re.compile(r"@keyframes\b"), "css:@keyframes"),
    (re.compile(r"\banimation\s*:", re.IGNORECASE), "css:animation"),
    (re.compile(r"\btransition\s*:\s*(?!\s*none\b)", re.IGNORECASE), "css:transition"),
]

TAILWIND_MOTION_PATTERNS = [
    # animate-<name>, animate-spin/animate-pulse/etc.
    (re.compile(r"\banimate-[a-zA-Z][\w-]*"), "tw:animate-*"),
    # transition-<x> — but NOT `transition-colors`, which is
    # color-only and usually acceptable without a guard. Match
    # everything that isn't `-colors` OR `-none`.
    (re.compile(r"\btransition-(?!colors\b|none\b)[a-zA-Z][\w-]*"), "tw:transition-*"),
    # motion-<safe|reduce> is the framework token; also motion-blur,
    # motion-scale, etc. Match the `motion-` prefix unless it's the
    # utility that ADDS the reduced-motion guard.
    (re.compile(r"\bmotion-(?!safe|reduce)[a-zA-Z][\w-]*"), "tw:motion-*"),
]

JS_MOTION_PATTERNS = [
    (re.compile(r"\bgsap\s*\.\s*(to|from|fromTo|timeline)\s*\("), "gsap"),
    (re.compile(r"\bScrollTrigger\b"), "gsap-scrolltrigger"),
    (re.compile(r'\bfrom\s+["\']framer-motion["\']'), "framer-motion-import"),
    (re.compile(r'\bfrom\s+["\']motion(/react)?["\']'), "motion-import"),
    (re.compile(r"\bAnimatePresence\b"), "framer-motion-usage"),
    (re.compile(r"\bmotion\.\w+"), "motion-component"),
    (re.compile(r"\bLenis\s*\("), "lenis"),
]

ALL_PATTERNS = CSS_MOTION_PATTERNS + TAILWIND_MOTION_PATTERNS + JS_MOTION_PATTERNS

# ─── Guard patterns ─────────────────────────────────────────────────
# CSS guard: `@media (prefers-reduced-motion: reduce)` (spaces flex).
# JS guard: `window.matchMedia('(prefers-reduced-motion:...)')` or the
# equivalent React hook. Tailwind's `motion-safe:` / `motion-reduce:`
# prefixes count as a guard when they cover the animated class.
GUARD_PATTERNS = [
    re.compile(r"@media\s*\(\s*prefers-reduced-motion\s*:", re.IGNORECASE),
    re.compile(r"matchMedia\s*\(\s*['\"]?\s*\(?\s*prefers-reduced-motion", re.IGNORECASE),
    # Tailwind — if the same file uses motion-safe: or motion-reduce:
    # ANYWHERE, count it as an authored guard for the whole file.
    # False positives are cheap; false negatives (missing guard) are
    # the failure this hook exists to prevent.
    re.compile(r"\bmotion-(safe|reduce):"),
]

# Global guard: if the config points at a project-level CSS file that
# holds the reduced-motion rules, load it once and treat every file
# as guarded.
project_globally_guarded = False
if global_guard_file:
    path = Path(global_guard_file)
    if path.is_file():
        content = path.read_text(encoding="utf-8", errors="replace")
        if any(p.search(content) for p in GUARD_PATTERNS):
            project_globally_guarded = True

def has_guard(text: str) -> bool:
    return project_globally_guarded or any(p.search(text) for p in GUARD_PATTERNS)

def motion_signals(text: str) -> list[tuple[str, int]]:
    """Return [(label, line), ...] for every motion pattern hit."""
    hits: list[tuple[str, int]] = []
    for regex, label in ALL_PATTERNS:
        for m in regex.finditer(text):
            line = text[: m.start()].count("\n") + 1
            hits.append((label, line))
    return hits

fail = 0
warn = 0

for f in files:
    p = Path(f)
    if not p.is_file():
        continue
    text = p.read_text(encoding="utf-8", errors="replace")

    signals = motion_signals(text)
    if not signals:
        continue

    if not has_guard(text):
        # First-hit line for the report — enough to point the fix.
        first_label, first_line = signals[0]
        print(
            f"[motion-lint] FAIL {p}:{first_line} motion added ({first_label}) "
            f"without a prefers-reduced-motion guard in this file or the "
            f"project-declared global guard file. WCAG 2.3.3 + real ADA "
            f"surface — every animation must respect reduced motion.",
            file=sys.stderr,
        )
        print(
            "  Fix (one of):",
            file=sys.stderr,
        )
        print(
            "    (a) Wrap animations in `@media (prefers-reduced-motion: reduce) { … }` OR use Tailwind's `motion-safe:` / `motion-reduce:` prefixes on the animated classes.",
            file=sys.stderr,
        )
        print(
            "    (b) Declare a project-global guard file in .process-engine.yaml → `motion_gate.global_guard_file: static/css/reduced-motion.css` (file must contain the @media rule).",
            file=sys.stderr,
        )
        fail += 1

    if len(signals) > effect_stack_cap:
        stack_labels = sorted({lbl for lbl, _ in signals})
        msg_stub = (
            f"[motion-lint] effect-stacking {p}: {len(signals)} motion "
            f"signals (cap {effect_stack_cap}) across "
            f"{len(stack_labels)} families: {', '.join(stack_labels[:6])}"
        )
        if len(stack_labels) > 6:
            msg_stub += f", +{len(stack_labels) - 6} more"
        msg_stub += (
            ". Effect-stacking is the #1 amateur design tell — one "
            "signature moment beats many decorations. Design-critic "
            "will judge motion-has-purpose in ceiling mode."
        )
        if strict:
            print(f"FAIL {msg_stub}", file=sys.stderr)
            fail += 1
        else:
            print(f"WARN {msg_stub}", file=sys.stderr)
            warn += 1

if fail > 0:
    print(
        f"\n[motion-lint] {fail} FAIL, {warn} WARN — commit blocked.",
        file=sys.stderr,
    )
    print(
        "Bypass: PE_SKIP_MOTION_LINT=1 git commit ...",
        file=sys.stderr,
    )
    sys.exit(1)

if warn > 0:
    print(
        f"\n[motion-lint] {warn} WARN (advisory) — commit proceeds.",
        file=sys.stderr,
    )

sys.exit(0)
PY
