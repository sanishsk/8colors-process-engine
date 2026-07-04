#!/usr/bin/env bash
# tests/test_d8_signature_gate.sh — D8 wiring shape checks.
#
# Verifies:
#   1. hooks/signature-lint.sh present + executable + wired
#   2. pre-commit template registers signature-lint id
#   3. bypass documented
#   4. SIGNATURE.md template landed with required sections
#   5. design-critic body advertises D8 + names the finding rules
#   6. install.sh copies templates/design/ into adopter project
#   7. new fixture landed + parses correctly

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_d8_signature_gate.sh — D8 wiring shape checks"
echo ""

# ─── 1. hook is present + executable ────────────────────────────────
if [ -x "$ENGINE_DIR/hooks/signature-lint.sh" ]; then
    record_pass "hooks/signature-lint.sh present + executable"
else
    record_fail "hooks/signature-lint.sh missing or not executable"
fi

# ─── 2. hooks.json wires signature-lint into PostToolUse ────────────
if grep -q '"command": "{{ENGINE_DIR}}/hooks/signature-lint.sh"' "$ENGINE_DIR/hooks/hooks.json"; then
    record_pass "hooks.json wires signature-lint into PostToolUse"
else
    record_fail "hooks.json missing signature-lint PostToolUse entry"
fi

# ─── 3. pre-commit template registers signature-lint id ────────────
if grep -q 'id: signature-lint' "$ENGINE_DIR/hooks/.pre-commit-config.yaml.template"; then
    record_pass ".pre-commit-config.yaml.template registers signature-lint id"
else
    record_fail ".pre-commit-config.yaml.template missing signature-lint id"
fi

# ─── 4. bypass documented ──────────────────────────────────────────
if grep -q 'PE_SKIP_SIGNATURE_LINT=1' "$ENGINE_DIR/hooks/.pre-commit-config.yaml.template"; then
    record_pass "PE_SKIP_SIGNATURE_LINT bypass documented in pre-commit template"
else
    record_fail "PE_SKIP_SIGNATURE_LINT bypass not documented"
fi

# ─── 5. SIGNATURE.md template landed with required sections ────────
sig_tmpl="$ENGINE_DIR/templates/design/SIGNATURE.md.template"
if [ -f "$sig_tmpl" ]; then
    record_pass "templates/design/SIGNATURE.md.template landed"
else
    record_fail "SIGNATURE.md.template missing"
fi

for section in "The product signature" "signature_token:" "flagship_paths" "PE_SKIP_SIGNATURE_LINT"; do
    if grep -q "$section" "$sig_tmpl"; then
        record_pass "SIGNATURE.md.template documents: $section"
    else
        record_fail "SIGNATURE.md.template missing section: $section"
    fi
done

# ─── 6. design-critic body advertises D8 ──────────────────────────
critic="$ENGINE_DIR/agents/design-critic.md"
if grep -q "D8 signature-system rule (v0.41.0)" "$critic"; then
    record_pass "design-critic body has D8 signature-system rule section"
else
    record_fail "design-critic missing D8 rule section"
fi

if grep -q "D8, v0.41.0 signature-system HARD FAIL on flagship" "$critic"; then
    record_pass "design-critic description advertises D8"
else
    record_fail "design-critic description missing D8 mention"
fi

# ─── 7. design-critic names the D8 finding rules ──────────────────
for rule in "d8.signature_phantom" "d8.signature_absent_flagship" "d8.signature_system_unknown"; do
    if grep -q "$rule" "$critic"; then
        record_pass "design-critic body names rule: $rule"
    else
        record_fail "design-critic missing rule: $rule"
    fi
done

# ─── 8. tell #9 upgraded to note D8 HARD FAIL ────────────────────
if awk '/^\| 9 \|/' "$critic" | grep -q "D8 upgrade"; then
    record_pass "tell #9 row upgraded to note D8 HARD FAIL on flagship"
else
    record_fail "tell #9 row missing D8 upgrade note"
fi

# ─── 9. install.sh copies templates/design/ into adopter ─────────
if grep -q 'ENGINE_DIR/templates/design"' "$ENGINE_DIR/scripts/install.sh"; then
    record_pass "install.sh copies templates/design/ into adopter project"
else
    record_fail "install.sh missing templates/design/ copy loop"
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
