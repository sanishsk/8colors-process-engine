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
# The runner was a serial for-loop, which cost 105s of wall clock at 57% of
# ONE core on an 8-core machine. Almost none of that was computation: these
# tests spend their time forking git, python and bash, so the box sat idle
# while the loop waited. The suite is the thing you run before every commit,
# and a two-minute suite is one people skip.
#
# Tests are safe to run concurrently because none of them writes into the
# repo tree — every test that needs a mutable tree builds one under
# `mktemp -d`, and the rest only read and assert. That is a property of the
# suite as it stands today, not a rule anything enforced, so the runner
# checks it: `git status --porcelain` is sampled before and after, and a
# difference is reported. A test that scribbles in the repo is the one way
# this runner can turn a real result into a flake, and it announces itself
# the first time it runs rather than the first time it loses a race.
#
# Usage:
#   tests/run-all.sh            every test
#   tests/run-all.sh hook       every test whose name contains "hook"
#   PE_TEST_JOBS=1 tests/run-all.sh    force serial (debugging)
#
# Exit 0 iff every test exits 0.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"

# Oversubscribed on purpose. These tests fork git, python and bash far more
# than they compute — the serial run burned 105s of wall clock at 57% of a
# single core — so the limiting resource is waiting, not CPU. Measured on an
# 8-core box: serial 105s, 8 jobs 28s, 16 jobs 23s. The floor is 12s, the
# slowest single test (test_hook_smoke), so there is little left to win and
# no reason to oversubscribe harder. Capped at 16 so a big CI runner does not
# open hundreds of concurrent git processes.
JOBS="${PE_TEST_JOBS:-}"
if [ -z "$JOBS" ]; then
    ncpu=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
    JOBS=$(( ncpu * 2 ))
    [ "$JOBS" -gt 16 ] && JOBS=16
fi

TESTS=()
for t in "$SELF_DIR"/test_*.sh; do
    [ -f "$t" ] || continue
    name=$(basename "$t" .sh)
    [ -n "$FILTER" ] && case "$name" in *"$FILTER"*) ;; *) continue ;; esac
    TESTS+=("$t")
done

if [ ${#TESTS[@]} -eq 0 ]; then
    echo "  no tests matched filter '${FILTER}'"
    exit 1
fi

OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
start=$(date +%s)

# Sampled, not asserted clean — you run this with work in progress.
TREE_BEFORE=$(git -C "$SELF_DIR/.." status --porcelain 2>/dev/null)

# Each worker captures its own output to a file and prints only its
# one-line verdict, so progress stays live while the multi-line failure
# detail below stays contiguous instead of interleaving with seven other
# tests. Workers always exit 0 — the real code goes in the .rc file — so
# xargs runs the whole list rather than stopping at the first red test.
printf '%s\n' "${TESTS[@]}" \
  | xargs -P "$JOBS" -n1 bash -c '
        t="$1"; name=$(basename "$t" .sh); o="'"$OUT"'/$name"
        bash "$t" >"$o.out" 2>&1; rc=$?
        echo "$rc" >"$o.rc"
        if [ "$rc" -eq 0 ]; then
            printf "  \033[32m✓\033[0m %s\n" "$name"
        else
            printf "  \033[31m✗\033[0m %s (exit %s)\n" "$name" "$rc"
        fi
    ' _

# Report in list order, not completion order, so two runs of a green suite
# produce identical output and a CI log diff means something.
pass=0; fail=0; failed=""
for t in "${TESTS[@]}"; do
    name=$(basename "$t" .sh)
    rc=$(cat "$OUT/$name.rc" 2>/dev/null || echo "missing")
    if [ "$rc" = "0" ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failed="$failed $name"
        echo
        printf '  \033[31m✗ %s\033[0m (exit %s)\n' "$name" "$rc"
        tail -12 "$OUT/$name.out" 2>/dev/null | sed 's/^/      /'
    fi
done

TREE_AFTER=$(git -C "$SELF_DIR/.." status --porcelain 2>/dev/null)
if [ "$TREE_BEFORE" != "$TREE_AFTER" ]; then
    echo
    echo "  ⚠ a test wrote into the repo working tree:"
    diff <(printf '%s\n' "$TREE_BEFORE") <(printf '%s\n' "$TREE_AFTER") \
        | sed -n 's/^> /      /p'
    echo "    Tests must build a scratch tree with \`mktemp -d\`. Until this"
    echo "    is fixed, results under parallel execution can race — rerun"
    echo "    with PE_TEST_JOBS=1 to confirm the verdicts above."
    fail=$((fail+1)); failed="$failed repo-tree-mutated"
fi

echo
echo "  ${pass} passed, ${fail} failed in $(( $(date +%s) - start ))s (${JOBS} jobs)"
if [ "$fail" -gt 0 ]; then
    echo "  failed:$failed"
    exit 1
fi
