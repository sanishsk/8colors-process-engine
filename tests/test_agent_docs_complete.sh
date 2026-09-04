#!/usr/bin/env bash
# tests/test_agent_docs_complete.sh — every agent is documented, and the
# gate table names exactly the agents that emit envelopes.
#
# docs/RUNNING_AGENTS.md exists because a beta tester asked how to run one
# agent — security, in their case — without adopting the whole engine. A
# catalogue that lists 15 of 21 agents answers that question wrongly for the
# six it omits, which is exactly what docs/launch/BETA_TESTER_BRIEF.md had
# been doing since v0.8.0.
#
# Same failure the hook catalogue had (tests/test_hooks_documented.sh): a
# table that was complete when it was written and that nothing re-checked.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
DOC="$ROOT/docs/RUNNING_AGENTS.md"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_agent_docs_complete"
[ -f "$DOC" ] || { echo "  ✗ docs/RUNNING_AGENTS.md missing"; exit 1; }

missing=""
for f in "$ROOT"/agents/*.md; do
    b=$(basename "$f" .md)
    case "$b" in _*) continue ;; esac
    grep -qF "\`$b\`" "$DOC" || missing="$missing $b"
done
[ -z "$missing" ] && ok "every agent appears in RUNNING_AGENTS.md" \
                  || bad "agents missing from the catalogue:$missing"

ghosts=""
for b in $(grep -oE '^\| `[a-z0-9-]+`' "$DOC" | tr -d '|` '); do
    [ -f "$ROOT/agents/$b.md" ] || ghosts="$ghosts $b"
done
[ -z "$ghosts" ] && ok "the catalogue names no agent that has been deleted" \
                 || bad "catalogue rows without an agent file:$ghosts"

# The gate table is the section between the "Gate agents" heading and the
# next heading. It must equal the set of agents carrying the gate contract —
# the property that actually makes an agent emit an envelope.
gate_rows=$(awk '/^### Gate agents/{f=1;next} /^###/{f=0} f' "$DOC" \
            | grep -oE '^\| `[a-z0-9-]+`' | tr -d '|` ' | sort)
contract=$(grep -l '_gate-contract' "$ROOT"/agents/*.md 2>/dev/null \
           | xargs -n1 basename | sed 's/\.md$//' | grep -v '^_' | sort)

if [ "$gate_rows" = "$contract" ]; then
    ok "the gate table names exactly the $(printf '%s\n' "$contract" | grep -c .) envelope-emitting agents"
else
    bad "gate table disagrees with agents/_gate-contract.md — table: $(echo $gate_rows), contract: $(echo $contract)"
fi

# The doc quotes counts. If it names a number, it must be right.
n_agents=$(find "$ROOT/agents" -name '*.md' -not -name '_*' | wc -l | tr -d ' ')
n_hooks=$(find "$ROOT/hooks" -name '*.sh' -not -name '_*' | wc -l | tr -d ' ')
grep -q "$n_agents agents and $n_hooks hooks" "$DOC" \
    && ok "RUNNING_AGENTS quotes $n_agents agents and $n_hooks hooks" \
    || bad "RUNNING_AGENTS does not quote '$n_agents agents and $n_hooks hooks'"

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
