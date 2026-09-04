#!/usr/bin/env bash
# tests/test_docs_version_claims.sh — a doc may not claim a version or an
# inventory count that the repository contradicts.
#
# On 2026-09-04 the engine was at 0.51.8 and:
#   VERSION                      0.51.3   (before the fixes)
#   plugin.json                  0.50.0
#   .claude-plugin/plugin.json   0.50.0
#   README badge                 0.50.0
#   README agent count           19       (21 agents on disk)
#   BETA_TESTER_BRIEF            v0.8.0, "15 specialist agents", 5 commands
#
# Six numbers, five of them wrong, one of them in a document written to be
# handed to external beta testers. CONTRIBUTING's bump checklist names steps
# for three of these files and had been followed halfway for four consecutive
# releases; tests/test_pe_pin.sh caught two of them and had been red the
# whole time because nothing ran the suite.
#
# Counting is not judgement. Anything countable gets counted here.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_docs_version_claims"

V=$(tr -d ' \n' < VERSION)
[ -n "$V" ] || { echo "  ✗ VERSION is empty"; exit 1; }

# ─── version, everywhere it is repeated ─────────────────────────────
for f in plugin.json .claude-plugin/plugin.json; do
    got=$("${PE_PYTHON:-python3}" -c "import json,sys;print(json.load(open(sys.argv[1])).get('version',''))" "$f")
    [ "$got" = "$V" ] && ok "$f version is $V" \
                      || bad "$f says $got, VERSION says $V"
done

badge=$(grep -oE 'version-[0-9]+\.[0-9]+\.[0-9]+-blue' README.md | head -1 | sed 's/version-//; s/-blue//')
[ "$badge" = "$V" ] && ok "README badge is $V" \
                    || bad "README badge says $badge, VERSION says $V"

brief=docs/launch/BETA_TESTER_BRIEF.md
if [ -f "$brief" ]; then
    claimed=$(grep -oE 'Current version: \*\*v?[0-9]+\.[0-9]+\.[0-9]+\*\*' "$brief" \
              | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    [ "$claimed" = "$V" ] \
        && ok "beta brief claims $V" \
        || bad "beta brief claims $claimed, VERSION says $V — and it is written to be handed to people outside the project"
fi

# ─── inventory counts ───────────────────────────────────────────────
agents=$(find agents -name '*.md' -not -name '_*' | wc -l | tr -d ' ')
cmds=$(find commands -name '*.md' | wc -l | tr -d ' ')
readme_agents=$(grep -oE '^- [0-9]+ specialist agents' README.md | head -1 | grep -oE '[0-9]+')
[ "$readme_agents" = "$agents" ] \
    && ok "README says $agents specialist agents, and there are $agents" \
    || bad "README says $readme_agents specialist agents; agents/ holds $agents"

if [ -f "$brief" ]; then
    brief_agents=$(grep -oE '\*\*[0-9]+ specialist agents\*\*' "$brief" | head -1 | grep -oE '[0-9]+')
    [ "$brief_agents" = "$agents" ] \
        && ok "beta brief says $agents specialist agents" \
        || bad "beta brief says $brief_agents specialist agents; agents/ holds $agents"
fi

hooks=$(find hooks -name '*.sh' -not -name '_*' | wc -l | tr -d ' ')
if grep -qE '[0-9]+ governance hooks' "$brief" 2>/dev/null; then
    brief_hooks=$(grep -oE '[0-9]+ governance hooks' "$brief" | head -1 | grep -oE '[0-9]+')
    [ "$brief_hooks" = "$hooks" ] \
        && ok "beta brief says $hooks governance hooks" \
        || bad "beta brief says $brief_hooks governance hooks; hooks/ holds $hooks"
fi

# ─── the brief's agent table must quote real model tiers ────────────
# It said `code-reviewer | Haiku` while agents/code-reviewer.md said sonnet
# and AGENT_INVOCATION_RULES.md explained why gates never run below Sonnet.
# Four of the fifteen tiers it listed were wrong.
if [ -f "$brief" ]; then
    wrong=""
    checked=0
    while IFS='|' read -r _ name model _; do
        name=$(printf '%s' "$name" | tr -d ' `')
        model=$(printf '%s' "$model" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        [ -f "agents/$name.md" ] || continue
        real=$(awk -F': *' '/^model:/{print $2; exit}' "agents/$name.md" | tr -d ' ')
        [ -z "$real" ] && continue
        checked=$((checked + 1))
        [ "$model" = "$real" ] || wrong="$wrong $name(doc:$model,real:$real)"
    done < <(grep -E '^\| `[a-z0-9-]+` \| [A-Za-z]+ \|' "$brief")

    if [ "$checked" -eq 0 ]; then
        bad "no agent/model rows found in the beta brief — has the table moved?"
    elif [ -z "$wrong" ]; then
        ok "all $checked agent model tiers in the beta brief match agents/*.md"
    else
        bad "beta brief quotes the wrong model for:$wrong"
    fi

    # Every agent must appear in the brief, or it is selling 15 of 21 again.
    absent=""
    for f in agents/*.md; do
        b=$(basename "$f" .md)
        case "$b" in _*) continue ;; esac
        grep -qF "\`$b\`" "$brief" || absent="$absent $b"
    done
    [ -z "$absent" ] && ok "every agent appears in the beta brief" \
                     || bad "agents missing from the beta brief:$absent"

    brief_cmds=$(grep -oE '^### [0-9]+ slash commands' "$brief" | grep -oE '[0-9]+')
    [ "$brief_cmds" = "$cmds" ] \
        && ok "beta brief says $cmds slash commands" \
        || bad "beta brief says $brief_cmds slash commands; commands/ holds $cmds"

    gates=$(grep -l '_gate-contract' agents/*.md | grep -v '_gate-contract' | wc -l | tr -d ' ')
    grep -q "The $gates gate agents" "$brief" \
        && ok "beta brief says $gates gate agents" \
        || bad "beta brief does not say '$gates gate agents'"
fi

# ─── the README carries the same tables, and drifted the same way ───
# It said "Agents (19)" with `code-reviewer | Haiku`, `data-model-auditor |
# Haiku` and `retrospective-agent | Sonnet`, and "Commands (4)" out of 10.
# The beta brief is what gets sent to people; the README is what they see
# first on GitHub. Both are held to the repository, by the same rules.
wrong=""
checked=0
while IFS='|' read -r _ name model _; do
    name=$(printf '%s' "$name" | tr -d ' `')
    model=$(printf '%s' "$model" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    [ -f "agents/$name.md" ] || continue
    real=$(awk -F': *' '/^model:/{print $2; exit}' "agents/$name.md" | tr -d ' ')
    [ -z "$real" ] && continue
    checked=$((checked + 1))
    [ "$model" = "$real" ] || wrong="$wrong $name(doc:$model,real:$real)"
done < <(grep -E '^\| `[a-z0-9-]+` \| [A-Za-z]+ \|' README.md)

if [ "$checked" -eq 0 ]; then
    bad "no agent/model rows found in README — has the table moved?"
elif [ -z "$wrong" ]; then
    ok "all $checked agent model tiers in README match agents/*.md"
else
    bad "README quotes the wrong model for:$wrong"
fi

absent=""
for f in agents/*.md; do
    b=$(basename "$f" .md)
    case "$b" in _*) continue ;; esac
    grep -qF "\`$b\`" README.md || absent="$absent $b"
done
[ -z "$absent" ] && ok "every agent appears in README" \
                 || bad "agents missing from README:$absent"

readme_heading=$(grep -oE '^### Agents \([0-9]+\)' README.md | grep -oE '[0-9]+')
[ "$readme_heading" = "$agents" ] \
    && ok "README's Agents heading says $agents" \
    || bad "README's Agents heading says $readme_heading; agents/ holds $agents"

readme_cmds=$(grep -oE '^### Commands \([0-9]+\)' README.md | grep -oE '[0-9]+')
[ "$readme_cmds" = "$cmds" ] \
    && ok "README's Commands heading says $cmds" \
    || bad "README's Commands heading says $readme_cmds; commands/ holds $cmds"

# The one-piece entry point must be reachable from the README, not buried
# in a doctrine list two thirds of the way down.
if grep -qE 'RUNNING_AGENTS\.md' README.md; then
    line=$(grep -nE 'RUNNING_AGENTS\.md' README.md | head -1 | cut -d: -f1)
    total=$(wc -l < README.md | tr -d ' ')
    if [ "$line" -le $((total / 3)) ]; then
        ok "README links RUNNING_AGENTS.md in its first third (line $line of $total)"
    else
        bad "README's first RUNNING_AGENTS.md link is at line $line of $total — too far down to find"
    fi
else
    bad "README does not link docs/RUNNING_AGENTS.md at all"
fi

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
