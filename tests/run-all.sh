#!/usr/bin/env bash
# tests/run-all.sh — run the whole suite and report what failed.
#
# There was no runner. Forty-three test scripts sat in tests/ and the only
# way to run them was to remember to. On 2026-09-04 three of them were red
# at HEAD and had been for some time:
#
#   test_pe_pin           plugin.json stuck at 0.50.0 while VERSION read
#                         0.51.3 — CONTRIBUTING's bump checklist skipped on
#                         four consecutive releases
#   test_incident_synth   a fixture missing two fields the proposal schema
#                         made required in 0.51.0
#   test_trailer_pipefail the regression test for a hook defect, itself red
#
# All three assert something true and useful. Nothing ran them.
#
# Usage:
#   tests/run-all.sh            every test
#   tests/run-all.sh hook       every test whose name contains "hook"
#
# Exit 0 iff every test exits 0.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"

pass=0; fail=0; failed=""
start=$(date +%s)

for t in "$SELF_DIR"/test_*.sh; do
    name=$(basename "$t" .sh)
    [ -n "$FILTER" ] && case "$name" in *"$FILTER"*) ;; *) continue ;; esac
    out=$(bash "$t" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  \033[32m✓\033[0m %s\n' "$name"
        pass=$((pass+1))
    else
        printf '  \033[31m✗\033[0m %s (exit %s)\n' "$name" "$rc"
        printf '%s\n' "$out" | tail -12 | sed 's/^/      /'
        fail=$((fail+1)); failed="$failed $name"
    fi
done

echo
echo "  ${pass} passed, ${fail} failed in $(( $(date +%s) - start ))s"
if [ "$fail" -gt 0 ]; then
    echo "  failed:$failed"
    exit 1
fi
