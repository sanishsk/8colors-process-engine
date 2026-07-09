#!/usr/bin/env bash
# tests/test_a9_4_resilience_wiring.sh — A9.4 wiring shape checks
# (v0.47.0).
#
# Verifies:
#   1. performance-reviewer.md advertises A9.4 in description + workflow section
#   2. Six A9.4 finding rules named + all pattern-conformant
#   3. Four-band threshold ladder documented + PF1-hook language
#   4. Tool cite with mcp__ai-testing-agent__ prefix
#   5. templates/mcp/README.md updated to note v0.47.0 wiring
#   6. process-engine.yaml.template documents the five threshold knobs
#   7. Fixture landed, validates as worker_quality escalation
#   8. Fixture carries a9-4-n-plus-one-under-load + latency-regression rules
#   9. No dotted A9.4 rule names anywhere (regression from v0.46.0 sweep)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_a9_4_resilience_wiring.sh — A9.4 wiring shape checks"
echo ""

perf="$ENGINE_DIR/agents/performance-reviewer.md"

# ─── 1. performance-reviewer advertises A9.4 ─────────────────────
if grep -q "A9.4 (v0.47.0)" "$perf"; then
    record_pass "performance-reviewer description advertises A9.4 v0.47.0"
else
    record_fail "performance-reviewer description missing A9.4 mention"
fi

if grep -q "^## A9.4 workflow" "$perf"; then
    record_pass "performance-reviewer body has A9.4 workflow section"
else
    record_fail "performance-reviewer missing A9.4 workflow section"
fi

# ─── 2. Six A9.4 finding rules named + pattern-conformant ────────
for rule in a9-4-n-plus-one-under-load a9-4-query-scale-under-load a9-4-latency-regression-under-load a9-4-error-rate-under-load a9-4-resilience-pass a9-4-resilience-check-skipped; do
    if grep -q "$rule" "$perf"; then
        record_pass "performance-reviewer names rule: $rule"
    else
        record_fail "performance-reviewer missing rule: $rule"
    fi
    if echo "$rule" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
        record_pass "rule $rule matches schema pattern ^[a-z0-9][a-z0-9-]*$"
    else
        record_fail "rule $rule does NOT match schema pattern"
    fi
done

# ─── 3. Threshold ladder documented ────────────────────────────
if grep -q "1.2" "$perf" && grep -q "500" "$perf" && grep -q "0.01" "$perf"; then
    record_pass "performance-reviewer body names the 1.2 / 500ms / 0.01 thresholds"
else
    record_fail "threshold ladder incomplete"
fi

if grep -q "measure_queries" "$perf"; then
    record_pass "performance-reviewer body names measure_queries flag (PF1-hook signal)"
else
    record_fail "measure_queries flag not documented"
fi

# ─── 4. Tool cite with MCP prefix ──────────────────────────────
if grep -q "run_resilience_tests" "$perf"; then
    record_pass "performance-reviewer cites run_resilience_tests tool"
else
    record_fail "performance-reviewer doesn't cite the MCP tool"
fi

if grep -q "mcp__ai-testing-agent" "$perf"; then
    record_pass "performance-reviewer uses the mcp__ai-testing-agent__ prefix"
else
    record_fail "performance-reviewer doesn't use MCP tool prefix"
fi

# ─── 5. MCP README updated ─────────────────────────────────────
mcp_readme="$ENGINE_DIR/templates/mcp/README.md"
if grep -q "A9.4 (v0.47.0)" "$mcp_readme"; then
    record_pass "templates/mcp/README.md updated to note v0.47.0 A9.4 wiring"
else
    record_fail "MCP README still says A9.4 pending"
fi

if grep -q "PF1 query-count hook on chaos runner" "$mcp_readme"; then
    record_pass "MCP README names the PF1-hook-on-chaos-runner mechanism"
else
    record_fail "MCP README missing PF1-hook language"
fi

# ─── 6. process-engine.yaml.template knobs ─────────────────────
pe_yaml="$ENGINE_DIR/templates/process-engine.yaml.template"
if grep -q "^performance_reviewer:" "$pe_yaml"; then
    record_pass "process-engine.yaml.template has performance_reviewer block"
else
    record_fail "process-engine.yaml.template missing performance_reviewer block"
fi

for knob in resilience_concurrent_users resilience_duration_seconds resilience_query_scale_factor_threshold resilience_p95_ms_threshold resilience_error_rate_threshold; do
    if grep -q "$knob" "$pe_yaml"; then
        record_pass "process-engine.yaml.template documents: $knob"
    else
        record_fail "process-engine.yaml.template missing: $knob"
    fi
done

# ─── 7. Fixture landed + validates ─────────────────────────────
fixdir="$ENGINE_DIR/evals/fixtures/performance-reviewer/fail-escalate-query-scale-under-load"
if [ -d "$fixdir" ] && [ -f "$fixdir/input.md" ] && [ -f "$fixdir/expected-envelope.json" ]; then
    record_pass "fixture fail-escalate-query-scale-under-load landed"
else
    record_fail "A9.4 fixture missing"
fi

rc=$(python3 "$ENGINE_DIR/scripts/pe_gate.py" --bare "$fixdir/expected-envelope.json" > /dev/null 2>&1; echo $?)
if [ "$rc" = "1" ]; then
    record_pass "fixture parses to worker_quality escalation exit 1"
else
    record_fail "fixture wrong exit: $rc (expected 1)"
fi

# ─── 8. Fixture carries load-tier rules ────────────────────────
if grep -q '"rule": "a9-4-n-plus-one-under-load"' "$fixdir/expected-envelope.json"; then
    record_pass "fixture findings[] carries a9-4-n-plus-one-under-load"
else
    record_fail "fixture missing a9-4-n-plus-one-under-load"
fi

if grep -q '"rule": "a9-4-latency-regression-under-load"' "$fixdir/expected-envelope.json"; then
    record_pass "fixture findings[] carries a9-4-latency-regression-under-load"
else
    record_fail "fixture missing a9-4-latency-regression-under-load"
fi

# ─── 9. No dotted A9.4 rule names anywhere ─────────────────────
dotted_hits=$(grep -rn 'a9\.4\.\b' \
    "$ENGINE_DIR/agents" \
    "$ENGINE_DIR/templates" \
    "$ENGINE_DIR/evals" \
    "$ENGINE_DIR/docs/design" \
    2>/dev/null | wc -l | tr -d ' ')
if [ "$dotted_hits" = "0" ]; then
    record_pass "no dotted A9.4 rule names in agents/templates/evals/docs"
else
    record_fail "$dotted_hits dotted A9.4 rule references — schema pattern breach"
fi

# ─── summary ────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  passed: $pass"
echo "  failed: $fail"
if [ $fail -gt 0 ]; then
    for f in "${failures[@]}"; do echo "    - $f"; done
    exit 1
fi
exit 0
