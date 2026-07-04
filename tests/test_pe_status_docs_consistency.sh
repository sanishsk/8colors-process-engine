#!/usr/bin/env bash
# tests/test_pe_status_docs_consistency.sh — inventory counts must agree
# across `pe status`, `pe docs check`, and `plugin.json`.
#
# v0.43.0 dogfood regression: `pe status` counted _gate-contract.md as
# an agent (22 agents reported), while `pe docs check` correctly
# excluded it (21 agents) — same rule needed to fire in both.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
PE="$ENGINE_DIR/scripts/pe"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_pe_status_docs_consistency.sh — inventory count agreement"
echo ""

status_agents=$("$PE" status 2>&1 | grep -E "^\s*Agents:" | awk '{print $2}')
status_cmds=$("$PE" status 2>&1 | grep -E "^\s*Commands:" | awk '{print $2}')
docs_agents=$("$PE" docs check 2>&1 | grep -oE '[0-9]+ agents' | head -1 | awk '{print $1}')
docs_cmds=$("$PE" docs check 2>&1 | grep -oE '[0-9]+ commands' | head -1 | awk '{print $1}')
plugin_agents=$(grep -oE '[0-9]+ agents' "$ENGINE_DIR/plugin.json" | head -1 | awk '{print $1}')

if [ "$status_agents" = "$docs_agents" ]; then
    record_pass "pe status agent count matches pe docs check ($status_agents)"
else
    record_fail "pe status ($status_agents) != pe docs check ($docs_agents)"
fi

if [ "$status_cmds" = "$docs_cmds" ]; then
    record_pass "pe status command count matches pe docs check ($status_cmds)"
else
    record_fail "pe status cmds ($status_cmds) != pe docs check ($docs_cmds)"
fi

if [ "$status_agents" = "$plugin_agents" ]; then
    record_pass "pe status agent count matches plugin.json ($plugin_agents)"
else
    record_fail "pe status ($status_agents) != plugin.json ($plugin_agents)"
fi

# Verify that _gate-contract.md exists but is NOT counted as an agent
# (the specific case that surfaced the bug).
if [ -f "$ENGINE_DIR/agents/_gate-contract.md" ]; then
    record_pass "agents/_gate-contract.md exists (spec file)"
    # And it is NOT counted as an agent
    if [ "$status_agents" -lt "$(find "$ENGINE_DIR/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" ]; then
        record_pass "leading-underscore spec files excluded from agent count"
    else
        record_fail "leading-underscore files still counted as agents"
    fi
else
    # If the spec was moved/renamed, skip this specific check but don't
    # fail — the earlier equality checks are what actually matter.
    record_pass "no leading-underscore spec files present (skipping exclusion check)"
fi

echo ""
echo "─────────────────────────────────────"
echo "  passed: $pass"
echo "  failed: $fail"
if [ $fail -gt 0 ]; then
    for f in "${failures[@]}"; do echo "    - $f"; done
    exit 1
fi
exit 0
