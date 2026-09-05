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

# The orchestrator needs Python 3.11+ (tomllib); stock macOS python3 is 3.9.
PY="${PE_PYTHON:-}"
if [ -z "$PY" ]; then
    for cand in python3 python3.13 python3.12 python3.11; do
        if command -v "$cand" >/dev/null 2>&1 \
           && "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
            PY="$cand"
            break
        fi
    done
fi
if [ -z "$PY" ]; then
    echo "SKIP: no Python 3.11+ interpreter found (set PE_PYTHON=/path/to/python3.11+)" >&2
    exit 0
fi
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

# Inline fixtures for the failure_class paths not in schemas/fixtures/.
# Confidence is set HIGH on these so the test confirms the
# failure_class rule fires — not the confidence override masking it.
mk_envelope() {
    local file="$1" fclass="$2" verdict="${3:-FAIL}"
    cat > "$file" <<JSON
{
  "schema_version": "1.0.0",
  "gate_name": "code-reviewer",
  "verdict": "$verdict",
  "failure_class": "$fclass",
  "confidence": 0.95,
  "model_used": "claude-sonnet-4-6",
  "tier": "sonnet",
  "timestamp": "2026-06-26T00:00:00Z",
  "summary": "$fclass synthetic test envelope",
  "findings": []
}
JSON
}
mk_envelope "$TMP/task-underspec-highconf.json" "task_underspecified"
mk_envelope "$TMP/blocked-highconf.json"        "blocked"
mk_envelope "$TMP/out-of-scope-highconf.json"   "out_of_scope"

# ─── routing-policy paths ──────────────────────────────────────────────────

echo "=== 1. worker_quality at haiku → escalate to sonnet ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$FIX/fail-escalate.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 1 --current-tier haiku --decisions-log "$LOG")"
assert_action "worker_quality at haiku" "escalate_one_tier" "$out"
assert_rule   "worker_quality at haiku" "worker_quality -> escalate_one_tier" "$out"

echo "=== 2. worker_quality at OPUS → terminal halt (operator refinement) ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$FIX/fail-escalate.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 2 --current-tier opus --decisions-log "$LOG")"
assert_action "worker_quality at opus" "halt_to_human" "$out"
assert_rule   "worker_quality at opus" "top_tier_worker_quality" "$out"

echo "=== 3. low-confidence (0.55) → halt via confidence override ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$FIX/fail-halt.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 3 --current-tier haiku --decisions-log "$LOG")"
assert_action "low-confidence halt" "halt_to_human" "$out"
assert_rule   "low-confidence halt" "confidence_below_0.6" "$out"

echo "=== 4. PASS envelope → continue ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$FIX/pass.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 4 --current-tier haiku --decisions-log "$LOG")"
assert_action "PASS continue" "continue" "$out"

echo "=== 5. schema-invalid envelope → halt (never silent-pass) ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$FIX/invalid-bad-enum.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 5 --current-tier sonnet --decisions-log "$LOG")"
assert_action "schema-invalid halt" "halt_to_human" "$out"
assert_rule   "schema-invalid halt" "schema_error" "$out"

echo "=== 5b. task_underspecified at conf=0.95 → halt (rule, not conf-override) ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$TMP/task-underspec-highconf.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 1 --current-tier haiku --decisions-log "$LOG")"
assert_action "task_underspecified high-conf halt" "halt_to_human" "$out"
assert_rule   "task_underspecified high-conf halt" "task_underspecified -> halt_to_human" "$out"

echo "=== 5c. blocked at conf=0.95 → halt ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$TMP/blocked-highconf.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 1 --current-tier haiku --decisions-log "$LOG")"
assert_action "blocked halt" "halt_to_human" "$out"
assert_rule   "blocked halt" "blocked -> halt_to_human" "$out"

echo "=== 5d. out_of_scope at conf=0.95 → halt ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$TMP/out-of-scope-highconf.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 1 --current-tier haiku --decisions-log "$LOG")"
assert_action "out_of_scope halt" "halt_to_human" "$out"
assert_rule   "out_of_scope halt" "out_of_scope -> halt_to_human" "$out"

echo "=== 5e. FAIL + failure_class=none (contradictory) → halt, never continue ==="
# Regression guard: the "none -> continue" rule must never apply to a FAIL
# verdict — before 2026-07-02 this envelope routed to continue (fail-safe hole).
mk_envelope "$TMP/fail-none-contradiction.json" "none" "FAIL"
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$TMP/fail-none-contradiction.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 1 --current-tier haiku --decisions-log "$LOG")"
# Two defense layers can catch this (pe_gate coherence check → schema_error,
# or route()'s fail_verdict_contradiction guard) — the contract under test is
# only: action is halt_to_human, NEVER continue.
assert_action "FAIL+none contradiction halt" "halt_to_human" "$out"

echo "=== 6. real transcript (E1.d cross-check enforced) → escalate ==="
out="$("$PY" "$ORCH" decide \
    --envelope "$FIX/transcript-with-crosscheck.md" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 1 --current-tier haiku --decisions-log "$LOG")"
assert_action "transcript escalate" "escalate_one_tier" "$out"

# ─── severity-override (2026-06-26 — slot 1M.3.224b catch) ────────────────
#
# Verdict-blind severity floor: a PASS/WARN envelope carrying HIGH or
# CRITICAL findings overrides the verdict→continue mapping and halts.
# Mirrors the consumer project's commit policy (HIGH = address-or-
# skip-documented). Without these tests, the regression would silently
# auto-merge HIGH-finding work at enforcement.

mk_envelope_with_findings() {
    # $1=file $2=verdict $3=findings_json_array
    local file="$1" verdict="$2" findings="$3"
    cat > "$file" <<JSON
{
  "schema_version": "1.0.0",
  "gate_name": "code-reviewer",
  "verdict": "$verdict",
  "failure_class": "none",
  "confidence": 0.95,
  "model_used": "claude-sonnet-4-6",
  "tier": "sonnet",
  "timestamp": "2026-06-26T00:00:00Z",
  "summary": "severity-override fixture",
  "findings": $findings
}
JSON
}

# 6a. WARN + 1 HIGH finding → halt (the original divergence case).
mk_envelope_with_findings "$TMP/warn-1high.json" "WARN" \
    '[{"severity": "HIGH", "rule": "x", "message": "y"}]'
echo "=== 6a. WARN + 1 HIGH finding → halt (severity override) ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$TMP/warn-1high.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 6 --current-tier sonnet --decisions-log "$LOG")"
assert_action "WARN+HIGH halt" "halt_to_human" "$out"
assert_rule   "WARN+HIGH halt" "severity_floor:HIGH" "$out"

# 6b. PASS + 1 CRITICAL → halt (CRITICAL also blocks regardless of verdict).
mk_envelope_with_findings "$TMP/pass-1critical.json" "PASS" \
    '[{"severity": "CRITICAL", "rule": "x", "message": "y"}]'
echo "=== 6b. PASS + 1 CRITICAL → halt (severity override) ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$TMP/pass-1critical.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 7 --current-tier sonnet --decisions-log "$LOG")"
assert_action "PASS+CRITICAL halt" "halt_to_human" "$out"
assert_rule   "PASS+CRITICAL halt" "severity_floor:CRITICAL" "$out"

# 6c. WARN + only MEDIUM/LOW → continue (no false positive).
mk_envelope_with_findings "$TMP/warn-medium-low.json" "WARN" \
    '[{"severity": "MEDIUM", "rule": "x", "message": "y"}, {"severity": "LOW", "rule": "z", "message": "w"}]'
echo "=== 6c. WARN + only MEDIUM/LOW → continue (no false positive) ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$TMP/warn-medium-low.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 8 --current-tier sonnet --decisions-log "$LOG")"
assert_action "WARN+MEDIUM/LOW continue" "continue" "$out"
assert_rule   "WARN+MEDIUM/LOW continue" "none" "$out"

# 6d. PASS + empty findings → continue (regression guard for §10.2).
mk_envelope_with_findings "$TMP/pass-empty.json" "PASS" "[]"
echo "=== 6d. PASS + empty findings → continue (regression guard) ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$TMP/pass-empty.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 9 --current-tier sonnet --decisions-log "$LOG")"
assert_action "PASS+empty continue" "continue" "$out"

# 6e. FAIL + HIGH finding → routes via failure_class, NOT severity floor.
# Severity floor MUST NOT shadow the existing FAIL→failure_class path.
mk_envelope_with_findings "$TMP/fail-high.json" "FAIL" \
    '[{"severity": "HIGH", "rule": "x", "message": "y"}]'
# Change failure_class to worker_quality so we can verify the FAIL path
# still routes via failure_class even when HIGH findings are present.
python3 -c "
import json
p = '$TMP/fail-high.json'
d = json.load(open(p))
d['failure_class'] = 'worker_quality'
json.dump(d, open(p, 'w'))
"
echo "=== 6e. FAIL + HIGH → failure_class path wins (severity floor doesn't shadow FAIL) ==="
out="$("$PY" "$ORCH" decide --bare \
    --envelope "$TMP/fail-high.json" \
    --slot-id PHASE3.1 --slot-kind feature_incremental \
    --iteration 10 --current-tier haiku --decisions-log "$LOG")"
assert_action "FAIL+HIGH escalate" "escalate_one_tier" "$out"
assert_rule   "FAIL+HIGH escalate" "worker_quality -> escalate_one_tier" "$out"

# ─── shadow-mode invariants (load-bearing — the whole point of Phase 3) ───

echo "=== SHADOW-1: every recorded decision has enforced=false ==="
nonshadow_count="$(python3 -c "
import json
with open('$LOG') as f:
    n = sum(1 for line in f if line.strip()
            and json.loads(line).get('enforced') is not False)
print(n)
")"
if [ "$nonshadow_count" = "0" ]; then
    echo "  ✓ all decisions have enforced=false (no row claimed enforcement)"
    pass=$((pass + 1))
else
    echo "  ✗ $nonshadow_count decisions had enforced!=false — shadow-mode is leaking"
    fail=$((fail + 1))
fi

echo "=== SHADOW-2: .pe/decisions.jsonl is the ONLY side-effect ==="
# Count files written under \$TMP outside .pe/ (orchestrator should not
# touch anything else — not worker invocations, not git, not network, not
# stub files in tmpdir). Orchestrator may also write
# .pe/breaker-cumulative.json — that's expected (breaker accounting),
# allowlist it.
unexpected_files="$(find "$TMP" -type f \
    ! -path "$TMP/.pe/decisions.jsonl" \
    ! -path "$TMP/.pe/breaker-cumulative.json" \
    ! -path "$TMP/.pe/reconciliations.jsonl" \
    ! -path "$TMP/task-underspec-highconf.json" \
    ! -path "$TMP/blocked-highconf.json" \
    ! -path "$TMP/out-of-scope-highconf.json" \
    ! -path "$TMP/fail-none-contradiction.json" \
    ! -path "$TMP/warn-1high.json" \
    ! -path "$TMP/pass-1critical.json" \
    ! -path "$TMP/warn-medium-low.json" \
    ! -path "$TMP/pass-empty.json" \
    ! -path "$TMP/fail-high.json")"
if [ -z "$unexpected_files" ]; then
    echo "  ✓ only .pe/{decisions,breaker-cumulative,reconciliations} written"
    pass=$((pass + 1))
else
    echo "  ✗ unexpected files created: $unexpected_files"
    fail=$((fail + 1))
fi

echo "=== SHADOW-3: decision record has all fields needed for reconciliation ==="
# Per docs/PHASE_3_ESCALATION_ROUTER.md §10, the shadow log must let
# `pe shadow reconcile` answer: would the router's choice have beaten
# reality? Missing any of these = unfalsifiable shadow-mode.
required_fields=(
    "decision_id" "ts" "slot_id" "slot_kind" "iteration" "gate_name"
    "envelope" "router_decision" "breaker_state_at_decision" "enforced"
)
missing_fields="$(python3 -c "
import json
required = $(printf '%s\n' "${required_fields[@]}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split()))')
with open('$LOG') as f:
    for line_no, line in enumerate(f, 1):
        line = line.strip()
        if not line: continue
        rec = json.loads(line)
        for r in required:
            if r not in rec:
                print(f'line {line_no}: missing {r}')
        rd = rec.get('router_decision', {})
        for r in ['action', 'from_tier', 'to_tier', 'rule_matched', 'rule_source']:
            if r not in rd:
                print(f'line {line_no}: router_decision missing {r}')
        bs = rec.get('breaker_state_at_decision', {})
        for r in ['slot_iterations_used', 'slot_iteration_cap',
                  'cumulative_worker_budget', 'cumulative_gate_budget',
                  'breaker_would_trip']:
            if r not in bs:
                print(f'line {line_no}: breaker_state missing {r}')
")"
if [ -z "$missing_fields" ]; then
    echo "  ✓ all decisions carry the full reconciliation schema"
    pass=$((pass + 1))
else
    echo "  ✗ missing fields detected:"
    echo "$missing_fields" | sed 's/^/      /'
    fail=$((fail + 1))
fi

# ─── breaker ───────────────────────────────────────────────────────────────

echo "=== 7. iteration cap (iter=6 hits slot_iteration_cap=6) → breaker trips ==="
out="$("$PY" "$ORCH" decide --bare \
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
echo "$reconciliation_payload" | "$PY" "$ORCH" reconcile \
    --slot-id PHASE3.1 --decisions-log "$LOG" \
    --reconciliations-log "$REC_LOG" 2>/dev/null

# Verify reconciliation file contents
# Expected count = every decide invocation in this script that targeted
# slot PHASE3.1. Recompute from the log instead of hardcoding — that way
# adding more upstream cases later doesn't silently desync this assert.
expected="$(python3 -c "
import json
n = 0
with open('$LOG') as f:
    for line in f:
        line = line.strip()
        if line and json.loads(line).get('slot_id') == 'PHASE3.1':
            n += 1
print(n)
")"
count="$(python3 -c "import json; print(len(json.loads(open('$REC_LOG').read().strip())['router_decisions']))")"
if [ "$count" = "$expected" ]; then
    echo "  ✓ reconciliation joined $count decisions (matches log)"
    pass=$((pass + 1))
else
    echo "  ✗ reconciliation joined $count decisions (log has $expected for slot)"
    fail=$((fail + 1))
fi

# ─── negative cases ────────────────────────────────────────────────────────

echo "=== 9. reconcile on unknown slot → exit 2 ==="
set +e
echo '{}' | "$PY" "$ORCH" reconcile --slot-id NOSUCH \
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
"$PY" "$ORCH" decide --bare \
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

echo "=== 11. every pe_orchestrator subcommand is reachable through \`pe\` ==="
# `reset` shipped in pe_orchestrator's argparse in P2.11 and the pe dispatcher
# routed only decide|reconcile, so it was unreachable through the CLI for
# eleven releases — a subcommand nobody could run. Derive the check from the
# argparse definition rather than from a list kept here.
PE_BIN="$(cd "$(dirname "$ORCH")/.." && pwd)/scripts/pe"
subs=$("$PY" - "$ORCH" <<'PYEOF'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
names = set()
for node in ast.walk(tree):
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "add_parser" and node.args
            and isinstance(node.args[0], ast.Constant)):
        names.add(node.args[0].value)
print(" ".join(sorted(names)))
PYEOF
)
# The dispatcher lives in a sourced command file, not in `pe` itself.
OPS="$(dirname "$PE_BIN")/_cmd_ops.sh"
unreachable=""
for sub in $subs; do
    grep -qE "^[[:space:]]*([a-z]+\|)*$sub(\|[a-z]+)*\)" "$OPS" \
        || unreachable="$unreachable $sub"
done
if [ -z "$unreachable" ]; then
    echo "  ✓ all subcommands ($subs) are routed by cmd_shadow"
    pass=$((pass + 1))
else
    echo "  ✗ pe_orchestrator defines subcommand(s) \`pe shadow\` cannot reach:$unreachable"
    fail=$((fail + 1))
fi

# ─── summary ───────────────────────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────"
echo "Phase 3 orchestrator tests: $pass passed, $fail failed"
echo "──────────────────────────────────────"
exit "$fail"
