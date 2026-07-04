#!/usr/bin/env bash
# tests/test_pe_recall.sh — A7 cross-session decision memory.
#
# Contract:
#   - `pe recall <query>` reads .pe/decisions.jsonl + reconciliations.jsonl,
#     tokenizes signal fields, and returns Jaccard-scored slot summaries.
#   - Preserves slot IDs (`1M.3`), SHAs, snake_case as single tokens.
#   - Missing corpus exits 1 with a hint (not 2 — that's for usage errors).
#   - --json emits parseable output with a `matches` array.
#   - --limit / --min-score respected.
#   - Multiple decisions on same slot collapse to one summary with a
#     verdict trajectory + iteration count.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
PE="$ENGINE_DIR/scripts/pe"
PY="${PE_PYTHON:-python3}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_pe_recall.sh — $PE recall"
echo ""

# ─── 1. missing corpus → exit 1, no crash ───────────────────────────
mkdir -p "$TMP/empty_project"
out=$("$PE" recall --project "$TMP/empty_project" "anything" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -qi "no decisions"; then
    record_pass "empty corpus → exit 1 with hint"
else
    record_fail "empty corpus wrong: rc=$rc out='$out'"
fi

# ─── 2. non-existent project → exit 2 ───────────────────────────────
out=$("$PE" recall --project "$TMP/nonexistent-xyz" "q" 2>&1)
rc=$?
if [ $rc -eq 2 ]; then
    record_pass "missing project dir → exit 2 (usage-class)"
else
    record_fail "missing project dir wrong: rc=$rc"
fi

# ─── 3. seed a corpus with 3 slots, varied trajectories ─────────────
proj="$TMP/proj"
mkdir -p "$proj/.pe"
cat > "$proj/.pe/decisions.jsonl" <<'EOF'
{"decision_id":"d1","ts":"2026-06-01T10:00:00Z","slot_id":"1M.3","slot_kind":"feature","iteration":1,"gate_name":"code-reviewer","envelope":{"verdict":"FAIL","failure_class":"worker_quality","notes":"missing test coverage on billing"},"router_decision":{"action":"escalate_one_tier","rule_matched":"quality_fail","rule_source":"policy.toml"},"breaker_state_at_decision":{}}
{"decision_id":"d2","ts":"2026-06-01T11:00:00Z","slot_id":"1M.3","slot_kind":"feature","iteration":2,"gate_name":"code-reviewer","envelope":{"verdict":"PASS","failure_class":"none","notes":"tests added"},"router_decision":{"action":"continue","rule_matched":"pass","rule_source":"policy.toml"},"breaker_state_at_decision":{}}
{"decision_id":"d3","ts":"2026-06-02T09:00:00Z","slot_id":"2A.1","slot_kind":"bugfix","iteration":1,"gate_name":"security-reviewer","envelope":{"verdict":"WARN","failure_class":"missing_input_validation","notes":"webhook lacks HMAC"},"router_decision":{"action":"continue","rule_matched":"warn_ok","rule_source":"policy.toml"},"breaker_state_at_decision":{}}
{"decision_id":"d4","ts":"2026-06-03T12:00:00Z","slot_id":"3B.7","slot_kind":"refactor","iteration":1,"gate_name":"code-reviewer","envelope":{"verdict":"FAIL","failure_class":"worker_quality","notes":"function too long"},"router_decision":{"action":"escalate_one_tier","rule_matched":"quality_fail","rule_source":"policy.toml"},"breaker_state_at_decision":{}}
{"decision_id":"d5","ts":"2026-06-03T13:00:00Z","slot_id":"3B.7","slot_kind":"refactor","iteration":2,"gate_name":"code-reviewer","envelope":{"verdict":"FAIL","failure_class":"worker_quality","notes":"still too long after split"},"router_decision":{"action":"halt_to_human","rule_matched":"repeated_quality_fail","rule_source":"policy.toml"},"breaker_state_at_decision":{}}
EOF
cat > "$proj/.pe/reconciliations.jsonl" <<'EOF'
{"slot_id":"1M.3","ts":"2026-06-01T12:00:00Z","actual_outcome":"shipped_clean","correctness_notes":"router was right to escalate"}
EOF

# ─── 4. matches for token in envelope.failure_class ─────────────────
out=$("$PE" recall --project "$proj" "worker_quality" 2>&1)
if echo "$out" | grep -q "1M.3" && echo "$out" | grep -q "3B.7"; then
    record_pass "recall matches slots by envelope.failure_class token"
else
    record_fail "failure_class match missed: '$out'"
fi

# ─── 5. slot IDs preserved as tokens (1M.3 stays one token) ─────────
out=$("$PE" recall --project "$proj" "1M.3" 2>&1)
if echo "$out" | grep -q "1M.3 (" && ! echo "$out" | grep -q "2A.1 ("; then
    record_pass "slot IDs preserved as tokens (1M.3 hits, 2A.1 not)"
else
    record_fail "slot-ID tokenization wrong: '$out'"
fi

# ─── 6. multiple decisions collapse into trajectory ─────────────────
out=$("$PE" recall --project "$proj" "worker_quality" 2>&1)
if echo "$out" | grep -q "FAIL → PASS" && echo "$out" | grep -q "FAIL×2"; then
    record_pass "verdict trajectory collapses runs (FAIL→PASS, FAIL×2)"
else
    record_fail "trajectory format wrong: '$out'"
fi

# ─── 7. reconciliation outcome surfaces ─────────────────────────────
out=$("$PE" recall --project "$proj" "1M.3" 2>&1)
if echo "$out" | grep -q "reconciled outcome: shipped_clean"; then
    record_pass "reconciliation outcome surfaced in summary"
else
    record_fail "reconciliation not surfaced: '$out'"
fi

# ─── 8. --json emits parseable output with matches ──────────────────
out=$("$PE" recall --project "$proj" "worker_quality" --json 2>&1)
count=$(echo "$out" | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)["matches"]))' 2>/dev/null || echo "-1")
if [ "$count" = "2" ]; then
    record_pass "--json returns 2 matches for worker_quality"
else
    record_fail "--json match_count wrong: '$count'"
fi

# ─── 9. --limit caps returned matches ───────────────────────────────
out=$("$PE" recall --project "$proj" "worker_quality quality_fail" --limit 1 --json 2>&1)
count=$(echo "$out" | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)["matches"]))' 2>/dev/null || echo "-1")
if [ "$count" = "1" ]; then
    record_pass "--limit 1 caps output"
else
    record_fail "--limit ignored: '$count'"
fi

# ─── 10. --min-score suppresses weak matches ────────────────────────
out=$("$PE" recall --project "$proj" "worker_quality" --min-score 0.5 --json 2>&1)
count=$(echo "$out" | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)["matches"]))' 2>/dev/null || echo "-1")
# At min_score 0.5, nothing this coarse should match; expect 0.
if [ "$count" = "0" ]; then
    record_pass "--min-score 0.5 filters out weak matches"
else
    record_fail "--min-score not applied: got '$count' matches"
fi

# ─── 11. corrupted jsonl line skipped, not fatal ────────────────────
proj2="$TMP/proj_corrupt"
mkdir -p "$proj2/.pe"
cat > "$proj2/.pe/decisions.jsonl" <<'EOF'
{"decision_id":"ok","ts":"2026-06-01T10:00:00Z","slot_id":"9Z.9","gate_name":"code-reviewer","envelope":{"verdict":"PASS","failure_class":"none"},"router_decision":{"action":"continue"},"breaker_state_at_decision":{}}
not valid json {{{
{"decision_id":"ok2","ts":"2026-06-02T10:00:00Z","slot_id":"9Z.9","gate_name":"code-reviewer","envelope":{"verdict":"PASS","failure_class":"none"},"router_decision":{"action":"continue"},"breaker_state_at_decision":{}}
EOF
out=$("$PE" recall --project "$proj2" "9Z.9" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "9Z.9"; then
    record_pass "corrupted jsonl line skipped, valid rows preserved"
else
    record_fail "corrupted jsonl broke recall: rc=$rc out='$out'"
fi

# ─── 11b. corruption warning surfaces on stderr (reviewer HIGH fix) ──
err_out=$("$PE" recall --project "$proj2" "9Z.9" 2>&1 1>/dev/null)
if echo "$err_out" | grep -qE "WARNING skipped malformed line"; then
    record_pass "corrupted jsonl WARN emitted to stderr (no silent data loss)"
else
    record_fail "corruption warning not surfaced: '$err_out'"
fi

# ─── 12. reconciliation-only slot surfaces even without a decision ──
proj3="$TMP/proj_reconly"
mkdir -p "$proj3/.pe"
touch "$proj3/.pe/decisions.jsonl"
cat > "$proj3/.pe/reconciliations.jsonl" <<'EOF'
{"slot_id":"ORPHAN.1","actual_outcome":"rolled_back","correctness_notes":"bad merge"}
EOF
out=$("$PE" recall --project "$proj3" "rolled_back" 2>&1)
if echo "$out" | grep -q "ORPHAN.1"; then
    record_pass "reconciliation-only slot still recallable"
else
    record_fail "orphan reconciliation not surfaced: '$out'"
fi

# ─── summary ────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  passed: $pass"
echo "  failed: $fail"
if [ $fail -gt 0 ]; then
    for f in "${failures[@]}"; do echo "    - $f"; done
    exit 1
fi
exit 0
