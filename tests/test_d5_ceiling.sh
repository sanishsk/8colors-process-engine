#!/usr/bin/env bash
# tests/test_d5_ceiling.sh — D5 design-critic ceiling mode shape checks.
#
# Live scoring against real screenshots is D7 territory. What we CAN
# assert in v0.38.0:
#   - The 4 aspirational-reference stubs are present with the required
#     sections in the required order (the critic reads by heading).
#   - The gate-envelope schema admits `awwwards_score` with the four
#     Awwwards dimensions + total + top_changes.
#   - The two new eval fixtures (fail-client-below-bar + pass-internal-
#     quiet-excellence) parse cleanly and match their expected exits.
#   - The design-critic agent body names the D5 ceiling section and
#     the aspirational-reference lookup contract.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
ASP_DIR="$ENGINE_DIR/docs/design/aspirational"
CRITIC="$ENGINE_DIR/agents/design-critic.md"
SCHEMA="$ENGINE_DIR/schemas/gate-envelope.schema.json"
PE="$ENGINE_DIR/scripts/pe"
PY="${PE_PYTHON:-python3}"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_d5_ceiling.sh — D5 ceiling-mode shape checks"
echo ""

# ─── 1. aspirational reference dir + README ─────────────────────────
if [ -d "$ASP_DIR" ] && [ -f "$ASP_DIR/README.md" ]; then
    record_pass "docs/design/aspirational/ exists with README.md index"
else
    record_fail "aspirational dir or README missing"
    exit 1
fi

# ─── 2. all four canonical archetypes present ───────────────────────
for archetype in marketing-site client-gallery internal-dashboard form-flow; do
    if [ -f "$ASP_DIR/$archetype.md" ]; then
        record_pass "archetype present: $archetype.md"
    else
        record_fail "archetype missing: $archetype.md"
    fi
done

# ─── 3. archetype files carry the six required sections ─────────────
REQUIRED_SECTIONS=(
    "## Surface class"
    "## Pass bar"
    "## Real-world exemplars"
    "## What earns 9.0"
    "## What earns 6.0"
    "## Signature signals unique to this archetype"
)

for archetype in marketing-site client-gallery internal-dashboard form-flow; do
    file="$ASP_DIR/$archetype.md"
    [ -f "$file" ] || continue
    missing=""
    for section in "${REQUIRED_SECTIONS[@]}"; do
        if ! grep -qF "$section" "$file"; then
            missing="$missing '$section'"
        fi
    done
    if [ -z "$missing" ]; then
        record_pass "$archetype has all 6 required section headings"
    else
        record_fail "$archetype missing sections:$missing"
    fi
done

# ─── 4. schema admits awwwards_score ────────────────────────────────
if "$PY" -c "
import json
s = json.load(open('$SCHEMA'))
score = s.get('properties', {}).get('awwwards_score', {})
assert score.get('type') == 'object', 'awwwards_score not an object'
required = set(score.get('required', []))
expected = {'surface_class', 'design', 'usability', 'creativity', 'content', 'total'}
assert expected.issubset(required), f'missing required: {expected - required}'
enum = set(score.get('properties', {}).get('surface_class', {}).get('enum', []))
assert enum == {'client_facing', 'internal'}, f'wrong surface enum: {enum}'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_pass "schema: awwwards_score present with required fields + surface enum"
else
    record_fail "schema: awwwards_score shape wrong"
fi

# ─── 5. schema has top_changes with dimension enum + max 3 ──────────
if "$PY" -c "
import json
s = json.load(open('$SCHEMA'))
tc = s['properties']['awwwards_score']['properties']['top_changes']
assert tc['type'] == 'array' and tc.get('maxItems') == 3, 'top_changes not maxItems=3 array'
items = tc['items']
dim_enum = set(items['properties']['dimension']['enum'])
assert dim_enum == {'design', 'usability', 'creativity', 'content'}, f'dimensions: {dim_enum}'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_pass "schema: top_changes is array (maxItems 3) with 4-dimension enum"
else
    record_fail "schema: top_changes shape wrong"
fi

# ─── 6. design-critic agent body advertises D5 ceiling mode ─────────
if grep -q "D5 ceiling mode" "$CRITIC" \
   && grep -q "Awwwards scoring" "$CRITIC" \
   && grep -q "docs/design/aspirational" "$CRITIC"; then
    record_pass "design-critic advertises D5 ceiling mode + aspirational-reference lookup"
else
    record_fail "design-critic body missing D5 section"
fi

# ─── 7. agent body names all four archetype file paths ──────────────
if grep -q "marketing-site.md" "$CRITIC" \
   && grep -q "client-gallery.md" "$CRITIC" \
   && grep -q "internal-dashboard.md" "$CRITIC" \
   && grep -q "form-flow.md" "$CRITIC"; then
    record_pass "design-critic body enumerates all 4 archetype files"
else
    record_fail "design-critic body missing one or more archetype file references"
fi

# ─── 8. new client-below-bar fixture parses + FAIL exit ─────────────
FAIL_FIXTURE="$ENGINE_DIR/evals/fixtures/design-critic/fail-escalate-client-below-bar"
if [ -d "$FAIL_FIXTURE" ]; then
    set +e
    "$PE" gate parse --bare "$FAIL_FIXTURE/expected-envelope.json" > /dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" = "1" ]; then
        record_pass "fail-escalate-client-below-bar fixture parses to escalate exit"
    else
        record_fail "client-below-bar fixture exit $rc, expected 1"
    fi
else
    record_fail "client-below-bar fixture dir missing"
fi

# ─── 9. new pass-internal fixture parses + PASS exit ────────────────
PASS_FIXTURE="$ENGINE_DIR/evals/fixtures/design-critic/pass-internal-quiet-excellence"
if [ -d "$PASS_FIXTURE" ]; then
    set +e
    "$PE" gate parse --bare "$PASS_FIXTURE/expected-envelope.json" > /dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" = "0" ]; then
        record_pass "pass-internal-quiet-excellence fixture parses to PASS exit"
    else
        record_fail "pass-internal fixture exit $rc, expected 0"
    fi
else
    record_fail "pass-internal fixture dir missing"
fi

# ─── 10. fail fixture envelope carries awwwards_score < 8.0 total ───
if "$PY" -c "
import json
e = json.load(open('$FAIL_FIXTURE/expected-envelope.json'))
s = e.get('awwwards_score', {})
assert s.get('surface_class') == 'client_facing', 'wrong class'
assert s.get('total', 0) < 8.0, f'total {s.get(\"total\")} should be < 8.0 for FAIL'
tc = s.get('top_changes', [])
assert 1 <= len(tc) <= 3, f'top_changes count wrong: {len(tc)}'
for c in tc:
    assert c['dimension'] in {'design','usability','creativity','content'}, c
    assert 0 <= c['current'] <= 10 and 0 <= c['expected'] <= 10, c
print('OK')
" 2>&1 | grep -q "OK"; then
    record_pass "fail fixture: client_facing + total < 8.0 + valid top_changes"
else
    record_fail "fail fixture awwwards_score invariants broken"
fi

# ─── 11. pass fixture envelope: internal + total >= 7.0 + top_changes present (pull-up rule) ─
if "$PY" -c "
import json
e = json.load(open('$PASS_FIXTURE/expected-envelope.json'))
s = e.get('awwwards_score', {})
assert s.get('surface_class') == 'internal', 'wrong class'
assert s.get('total', 0) >= 7.0, f'total {s.get(\"total\")} should be >= 7.0 for PASS'
tc = s.get('top_changes', [])
assert len(tc) >= 1, 'pull-up rule: PASS must still emit top_changes'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_pass "pass fixture: internal + total >= 7.0 + top_changes present (pull-up rule)"
else
    record_fail "pass fixture awwwards_score invariants broken"
fi

# ─── 12a. pe_gate.py rejects inconsistent-arithmetic envelope ───────
BAD_ARITH=$(mktemp --suffix=.json 2>/dev/null || mktemp)
cat > "$BAD_ARITH" <<'EOF'
{
  "schema_version": "1.0.0",
  "gate_name": "design-critic",
  "verdict": "PASS",
  "failure_class": "none",
  "model_used": "test-model",
  "timestamp": "2026-07-04T13:00:00Z",
  "findings": [],
  "awwwards_score": {
    "surface_class": "internal",
    "design": 10.0,
    "usability": 10.0,
    "creativity": 10.0,
    "content": 10.0,
    "total": 6.5
  }
}
EOF
set +e
"$PE" gate parse --bare "$BAD_ARITH" > /dev/null 2>&1
rc=$?
set -e
if [ "$rc" = "4" ]; then
    record_pass "pe gate parse: rejects inconsistent-arithmetic envelope (reviewer HIGH)"
else
    record_fail "arithmetic check missing: bad envelope got exit $rc, expected 4"
fi
rm -f "$BAD_ARITH"

# ─── 12b. pe_gate.py rejects below-bar PASS envelope ────────────────
BAD_BAR=$(mktemp --suffix=.json 2>/dev/null || mktemp)
cat > "$BAD_BAR" <<'EOF'
{
  "schema_version": "1.0.0",
  "gate_name": "design-critic",
  "verdict": "PASS",
  "failure_class": "none",
  "model_used": "test-model",
  "timestamp": "2026-07-04T13:00:00Z",
  "findings": [],
  "awwwards_score": {
    "surface_class": "client_facing",
    "design": 7.0,
    "usability": 8.0,
    "creativity": 7.0,
    "content": 7.0,
    "total": 7.3
  }
}
EOF
set +e
"$PE" gate parse --bare "$BAD_BAR" > /dev/null 2>&1
rc=$?
set -e
if [ "$rc" = "4" ]; then
    record_pass "pe gate parse: rejects PASS with client_facing total < 8.0 (reviewer HIGH)"
else
    record_fail "pass-bar check missing: below-bar PASS got exit $rc, expected 4"
fi
rm -f "$BAD_BAR"

# ─── 12c. absence of awwwards_score is legal (floor-only mode) ──────
FLOOR_ONLY=$(mktemp --suffix=.json 2>/dev/null || mktemp)
cat > "$FLOOR_ONLY" <<'EOF'
{
  "schema_version": "1.0.0",
  "gate_name": "design-critic",
  "verdict": "PASS",
  "failure_class": "none",
  "model_used": "test-model",
  "timestamp": "2026-07-04T13:00:00Z",
  "findings": []
}
EOF
set +e
"$PE" gate parse --bare "$FLOOR_ONLY" > /dev/null 2>&1
rc=$?
set -e
if [ "$rc" = "0" ]; then
    record_pass "pe gate parse: absent awwwards_score is legal (floor-only mode)"
else
    record_fail "absent awwwards_score should be legal: got exit $rc"
fi
rm -f "$FLOOR_ONLY"

# ─── 12. surface_class enum matches the two archetypes' classes ─────
# marketing-site + client-gallery + form-flow must declare client_facing.
# internal-dashboard must declare internal.
if grep -q "client_facing" "$ASP_DIR/marketing-site.md" \
   && grep -q "client_facing" "$ASP_DIR/client-gallery.md" \
   && grep -q "client_facing" "$ASP_DIR/form-flow.md" \
   && grep -q "\`internal\`" "$ASP_DIR/internal-dashboard.md"; then
    record_pass "archetype files declare surface_class matching the schema enum"
else
    record_fail "archetype surface_class declarations wrong"
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
