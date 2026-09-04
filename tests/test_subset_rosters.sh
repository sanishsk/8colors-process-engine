#!/usr/bin/env bash
# tests/test_subset_rosters.sh — the install presets must mean what they say.
#
# `--subset gate-only` promises "the gate agents". It was written in v0.8.0
# with the five that existed then, and never revisited: `design-critic`
# arrived in v0.18.0 and `performance-reviewer` in v0.37.0, both emitting
# gate envelopes, and neither was added. For roughly a year an adopter who
# chose the leanest install for review discipline silently got five of seven
# gates — no design gate, no performance gate — and
# docs/CAPABILITY_CATALOG.md agreed with the roster, so nothing looked wrong.
#
# A preset is a promise about a set. Derive the set from the property that
# defines it, and check the roster against that property instead of against
# a number somebody typed once.
#
# The defining property: a gate agent's prompt sources
# agents/_gate-contract.md. That is what makes it emit an envelope, which is
# what the router consumes.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_subset_rosters"

# shellcheck source=../scripts/_subset.sh
. "$ROOT/scripts/_subset.sh"

# Every agent whose prompt carries the gate contract.
contract=$(grep -l '_gate-contract' "$ROOT"/agents/*.md 2>/dev/null \
           | xargs -n1 basename | sed 's/\.md$//' | grep -v '^_' | sort)

roster=$(printf '%s\n' $GATE_ONLY_AGENTS | sort)

if [ "$contract" = "$roster" ]; then
    n=$(printf '%s\n' "$contract" | grep -c .)
    ok "gate-only holds exactly the $n agents that emit a gate envelope"
else
    missing=$(comm -23 <(printf '%s\n' "$contract") <(printf '%s\n' "$roster") | tr '\n' ' ')
    extra=$(comm -13 <(printf '%s\n' "$contract") <(printf '%s\n' "$roster") | tr '\n' ' ')
    [ -n "$missing" ] && bad "gate agents missing from --subset gate-only: $missing"
    [ -n "$extra" ]   && bad "--subset gate-only lists non-gate agents: $extra"
fi

# core = gate-only + the three planning agents. Stated as a relationship, so
# growing the gate set grows core with it instead of silently diverging.
expected_core=$(printf '%s\n' $GATE_ONLY_AGENTS planner brief-writer architect | sort -u)
actual_core=$(printf '%s\n' $CORE_AGENTS | sort -u)
[ "$expected_core" = "$actual_core" ] \
    && ok "core is gate-only plus planner, brief-writer and architect" \
    || bad "core has drifted from 'gate-only + the three planning agents'"

# Every name in every roster must exist on disk. A typo here silently
# installs one fewer agent than the operator asked for.
ghosts=""
for a in $CORE_AGENTS; do
    [ -f "$ROOT/agents/$a.md" ] || ghosts="$ghosts $a"
done
[ -z "$ghosts" ] && ok "every agent named in a preset exists in agents/" \
                 || bad "presets name agents that do not exist:$ghosts"

# agent_in_subset is what install.sh and pe sync actually call. Prove the
# roster and the predicate agree, rather than assuming.
mismatch=""
for a in $GATE_ONLY_AGENTS; do
    agent_in_subset "$a" gate-only || mismatch="$mismatch $a"
done
for a in doc-updater ceo researcher; do
    agent_in_subset "$a" gate-only && mismatch="$mismatch !$a"
done
[ -z "$mismatch" ] && ok "agent_in_subset agrees with the roster" \
                   || bad "agent_in_subset disagrees with the roster:$mismatch"

# The catalogue quotes the counts. If it names a number, it must be right.
cat="$ROOT/docs/CAPABILITY_CATALOG.md"
if [ -f "$cat" ]; then
    n_gate=$(printf '%s\n' $GATE_ONLY_AGENTS | grep -c .)
    n_core=$(printf '%s\n' $CORE_AGENTS | sort -u | grep -c .)
    if grep -q "gate-only\` ($n_gate gate agents)" "$cat" \
       && grep -q "= $n_core agents" "$cat"; then
        ok "CAPABILITY_CATALOG quotes $n_gate gate agents and $n_core core"
    else
        bad "CAPABILITY_CATALOG does not quote $n_gate gate / $n_core core"
    fi
fi

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
