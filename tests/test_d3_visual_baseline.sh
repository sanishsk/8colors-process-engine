#!/usr/bin/env bash
# tests/test_d3_visual_baseline.sh — D3 wiring shape checks (v0.45.0).
#
# Verifies:
#   1. templates/e2e/visual-baseline.spec.ts.template lands with required shape
#   2. docs/design/reference/README.md documents the reference-lock process
#   3. hooks/visual-baseline-guard.sh present + wired
#   4. pre-commit template registers visual-baseline-guard id
#   5. design-critic body advertises D3
#   6. templates/design/reference-README.md.template exists for install-side landing
#   7. install.sh comment mentions D3

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_d3_visual_baseline.sh — D3 wiring shape checks"
echo ""

# ─── 1. Playwright spec template exists with required structure ──
spec="$ENGINE_DIR/templates/e2e/visual-baseline.spec.ts.template"
if [ -f "$spec" ]; then
    record_pass "templates/e2e/visual-baseline.spec.ts.template landed"
else
    record_fail "visual-baseline.spec.ts.template missing"
fi

for anchor in "PAGES_TO_LOCK" "toHaveScreenshot" "maxDiffPixelRatio" "1280" "375"; do
    if grep -q "$anchor" "$spec"; then
        record_pass "spec template names anchor: $anchor"
    else
        record_fail "spec template missing anchor: $anchor"
    fi
done

# ─── 2. Reference README documents the process ──────────────────
readme="$ENGINE_DIR/docs/design/reference/README.md"
if [ -f "$readme" ]; then
    record_pass "docs/design/reference/README.md landed"
else
    record_fail "reference README missing"
fi

for anchor in "reference lock" "Match the locked reference" "update-snapshots" "designer approval" "flagship_pages"; do
    if grep -qi "$anchor" "$readme"; then
        record_pass "reference README documents: $anchor"
    else
        record_fail "reference README missing: $anchor"
    fi
done

# ─── 3. Guard hook present + executable ─────────────────────────
if [ -x "$ENGINE_DIR/hooks/visual-baseline-guard.sh" ]; then
    record_pass "hooks/visual-baseline-guard.sh present + executable"
else
    record_fail "hooks/visual-baseline-guard.sh missing or not executable"
fi

# ─── 4. hooks.json wires guard into PostToolUse ──────────────────
if grep -q '"command": "{{ENGINE_DIR}}/hooks/visual-baseline-guard.sh"' "$ENGINE_DIR/hooks/hooks.json"; then
    record_pass "hooks.json wires visual-baseline-guard into PostToolUse"
else
    record_fail "hooks.json missing visual-baseline-guard PostToolUse entry"
fi

# ─── 5. pre-commit template registers visual-baseline-guard ─────
if grep -q 'id: visual-baseline-guard' "$ENGINE_DIR/hooks/.pre-commit-config.yaml.template"; then
    record_pass ".pre-commit-config.yaml.template registers visual-baseline-guard id"
else
    record_fail ".pre-commit-config.yaml.template missing visual-baseline-guard id"
fi

# ─── 6. bypass documented ──────────────────────────────────────
if grep -q 'PE_SKIP_VISUAL_BASELINE=1' "$ENGINE_DIR/hooks/.pre-commit-config.yaml.template"; then
    record_pass "PE_SKIP_VISUAL_BASELINE bypass documented in pre-commit template"
else
    record_fail "PE_SKIP_VISUAL_BASELINE bypass not documented"
fi

# ─── 7. design-critic advertises D3 ────────────────────────────
critic="$ENGINE_DIR/agents/design-critic.md"
if grep -q "D3, v0.45.0" "$critic"; then
    record_pass "design-critic body has D3 v0.45.0 section"
else
    record_fail "design-critic missing D3 v0.45.0 section"
fi

if grep -q "d1-reference-drift" "$critic"; then
    record_pass "design-critic names the d1-reference-drift finding rule"
else
    record_fail "design-critic missing d1-reference-drift"
fi

if grep -q "hooks/visual-baseline-guard.sh" "$critic"; then
    record_pass "design-critic body cites hooks/visual-baseline-guard.sh"
else
    record_fail "design-critic doesn't cite the visual-baseline-guard"
fi

if grep -q "visual-baseline.spec.ts.template" "$critic"; then
    record_pass "design-critic body cites templates/e2e/visual-baseline.spec.ts.template"
else
    record_fail "design-critic doesn't cite the visual-baseline Playwright template"
fi

# ─── 8. reference-README template lands via install pipeline ────
if [ -f "$ENGINE_DIR/templates/design/reference-README.md.template" ]; then
    record_pass "templates/design/reference-README.md.template landed"
else
    record_fail "templates/design/reference-README.md.template missing"
fi

# ─── 9. install.sh comment mentions D3 ─────────────────────────
if grep -q "D3.*reference-lock\|D3 reference" "$ENGINE_DIR/scripts/install.sh"; then
    record_pass "install.sh comment names D3 reference-lock landing"
else
    record_fail "install.sh comment doesn't mention D3"
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
