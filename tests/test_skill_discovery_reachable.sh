#!/usr/bin/env bash
# tests/test_skill_discovery_reachable.sh — "check for an existing skill
# first" and "grill before planning" have to live where the work starts.
#
# On 2026-09-16 an operator found at a conference what the engine should have
# found itself: the frontend-design skill on their machine was the December
# 2025 text, rewritten upstream twice since, and the old text pushed toward
# exactly the glow-and-gradient look design-critic fails. Checking the other
# sixteen external skills in the core set found all sixteen stale. Nothing in
# the engine told anyone to look, and nothing recorded where a skill came from
# so that looking was possible.
#
# The engine also had no interview step: brief-writer lists one to
# three open questions at the end, and planner said "ask clarifying questions
# if needed", with no procedure. Earlier that month an include-list went into
# an adopter's review-gate wrapper where an exempt-list was the safe polarity,
# and missed two files; a single question would have caught it.
#
# This asserts each rule is REACHED from the file where that decision is made,
# and that the core set cannot drift between the doc and the audit script.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
has() { grep -qiE -- "$2" "$1" 2>/dev/null; }

echo "test_skill_discovery_reachable"

# ─── discovery: check the ecosystem before building ─────────────────
has docs/OSS_SEARCH_ORDER.md 'skills\.sh' \
    && ok "OSS_SEARCH_ORDER sends agent-behaviour work to skills.sh first" \
    || bad "OSS_SEARCH_ORDER never mentions skills.sh — the search order skips the one place a skill would be"

# The check belongs in the steps a contributor follows, not only in doctrine.
section=$(awk '/^## Before adding/,/^## Adding a new doctrine doc/' CONTRIBUTING.md)
if grep -qiE 'skills\.sh' <<<"$section"; then
    ok "CONTRIBUTING's add-an-agent/command/skill steps start with the ecosystem check"
else
    bad "CONTRIBUTING's add steps do not mention skills.sh — the rule is unreachable where a new one gets written"
fi

# ─── the core set: sourced, and one list not two ────────────────────
rows=$(grep -E '^\| [0-9]+ \| `' docs/SKILLS.md)
# The checks below read columns by position. A literal '|' inside a cell
# would shift them and turn a real failure into a pass, so the shape is
# asserted first: four columns means six fields around the pipes.
misshapen=$(awk -F'|' 'NF != 6 {print $3}' <<<"$rows" | tr -d ' `')
if [ -n "$rows" ] && [ -z "$misshapen" ]; then
    ok "every core-set row has exactly four columns (positional checks below are sound)"
else
    bad "core-set rows with a '|' inside a cell or a missing column:$(printf ' %s' $misshapen)"
fi
unsourced=$(awk -F'|' '{ if ($5 !~ /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/) print $3 }' <<<"$rows" | tr -d ' `')
if [ -n "$rows" ] && [ -z "$unsourced" ]; then
    ok "every core skill in SKILLS.md names an owner/repo source (freshness is checkable)"
else
    bad "core skills without an owner/repo source:$(printf ' %s' $unsourced)"
fi

doc_set=$(awk -F'|' '{print $3}' <<<"$rows" | tr -d ' `' | sort)
py_set=$("${PE_PYTHON:-python3}" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sa", "scripts/skills_audit.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("\n".join(sorted(m.CORE_SKILLS)))')
if [ "$doc_set" = "$py_set" ]; then
    ok "SKILLS.md and skills_audit.CORE_SKILLS list the same skills"
else
    bad "SKILLS.md and skills_audit.CORE_SKILLS disagree: $(diff <(echo "$doc_set") <(echo "$py_set") | grep '^[<>]' | tr '\n' ' ')"
fi

grep -qx grilling <<<"$doc_set" \
    && ok "grilling is in the core set" \
    || bad "grilling is not in the core set"

# ─── grilling, wired where decisions are still open ─────────────────
has commands/brainstorm.md 'grilling' \
    && ok "/brainstorm runs a grilling round before brief-writer" \
    || bad "/brainstorm does not mention grilling — briefs still get written over unsettled decisions"

has agents/planner.md 'grilling' \
    && ok "planner cites the grilling procedure" \
    || bad "planner does not cite grilling"

# planner is a subagent: it cannot hold a conversation. The old line invited
# it to ask and then, finding nobody to ask, to guess.
if has agents/planner.md 'ask clarifying questions if needed'; then
    bad "planner still says 'ask clarifying questions if needed' — a subagent reads that as permission to guess"
else
    ok "planner no longer carries the unenforceable 'ask if needed' line"
fi

# ─── freshness is a ritual, not an accident ─────────────────────────
has docs/RHYTHM.md 'skills-audit' \
    && ok "RHYTHM schedules the skills audit" \
    || bad "RHYTHM has no skills audit — staleness is found by accident again"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
