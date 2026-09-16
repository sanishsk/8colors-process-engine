#!/usr/bin/env bash
# tests/test_design_tells_2026.sh — design-critic's floor is calibrated to the
# AI-generated design of now, not of when it was written.
#
# The nine tells were written in July 2026 against the slop of that moment:
# dark + cyan + gradient, glow, manifesto copy, emoji icons, Inter. By
# September the anthropics/skills frontend-design skill had catalogued what
# generated pages had moved on to (a cream ground with a terracotta accent,
# near-black with one acid accent, the broadsheet layout, the identical-card
# kit, template chrome: tracked all-caps eyebrows, middle-dot meta strings,
# arrows on every link). A page built entirely from those passed all nine.
#
# The operator chose to FOLD the new patterns into the existing nine rather
# than add rows, so the ≥3 threshold and the gate history stay comparable.
# This asserts the fold landed in the rows it belongs to, that the count and
# the threshold did not move, and that the one copy of the table outside
# design-critic is gone rather than left to drift.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
CRITIC="$ROOT/agents/design-critic.md"
REVIEWER="$ROOT/agents/code-reviewer.md"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_design_tells_2026"

tells=$(awk '/^### The 9 tells/,/^\*\*Verdict rule for the tells/' "$CRITIC")
row() { grep -E "^\| $1 \|" <<<"$tells"; }
row_has() {   # $1=row  $2=regex  $3=label
    if row "$1" | grep -qiE -- "$2"; then ok "$3"; else bad "$3 — tell $1 does not mention /$2/"; fi
}

# ─── the shape did not move ─────────────────────────────────────────
n=$(grep -cE '^\| [0-9]+ \|' <<<"$tells")
[ "$n" = "9" ] && ok "still exactly nine tells" || bad "$n tell rows — the fold was supposed to keep nine"
grep -q '3+ tells on a new / reworked screen: \*\*FAIL\*\*' "$CRITIC" \
    && ok "FAIL threshold is still 3+ tells" \
    || bad "the 3+ FAIL threshold changed — gate history is no longer comparable"
row 6 | grep -q 'Over-padding' \
    && ok "over-padding stays: design-lint checks spacing is on-token, not that it is excessive" \
    || bad "over-padding was removed, but no hook catches it"
row 9 | grep -q 'D8 upgrade' && ok "tell 9 keeps its D8 HARD FAIL note" || bad "tell 9 lost its D8 note"

# ─── each 2026 pattern folded into the row it belongs to ────────────
row_has 1 'F4F1EA'     "tell 1 covers the off-white ground, serif, burnt-orange palette"
row_has 1 'acid'       "tell 1 covers near-black with a single acid accent"
row_has 4 'newspaper'  "tell 4 covers the broadsheet (newspaper) layout"
row_has 4 'radius'     "tell 4 covers the identical-card kit (one radius, one shadow)"
row_has 7 'eyebrow'    "tell 7 covers all-caps eyebrow labels"
row_has 7 'lone word'  "tell 7 covers the single accented word in a headline"
row_has 8 '·'          "tell 8 covers middle-dot meta strings"
row_has 8 '→'          "tell 8 covers arrows appended to links and buttons"

grep -q 'anthropics/skills' <<<"$tells" \
    && ok "the calibration names its source, so the next refresh knows where to look" \
    || bad "no source cited for the 2026 calibration"

# How the widened rows count must be stated, or three bundled rows reach ≥3 on one page.
grep -q 'Each numbered tell counts once' "$CRITIC" \
    && ok "the counting rule says each row counts once, however many of its patterns appear" \
    || bad "no counting rule for rows that bundle several patterns"

# A pattern the brief asks for is a choice, not a tell.
fp=$(awk '/^## Common false positives/,/^## Interaction with other engine layers/' "$CRITIC")
grep -qiE 'brief .*asks for|asked for' <<<"$fp" \
    && ok "a pattern the brief or SIGNATURE.md asks for is listed as a false positive" \
    || bad "no false-positive rule for a look the brief explicitly asks for"
grep -qi 'design-system convention' <<<"$fp" \
    && ok "a design-system token applied on purpose is listed as a false positive" \
    || bad "no false-positive rule for a consistent radius/shadow token or a specified convention"

# Up to the next H1 or H2. A plain range would end on its own start line.
layers=$(awk '/^## Interaction with other engine layers/{f=1; next} /^#{1,2} /{f=0} f' "$CRITIC")
grep -q 'frontend-design' <<<"$layers" \
    && ok "the layers table names the frontend-design skill as the generator this gate checks" \
    || bad "design-critic's layers table does not mention the frontend-design skill"

# ─── one table, not two ─────────────────────────────────────────────
if grep -qE '^\| [1-9] \| \**(Stock|Glow|Manifesto|Card|Emoji|Over|Default|Word|Template|No signature)' "$REVIEWER"; then
    bad "code-reviewer still carries its own copy of the tells table — it had already drifted once"
else
    ok "code-reviewer has no copy of the tells table"
fi
grep -q 'agents/design-critic.md' "$REVIEWER" \
    && ok "code-reviewer points at design-critic for the tells" \
    || bad "code-reviewer no longer says where the tells live"

# ─── E7 shares the generator's vocabulary ───────────────────────────
grep -E '^\| E7 \|' "$ROOT/docs/DESIGN_TOOLING_PLAN.md" | grep -q 'frontend-design' \
    && ok "E7's spec is shaped like the frontend-design plan pass" \
    || bad "E7 row does not reference the frontend-design plan pass"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
