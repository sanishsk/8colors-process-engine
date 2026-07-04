#!/usr/bin/env bash
# tests/test_d6_motion_craft.sh — D6 wiring shape checks.
#
# The motion-lint gate itself is covered by test_motion_lint.sh (16
# cases). This file asserts the OTHER D6 surfaces:
#   - hook wired into hooks.json PostToolUse + pre-commit template
#   - design-critic agent body advertises the motion-craft rubric
#   - a new eval fixture (fail-escalate-motion-effect-stacking)
#     lands with the expected envelope shape

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
HOOKS_JSON="$ENGINE_DIR/hooks/hooks.json"
PRECOMMIT="$ENGINE_DIR/hooks/.pre-commit-config.yaml.template"
CRITIC="$ENGINE_DIR/agents/design-critic.md"
FIXTURE="$ENGINE_DIR/evals/fixtures/design-critic/fail-escalate-motion-effect-stacking"
PE="$ENGINE_DIR/scripts/pe"
PY="${PE_PYTHON:-python3}"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_d6_motion_craft.sh — D6 wiring shape checks"
echo ""

# ─── 1. hook file exists + is executable ────────────────────────────
if [ -x "$ENGINE_DIR/hooks/motion-lint.sh" ]; then
    record_pass "hooks/motion-lint.sh present + executable"
else
    record_fail "hooks/motion-lint.sh missing or not executable"
fi

# ─── 2. hooks.json wires motion-lint into PostToolUse ───────────────
if grep -q "motion-lint.sh" "$HOOKS_JSON"; then
    record_pass "hooks.json wires motion-lint into PostToolUse"
else
    record_fail "hooks.json missing motion-lint entry"
fi

# ─── 3. .pre-commit-config.yaml.template wires motion-lint ──────────
if grep -qE "^\s*- id:\s*motion-lint\b" "$PRECOMMIT"; then
    record_pass ".pre-commit-config.yaml.template registers motion-lint id"
else
    record_fail "pre-commit template missing motion-lint id"
fi

# ─── 4. bypass hint documented in template ──────────────────────────
if grep -q "PE_SKIP_MOTION_LINT=1" "$PRECOMMIT"; then
    record_pass "pre-commit template documents PE_SKIP_MOTION_LINT bypass"
else
    record_fail "PE_SKIP_MOTION_LINT bypass hint missing from template"
fi

# ─── 5. design-critic advertises D6 motion-craft rubric ─────────────
if grep -q "Motion-craft dimension" "$CRITIC" \
   && grep -q "D6" "$CRITIC" \
   && grep -q "motion-lint.sh" "$CRITIC"; then
    record_pass "design-critic body advertises D6 motion-craft rubric + cites motion-lint"
else
    record_fail "design-critic body missing D6 motion-craft section"
fi

# ─── 6. design-critic rubric names the three motion questions ───────
# Cheap read of the rubric to make sure the three questions land:
# communicates vs decorates, CWV budget, reduced-motion degrades.
if grep -qi "Does the motion communicate" "$CRITIC" \
   && grep -qi "CWV budget preserved" "$CRITIC" \
   && grep -qi "degrade gracefully" "$CRITIC"; then
    record_pass "design-critic names the three motion-craft questions"
else
    record_fail "design-critic missing one of the 3 motion-craft questions"
fi

# ─── 7. design-critic names the four motion-craft finding rules ─────
for rule in \
    motion-decoration-not-communication \
    motion-effect-stacking \
    motion-cwv-regression \
    motion-reduced-path-silent; do
    if grep -q "$rule" "$CRITIC"; then
        record_pass "design-critic body names rule: $rule"
    else
        record_fail "design-critic missing rule: $rule"
    fi
done

# ─── 8. new fixture directory present ───────────────────────────────
if [ -d "$FIXTURE" ] \
   && [ -f "$FIXTURE/input.md" ] \
   && [ -f "$FIXTURE/expected-envelope.json" ]; then
    record_pass "new fixture fail-escalate-motion-effect-stacking landed"
else
    record_fail "motion fixture missing files"
fi

# ─── 9. fixture envelope parses to worker_quality escalate exit ─────
set +e
"$PE" gate parse --bare "$FIXTURE/expected-envelope.json" > /dev/null 2>&1
rc=$?
set -e
if [ "$rc" = "1" ]; then
    record_pass "motion fixture parses to escalate exit 1"
else
    record_fail "motion fixture wrong exit: got $rc, expected 1"
fi

# ─── 10. fixture envelope carries all 4 motion-craft rules ──────────
if "$PY" -c "
import json
e = json.load(open('$FIXTURE/expected-envelope.json'))
rules = {f.get('rule') for f in e.get('findings', [])}
expected = {
    'motion-effect-stacking',
    'motion-reduced-path-silent',
    'motion-cwv-regression',
    'motion-decoration-not-communication',
}
missing = expected - rules
assert not missing, f'missing rules: {missing}'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_pass "motion fixture findings[] carries all 4 motion-craft rules"
else
    record_fail "motion fixture missing one or more motion-craft rules"
fi

# ─── 11. fixture awwwards_score reflects motion-craft caps ──────────
# Motion-craft rubric caps Creativity at 6.0 for decoration and 5.0
# for CWV regression; the fixture should encode Creativity below 6.0.
if "$PY" -c "
import json
e = json.load(open('$FIXTURE/expected-envelope.json'))
s = e['awwwards_score']
assert s['creativity'] < 6.0, f'creativity {s[\"creativity\"]} should be below cap 6.0'
assert s['total'] < 8.0, f'total {s[\"total\"]} should be below client bar 8.0'
tc = s['top_changes']
lifts = [c['dimension'] for c in tc]
assert 'creativity' in lifts, 'top_changes should include a creativity lift'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_pass "motion fixture: Creativity capped + top_changes lifts Creativity"
else
    record_fail "motion fixture awwwards_score does not reflect motion caps"
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
