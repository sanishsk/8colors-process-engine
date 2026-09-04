#!/usr/bin/env bash
# tests/test_agent_refs.sh — a doc may not route work to an agent that does
# not exist, nor claim a corpus the disk does not hold.
#
# Three defects, all found on 2026-09-04, all the same shape — a document
# describing a repository that has moved on:
#
#   1. docs/AGENT_INVOCATION_RULES.md's slot matrix routed "UI change" to
#      `ui-ux-design-agent`. No such file in agents/. That table is what
#      Claude reads to pick an agent, so the row was live and dead at once.
#      docs/IMPROVEMENT_PLAN.md:327 had ALREADY flagged it — "fix dangling
#      references (ui-ux-design-agent in AGENT_INVOCATION_RULES ...)" — and
#      nothing acted on it, because nothing checked.
#
#   2. docs/CAPABILITY_CATALOG.md listed seven agents as "8CStudio-only, NOT
#      installed by pe install". Four of them — data-model-auditor,
#      tenant-isolation-auditor, project-kickstarter, project-onboarder —
#      had since been promoted into the engine and ARE installed.
#
#   3. evals/README.md claimed "16 fixtures across 5 gates". The disk held
#      26 across 6, with performance-reviewer absent from the page entirely.
#
# Counting is not judgement. Anything countable gets counted.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_agent_refs"

# ─── 1. the routing matrix may only name agents that exist ──────────
# Scope: the slot-type table at the top of AGENT_INVOCATION_RULES.md. Only
# the table, because prose elsewhere legitimately discusses agents that live
# in other projects.
matrix=$(awk '/^\| Slot type/{f=1} f && /^\|/{print} f && !/^\|/{exit}' \
         docs/AGENT_INVOCATION_RULES.md)
[ -n "$matrix" ] || { echo "  ✗ could not find the slot matrix"; exit 1; }

ghosts=""
for a in $(printf '%s\n' "$matrix" \
           | grep -oE '[a-z][a-z0-9]*(-[a-z0-9]+)+' | sort -u); do
    # Only names that LOOK like agents — skip slash-commands and prose.
    case "$a" in
        *-reviewer|*-writer|*-guide|*-runner|*-critic|*-auditor|*-resolver|\
        *-updater|*-consolidator|*-synthesizer|*-kickstarter|*-onboarder|*-agent) ;;
        *) continue ;;
    esac
    [ -f "agents/$a.md" ] || ghosts="$ghosts $a"
done
[ -z "$ghosts" ] \
    && ok "the slot matrix names only agents that exist" \
    || bad "slot matrix routes to non-existent agents:$ghosts"

# ─── 2. the "not installed" table must not name shipped agents ──────
notinst=$(awk '/^\| Agent \| Why not in the engine/{f=1;next} f && /^\|/{print} f && !/^\|/{exit}' \
          docs/CAPABILITY_CATALOG.md)
if [ -z "$notinst" ]; then
    bad "could not find CAPABILITY_CATALOG's 'not installed' table"
else
    # FIRST COLUMN ONLY. A row's rationale legitimately names other agents
    # — the ui-ux-design-agent row points at design-critic as the engine's
    # equivalent — and scanning the whole row flagged that as a defect.
    wrong=""
    for a in $(printf '%s\n' "$notinst" | cut -d'|' -f2 \
               | grep -oE '`[a-z][a-z0-9-]+`' | tr -d '`' | sort -u); do
        [ -f "agents/$a.md" ] && wrong="$wrong $a"
    done
    [ -z "$wrong" ] \
        && ok "the 'not installed' table names no agent the engine ships" \
        || bad "listed as not-installed but present in agents/:$wrong"
fi

# ─── 3. eval corpus counts must match the disk ──────────────────────
gates_disk=$(find evals/fixtures -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
fx_disk=$(find evals/fixtures -mindepth 2 -maxdepth 2 -type d | wc -l | tr -d ' ')

# "across 7 gates" and "across all 7 gates" both count — the sentence is
# allowed to say the corpus now covers every gate.
claimed=$(grep -oE 'Total: [0-9]+ fixtures across (all )?[0-9]+ gates' evals/README.md | head -1)
if [ -z "$claimed" ]; then
    bad "evals/README.md states no corpus total"
else
    c_fx=$(printf '%s' "$claimed" | grep -oE '[0-9]+' | head -1)
    c_gates=$(printf '%s' "$claimed" | grep -oE '[0-9]+' | tail -1)
    [ "$c_fx" = "$fx_disk" ] && [ "$c_gates" = "$gates_disk" ] \
        && ok "evals/README says $fx_disk fixtures across $gates_disk gates" \
        || bad "evals/README says $c_fx/$c_gates; disk has $fx_disk fixtures across $gates_disk gates"
fi

# Every gate with fixtures on disk must have a line, with the right count.
miscounted=""
for d in evals/fixtures/*/; do
    g=$(basename "$d")
    n=$(find "$d" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    line=$(grep -E "^- \*\*$g\*\* — [0-9]+ fixtures" evals/README.md | head -1)
    if [ -z "$line" ]; then
        miscounted="$miscounted $g(absent)"
    else
        said=$(printf '%s' "$line" | grep -oE '[0-9]+ fixtures' | grep -oE '[0-9]+')
        [ "$said" = "$n" ] || miscounted="$miscounted $g(says:$said,has:$n)"
    fi
done
[ -z "$miscounted" ] \
    && ok "every seeded gate's fixture count matches the disk" \
    || bad "evals/README per-gate counts wrong:$miscounted"

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
