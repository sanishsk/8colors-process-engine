#!/usr/bin/env bash
# tests/test_a9_5_owasp_payloads.sh — A9.5 OWASP payload catalogue
# wiring shape checks (v0.48.0).
#
# Verifies:
#   1. templates/security/owasp-payloads.py.template landed
#   2. All 13 payload list constants defined
#   3. Python parses the template file (syntactic validity)
#   4. security README documents categories + adopter usage + SAST split
#   5. auth-robustness template names A9.5 parametrization pattern
#   6. security-reviewer advertises A9.5 + rule name
#   7. Rule name pattern-conforms to schema ^[a-z0-9][a-z0-9-]*$
#   8. MCP README A9.5 blockquote landed

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_a9_5_owasp_payloads.sh — A9.5 wiring shape checks"
echo ""

catalogue="$ENGINE_DIR/templates/security/owasp-payloads.py.template"
security_readme="$ENGINE_DIR/templates/security/README.md"
auth_template="$ENGINE_DIR/templates/tests/auth-robustness.test.py.template"
sec_reviewer="$ENGINE_DIR/agents/security-reviewer.md"
mcp_readme="$ENGINE_DIR/templates/mcp/README.md"

# ─── 1. Catalogue file landed ─────────────────────────────────────
if [ -f "$catalogue" ]; then
    record_pass "templates/security/owasp-payloads.py.template landed"
else
    record_fail "OWASP payload catalogue missing"
fi

# ─── 2. All 13 payload list constants defined ─────────────────────
for const in BOLA_PAYLOADS BROKEN_AUTH_PAYLOADS MASS_ASSIGNMENT_PAYLOADS \
             RESOURCE_EXHAUSTION_PAYLOADS BFLA_METHOD_PAYLOADS \
             MISCONFIG_HEADER_PAYLOADS INJECTION_SQL_PAYLOADS \
             INJECTION_NOSQL_PAYLOADS INJECTION_LDAP_PAYLOADS \
             INJECTION_XSS_PAYLOADS INJECTION_CMD_PAYLOADS \
             XXE_PAYLOADS SSRF_PAYLOADS PATH_TRAVERSAL_PAYLOADS \
             DESERIALIZATION_PAYLOADS INJECTION_PAYLOADS; do
    if grep -q "^${const} = \|^${const} =$" "$catalogue"; then
        record_pass "catalogue defines: $const"
    else
        record_fail "catalogue missing constant: $const"
    fi
done

# ─── 3. Python parses the template ────────────────────────────────
if python3 -c "
import ast
src = open('$catalogue').read()
ast.parse(src)
" 2>/dev/null; then
    record_pass "owasp-payloads.py.template parses as valid Python"
else
    record_fail "template has Python syntax errors"
fi

# ─── 4. Security README documents A9.5 ────────────────────────────
if grep -q "A9.5" "$security_readme"; then
    record_pass "templates/security/README.md documents A9.5 section"
else
    record_fail "security README missing A9.5"
fi

for anchor in "OWASP API Top 10" "parametrize" "4xx not 5xx" "Split with hooks/sast-scan"; do
    if grep -qi "$anchor" "$security_readme"; then
        record_pass "security README anchor: $anchor"
    else
        record_fail "security README missing anchor: $anchor"
    fi
done

# ─── 5. auth-robustness template names A9.5 pattern ───────────────
if grep -q "A9.5 (v0.48.0)" "$auth_template"; then
    record_pass "auth-robustness template has A9.5 v0.48.0 section"
else
    record_fail "auth-robustness template missing A9.5 section"
fi

for const in BROKEN_AUTH_PAYLOADS INJECTION_SQL_PAYLOADS INJECTION_XSS_PAYLOADS; do
    if grep -q "$const" "$auth_template"; then
        record_pass "auth-robustness template names: $const"
    else
        record_fail "auth-robustness template missing: $const"
    fi
done

# ─── 6. security-reviewer advertises A9.5 ─────────────────────────
if grep -q "A9.5 (v0.48.0)" "$sec_reviewer"; then
    record_pass "security-reviewer body advertises A9.5 v0.48.0"
else
    record_fail "security-reviewer missing A9.5 body mention"
fi

if grep -q "a9-5-owasp-payload-coverage-missing" "$sec_reviewer"; then
    record_pass "security-reviewer names a9-5-owasp-payload-coverage-missing rule"
else
    record_fail "security-reviewer missing the A9.5 finding rule"
fi

# ─── 7. Rule name pattern-conforms to schema ──────────────────────
rule="a9-5-owasp-payload-coverage-missing"
if echo "$rule" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
    record_pass "rule $rule matches schema pattern ^[a-z0-9][a-z0-9-]*$"
else
    record_fail "rule $rule does NOT match schema pattern"
fi

# ─── 8. MCP README A9.5 blockquote landed ────────────────────────
if grep -q "A9.5 (v0.48.0)" "$mcp_readme"; then
    record_pass "templates/mcp/README.md has A9.5 v0.48.0 blockquote"
else
    record_fail "MCP README missing A9.5 blockquote"
fi

# ─── 9. No dotted A9.5 rule names anywhere ───────────────────────
dotted_hits=$(grep -rn 'a9\.5\.\b' \
    "$ENGINE_DIR/agents" \
    "$ENGINE_DIR/templates" \
    "$ENGINE_DIR/evals" \
    "$ENGINE_DIR/docs/design" \
    2>/dev/null | wc -l | tr -d ' ')
if [ "$dotted_hits" = "0" ]; then
    record_pass "no dotted A9.5 rule names — schema-conformant"
else
    record_fail "$dotted_hits dotted A9.5 rule references — schema pattern breach"
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
