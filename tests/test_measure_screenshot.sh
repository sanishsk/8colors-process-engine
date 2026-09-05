#!/usr/bin/env bash
# tests/test_measure_screenshot.sh — the measuring tool, against images whose
# answers are known exactly.
#
# Ported from the adopter project this script was promoted from, into the
# engine's bash suite. Synthetic on purpose: a test that measures a real
# reference PNG and asserts "the title is 12.33pt" is a test of that PNG, and
# it goes red the day someone re-crops it. These draw a rectangle of a known
# size at a known place and assert the tool reports that size — the only
# property worth locking, because the whole point of the tool is that it does
# not guess.
#
# Pillow is not in the engine's dependency set (bash + stdlib Python by
# design), so this skips loudly when it is absent — and CI installs Pillow
# for the suite job specifically so these assertions actually execute. A
# promoted script whose test never runs is the shape this repo keeps finding:
# a capability nothing invokes.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
TOOL="$ROOT/templates/tools/measure_screenshot.py"
PY="${PE_PYTHON:-python3}"

echo "test_measure_screenshot"

if ! "$PY" -c "import PIL" >/dev/null 2>&1; then
    echo "  ⊘ SKIPPED — Pillow not installed (pip install Pillow to run these)"
    echo "  0 passed, 0 failed"
    exit 0
fi

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# 600×400 of #0c0c0e with three known marks:
#   * an amber rectangle (100,50)-(219,129) — 120 × 80 px
#   * a 1px white rule across the full width at y=200
#   * a 3px rule at y=300, to prove thickness is ONE rule, not three
CANVAS="$TMP/canvas.png"
FLAT="$TMP/flat.png"
"$PY" - "$CANVAS" "$FLAT" <<'PY'
import sys
from PIL import Image, ImageDraw
canvas, flat = sys.argv[1], sys.argv[2]
img = Image.new("RGB", (600, 400), (12, 12, 14))
d = ImageDraw.Draw(img)
d.rectangle([100, 50, 219, 129], fill=(245, 158, 11))
d.rectangle([0, 200, 599, 200], fill=(255, 255, 255))
d.rectangle([0, 300, 599, 302], fill=(255, 255, 255))
img.save(canvas)
Image.new("RGB", (200, 100), (12, 12, 14)).save(flat)
PY

# Run the tool and read one field out of its JSON. Output to a file and the
# field via a second call — a $(...) wrapping the whole pipeline would hide
# a non-zero exit behind an empty string.
OUT="$TMP/.out"
run() { "$PY" "$TOOL" "$@" >"$OUT" 2>&1; }
field() { "$PY" -c "import json,sys;print(json.load(open(sys.argv[1]))$1)" "$OUT" 2>/dev/null; }

# ─── 1. a colour is the pixel, not an average of its neighbours ─────
# The difference from a palette extractor, and why one is right for a design
# token and the other is not.
run colour "$CANVAS" 150 90
[ "$(field '["hex"]')" = "#f59e0b" ] \
    && ok "the amber block reports the amber, not a blend with the ground" \
    || bad "colour at (150,90) was $(field '["hex"]'), expected #f59e0b"

run colour "$CANVAS" 10 10
[ "$(field '["hex"]')" = "#0c0c0e" ] \
    && ok "the ground reports the ground" \
    || bad "colour at (10,10) was $(field '["hex"]')"

# ─── 2. ink reports the drawn size exactly ──────────────────────────
run ink "$CANVAS" 50 20 300 160
if [ "$(field '["ink_width_px"]')" = "120" ] && [ "$(field '["ink_height_px"]')" = "80" ]; then
    ok "ink boxes the drawn rectangle at exactly 120×80"
else
    bad "ink was $(field '["ink_width_px"]')×$(field '["ink_height_px"]'), expected 120×80"
fi

# ─── 3. points need the device width, and are ABSENT without it ─────
# The honest half of the tool. A screenshot does not know what a point is,
# so without the logical width the answer stays in pixels rather than being
# silently wrong by a factor of two or three.
[ "$(field '["ink_height_pt"]')" = "None" ] \
    && ok "with no --device-width the point value is null, not a guess" \
    || bad "reported a point value without knowing the scale: $(field '["ink_height_pt"]')"

run ink "$CANVAS" 50 20 300 160 --device-width 300
if [ "$(field '["ink_height_pt"]')" = "40.0" ] && [ "$(field '["ink_width_pt"]')" = "60.0" ]; then
    ok "600px across a 300pt device converts at 2px/pt"
else
    bad "conversion wrong: $(field '["ink_width_pt"]')×$(field '["ink_height_pt"]')"
fi

# ─── 4. empty is not zero ───────────────────────────────────────────
# "A zero-size box" and "there was nothing here" are different answers, and
# only one of them is safe to put in a spec.
run ink "$CANVAS" 300 20 400 60
if [ "$(field '["found"]')" = "False" ] && grep -q "nothing differed" "$OUT"; then
    ok "an empty region says so rather than returning a zero-size box"
else
    bad "empty region returned found=$(field '["found"]')"
fi

# ─── 5. rules: found, and a thick one is ONE rule ───────────────────
run rules "$CANVAS" --device-width 300
YS=$(field '["rules"]' | tr -d '[]' | tr ',' '\n' | grep -o "'y': [0-9]*" | grep -o '[0-9]*')
if grep -qx 200 <<<"$YS" && grep -qx 300 <<<"$YS"; then
    ok "both rules are found at y=200 and y=300"
else
    bad "rules found at: $(echo "$YS" | tr '\n' ' ')"
fi

THICK=$("$PY" -c "
import json;d=json.load(open('$OUT'))
r=[x for x in d['rules'] if x['y']==300]
print(r[0]['thickness_px'] if r else 'missing')" 2>/dev/null)
[ "$THICK" = "3" ] \
    && ok "three adjacent rows are reported as one 3px rule, not three rules" \
    || bad "the thick rule reported thickness $THICK, expected 3"

THIN_PT=$("$PY" -c "
import json;d=json.load(open('$OUT'))
r=[x for x in d['rules'] if x['y']==200]
print(r[0]['pt'] if r else 'missing')" 2>/dev/null)
[ "$THIN_PT" = "100.0" ] \
    && ok "a rule's position converts to points too" \
    || bad "rule at y=200 reported pt=$THIN_PT, expected 100.0"

# ─── 6. a flat background is not a rule ─────────────────────────────
# The condition that makes the scan useful: a rule must CONTRAST with the row
# above it. Without that, every row of a plain background qualifies and the
# answer is the whole image.
run rules "$FLAT"
[ "$(field '["count"]')" = "0" ] \
    && ok "a plain background yields zero rules, not four hundred" \
    || bad "a flat image reported $(field '["count"]') rules"

# ─── 7. gap measures both axes ──────────────────────────────────────
run gap "$CANVAS" 100 50 220 130 --device-width 300
if [ "$(field '["dx_px"]')" = "120" ] && [ "$(field '["dy_px"]')" = "80" ] \
   && [ "$(field '["dx_pt"]')" = "60.0" ] && [ "$(field '["scale_px_per_pt"]')" = "2.0" ]; then
    ok "gap reports both axes in px and pt with the scale it used"
else
    bad "gap: dx=$(field '["dx_px"]')px/$(field '["dx_pt"]')pt scale=$(field '["scale_px_per_pt"]')"
fi

# ─── 8. delivered where design-critic expects it ────────────────────
# The engine's recurring defect is a capability nothing invokes. The script
# is only useful if pe install puts it in adopters and the agent knows the
# path, so both are asserted here rather than assumed.
grep -q 'templates/tools' "$ROOT/scripts/install.sh" \
    && ok "install.sh delivers templates/tools/ to adopters" \
    || bad "the script is in the engine but pe install never copies it"

grep -q 'measure_screenshot' "$ROOT/agents/design-critic.md" \
    && ok "design-critic knows to shell out to it before citing drift" \
    || bad "nothing invokes the measuring tool — it would sit unused"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
