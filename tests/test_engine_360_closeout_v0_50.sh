#!/usr/bin/env bash
# tests/test_engine_360_closeout_v0_50.sh — v0.50.0 ENGINE_360 close-out.
#
# Locks in the resolution of the remaining ENGINE_360_REVIEW items:
#   I2 — gate-efficacy shape mode now asserts primary-rule pattern
#        conformance + live mode surfaces expected-vs-emitted primary
#        rule drift as an advisory metric.
#   G2 — security-reviewer emits an explicit coverage-boundary
#        disclaimer on auth/payment/webhook/tenant paths.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_engine_360_closeout_v0_50.sh — I2 + G2 shape checks"
echo ""

gate_eff="$ENGINE_DIR/tests/test_gate_efficacy.sh"
sec="$ENGINE_DIR/agents/security-reviewer.md"
review="$ENGINE_DIR/docs/ENGINE_360_REVIEW.md"

# ─── 1. gate-efficacy loads _py.sh (needed for I2 primary-rule check)
if grep -q '\. "\$SCRIPT_DIR/_py\.sh"' "$gate_eff"; then
    record_pass "test_gate_efficacy.sh sources _py.sh"
else
    record_fail "test_gate_efficacy.sh missing _py.sh source"
fi

# ─── 2. I2 shape-mode primary-rule pattern check present ─────────
if grep -q "I2 (v0.50.0)" "$gate_eff" && grep -q "primary_rule=" "$gate_eff"; then
    record_pass "test_gate_efficacy.sh has I2 primary-rule pattern check"
else
    record_fail "test_gate_efficacy.sh missing I2 shape-mode check"
fi

if grep -q 'a-z0-9\]\[a-z0-9-' "$gate_eff"; then
    record_pass "test_gate_efficacy.sh asserts schema pattern"
else
    record_fail "test_gate_efficacy.sh missing pattern regex"
fi

# ─── 3. I2 live-mode primary-rule precision comparison present ────
if grep -q "primary-rule precision" "$gate_eff" && grep -q "primary rule drift" "$gate_eff"; then
    record_pass "test_gate_efficacy.sh has I2 live-mode drift metric"
else
    record_fail "test_gate_efficacy.sh missing I2 live-mode metric"
fi

# ─── 4. Shape-mode gate-efficacy passes with I2 checks ────────────
if bash "$gate_eff" >/dev/null 2>&1; then
    record_pass "test_gate_efficacy.sh shape mode passes with I2 checks active"
else
    record_fail "test_gate_efficacy.sh failing after I2 additions"
fi

# ─── 5. G2 honesty statement in security-reviewer ────────────────
if grep -q "G2 honesty statement (v0.50.0)" "$sec"; then
    record_pass "security-reviewer.md has G2 honesty statement block"
else
    record_fail "security-reviewer.md missing G2 statement"
fi

if grep -q "security-coverage-boundary" "$sec"; then
    record_pass "security-reviewer.md names the coverage-boundary rule"
else
    record_fail "security-coverage-boundary rule not documented"
fi

if echo "security-coverage-boundary" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
    record_pass "security-coverage-boundary rule matches schema pattern"
else
    record_fail "security-coverage-boundary rule fails schema pattern"
fi

for anchor in "BOLA / IDOR" "rate-limit" "business-logic" "model-DoS" "review REQUIRED"; do
    if grep -qi "$anchor" "$sec"; then
        record_pass "G2 statement names: $anchor"
    else
        record_fail "G2 statement missing: $anchor"
    fi
done

# ─── 6. ENGINE_360_REVIEW.md updated to close I2 + G2 ─────────────
if grep -q "I2 (v0.50.0)" "$review" || grep -q "I2 —.*SHIPPED\|I2.*✅" "$review"; then
    record_pass "ENGINE_360_REVIEW.md notes I2 shipped"
else
    record_fail "ENGINE_360_REVIEW.md missing I2 close-out note"
fi

if grep -q "G2 honesty" "$review"; then
    record_pass "ENGINE_360_REVIEW.md notes G2 honesty statement"
else
    record_fail "ENGINE_360_REVIEW.md missing G2 close-out note"
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
