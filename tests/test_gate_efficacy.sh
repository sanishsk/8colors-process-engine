#!/usr/bin/env bash
# test_gate_efficacy.sh — A2 shape-mode runner for the eval corpus.
#
# For every fixture under evals/fixtures/<gate>/<verdict>-<slug>/:
#   1. Assert input.md exists and starts with '# <slug>'.
#   2. Call `pe gate parse --bare expected-envelope.json`.
#   3. Assert the exit code class matches the directory-prefix contract:
#        pass-*         → exit 0
#        fail-escalate-* → exit 1
#        fail-halt-*    → exit 2
#        warn-*         → exit 3
#        adversarial-*  → exit 0 (safe lookalike must not FP)
#
# Runs in CI. Zero API cost. Catches:
#   - Envelopes that no longer validate against the schema (drift).
#   - Fixtures with mislabeled verdict semantics.
#   - Missing input.md scaffolding.
#
# Does NOT invoke the live agent. See evals/README.md for the planned
# --live mode (weekly / pre-release, requires ANTHROPIC_API_KEY).

set -uo pipefail

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENGINE_DIR=$(cd -P "$SCRIPT_DIR/.." && pwd)
PE="$ENGINE_DIR/scripts/pe"
CORPUS="$ENGINE_DIR/evals/fixtures"

pass=0
fail=0
declare -a failures=()

record_fail() {
    fail=$((fail+1))
    failures+=("$1")
    echo "  ✗ $1"
}

record_pass() {
    pass=$((pass+1))
    echo "  ✓ $1"
}

expected_exit_for() {
    local dir_name="$1"
    case "$dir_name" in
        pass-*)           echo 0 ;;
        fail-escalate-*)  echo 1 ;;
        fail-halt-*)      echo 2 ;;
        warn-*)           echo 3 ;;
        adversarial-*)    echo 0 ;;
        *)                echo "?" ;;
    esac
}

if [ ! -d "$CORPUS" ]; then
    echo "ERROR: eval corpus missing: $CORPUS" >&2
    echo "  (v0.19.0 seeded evals/fixtures/security-reviewer/. Was it deleted?)" >&2
    exit 2
fi

echo "gate-efficacy shape check — $CORPUS"
echo ""

for gate_dir in "$CORPUS"/*/; do
    [ -d "$gate_dir" ] || continue
    gate_name=$(basename "$gate_dir")
    echo "gate: $gate_name"

    for fixture_dir in "$gate_dir"*/; do
        [ -d "$fixture_dir" ] || continue
        fixture_name=$(basename "$fixture_dir")
        expected=$(expected_exit_for "$fixture_name")

        if [ "$expected" = "?" ]; then
            record_fail "$gate_name/$fixture_name — unknown directory prefix (expected pass-/fail-escalate-/fail-halt-/warn-/adversarial-)"
            continue
        fi

        # 1. input.md present + first line matches slug
        input_md="$fixture_dir/input.md"
        if [ ! -f "$input_md" ]; then
            record_fail "$gate_name/$fixture_name — missing input.md"
            continue
        fi
        first_line=$(head -1 "$input_md")
        if [ "$first_line" != "# $fixture_name" ]; then
            record_fail "$gate_name/$fixture_name — input.md first line is '$first_line', expected '# $fixture_name'"
            continue
        fi

        # 2. expected-envelope.json present
        envelope="$fixture_dir/expected-envelope.json"
        if [ ! -f "$envelope" ]; then
            record_fail "$gate_name/$fixture_name — missing expected-envelope.json"
            continue
        fi

        # 3. pe gate parse --bare exit code matches contract
        set +e
        "$PE" gate parse --bare "$envelope" > /dev/null 2>&1
        actual=$?
        set -e

        if [ "$actual" != "$expected" ]; then
            record_fail "$gate_name/$fixture_name — pe gate parse exit=$actual, expected=$expected"
        else
            record_pass "$gate_name/$fixture_name (exit=$actual)"
        fi
    done
    echo ""
done

echo "───────────────────────────────────────────────────"
echo "gate-efficacy shape: $pass passed, $fail failed"
if [ $fail -gt 0 ]; then
    echo ""
    echo "Failures:"
    for f in "${failures[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
