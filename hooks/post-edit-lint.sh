#!/usr/bin/env bash
# post-edit-lint — Claude Code PostToolUse hook (P1.1).
#
# Fires after Edit/Write/MultiEdit. Best-effort lints the touched file by
# stack detection:
#   .py            → ruff check (if installed), then black --check
#   .ts/.tsx/.js   → eslint --no-error-on-unmatched-pattern (if installed)
#   .json          → python -m json.tool
#   .yaml/.yml     → python -c "import yaml; yaml.safe_load(...)" (if PyYAML)
#   .sh            → shellcheck (if installed)
#
# Never fails the tool call — this is a signal, not a gate (commit-time
# hooks are the gate). Advisory JSON output routed back to the model via
# {"decision":"allow","reason":"..."} so it sees warnings.
#
# To disable: set PE_SKIP_LINT=1 in the env.

set -uo pipefail

INPUT="$(cat)"

if [ "${PE_SKIP_LINT:-0}" = "1" ]; then
    exit 0
fi

FILE=$("${PE_PYTHON:-python3}" -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
    ti = data.get("tool_input", {})
    # Edit/Write use "file_path"; MultiEdit has "edits" — pick first file
    print(ti.get("file_path", ""))
except Exception:
    pass
' <<<"$INPUT")

# No file → nothing to do (e.g. NotebookEdit or malformed input)
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
    exit 0
fi

# Cap runtime — a slow linter should not block the loop.
run_capped() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 8 "$@" 2>&1 || true
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 8 "$@" 2>&1 || true
    else
        "$@" 2>&1 || true
    fi
}

emit_advisory() {
    local msg="$1"
    "${PE_PYTHON:-python3}" -c '
import json, sys
print(json.dumps({"decision": "allow", "reason": sys.argv[1]}))
' "$msg" 2>/dev/null || true
}

case "$FILE" in
    *.py)
        OUT=""
        if command -v ruff >/dev/null 2>&1; then
            R=$(run_capped ruff check "$FILE")
            [ -n "$R" ] && OUT="ruff: $R"
        fi
        if command -v black >/dev/null 2>&1; then
            B=$(run_capped black --check --quiet "$FILE")
            if [ -n "$B" ]; then
                OUT="${OUT:+$OUT | }black: $B"
            fi
        fi
        [ -n "$OUT" ] && emit_advisory "post-edit-lint($FILE): $OUT"
        ;;
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs)
        if command -v eslint >/dev/null 2>&1; then
            E=$(run_capped eslint --no-error-on-unmatched-pattern "$FILE")
            [ -n "$E" ] && emit_advisory "post-edit-lint($FILE): eslint: $E"
        fi
        ;;
    *.json)
        J=$("${PE_PYTHON:-python3}" -m json.tool "$FILE" >/dev/null 2>&1 || echo "invalid JSON")
        [ -n "$J" ] && emit_advisory "post-edit-lint($FILE): $J"
        ;;
    *.yaml|*.yml)
        Y=$("${PE_PYTHON:-python3}" -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$FILE" 2>&1 || true)
        [ -n "$Y" ] && emit_advisory "post-edit-lint($FILE): yaml: $Y"
        ;;
    *.sh|*.bash)
        if command -v shellcheck >/dev/null 2>&1; then
            S=$(run_capped shellcheck "$FILE")
            [ -n "$S" ] && emit_advisory "post-edit-lint($FILE): shellcheck: $S"
        fi
        ;;
esac

exit 0
