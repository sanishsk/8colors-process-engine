#!/usr/bin/env bash
# signature-lint — deterministic D8 signature-system gate (v0.41.0).
#
# The mechanical half of D8. Design-critic's tell #9 ("no signature
# element") is the deepest AI-tell — "nothing ties this to the
# product." Historically it was a soft tell (counted toward
# ≥3-tells-FAIL threshold). D8 makes it HARD on flagship screens.
#
# Contract:
#
#   1. Look for docs/design/SIGNATURE.md in the adopter project.
#      Absence → this gate is DISABLED (opt-in per product; not
#      every project needs a signature system yet).
#
#   2. Extract declared `signature_token: <slug>` lines from
#      SIGNATURE.md. These are the tokens the critic and the hook
#      both scan for.
#
#   3. Determine "flagship" files touched by this commit — file
#      paths matching the flagship_paths regex list (default set
#      covers marketing/, landing/, home/pricing/about/docs-home
#      templates + Next.js app/(marketing)/ and app/marketing/
#      routes). Overridable via .process-engine.yaml
#      → signature_gate.flagship_paths.
#
#   4. For each flagship file in the diff, scan its content for
#      any of the declared signature tokens. Zero matches on a
#      flagship file with any diff content → BLOCK. The commit
#      wants to change a flagship page and none of the declared
#      product signatures are present.
#
# What this hook cannot catch (delegated to design-critic):
#   - A signature TOKEN present in code as a CSS class but visually
#     unused (the composition doesn't show it).
#   - A "new" signature the diff invents on the fly without
#     updating SIGNATURE.md — the hook trusts the file, the critic
#     judges whether the token maps to the composition.
#
# Runs on:
#   - Pre-commit for staged flagship files.
#   - PostToolUse Write/Edit/MultiEdit on flagship-matching paths
#     for immediate feedback (does not block agent-side edits,
#     surfaces the finding early).
#
# Config (.process-engine.yaml):
#   signature_gate.enabled: true|false     (default: true if
#                                           SIGNATURE.md exists;
#                                           auto-false otherwise)
#   signature_gate.flagship_paths: []      (list of regex strings)
#   signature_gate.require_count: 1        (min distinct tokens per
#                                           flagship diff — default
#                                           1; one signature per
#                                           flagship page is the
#                                           floor)
#
# Bypass: PE_SKIP_SIGNATURE_LINT=1 git commit ...

set -euo pipefail

if [ "${PE_SKIP_SIGNATURE_LINT:-0}" = "1" ]; then
    echo "[signature-lint] skipped (PE_SKIP_SIGNATURE_LINT=1)" >&2
    exit 0
fi

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ENGINE_DIR/scripts/_yaml.sh" ]; then
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/scripts/_yaml.sh"
fi

SIGNATURE_FILE="docs/design/SIGNATURE.md"
CONFIG=".process-engine.yaml"

# Opt-in gate: no SIGNATURE.md → this hook does nothing. Adopters
# who haven't declared a signature system yet aren't blocked; the
# gate is a product-maturity signal, not a floor requirement.
if [ ! -f "$SIGNATURE_FILE" ]; then
    exit 0
fi

enabled="true"
require_count="1"
flagship_paths_raw=""

if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get signature_gate.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    v=$(yaml_get signature_gate.require_count "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && require_count="$v"
    # flagship_paths is a list; yaml_get doesn't split, so we read
    # the raw block via python below.
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
    TARGET_FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
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
    [ -n "$file_path" ] && [ -f "$file_path" ] && TARGET_FILES="$file_path"
fi

if [ -z "$TARGET_FILES" ]; then
    exit 0
fi

# ─── Delegate to Python for regex + config parsing ──────────────────
# File list via env var so filenames with spaces survive (same
# lesson learned in D6 motion-lint reviewer fix, v0.39.0).
export PE_SIGNATURE_LINT_FILES="$TARGET_FILES"
python3 - "$require_count" "$MODE" "$SIGNATURE_FILE" "$CONFIG" <<'PY'
"""D8 signature-lint core.

Contract:
  - Load declared signature tokens from docs/design/SIGNATURE.md
    (lines matching `signature_token: <slug>`).
  - Load flagship_paths from .process-engine.yaml if present, else
    use built-in defaults.
  - For each target file that matches a flagship path, count
    distinct signature tokens present in the file. If count <
    require_count → FAIL (block).
"""

import os
import re
import sys
from pathlib import Path

require_count = int(sys.argv[1] or "1")
mode = sys.argv[2]
signature_file = Path(sys.argv[3])
config_file = Path(sys.argv[4])

files = [
    line for line in os.environ.get("PE_SIGNATURE_LINT_FILES", "").splitlines() if line
]

# ─── Load declared signature tokens ─────────────────────────────────
TOKEN_LINE = re.compile(r"^\s*[-*]?\s*`?signature_token:\s*([a-z0-9][a-z0-9-]*)`?", re.MULTILINE | re.IGNORECASE)
declared_tokens: list[str] = []
if signature_file.is_file():
    text = signature_file.read_text(encoding="utf-8", errors="replace")
    declared_tokens = list(dict.fromkeys(m.group(1).lower() for m in TOKEN_LINE.finditer(text)))

if not declared_tokens:
    # SIGNATURE.md exists but no tokens declared — not a fail; the
    # adopter is in the middle of authoring. Print a one-time notice
    # and exit clean.
    print(
        "[signature-lint] SIGNATURE.md present but no `signature_token: <slug>` lines declared — gate is inert until at least one token is declared.",
        file=sys.stderr,
    )
    sys.exit(0)

# ─── Load flagship paths (regex list) ───────────────────────────────
DEFAULT_FLAGSHIP_PATHS = [
    r"^templates/marketing/",
    r"^templates/landing/",
    r"^pages/marketing/",
    r"^app/marketing/",
    r"^app/\(marketing\)/",
    r"^templates/home\.",
    r"^templates/index\.",
    r"^templates/pricing\.",
    r"^templates/about\.",
    r"^templates/docs-home\.",
    r"^app/page\.(tsx|jsx|js|ts)$",
    r"^app/marketing/page\.",
    r"^app/pricing/page\.",
    r"^app/about/page\.",
]

flagship_patterns_raw: list[str] = []
if config_file.is_file():
    # Parse the flagship_paths list. Minimal YAML — we only need the
    # sequence under signature_gate.flagship_paths. Full YAML parse
    # is overkill for the hook layer.
    cfg = config_file.read_text(encoding="utf-8", errors="replace").splitlines()
    in_section = False
    in_list = False
    for line in cfg:
        stripped = line.strip()
        if re.match(r"^signature_gate\s*:\s*$", stripped):
            in_section = True
            continue
        if in_section:
            if re.match(r"^\S", line):
                # left the section
                in_section = False
                in_list = False
                continue
            if re.match(r"^\s*flagship_paths\s*:\s*$", line):
                in_list = True
                continue
            if in_list:
                m = re.match(r"^\s*-\s*['\"]?([^'\"]+)['\"]?\s*$", line)
                if m:
                    flagship_patterns_raw.append(m.group(1))
                    continue
                if re.match(r"^\s*\S", line) and not line.lstrip().startswith("-"):
                    in_list = False

flagship_patterns_raw = flagship_patterns_raw or DEFAULT_FLAGSHIP_PATHS
try:
    flagship_regexes = [re.compile(p) for p in flagship_patterns_raw]
except re.error as e:
    print(f"[signature-lint] invalid regex in signature_gate.flagship_paths: {e}", file=sys.stderr)
    sys.exit(2)

def is_flagship(path: str) -> bool:
    # PostToolUse hands over absolute paths; the flagship regexes are
    # written against repo-relative paths (^templates/, ^app/...). Try
    # both the raw path and a repo-relative variant so absolute-path
    # events from PostToolUse still match.
    candidates = [path]
    try:
        rel = os.path.relpath(path)
        if not rel.startswith(".."):
            candidates.append(rel)
    except ValueError:
        pass
    return any(rgx.search(c) for c in candidates for rgx in flagship_regexes)

# ─── Scan each flagship file ────────────────────────────────────────
token_regexes = {tok: re.compile(r"\b" + re.escape(tok) + r"\b") for tok in declared_tokens}

fail = 0
for f in files:
    if not is_flagship(f):
        continue
    p = Path(f)
    if not p.is_file():
        continue
    text = p.read_text(encoding="utf-8", errors="replace")
    hits = sorted({tok for tok, rgx in token_regexes.items() if rgx.search(text)})
    if len(hits) < require_count:
        print(
            f"[signature-lint] FAIL {p}: flagship file carries {len(hits)} declared signature tokens "
            f"(require {require_count}). Declared: {', '.join(declared_tokens)}. Found: {', '.join(hits) or '(none)'}.",
            file=sys.stderr,
        )
        print(
            "  Flagship screens (marketing / landing / pricing / about / home) must carry ≥1 "
            "signature element that ties them to the product. If the diff genuinely doesn't touch a "
            "flagship surface, exclude the path via .process-engine.yaml → signature_gate.flagship_paths.",
            file=sys.stderr,
        )
        print(
            "  Fix (one of):",
            file=sys.stderr,
        )
        print(
            "    (a) Add a class / attribute / class-hook referencing one of the declared tokens "
            "(e.g. `class=\"slate-headline\"` for `signature_token: slate-headline`).",
            file=sys.stderr,
        )
        print(
            "    (b) If the signature system has changed, update docs/design/SIGNATURE.md to declare the new token.",
            file=sys.stderr,
        )
        print(
            "    (c) Bypass one-off: PE_SKIP_SIGNATURE_LINT=1 git commit ...",
            file=sys.stderr,
        )
        fail += 1

if fail > 0:
    print(
        f"\n[signature-lint] {fail} FAIL on flagship path(s) — commit blocked.",
        file=sys.stderr,
    )
    print(
        "Bypass: PE_SKIP_SIGNATURE_LINT=1 git commit ...",
        file=sys.stderr,
    )
    sys.exit(1)

sys.exit(0)
PY
