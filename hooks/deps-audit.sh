#!/usr/bin/env bash
# deps-audit — pre-commit hook that audits dependency manifests for known
# vulnerabilities before a manifest change lands (P1.3).
#
# Fires only when a dep manifest is staged:
#   requirements*.txt · pyproject.toml · Pipfile.lock · poetry.lock  → pip-audit
#   package.json · package-lock.json · pnpm-lock.yaml · yarn.lock    → npm/pnpm audit
#   go.mod · go.sum                                                  → govulncheck (if installed)
#   Cargo.toml · Cargo.lock                                          → cargo audit (if installed)
#
# If the relevant scanner is missing, prints an install hint and exits 0.
# Bypass: ENGINE_SKIP_DEPS_AUDIT=1.

set -uo pipefail

if [ "${ENGINE_SKIP_DEPS_AUDIT:-0}" = "1" ]; then
    echo "deps-audit: ENGINE_SKIP_DEPS_AUDIT=1 — skipping" >&2
    exit 0
fi

STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)

want_python=0
want_node=0
want_go=0
want_rust=0
while IFS= read -r f; do
    case "$f" in
        requirements*.txt|pyproject.toml|Pipfile.lock|poetry.lock) want_python=1 ;;
        package.json|package-lock.json|pnpm-lock.yaml|yarn.lock)   want_node=1 ;;
        go.mod|go.sum)                                              want_go=1 ;;
        Cargo.toml|Cargo.lock)                                      want_rust=1 ;;
    esac
done <<< "$STAGED"

if [ "$want_python" = "0" ] && [ "$want_node" = "0" ] && \
   [ "$want_go" = "0" ] && [ "$want_rust" = "0" ]; then
    exit 0
fi

RC=0

if [ "$want_python" = "1" ]; then
    if command -v pip-audit >/dev/null 2>&1; then
        echo "deps-audit(python): pip-audit"
        pip-audit || RC=$?
    else
        echo "deps-audit(python): pip-audit not installed — pipx install pip-audit" >&2
    fi
fi

if [ "$want_node" = "1" ]; then
    if command -v pnpm >/dev/null 2>&1 && [ -f pnpm-lock.yaml ]; then
        echo "deps-audit(node): pnpm audit"
        pnpm audit || RC=$?
    elif command -v npm >/dev/null 2>&1; then
        echo "deps-audit(node): npm audit"
        npm audit || RC=$?
    else
        echo "deps-audit(node): no package manager on PATH — skipping" >&2
    fi
fi

if [ "$want_go" = "1" ]; then
    if command -v govulncheck >/dev/null 2>&1; then
        echo "deps-audit(go): govulncheck ./..."
        govulncheck ./... || RC=$?
    else
        echo "deps-audit(go): govulncheck not installed — go install golang.org/x/vuln/cmd/govulncheck@latest" >&2
    fi
fi

if [ "$want_rust" = "1" ]; then
    if command -v cargo >/dev/null 2>&1 && cargo audit --version >/dev/null 2>&1; then
        echo "deps-audit(rust): cargo audit"
        cargo audit || RC=$?
    else
        echo "deps-audit(rust): cargo audit not installed — cargo install cargo-audit" >&2
    fi
fi

exit $RC
