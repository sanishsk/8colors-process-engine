#!/usr/bin/env bash
# tests/test_gate_review_behaviour.sh — run workflows/gate-review.js for real
# and assert what it decides.
#
# Shell wrapper so run-all.sh (which globs test_*.sh) and CI pick it up. The
# assertions live in tests/gate_review_harness.mjs, which loads the actual
# workflow file, stubs the runtime's four hooks, and drives the real control
# flow — rather than testing a description of it.
#
# node is NOT an engine dependency and never becomes one: the workflow script
# is executed by Claude Code's own runtime, never by node on an adopter's
# machine. node is used here only to exercise the logic in CI, where GitHub's
# ubuntu-latest image ships it. Absent node, this skips loudly — the same
# contract as sast-scan with no scanner installed.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
    echo "test_gate_review_behaviour"
    echo "  ⚠ SKIPPED — node not on PATH."
    echo "    The workflow's decision logic is therefore UNTESTED in this run."
    echo "    node is not an engine dependency; Claude Code runs the script."
    exit 0
fi

exec node "$SELF_DIR/gate_review_harness.mjs"
