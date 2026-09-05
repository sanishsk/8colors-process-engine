#!/usr/bin/env bash
# tests/test_promotion_boundary_reachable.sh — the doctrine has to be reachable
# from where the decision is actually made.
#
# PROMOTION_BOUNDARY.md exists because the engine kept shipping controls that
# lived only in prose: a reference-screenshot path documented and never
# created, a CLAUDE.md threshold configured where half its readers could not
# see it, a review gate whose narrowing had to be re-implemented in a wrapper.
#
# A doctrine doc that nothing links to is the same defect wearing the doc's
# own words. So this asserts the doc is REACHED, not merely present:
#
#   * the README indexes it, which is what an adopter reads at install time
#   * CONTRIBUTING cites it from the value bar, where a human decides
#   * incident-synthesizer cites it from `generalisable`, where an AGENT
#     decides — and that agent's decision opens PRs against this repo
#
# It also checks the doc keeps its own rules: under the 200-line doctrine
# budget CONTRIBUTING sets, and carrying the checklist it promises.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
DOC="docs/PROMOTION_BOUNDARY.md"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_promotion_boundary_reachable"

if [ ! -f "$ROOT/$DOC" ]; then
    echo "  ✗ $DOC is missing"
    echo "  0 passed, 1 failed"
    exit 1
fi
ok "$DOC exists"

# ─── reachable from each place the call gets made ───────────────────
cites() {   # $1=file  $2=label
    if grep -q "PROMOTION_BOUNDARY" "$ROOT/$1" 2>/dev/null; then
        ok "$2 links to the doctrine"
    else
        bad "$2 does not link to it — the doctrine is unreachable from where the decision is made"
    fi
}
cites "README.md"                     "the README's doctrine index (what an adopter reads)"
cites "CONTRIBUTING.md"               "CONTRIBUTING's value bar (where a human decides)"
cites "agents/incident-synthesizer.md" "incident-synthesizer's generalisable field (where an AGENT decides)"

# ─── it keeps the rules it states ───────────────────────────────────
LINES=$(wc -l < "$ROOT/$DOC" | tr -d ' ')
if [ "$LINES" -le 200 ]; then
    ok "under the 200-line doctrine budget CONTRIBUTING sets ($LINES lines)"
else
    bad "$LINES lines — over the doctrine budget it is subject to"
fi

# The checklist is the part anyone will actually use under time pressure.
if grep -q '^- \[ \]' "$ROOT/$DOC"; then
    ok "carries the actionable checklist it promises"
else
    bad "no checklist — the doc is an essay, and an essay is not a mechanism"
fi

# The three layers are the whole point; a doc that names only two has
# reverted to the binary framing that caused the wrapper.
for layer in "Layer 1" "Layer 2" "Layer 3"; do
    grep -q "$layer" "$ROOT/$DOC" \
        || bad "$layer is missing — the middle layer is the one that gets forgotten"
done
grep -q "Layer 2" "$ROOT/$DOC" \
    && ok "all three layers are named, including engine-mechanism-plus-project-config"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
