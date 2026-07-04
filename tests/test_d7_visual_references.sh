#!/usr/bin/env bash
# tests/test_d7_visual_references.sh — D7 curated visual references
# + Style Dictionary + design-scan wiring.
#
# D7 upgrades D5's stub archetype files to curated visual reference
# tables. Each archetype MUST carry a "Curated visual references"
# section with:
#   - a markdown table
#   - at least one 9.0-anchor row
#   - at least one 6.0 anti-exemplar row
#   - a per-row "Concrete visual anchor" description column
#
# design-critic MUST advertise D7 in its description and retire the
# STUB caveat. The design-scan command MUST land. The Style
# Dictionary template MUST parse as valid JSON.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_d7_visual_references.sh — D7 wiring shape checks"
echo ""

# ─── 1. all 4 archetypes carry the Curated visual references section
for archetype in marketing-site client-gallery internal-dashboard form-flow; do
    f="$ENGINE_DIR/docs/design/aspirational/$archetype.md"
    if grep -q '^## Curated visual references' "$f"; then
        record_pass "$archetype.md has Curated visual references section"
    else
        record_fail "$archetype.md missing Curated visual references section"
    fi
done

# ─── 5. each archetype has at least one 9.0 anchor row
for archetype in marketing-site client-gallery internal-dashboard form-flow; do
    f="$ENGINE_DIR/docs/design/aspirational/$archetype.md"
    # look for a table row where the "Bar" column contains 9.0 within
    # the Curated visual references section.
    if awk '/^## Curated visual references/,/^## What earns 9.0/' "$f" \
       | grep -qE '\|[[:space:]]*9\.0[[:space:]]*\|'; then
        record_pass "$archetype.md carries a 9.0-anchor row"
    else
        record_fail "$archetype.md missing 9.0-anchor row"
    fi
done

# ─── 9. each archetype has at least one 6.0 or below anti-exemplar row
for archetype in marketing-site client-gallery internal-dashboard form-flow; do
    f="$ENGINE_DIR/docs/design/aspirational/$archetype.md"
    if awk '/^## Curated visual references/,/^## What earns 9.0/' "$f" \
       | grep -qE '\|[[:space:]]*[456]\.[05][[:space:]]*\|'; then
        record_pass "$archetype.md carries an anti-exemplar row (≤6.0)"
    else
        record_fail "$archetype.md missing anti-exemplar row"
    fi
done

# ─── 13. aspirational README retires STUB caveat + names D7
readme="$ENGINE_DIR/docs/design/aspirational/README.md"
if grep -q "v0.40.0 status — CURATED (D7)" "$readme"; then
    record_pass "aspirational README retires STUB → CURATED"
else
    record_fail "aspirational README still says STUB"
fi

if grep -q "commands/design-scan.md" "$readme"; then
    record_pass "aspirational README points at design-scan ritual"
else
    record_fail "aspirational README missing design-scan pointer"
fi

# ─── 15. design-critic advertises D7 + retires STUB caveat
critic="$ENGINE_DIR/agents/design-critic.md"
if grep -q "D7, v0.40.0 curated visual references" "$critic"; then
    record_pass "design-critic description advertises D7"
else
    record_fail "design-critic description missing D7 mention"
fi

if grep -q "v0.40.0 — D7 curated visual reference library" "$critic"; then
    record_pass "design-critic body has D7 section replacing STUB caveat"
else
    record_fail "design-critic body missing D7 section"
fi

# STUB caveat MUST be gone (retired, not just augmented)
if grep -q "reference is a stub" "$critic"; then
    record_fail "design-critic STILL carries STUB language — should be retired"
else
    record_pass "design-critic no longer carries STUB caveat language"
fi

# ─── 19. design-scan command landed with required frontmatter
scan="$ENGINE_DIR/commands/design-scan.md"
if [ -f "$scan" ] && grep -q '^description:' "$scan" && grep -q 'Quarterly design-scan' "$scan"; then
    record_pass "commands/design-scan.md landed with description frontmatter"
else
    record_fail "commands/design-scan.md missing or malformed"
fi

# ─── 20. Style Dictionary template is valid JSON
tokens="$ENGINE_DIR/templates/design/tokens.json.template"
if [ -f "$tokens" ] && python3 -c "import json,sys; json.load(open('$tokens'))" 2>/dev/null; then
    record_pass "tokens.json.template parses as valid JSON"
else
    record_fail "tokens.json.template invalid or missing"
fi

# ─── 21. Style Dictionary config template exists
sdconfig="$ENGINE_DIR/templates/design/style-dictionary.config.js.template"
if [ -f "$sdconfig" ] && grep -q "source:" "$sdconfig" && grep -q "platforms:" "$sdconfig"; then
    record_pass "style-dictionary.config.js.template landed"
else
    record_fail "style-dictionary.config.js.template missing or malformed"
fi

# ─── 22. templates/design/README documents the pipeline
tdreadme="$ENGINE_DIR/templates/design/README.md"
if [ -f "$tdreadme" ] && grep -q "Style Dictionary" "$tdreadme" && grep -q "Per-tenant themes" "$tdreadme"; then
    record_pass "templates/design/README documents the pipeline"
else
    record_fail "templates/design/README missing or incomplete"
fi

# ─── 23. archetype schema block in README updated to include D7 section
if grep -q "^## Curated visual references (D7, v0.40.0)$" "$readme"; then
    record_pass "archetype schema block in README includes Curated visual references"
else
    record_fail "archetype schema block missing Curated visual references heading"
fi

# ─── summary ────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  passed: $pass"
echo "  failed: $fail"
if [ $fail -gt 0 ]; then
    for f in "${failures[@]}"; do echo "    - $f"; done
    exit 1
fi
exit 0
