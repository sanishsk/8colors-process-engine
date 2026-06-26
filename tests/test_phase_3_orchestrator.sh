#!/usr/bin/env bash
# tests/test_phase_3_orchestrator.sh
#
# Exit-coded smoke tests for the Phase 3 shadow-mode orchestrator
# (pe shadow decide / reconcile). Stdlib-only, no pytest dependency
# — matches the engine's existing CLI-test style.
#
# Run: bash tests/test_phase_3_orchestrator.sh
#
# Exits 0 if all assertions pass; non-zero on first failure.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
ORCH="$ENGINE_DIR/scripts/pe_orchestrator.py"
FIX="$ENGINE_DIR/schemas/fixtures"
TMP="$(mktemp -d -t pe_phase3_test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

LOG="$TMP/.pe/decisions.jsonl"
REC_LOG="$TMP/.pe/reconciliations.jsonl"
mkdir -p "$TMP/.pe"

fail=0
pass=0

assert_action() {
    local desc="$1" expected="$2" actual
    actual="$(echo "$3" | python3 -c 'import sys, json; print(json.load(sys.stdin)["action"])')"
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $desc — action=$actual"
        pass=$((pass + 1))
    else
        echo "  ✗ $desc — expected action=$expected, got $actual"
        fail=$((fail + 1))
    fi
}

assert_rule() {
    local desc="$1" expected="$2" actual
    actual="$(echo "$3" | python3 -c 'import sys, json; print(json.load(sys.stdin)["rule_matched"])')"
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $desc — rule=$actual"
        pass=$((pass + 1))
    else
        echo "  ✗ $desc — expected rule=$expected, got $actual"
        fail=$((fail + 1))
    fi
}

assert_breaker_trip() {
    local desc="$1" expected="$2" actual
    actual="$(echo "$3" | python3 -c 'import sys, json; print(json.load(sys.stdin)["breaker_would_trip"])')"
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $desc — breaker_would_trip=$actual"
        pass=$((pass + 1))
    else
        echo "  ✗ $desc — expected breaker_would_trip=$expected, got $actual"
        fail=$((fail + 1))
    fi
}

# ─── routing-policy paths ──────────────────────────────────────────────────

echo "=== 1. worker_quality at haiku → escalate to sonnet ==="
out="$(python3 "$ORCH" decide --bare \
    --envelope "$FIX/fail-escalate.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 1 --current-tier haiku --decisions-log "$LOG")"
assert_action "worker_quality at haiku" "escalate_one_tier" "$out"
assert_rule   "worker_quality at haiku" "worker_quality -> escalate_one_tier" "$out"

echo "=== 2. worker_quality at OPUS → terminal halt (operator refinement) ==="
out="$(python3 "$ORCH" decide --bare \
    --envelope "$FIX/fail-escalate.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 2 --current-tier opus --decisions-log "$LOG")"
assert_action "worker_quality at opus" "halt_to_human" "$out"
assert_rule   "worker_quality at opus" "top_tier_worker_quality" "$out"

echo "=== 3. low-confidence (0.55) → halt via confidence override ==="
out="$(python3 "$ORCH" decide --bare \
    --envelope "$FIX/fail-halt.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 3 --current-tier haiku --decisions-log "$LOG")"
assert_action "low-confidence halt" "halt_to_human" "$out"
assert_rule   "low-confidence halt" "confidence_below_0.6" "$out"

echo "=== 4. PASS envelope → continue ==="
out="$(python3 "$ORCH" decide --bare \
    --envelope "$FIX/pass.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 4 --current-tier haiku --decisions-log "$LOG")"
assert_action "PASS continue" "continue" "$out"

echo "=== 5. schema-invalid envelope → halt (never silent-pass) ==="
out="$(python3 "$ORCH" decide --bare \
    --envelope "$FIX/invalid-bad-enum.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 5 --current-tier sonnet --decisions-log "$LOG")"
assert_action "schema-invalid halt" "halt_to_human" "$out"
assert_rule   "schema-invalid halt" "schema_error" "$out"

echo "=== 6. real transcript (E1.d cross-check enforced) → escalate ==="
out="$(python3 "$ORCH" decide \
    --envelope "$FIX/transcript-with-crosscheck.md" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 1 --current-tier haiku --decisions-log "$LOG")"
assert_action "transcript escalate" "escalate_one_tier" "$out"

# ─── breaker ───────────────────────────────────────────────────────────────

echo "=== 7. iteration cap (iter=6 hits slot_iteration_cap=6) → breaker trips ==="
out="$(python3 "$ORCH" decide --bare \
    --envelope "$FIX/fail-escalate.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 6 --current-tier sonnet --decisions-log "$LOG")"
assert_breaker_trip "iter=6 trips cap" "True" "$out"

# ─── reconciliation ────────────────────────────────────────────────────────

echo "=== 8. reconcile joins all decisions for the slot ==="
reconciliation_payload='{
  "merge_commit": "test1234",
  "ultimate_outcome": "merged",
  "actual_iterations_used": 4,
  "actual_tier_progression": ["haiku", "sonnet", "sonnet", "sonnet"],
  "router_correctness": {
    "decisions_matching_reality": 6,
    "decisions_diverging_from_reality": 1,
    "notes": "test fixture"
  }
}'
echo "$reconciliation_payload" | python3 "$ORCH" reconcile \
    --slot-id PHASE3.1 --decisions-log "$LOG" \
    --reconciliations-log "$REC_LOG" 2>/dev/null

# Verify reconciliation file contents
count="$(python3 -c "import json; print(len(json.loads(open('$REC_LOG').read().strip())['router_decisions']))")"
if [ "$count" = "7" ]; then
    echo "  ✓ reconciliation joined 7 decisions"
    pass=$((pass + 1))
else
    echo "  ✗ reconciliation joined $count decisions (expected 7)"
    fail=$((fail + 1))
fi

# ─── negative cases ────────────────────────────────────────────────────────

echo "=== 9. reconcile on unknown slot → exit 2 ==="
set +e
echo '{}' | python3 "$ORCH" reconcile --slot-id NOSUCH \
    --decisions-log "$LOG" \
    --reconciliations-log "$REC_LOG" 2>/dev/null
rc=$?
set -e
if [ $rc -eq 2 ]; then
    echo "  ✓ unknown-slot reconcile exits 2"
    pass=$((pass + 1))
else
    echo "  ✗ unknown-slot reconcile exited $rc (expected 2)"
    fail=$((fail + 1))
fi

echo "=== 10. decide on nonexistent envelope → exit 2 ==="
set +e
python3 "$ORCH" decide --bare \
    --envelope "$TMP/does-not-exist.json" \
    --slot-id PHASE3.1 --iteration 1 --current-tier haiku 2>/dev/null
rc=$?
set -e
if [ $rc -eq 2 ]; then
    echo "  ✓ nonexistent-envelope exits 2"
    pass=$((pass + 1))
else
    echo "  ✗ nonexistent-envelope exited $rc (expected 2)"
    fail=$((fail + 1))
fi

# ─── summary ───────────────────────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────"
echo "Phase 3 orchestrator tests: $pass passed, $fail failed"
echo "──────────────────────────────────────"
exit "$fail"
