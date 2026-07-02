#!/usr/bin/env bash
# test-run — pre-commit hook that runs the detected test framework
# scoped to files changed in this commit (P1.2).
#
# Runner detection order:
#   1. ENGINE_TEST_CMD env var — explicit override (wins over auto-detect)
#   2. pyproject.toml or setup.py present → pytest
#   3. package.json present → npm test (or pnpm/yarn if their lockfile exists)
#   4. go.mod present → go test ./...
#   5. Cargo.toml present → cargo test
#   6. No known stack → skip (exit 0 with notice)
#
# Scope: runs tests for the packages/modules touched by staged files.
# Full-suite fallback via ENGINE_TEST_FULL=1.
#
# Coverage floor (optional, opt-in): set ENGINE_COVERAGE_MIN to a number
# in [0, 100]. Currently pytest-cov and jest --coverage are recognised.
#
# Install via .pre-commit-config.yaml:
#   - id: test-run
#     entry: hooks/test-run.sh
#     language: script
#     pass_filenames: false
#     stages: [pre-commit]
#
# Bypass: `git commit --no-verify`, or ENGINE_SKIP_TESTS=1.

set -uo pipefail

if [ "${ENGINE_SKIP_TESTS:-0}" = "1" ]; then
    echo "test-run: ENGINE_SKIP_TESTS=1 — skipping" >&2
    exit 0
fi

STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
if [ -z "$STAGED" ]; then
    exit 0
fi

# Runner overrides win. This is how CI templates + adopters with unusual
# stacks (bazel, gradle, mix) plug in.
if [ -n "${ENGINE_TEST_CMD:-}" ]; then
    echo "test-run: running ENGINE_TEST_CMD"
    eval "$ENGINE_TEST_CMD"
    exit $?
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT"

# Bail out — friendly notice — if no runner is detectable. Better to skip
# than to fail commits when the project ships no tests yet.
detect_stack() {
    if [ -f pyproject.toml ] || [ -f setup.py ] || [ -f setup.cfg ]; then
        echo "python"; return
    fi
    if [ -f package.json ]; then
        echo "node"; return
    fi
    if [ -f go.mod ]; then
        echo "go"; return
    fi
    if [ -f Cargo.toml ]; then
        echo "rust"; return
    fi
    echo "unknown"
}

STACK=$(detect_stack)

if [ "$STACK" = "unknown" ]; then
    echo "test-run: no known runner (pyproject/package.json/go.mod/Cargo.toml) — skipping" >&2
    exit 0
fi

FULL="${ENGINE_TEST_FULL:-0}"

run_python() {
    if ! command -v pytest >/dev/null 2>&1 && ! "${PE_PYTHON:-python3}" -m pytest --version >/dev/null 2>&1; then
        echo "test-run(python): pytest not installed — skipping (install: pip install pytest)" >&2
        return 0
    fi
    local pytest_bin
    if command -v pytest >/dev/null 2>&1; then
        pytest_bin="pytest"
    else
        pytest_bin="${PE_PYTHON:-python3} -m pytest"
    fi

    local paths=""
    if [ "$FULL" = "1" ]; then
        paths=""
    else
        # Map .py files to the deepest tests/ dir up the tree, or their own dir.
        local candidates=""
        while IFS= read -r f; do
            case "$f" in
                *.py)
                    local d
                    d=$(dirname "$f")
                    # walk up looking for tests/
                    while [ "$d" != "." ] && [ "$d" != "/" ]; do
                        if [ -d "$d/tests" ]; then
                            candidates="$candidates $d/tests"
                            break
                        fi
                        d=$(dirname "$d")
                    done
                    ;;
            esac
        done <<< "$STAGED"
        # Fallback: top-level tests/ if it exists.
        if [ -z "$candidates" ] && [ -d "tests" ]; then
            candidates="tests"
        fi
        paths=$(echo "$candidates" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    fi

    local cov_args=""
    if [ -n "${ENGINE_COVERAGE_MIN:-}" ]; then
        if "${PE_PYTHON:-python3}" -c "import pytest_cov" 2>/dev/null; then
            cov_args="--cov --cov-fail-under=$ENGINE_COVERAGE_MIN"
        else
            echo "test-run(python): pytest-cov not installed — ignoring ENGINE_COVERAGE_MIN" >&2
        fi
    fi

    if [ -z "$paths" ]; then
        echo "test-run(python): no test paths matched changed files — skipping" >&2
        return 0
    fi

    echo "test-run(python): $pytest_bin $cov_args $paths"
    # shellcheck disable=SC2086
    $pytest_bin $cov_args $paths
}

run_node() {
    local runner=""
    if [ -f pnpm-lock.yaml ] && command -v pnpm >/dev/null 2>&1; then
        runner="pnpm test"
    elif [ -f yarn.lock ] && command -v yarn >/dev/null 2>&1; then
        runner="yarn test"
    elif command -v npm >/dev/null 2>&1; then
        runner="npm test"
    else
        echo "test-run(node): no package manager on PATH — skipping" >&2
        return 0
    fi

    # No easy per-file targeting portable across jest/mocha/vitest — run full
    # suite. Node adopters that want scoped can set ENGINE_TEST_CMD.
    echo "test-run(node): $runner"
    eval "$runner"
}

run_go() {
    if ! command -v go >/dev/null 2>&1; then
        echo "test-run(go): go not installed — skipping" >&2
        return 0
    fi
    local pkgs=""
    if [ "$FULL" = "1" ]; then
        pkgs="./..."
    else
        pkgs=$(echo "$STAGED" | grep '\.go$' | xargs -n1 dirname 2>/dev/null | sort -u | sed 's|^|./|' | tr '\n' ' ')
        [ -z "$pkgs" ] && pkgs="./..."
    fi
    local cov_args=""
    if [ -n "${ENGINE_COVERAGE_MIN:-}" ]; then
        cov_args="-cover"
    fi
    echo "test-run(go): go test $cov_args $pkgs"
    # shellcheck disable=SC2086
    go test $cov_args $pkgs
}

run_rust() {
    if ! command -v cargo >/dev/null 2>&1; then
        echo "test-run(rust): cargo not installed — skipping" >&2
        return 0
    fi
    echo "test-run(rust): cargo test"
    cargo test
}

case "$STACK" in
    python) run_python ;;
    node)   run_node ;;
    go)     run_go ;;
    rust)   run_rust ;;
esac
