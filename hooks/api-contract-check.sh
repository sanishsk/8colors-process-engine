#!/usr/bin/env bash
# api-contract-check — API breaking-change gate (A9.2, v0.17.1).
#
# When a committed OpenAPI/Swagger spec changes, this compares the HEAD
# version against the staged version and BLOCKS the commit on a breaking
# change (endpoint/param/required-field removal, type change). Additions
# are advisory (WARN).
#
# Mechanism: reuses the ai-testing-agent's differ via its CLI
#   ai-test api-diff --old <head-spec> --new <staged-spec>
# (the same APIDiffer the `compare_api_specs` MCP tool uses — one source
# of truth). The CLI is OPTIONAL: if `ai-test` isn't installed the gate
# is an advisory skip, exactly like sast-scan when semgrep is absent.
#
# For full param/schema analysis the differ wants `deepdiff`
# (pip install 'ai-testing-agent[diff]'); without it endpoint-level
# removals are still caught.
#
# Config (.process-engine.yaml):
#   api_contract_gate.enabled    — default true (opt-out per project)
#   api_contract_gate.spec_globs — space-separated globs of committed specs
#                                   (default openapi*/swagger* .yaml/.yml/.json)
#
# One-shot bypass:
#   PE_SKIP_API_CONTRACT=1 git commit ...

set -euo pipefail

if [ "${PE_SKIP_API_CONTRACT:-0}" = "1" ]; then
    echo "[api-contract] skipped (PE_SKIP_API_CONTRACT=1)" >&2
    exit 0
fi

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ENGINE_DIR/scripts/_yaml.sh" ]; then
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/scripts/_yaml.sh"
fi

CONFIG=".process-engine.yaml"
enabled="true"
spec_globs="openapi*.yaml openapi*.yml openapi*.json swagger*.yaml swagger*.yml swagger*.json"

if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get api_contract_gate.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    v=$(yaml_get api_contract_gate.spec_globs "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && spec_globs="$v"
fi

if [ "$enabled" != "true" ]; then
    exit 0
fi

# ─── which staged files are committed API specs? ────────────────────
STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
[ -z "$STAGED" ] && exit 0

matched=""
for f in $STAGED; do
    base=$(basename "$f")
    for glob in $spec_globs; do
        # shellcheck disable=SC2254
        case "$base" in
            $glob) matched="$matched $f"; break ;;
        esac
    done
done
matched=$(echo "$matched" | xargs -n1 2>/dev/null | sort -u || true)
[ -z "$matched" ] && exit 0

# ─── the differ CLI is optional ─────────────────────────────────────
if ! command -v ai-test >/dev/null 2>&1; then
    echo "[api-contract] ai-test not installed — advisory skip." >&2
    echo "[api-contract] install: pip install 'ai-testing-agent[diff]'" >&2
    exit 0
fi

TMPDIR_AC=$(mktemp -d)
trap 'rm -rf "$TMPDIR_AC"' EXIT

fail=0
checked=0

for spec in $matched; do
    # Need a HEAD version to compare against; brand-new specs have nothing.
    if ! git cat-file -e "HEAD:$spec" 2>/dev/null; then
        echo "[api-contract] $spec is new — no baseline to compare, skipping." >&2
        continue
    fi

    old="$TMPDIR_AC/old_$(echo "$spec" | tr '/' '_')"
    new="$TMPDIR_AC/new_$(echo "$spec" | tr '/' '_')"
    git show "HEAD:$spec" > "$old" 2>/dev/null || continue
    git show ":$spec" > "$new" 2>/dev/null || continue   # staged blob

    printf '\n[api-contract] diffing %s (HEAD → staged)\n' "$spec" >&2
    checked=1

    # Exit code: 0 ok, 1 breaking, 2 load error.
    set +e
    out=$(ai-test api-diff --old "$old" --new "$new" 2>&1)
    rc=$?
    set -e

    echo "$out" >&2
    if [ "$rc" -eq 1 ]; then
        fail=1
    elif [ "$rc" -eq 2 ]; then
        echo "[api-contract] could not parse $spec — treating as advisory (not blocking)." >&2
    fi
done

if [ "$checked" -eq 0 ]; then
    exit 0
fi

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'

[api-contract] FAIL — a staged OpenAPI/Swagger spec removed or changed an
existing endpoint/parameter/field in a backward-incompatible way.

Resolutions:
  1. Keep the old shape and add the new one alongside (non-breaking).
  2. If the break is intentional: bump the API MAJOR version and/or add a
     deprecation window, then re-commit.
  3. One-shot bypass (logged in the commit audit):
     PE_SKIP_API_CONTRACT=1 git commit ...
EOF
    exit 1
fi

exit 0
