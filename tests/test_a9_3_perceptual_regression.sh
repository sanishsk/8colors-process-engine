#!/usr/bin/env bash
# tests/test_a9_3_perceptual_regression.sh — A9.3 wiring shape checks
# (v0.46.0).
#
# Verifies:
#   1. design-critic.md advertises A9.3 in description + body section
#   2. All 4 finding rules named + all match the schema pattern
#   3. Threshold ladder documented (0.95 / 0.90 defaults)
#   4. templates/mcp/README.md is up-to-date on the wired state
#   5. process-engine.yaml.template documents the threshold knobs
#   6. New fixture landed + parses to a worker_quality escalation
#   7. Fixture carries the a9-3-perceptual-regression rule

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_a9_3_perceptual_regression.sh — A9.3 wiring shape checks"
echo ""

critic="$ENGINE_DIR/agents/design-critic.md"

# ─── 1. design-critic advertises A9.3 ─────────────────────────
if grep -q "A9.3, v0.46.0" "$critic"; then
    record_pass "design-critic description advertises A9.3 v0.46.0"
else
    record_fail "design-critic description missing A9.3 mention"
fi

if grep -q "^### A9.3 workflow" "$critic"; then
    record_pass "design-critic body has A9.3 workflow section"
else
    record_fail "design-critic missing A9.3 workflow section"
fi

# ─── 2. Four finding rules named + pattern-conformant ─────────
for rule in a9-3-perceptual-pass a9-3-perceptual-drift a9-3-perceptual-regression a9-3-perceptual-check-skipped; do
    if grep -q "$rule" "$critic"; then
        record_pass "design-critic names rule: $rule"
    else
        record_fail "design-critic missing rule: $rule"
    fi
    if echo "$rule" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
        record_pass "rule $rule matches schema pattern ^[a-z0-9][a-z0-9-]*$"
    else
        record_fail "rule $rule does NOT match schema pattern"
    fi
done

# ─── 3. Threshold ladder documented ────────────────────────────
if grep -q "0.95" "$critic" && grep -q "0.90" "$critic"; then
    record_pass "design-critic body names the 0.95 PASS + 0.90 FAIL thresholds"
else
    record_fail "threshold ladder incomplete"
fi

if grep -q "run_visual_regression" "$critic"; then
    record_pass "design-critic cites run_visual_regression tool"
else
    record_fail "design-critic doesn't cite the MCP tool"
fi

if grep -q "mcp__ai-testing-agent" "$critic"; then
    record_pass "design-critic uses the mcp__ai-testing-agent__ prefix"
else
    record_fail "design-critic doesn't use MCP tool prefix"
fi

# ─── 4. MCP README updated ─────────────────────────────────────
mcp_readme="$ENGINE_DIR/templates/mcp/README.md"
if grep -q "shipped v0.46.0" "$mcp_readme"; then
    record_pass "templates/mcp/README.md updated to note v0.46.0 wiring"
else
    record_fail "MCP README still says A9.3 is engine-side pending"
fi

if grep -q "design_critic.perceptual_similarity_threshold" "$mcp_readme"; then
    record_pass "MCP README names the perceptual_similarity_threshold knob"
else
    record_fail "MCP README missing threshold knob mention"
fi

# ─── 5. process-engine.yaml.template documents knobs ──────────
pe_yaml="$ENGINE_DIR/templates/process-engine.yaml.template"
if grep -q "design_critic:" "$pe_yaml"; then
    record_pass "process-engine.yaml.template has design_critic block"
else
    record_fail "process-engine.yaml.template missing design_critic block"
fi

for knob in perceptual_similarity_threshold perceptual_regression_threshold; do
    if grep -q "$knob" "$pe_yaml"; then
        record_pass "process-engine.yaml.template documents: $knob"
    else
        record_fail "process-engine.yaml.template missing: $knob"
    fi
done

# ─── 6. New fixture landed + validates ────────────────────────
fixdir="$ENGINE_DIR/evals/fixtures/design-critic/fail-escalate-perceptual-regression"
if [ -d "$fixdir" ] && [ -f "$fixdir/input.md" ] && [ -f "$fixdir/expected-envelope.json" ]; then
    record_pass "fixture fail-escalate-perceptual-regression landed"
else
    record_fail "A9.3 fixture missing"
fi

# ─── 7. Fixture envelope parses to escalate exit 1 ───────────
rc=$(python3 "$ENGINE_DIR/scripts/pe_gate.py" --bare "$fixdir/expected-envelope.json" > /dev/null 2>&1; echo $?)
if [ "$rc" = "1" ]; then
    record_pass "fixture parses to worker_quality escalation exit 1"
else
    record_fail "fixture wrong exit: $rc (expected 1)"
fi

# ─── 8. Fixture carries the a9-3-perceptual-regression rule ──
if grep -q '"rule": "a9-3-perceptual-regression"' "$fixdir/expected-envelope.json"; then
    record_pass "fixture findings[] carries a9-3-perceptual-regression"
else
    record_fail "fixture missing a9-3-perceptual-regression"
fi

# ─── 9a. v0.46.0 reviewer CRITICAL: no dotted rule names anywhere ─
# The schema's rule pattern is ^[a-z0-9][a-z0-9-]*$ — dots and
# underscores fail validation. Sweep agents/, templates/, evals/, and
# docs/design/ for any dotted rule reference. This prevents the
# dotted names from silently returning (they can look identical to
# dashed names in prose without triggering the schema at compile
# time — only at gate-parse time).
dotted_hits=$(grep -rn 'd1\.ai\|d1\.reference_drift\|d1\.dimension\|a9\.3\.\b' \
    "$ENGINE_DIR/agents" \
    "$ENGINE_DIR/templates" \
    "$ENGINE_DIR/evals" \
    "$ENGINE_DIR/docs/design" \
    2>/dev/null | wc -l | tr -d ' ')
if [ "$dotted_hits" = "0" ]; then
    record_pass "no dotted rule names remain in agents/templates/evals/docs (schema-conformant)"
else
    record_fail "$dotted_hits dotted-rule references still present — schema pattern breach"
fi

# ─── 9b. Fixture references docs/design/reference/home.png ──
if grep -q "docs/design/reference/home.png" "$fixdir/expected-envelope.json"; then
    record_pass "fixture cites the reference PNG in the finding message"
else
    record_fail "fixture missing reference-PNG citation"
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
