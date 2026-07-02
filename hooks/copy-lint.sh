#!/usr/bin/env bash
# copy-lint — flag AI-manifesto copy in templates (P5.7).
#
# Pre-commit hook that scans staged templates for the strongest
# "AI-generated marketing copy" tells: manifesto verbs, empty-state
# emoji-as-icon, Title Case labels in buttons, and word-chip UI.
#
# Config in .process-engine.yaml:
#   copy_lint.enabled       — default true
#   copy_lint.strict        — default false (WARN); true = FAIL
#   copy_lint.banned_phrases — extra regex list (semicolon-separated)
#
# Bypass: PE_SKIP_COPY_LINT=1 git commit ...

set -euo pipefail

if [ "${PE_SKIP_COPY_LINT:-0}" = "1" ]; then
    echo "[copy-lint] skipped (PE_SKIP_COPY_LINT=1)" >&2
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
extra_banned=""

if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get copy_lint.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    v=$(yaml_get copy_lint.strict "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && strict="$v"
    v=$(yaml_get copy_lint.banned_phrases "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && extra_banned="$v"
fi

if [ "$enabled" != "true" ]; then
    exit 0
fi

TARGET_FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | \
               grep -E '\.(html|jinja|jinja2|tsx|jsx|vue|svelte|mdx)$' || true)
if [ -z "$TARGET_FILES" ]; then
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[copy-lint] python3 unavailable — cannot run" >&2
    exit 0
fi

# shellcheck disable=SC2086
python3 - "$strict" "$extra_banned" $TARGET_FILES <<'PY'
import re, sys
from pathlib import Path

strict = (sys.argv[1].lower() == "true")
extra = [p for p in (sys.argv[2] or "").split(";") if p.strip()]
files = sys.argv[3:]

# Default banned-phrase list — the AI-manifesto tells codified in the
# 8CStudio audit + Phase A+ tells rubric.
banned = [
    (r"\bImagine\.\s*Create\.?\s*Together\.?", "manifesto verb chain 'Imagine. Create. Together'"),
    (r"\bInnovate\b", "marketing verb 'Innovate'"),
    (r"\bBoundless\b", "marketing adjective 'Boundless'"),
    (r"\bUnleash\b", "marketing verb 'Unleash'"),
    (r"\bEmpower\b", "marketing verb 'Empower'"),
    (r"\bElevat(?:e|ing|es|ed)\b", "marketing verb 'Elevate'"),
    (r"\bSeamless(?:ly)?\b", "marketing adjective 'Seamless'"),
    (r"\bTransform(?:ing|ed|s)?\s+(?:the\s+)?(?:way|future|world)", "marketing 'Transform the ...'"),
    (r"\bReimagin(?:e|ed|ing)\b", "marketing verb 'Reimagine'"),
]

# Emoji-in-button / emoji-in-heading detection
EMOJI_RE = re.compile(r"[\U0001F300-\U0001FAFF\U00002600-\U000027BF]")
BUTTON_TAG = re.compile(r"<button\b[^>]*>(.*?)</button>", re.DOTALL | re.IGNORECASE)
HEADING_TAG = re.compile(r"<h[1-4]\b[^>]*>(.*?)</h[1-4]>", re.DOTALL | re.IGNORECASE)

# Title Case in button labels — >=2 consecutive capitalized words
BUTTON_TITLE_CASE = re.compile(r"^\s*[A-Z][a-z]+\s+[A-Z][a-z]+", re.MULTILINE)

warn = 0
fail = 0
for f in files:
    p = Path(f)
    if not p.is_file():
        continue
    text = p.read_text(encoding="utf-8", errors="replace")

    # Banned phrases
    for pat, label in banned:
        for m in re.finditer(pat, text, re.IGNORECASE):
            line = text[:m.start()].count("\n") + 1
            level = "FAIL" if strict else "WARN"
            print(f"[copy-lint] {level} {p}:{line} {label}: '{m.group(0)}'", file=sys.stderr)
            if strict: fail += 1
            else: warn += 1
    # Extra banned regexes from adopter config
    for pat in extra:
        for m in re.finditer(pat, text, re.IGNORECASE):
            line = text[:m.start()].count("\n") + 1
            level = "FAIL" if strict else "WARN"
            print(f"[copy-lint] {level} {p}:{line} custom banned: '{m.group(0)}'", file=sys.stderr)
            if strict: fail += 1
            else: warn += 1

    # Emoji in buttons
    for m in BUTTON_TAG.finditer(text):
        inner = m.group(1)
        if EMOJI_RE.search(inner):
            line = text[:m.start()].count("\n") + 1
            print(f"[copy-lint] WARN {p}:{line} emoji inside <button> — use an icon component", file=sys.stderr)
            warn += 1
    # Emoji in headings
    for m in HEADING_TAG.finditer(text):
        inner = m.group(1)
        if EMOJI_RE.search(inner):
            line = text[:m.start()].count("\n") + 1
            print(f"[copy-lint] WARN {p}:{line} emoji inside heading — pick copy over decoration", file=sys.stderr)
            warn += 1
    # Title Case buttons (best-effort — grep the plain text inside)
    for m in BUTTON_TAG.finditer(text):
        inner = re.sub(r"<[^>]+>", "", m.group(1))
        if BUTTON_TITLE_CASE.match(inner):
            line = text[:m.start()].count("\n") + 1
            print(f"[copy-lint] WARN {p}:{line} button label uses Title Case: '{inner.strip()[:40]}' — prefer sentence case", file=sys.stderr)
            warn += 1

if fail > 0:
    print(f"\n[copy-lint] {fail} FAIL, {warn} WARN — commit blocked (copy_lint.strict=true).", file=sys.stderr)
    print("Bypass: PE_SKIP_COPY_LINT=1 git commit ...", file=sys.stderr)
    sys.exit(1)
if warn > 0:
    print(f"\n[copy-lint] {warn} WARN (advisory — set copy_lint.strict=true to enforce).", file=sys.stderr)
sys.exit(0)
PY
