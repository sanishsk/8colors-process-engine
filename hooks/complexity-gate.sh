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
        # `--yes --no-install` is contradictory — see run_eslint. --no-install
        # alone means "use it if the project has it, never download".
        npx --no-install knip --no-progress 2>/dev/null || log_skip "knip via npx (not installed)"
    fi
    # knip is advisory-only by default (project-scoped analysis, not per-file)
}

run_eslint() {
    [ -z "$STAGED_JS" ] && return 0

    # This path had never executed. The engine repo contained zero JavaScript
    # until 2026-09-04, so STAGED_JS was always empty and the function
    # returned on its first line. The first .js file ever staged found it
    # broken in three ways at once:
    #
    #   1. `npx --yes --no-install` is self-contradictory — --no-install says
    #      "do not download", --yes says "auto-confirm the download". npm
    #      resolves it by cancelling: "npx canceled due to missing packages
    #      and no YES option".
    #   2. That error went to 2>/dev/null, so the hook reported "FAIL — one
    #      or more checks blocked the commit" with no reason. A missing tool
    #      was indistinguishable from a real complexity violation, and every
    #      other tool in this file skips loudly when absent.
    #   3. `--no-eslintrc` is an eslint 8 flag. eslint 9 renamed it to
    #      --no-config-lookup, so even a correctly-installed eslint 9 would
    #      have failed on the flag rather than on the code.
    #
    # A gate that cannot run must skip and say so, never block silently.
    local runner=""
    if command -v eslint >/dev/null 2>&1; then
        runner="eslint"
    elif command -v npx >/dev/null 2>&1 && npx --no-install eslint --version >/dev/null 2>&1; then
        # --no-install alone: use a locally installed eslint, never download.
        runner="npx --no-install eslint"
    else
        log_skip "eslint (not installed — npm i -D eslint to enable)"
        return 0
    fi

    # Claude Code workflow scripts are not standalone JavaScript. The body
    # runs inside a runtime-supplied async wrapper, where a top-level
    # `return` IS the contract — it is the workflow's result. eslint parsing
    # one as a module reports "Parsing error: 'return' outside of function"
    # and stops, which is the linter being wrong about the file, not the file
    # being wrong.
    #
    # They are excluded, and the exclusion is ANNOUNCED. A silent exemption
    # list is how a gate stops meaning anything.
    local lintable="" skipped=""
    local f
    for f in $STAGED_JS; do
        case "$f" in
            workflows/*|*/workflows/*) skipped="$skipped $f" ;;
            *) lintable="$lintable $f" ;;
        esac
    done
    if [ -n "$skipped" ]; then
        echo "[complexity-gate] eslint: not linting workflow script(s) —$skipped" >&2
        echo "                  (top-level return is the workflow contract; a" >&2
        echo "                   module-mode parser cannot read them)" >&2
    fi
    if [ -z "${lintable// /}" ]; then
        log_skip "eslint (only workflow scripts staged)"
        return 0
    fi
    STAGED_JS="$lintable"

    log_run "eslint (complexity/max-depth/max-lines-per-function)"

    # eslint 9 dropped --no-eslintrc for --no-config-lookup. Pick by version
    # rather than guessing; an unreadable version falls back to the 9 form.
    local ver no_config
    ver=$($runner --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
    if [ -n "$ver" ] && [ "$ver" -lt 9 ] 2>/dev/null; then
        no_config="--no-eslintrc"
    else
        no_config="--no-config-lookup"
    fi

    # stderr is NOT discarded. If eslint refuses to run, the operator sees
    # why instead of an unexplained block.
    # shellcheck disable=SC2086
    if ! $runner --rule 'complexity: ["error",{"max":10}]' \
                 --rule 'max-depth: ["error",{"max":4}]' \
                 --rule 'max-lines-per-function: ["error",{"max":50,"skipBlankLines":true,"skipComments":true,"IIFEs":true}]' \
                 $no_config \
                 $STAGED_JS; then
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
