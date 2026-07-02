#!/usr/bin/env bash
# design-lint — deterministic design-token / structure gate (P5.3).
#
# Multi-theme aware: config maps path patterns to theme scopes, and
# each theme declares its own allowlist for colors, radii, spacing
# tokens, and forbidden inline markup.
#
# Config: .design-lint.yaml (project root). Ships as a template at
# templates/design-lint.config.template — engine copies to
# docs/templates/design-lint.config.template during pe install.
#
# Runs on:
#   - Pre-commit for staged .html/.jinja/.jinja2/.tsx/.jsx templates
#   - PostToolUse for the same paths (advisory, immediate feedback)
#
# Checks (per-theme):
#   1. Forbidden raw attributes: any `style="..."` on template elements
#      → FAIL. Engine expectation: use tokens/classes, not inline.
#   2. Forbidden class fragments (configurable): `gradient-`, `blur-`,
#      `backdrop-blur`, etc. — the "AI look" tells.
#   3. Raw modal markup detection: `<div class="fixed inset-0` without
#      a macro/component wrapper → FAIL.
#   4. Color-hex outside allowlist: `#[0-9a-f]{3,8}` not matching one
#      of the theme's tokens → WARN (upgrade to FAIL via strict flag).
#
# Bypass: PE_SKIP_DESIGN_LINT=1 git commit ...

set -euo pipefail

if [ "${PE_SKIP_DESIGN_LINT:-0}" = "1" ]; then
    echo "[design-lint] skipped (PE_SKIP_DESIGN_LINT=1)" >&2
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
design_config_path=".design-lint.yaml"

if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get design_lint.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    v=$(yaml_get design_lint.strict "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && strict="$v"
    v=$(yaml_get design_lint.config "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && design_config_path="$v"
fi

if [ "$enabled" != "true" ]; then
    exit 0
fi

# Detect PostToolUse mode
MODE="pre-commit"
STDIN_JSON=""
if [ ! -t 0 ]; then
    STDIN_JSON="$(cat 2>/dev/null || true)"
    if [ -n "$STDIN_JSON" ] && printf '%s' "$STDIN_JSON" | grep -q '"tool_name"'; then
        MODE="posttooluse"
    fi
fi

# Determine target files
TARGET_FILES=""
if [ "$MODE" = "posttooluse" ]; then
    edited=$(printf '%s' "$STDIN_JSON" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin);ti=d.get("tool_input",{}) or {}
    print(ti.get("file_path","") or ti.get("path",""))
except Exception: print("")' 2>/dev/null || true)
    case "$edited" in
        *.html|*.jinja|*.jinja2|*.tsx|*.jsx|*.vue|*.svelte)
            TARGET_FILES="$edited" ;;
        *) exit 0 ;;
    esac
else
    TARGET_FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | \
                   grep -E '\.(html|jinja|jinja2|tsx|jsx|vue|svelte)$' || true)
fi

if [ -z "$TARGET_FILES" ]; then
    exit 0
fi

# If no design config file present in project, ship an advisory hint
# and continue with engine defaults only.
if [ ! -f "$design_config_path" ]; then
    echo "[design-lint] no $design_config_path — running with engine defaults only" >&2
fi

# The heavy lifting is in Python — regex + YAML + multi-theme.
if ! command -v python3 >/dev/null 2>&1; then
    echo "[design-lint] python3 unavailable — cannot run" >&2
    exit 0
fi

# shellcheck disable=SC2086
python3 - "$design_config_path" "$strict" "$MODE" $TARGET_FILES <<'PY'
import re
import sys
from pathlib import Path

config_path, strict, mode, *files = sys.argv[1:]
strict = (strict.lower() == "true")

# ─── Defaults (theme-agnostic) ────────────────────────────────────
default_forbidden_class_frags = [
    r"gradient-",
    r"backdrop-blur",
    r"\bblur-\w+",
]
default_forbidden_inline = [
    r'\bstyle\s*=\s*"[^"]*"',    # inline styles
    r'<div\s+class="[^"]*\bfixed\s+inset-0\b',  # raw modal markup
]

# ─── Load per-theme config if present ────────────────────────────
themes = {}
default_theme_key = "_default"
if Path(config_path).exists():
    try:
        import yaml  # noqa: PLC0415
        with open(config_path) as f:
            cfg = yaml.safe_load(f) or {}
    except ImportError:
        # PyYAML not installed — parse a minimal subset manually.
        cfg = {}
        cur = None
        for line in Path(config_path).read_text().splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if not line.startswith(" ") and stripped.endswith(":"):
                cur = stripped[:-1]
                cfg[cur] = {}
    themes = (cfg.get("themes") or {}) if isinstance(cfg, dict) else {}
    if not themes and isinstance(cfg, dict):
        themes = {default_theme_key: cfg}
else:
    themes = {default_theme_key: {}}

def theme_for(path: str) -> tuple[str, dict]:
    """Match a file path against theme.path_patterns; first match wins."""
    for name, spec in themes.items():
        patterns = (spec.get("path_patterns") or []) if isinstance(spec, dict) else []
        for pat in patterns:
            if re.search(pat, path):
                return name, spec
    return default_theme_key, themes.get(default_theme_key, {}) or {}

fail = 0
warn = 0
for f in files:
    p = Path(f)
    if not p.is_file():
        continue
    text = p.read_text(encoding="utf-8", errors="replace")
    theme_name, spec = theme_for(str(p))

    forbidden_class = list(default_forbidden_class_frags)
    forbidden_class += list((spec.get("forbid_class_fragments") or []))
    forbidden_inline = list(default_forbidden_inline)
    forbidden_inline += list((spec.get("forbid_inline_regex") or []))
    color_allowlist = set((spec.get("color_tokens") or []))
    color_check = bool(color_allowlist)

    for pat in forbidden_inline:
        for m in re.finditer(pat, text):
            line = text[:m.start()].count("\n") + 1
            print(f"[design-lint] FAIL {p}:{line} theme={theme_name} forbidden inline: {m.group(0)[:80]}", file=sys.stderr)
            fail += 1
    for pat in forbidden_class:
        for m in re.finditer(pat, text):
            line = text[:m.start()].count("\n") + 1
            print(f"[design-lint] FAIL {p}:{line} theme={theme_name} forbidden class fragment: {m.group(0)}", file=sys.stderr)
            fail += 1
    if color_check:
        for m in re.finditer(r"#([0-9a-fA-F]{3,8})\b", text):
            token = "#" + m.group(1).lower()
            if token not in color_allowlist:
                line = text[:m.start()].count("\n") + 1
                if strict:
                    print(f"[design-lint] FAIL {p}:{line} theme={theme_name} color {token} not in allowlist", file=sys.stderr)
                    fail += 1
                else:
                    print(f"[design-lint] WARN {p}:{line} theme={theme_name} color {token} not in allowlist", file=sys.stderr)
                    warn += 1

if fail > 0:
    print(f"\n[design-lint] {fail} FAIL, {warn} WARN — commit blocked.", file=sys.stderr)
    print("Bypass: PE_SKIP_DESIGN_LINT=1 git commit ...", file=sys.stderr)
    sys.exit(1)
if warn > 0:
    print(f"\n[design-lint] {warn} WARN (advisory) — commit proceeds.", file=sys.stderr)
sys.exit(0)
PY
