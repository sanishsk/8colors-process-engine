#!/usr/bin/env bash
# complexity-gate — pre-commit hook that feature-detects installed
# complexity/dead-code tools and runs them on the staged diff (P6.2).
#
# Tool ladder (each optional; missing = advisory skip):
#   Python:
#     - ruff check --select C901,PLR,B,SIM,RET,UP  (uses ruff.toml if present)
#     - xenon --max-absolute B                     (blocks on any function worse than B)
#     - vulture (with .vulture-allowlist.txt)      (dead code)
#   JS/TS:
#     - knip                                        (dead exports/files/unused deps)
#     - eslint (with complexity rule enabled)
#
# Config in .process-engine.yaml:
#   complexity_gate.enabled  — default true; false to skip entirely
#   complexity_gate.strict   — default false; true = xenon exit code counts
#
# Bypass one commit: PE_SKIP_COMPLEXITY=1 git commit ...

set -euo pipefail

if [ "${PE_SKIP_COMPLEXITY:-0}" = "1" ]; then
    echo "[complexity-gate] skipped (PE_SKIP_COMPLEXITY=1)" >&2
    exit 0
fi

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Source yaml helper if present
if [ -f "$ENGINE_DIR/scripts/_yaml.sh" ]; then
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/scripts/_yaml.sh"
fi

CONFIG=".process-engine.yaml"
enabled="true"
strict="false"
if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get complexity_gate.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    v=$(yaml_get complexity_gate.strict "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && strict="$v"
fi

if [ "$enabled" != "true" ]; then
    exit 0
fi

# Staged files by language
STAGED_PY=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep -E '\.py$' || true)
STAGED_JS=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep -E '\.(ts|tsx|js|jsx|mjs|cjs)$' || true)

fail=0

log_run()  { printf '\n[complexity-gate] %s\n' "$*" >&2; }
log_skip() { printf '[complexity-gate] %s (tool not installed — skipped)\n' "$*" >&2; }

run_ruff() {
    [ -z "$STAGED_PY" ] && return 0
    if ! command -v ruff >/dev/null 2>&1; then
        log_skip "ruff"; return 0
    fi
    log_run "ruff check --select C901,PLR,B,SIM,RET,UP"
    local args=(check --select C901,PLR,B,SIM,RET,UP)
    if [ ! -f ruff.toml ] && [ ! -f pyproject.toml ]; then
        args+=(--config "$ENGINE_DIR/templates/complexity/ruff.toml.template")
    fi
    # shellcheck disable=SC2086
    if ! ruff "${args[@]}" $STAGED_PY; then
        fail=1
    fi
}

run_xenon() {
    [ -z "$STAGED_PY" ] && return 0
    if ! command -v xenon >/dev/null 2>&1; then
        log_skip "xenon"; return 0
    fi
    log_run "xenon --max-absolute B (strict=$strict)"
    # shellcheck disable=SC2086
    if ! xenon --max-absolute B $STAGED_PY; then
        if [ "$strict" = "true" ]; then
            fail=1
        else
            echo "[complexity-gate] xenon: complexity above grade B — advisory (set complexity_gate.strict=true to enforce)" >&2
        fi
    fi
}

run_vulture() {
    [ -z "$STAGED_PY" ] && return 0
    if ! command -v vulture >/dev/null 2>&1; then
        log_skip "vulture"; return 0
    fi
    log_run "vulture (dead code)"
    local allow=".vulture-allowlist.txt"
    local args=()
    [ -f "$allow" ] && args+=("$allow")
    # shellcheck disable=SC2086
    if ! vulture $STAGED_PY "${args[@]}" --min-confidence 80; then
        echo "[complexity-gate] vulture: possible dead code above — advisory" >&2
        # not blocking — false-positive rate too high without a tuned allowlist
    fi
}

run_knip() {
    [ -z "$STAGED_JS" ] && return 0
    if ! command -v knip >/dev/null 2>&1 && ! command -v npx >/dev/null 2>&1; then
        log_skip "knip"; return 0
    fi
    log_run "knip (dead exports/files/unused deps)"
    if command -v knip >/dev/null 2>&1; then
        knip --no-progress || echo "[complexity-gate] knip: issues above — advisory" >&2
    else
        npx --yes --no-install knip --no-progress 2>/dev/null || log_skip "knip via npx"
    fi
    # knip is advisory-only by default (project-scoped analysis, not per-file)
}

run_eslint() {
    [ -z "$STAGED_JS" ] && return 0
    if ! command -v eslint >/dev/null 2>&1 && ! command -v npx >/dev/null 2>&1; then
        log_skip "eslint"; return 0
    fi
    log_run "eslint (complexity/max-depth/max-lines-per-function)"
    local runner="eslint"
    command -v eslint >/dev/null 2>&1 || runner="npx --yes --no-install eslint"
    # shellcheck disable=SC2086
    if ! $runner --rule 'complexity: ["error",{"max":10}]' \
                 --rule 'max-depth: ["error",{"max":4}]' \
                 --rule 'max-lines-per-function: ["error",{"max":50,"skipBlankLines":true,"skipComments":true,"IIFEs":true}]' \
                 --no-eslintrc \
                 $STAGED_JS 2>/dev/null; then
        fail=1
    fi
}

run_ruff
run_xenon
run_vulture
run_knip
run_eslint

if [ "$fail" -ne 0 ]; then
    cat >&2 <<EOF

[complexity-gate] FAIL — one or more checks blocked the commit.

To bypass this commit (logged):
  PE_SKIP_COMPLEXITY=1 git commit ...

To disable the gate for this project, set in .process-engine.yaml:
  complexity_gate:
    enabled: false
EOF
    exit 1
fi

exit 0
