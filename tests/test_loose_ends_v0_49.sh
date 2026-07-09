#!/usr/bin/env bash
# tests/test_loose_ends_v0_49.sh — v0.49.0 Loose-ends cleanup checks.
#
# The plan's "Loose ends" section listed four small items. This test
# locks in the resolution:
#   1. e2e-runner self-grade prohibition strengthened
#   2. tdd-guide "reviewer"/"author" ambiguity clarified
#   3. `memory:` frontmatter removed from all 11 agents
#   4. database-reviewer gains API-contract + seed-data sections

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_loose_ends_v0_49.sh — Loose-ends cleanup shape checks"
echo ""

# ─── 1. e2e-runner self-grade prohibition hardened ─────────────
e2e="$ENGINE_DIR/agents/e2e-runner.md"
if grep -q "Self-grade prohibition (v0.49.0)" "$e2e"; then
    record_pass "e2e-runner has v0.49.0 self-grade prohibition block"
else
    record_fail "e2e-runner missing v0.49.0 prohibition"
fi

if grep -q "test-execution-flaky\|test-execution-regression" "$e2e"; then
    record_pass "e2e-runner names execution-specific rules (flaky / regression)"
else
    record_fail "e2e-runner missing execution-specific rule names"
fi

# ─── 2. tdd-guide identity clarified ──────────────────────────
tdd="$ENGINE_DIR/agents/tdd-guide.md"
if grep -q "Identity note (v0.49.0)" "$tdd"; then
    record_pass "tdd-guide has v0.49.0 identity note"
else
    record_fail "tdd-guide missing v0.49.0 identity note"
fi

if grep -q "state-machine gate" "$tdd" && grep -q "not a reviewer" "$tdd"; then
    record_pass "tdd-guide explicitly calls itself state-machine gate (not reviewer)"
else
    record_fail "tdd-guide identity language not resolved"
fi

# ─── 3. memory: frontmatter removed from all 11 agents ────────
memory_count=$(grep -c "^memory:" "$ENGINE_DIR"/agents/*.md 2>/dev/null | grep -v ":0" | wc -l | tr -d ' ')
if [ "$memory_count" = "0" ]; then
    record_pass "no agent frontmatter carries the memory: field (11 → 0)"
else
    record_fail "$memory_count agents still carry memory: frontmatter"
fi

# ─── 4. effort: field documented in _gate-contract.md ─────────
gc="$ENGINE_DIR/agents/_gate-contract.md"
if grep -q "Section 0 — Frontmatter fields (v0.49.0" "$gc"; then
    record_pass "_gate-contract.md has Section 0 frontmatter-fields documentation"
else
    record_fail "_gate-contract.md missing Section 0"
fi

if grep -q "Removed in v0.49.0" "$gc" && grep -q "\`memory:\`" "$gc"; then
    record_pass "_gate-contract.md documents memory: field removal"
else
    record_fail "_gate-contract.md missing memory: removal note"
fi

# ─── 5. database-reviewer API-contract section landed ─────────
dbr="$ENGINE_DIR/agents/database-reviewer.md"
if grep -q "^## API contract (v0.49.0" "$dbr"; then
    record_pass "database-reviewer has API contract section"
else
    record_fail "database-reviewer missing API contract section"
fi

for rule in api-contract-required-field-added \
             api-contract-response-field-removed \
             api-contract-type-narrowed \
             api-contract-semantic-drift \
             api-contract-missing-spec-entry \
             api-contract-version-shape-drift; do
    if grep -q "$rule" "$dbr"; then
        record_pass "database-reviewer names rule: $rule"
    else
        record_fail "database-reviewer missing rule: $rule"
    fi
    if echo "$rule" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
        record_pass "rule $rule matches schema pattern"
    else
        record_fail "rule $rule fails schema pattern"
    fi
done

# ─── 6. database-reviewer Seed-data section landed ────────────
if grep -q "^## Seed-data convention (v0.49.0" "$dbr"; then
    record_pass "database-reviewer has Seed-data convention section"
else
    record_fail "database-reviewer missing Seed-data section"
fi

for rule in seed-data-missing-for-new-table \
             seed-data-production-values \
             seed-data-non-idempotent \
             seed-data-single-tenant-only; do
    if grep -q "$rule" "$dbr"; then
        record_pass "database-reviewer names rule: $rule"
    else
        record_fail "database-reviewer missing rule: $rule"
    fi
done

# ─── 7. schemathesis + api-contract-check cite present ────────
if grep -q "schemathesis" "$dbr" && grep -q "hooks/api-contract-check.sh" "$dbr"; then
    record_pass "database-reviewer cites schemathesis + api-contract-check.sh"
else
    record_fail "database-reviewer missing complementary tools cite"
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
