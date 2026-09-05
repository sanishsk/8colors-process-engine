#!/usr/bin/env bash
# tests/test_parallel_fix.sh — run workflows/parallel-fix.js for real and
# assert what it decides.
#
# Shell wrapper so run-all.sh (which globs test_*.sh) and CI pick it up. The
# assertions live in tests/parallel_fix_harness.mjs, which loads the actual
# workflow file, stubs the runtime's hooks, and drives the real control flow.
#
# node is NOT an engine dependency and never becomes one: the workflow script
# is executed by Claude Code's own runtime, never by node on an adopter's
# machine. node is used here only to exercise the logic in CI, where GitHub's
# ubuntu-latest image ships it. Absent node, this skips loudly — the same
# contract as test_gate_review_behaviour.sh.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
    echo "test_parallel_fix"
    echo "  ⚠ SKIPPED — node not on PATH."
    echo "    The workflow's landability floor is therefore UNTESTED in this run."
    echo "    node is not an engine dependency; Claude Code runs the script."
    exit 0
fi

exec node "$SELF_DIR/parallel_fix_harness.mjs"
