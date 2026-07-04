#!/usr/bin/env bash
# tests/test_signature_lint.sh — D8 signature-system gate coverage.
#
# The hook has three responsibilities:
#   1. Opt-in: no docs/design/SIGNATURE.md → gate is inert (exit 0).
#   2. Flagship-path detection: only files matching flagship_paths
#      (defaults + config-override) are scanned.
#   3. Token check: flagship file must textually reference ≥
#      require_count declared signature tokens or BLOCK.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ENGINE_DIR/hooks/signature-lint.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_signature_lint.sh — $HOOK"
echo ""

new_repo() {
    local d="$1"
    mkdir -p "$d"
    cd "$d"
    git init -q
    git config user.email t@t
    git config user.name t
    echo seed > seed.txt
    git add seed.txt
    git -c commit.gpgsign=false commit -qm seed
}

seed_signature_md() {
    mkdir -p docs/design
    cat > docs/design/SIGNATURE.md <<'MD'
# Test — Signature System
## The product signature
- `signature_token: slate-headline`
- `signature_token: timecode-label`
MD
}

# ─── 1. no SIGNATURE.md → gate inert (exit 0 silent) ────────────────
new_repo "$TMP/s1"
mkdir -p templates/marketing
echo '<div class="hero">generic marketing page</div>' > templates/marketing/index.html
git add templates/marketing/index.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "no SIGNATURE.md → gate inert (exit 0 silent)"
else
    record_fail "gate should be inert without SIGNATURE.md: rc=$rc out='$out'"
fi

# ─── 2. SIGNATURE.md present but no tokens → advisory notice, exit 0
new_repo "$TMP/s2"
mkdir -p docs/design templates/marketing
cat > docs/design/SIGNATURE.md <<'MD'
# Empty
## The product signature
(none declared yet)
MD
echo '<div>marketing</div>' > templates/marketing/index.html
git add docs/design/SIGNATURE.md templates/marketing/index.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "no .signature_token: <slug>. lines declared"; then
    record_pass "SIGNATURE.md with zero tokens → advisory notice, exit 0"
else
    record_fail "empty-tokens case wrong: rc=$rc out='$out'"
fi

# ─── 3. flagship path + no signature token → BLOCK ──────────────────
new_repo "$TMP/s3"
seed_signature_md
mkdir -p templates/marketing
echo '<div class="hero">generic marketing hero</div>' > templates/marketing/index.html
git add docs/design/SIGNATURE.md templates/marketing/index.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "flagship file carries 0 declared signature tokens"; then
    record_pass "flagship path + no signature token → BLOCK naming counts"
else
    record_fail "flagship-no-token case: rc=$rc out='$out'"
fi

# ─── 4. flagship path + signature token present → OK ────────────────
new_repo "$TMP/s4"
seed_signature_md
mkdir -p templates/marketing
echo '<h1 class="slate-headline">Product</h1>' > templates/marketing/index.html
git add docs/design/SIGNATURE.md templates/marketing/index.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "flagship path + signature token → exit 0"
else
    record_fail "flagship-with-token case should pass: rc=$rc out='$out'"
fi

# ─── 5. non-flagship path → not scanned ─────────────────────────────
new_repo "$TMP/s5"
seed_signature_md
mkdir -p templates/dashboard
echo '<div>admin table row</div>' > templates/dashboard/orders.html
git add docs/design/SIGNATURE.md templates/dashboard/orders.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "non-flagship path → not scanned (exit 0)"
else
    record_fail "non-flagship should skip: rc=$rc out='$out'"
fi

# ─── 6. Next.js app/(marketing) path detected ───────────────────────
new_repo "$TMP/s6"
seed_signature_md
mkdir -p "app/(marketing)"
cat > "app/(marketing)/page.tsx" <<'TSX'
export default function Page() { return <div>generic</div> }
TSX
git add docs/design/SIGNATURE.md "app/(marketing)/page.tsx"
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "flagship file carries"; then
    record_pass "Next.js app/(marketing)/ path detected as flagship"
else
    record_fail "Next.js marketing group not detected: rc=$rc out='$out'"
fi

# ─── 7. templates/pricing.html detected as flagship ────────────────
new_repo "$TMP/s7"
seed_signature_md
mkdir -p templates
echo '<div>$29/mo</div>' > templates/pricing.html
git add docs/design/SIGNATURE.md templates/pricing.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "flagship file carries"; then
    record_pass "templates/pricing.html detected as flagship"
else
    record_fail "pricing.html not flagship-caught: rc=$rc out='$out'"
fi

# ─── 8. config override — custom flagship path ─────────────────────
new_repo "$TMP/s8"
seed_signature_md
cat > .process-engine.yaml <<'YAML'
signature_gate:
  flagship_paths:
    - '^web/brand/'
YAML
mkdir -p web/brand templates/marketing
echo '<div>no signature</div>' > web/brand/hero.html
echo '<div>no signature</div>' > templates/marketing/index.html
git add docs/design/SIGNATURE.md .process-engine.yaml web/brand/hero.html templates/marketing/index.html
out=$(bash "$HOOK" 2>&1)
rc=$?
# custom path (web/brand/) should BLOCK; templates/marketing/ should NOT
# (was overridden). Test both properties.
if [ $rc -eq 1 ] \
   && echo "$out" | grep -q "web/brand/hero.html" \
   && ! echo "$out" | grep -q "templates/marketing/index.html"; then
    record_pass "config override — custom flagship_paths honored (marketing/ no longer flagship)"
else
    record_fail "config override wrong: rc=$rc out='$out'"
fi

# ─── 9. require_count > 1 — one token not enough ───────────────────
new_repo "$TMP/s9"
seed_signature_md
cat > .process-engine.yaml <<'YAML'
signature_gate:
  require_count: 2
YAML
mkdir -p templates/marketing
echo '<h1 class="slate-headline">Only one signature</h1>' > templates/marketing/index.html
git add docs/design/SIGNATURE.md .process-engine.yaml templates/marketing/index.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "carries 1 declared signature tokens (require 2)"; then
    record_pass "require_count=2 blocks single-token flagship"
else
    record_fail "require_count=2 case wrong: rc=$rc out='$out'"
fi

# ─── 10. require_count=2 satisfied when two tokens present ────────
new_repo "$TMP/s10"
seed_signature_md
cat > .process-engine.yaml <<'YAML'
signature_gate:
  require_count: 2
YAML
mkdir -p templates/marketing
cat > templates/marketing/index.html <<'HTML'
<div class="slate-headline">
  <span class="timecode-label">01:23:45</span>
  <h1>Product</h1>
</div>
HTML
git add docs/design/SIGNATURE.md .process-engine.yaml templates/marketing/index.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "two signatures present → require_count=2 OK"
else
    record_fail "two-signature case failed: rc=$rc out='$out'"
fi

# ─── 11. gate can be disabled via enabled=false ────────────────────
new_repo "$TMP/s11"
seed_signature_md
cat > .process-engine.yaml <<'YAML'
signature_gate:
  enabled: false
YAML
mkdir -p templates/marketing
echo '<div>no signature</div>' > templates/marketing/index.html
git add docs/design/SIGNATURE.md .process-engine.yaml templates/marketing/index.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "signature_gate.enabled=false → silent exit 0"
else
    record_fail "disabled case wrong: rc=$rc out='$out'"
fi

# ─── 12. bypass env var ────────────────────────────────────────────
new_repo "$TMP/s12"
seed_signature_md
mkdir -p templates/marketing
echo '<div>no signature</div>' > templates/marketing/index.html
git add docs/design/SIGNATURE.md templates/marketing/index.html
out=$(PE_SKIP_SIGNATURE_LINT=1 bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "PE_SKIP_SIGNATURE_LINT=1"; then
    record_pass "PE_SKIP_SIGNATURE_LINT=1 bypass with stderr notice"
else
    record_fail "bypass wrong: rc=$rc out='$out'"
fi

# ─── 13. PostToolUse mode: Write event on flagship path → BLOCK ────
new_repo "$TMP/s13"
seed_signature_md
mkdir -p templates/marketing
echo '<div>no signature</div>' > templates/marketing/index.html
event=$(python3 -c "
import json, os
print(json.dumps({
  'tool_name': 'Write',
  'tool_input': {'file_path': os.path.abspath('templates/marketing/index.html')},
}))
")
out=$(printf "%s" "$event" | bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "flagship file carries"; then
    record_pass "PostToolUse mode: Write event on flagship → BLOCK"
else
    record_fail "PostToolUse Write wrong: rc=$rc out='$out'"
fi

# ─── 14. PostToolUse mode: Bash event → silent skip ────────────────
new_repo "$TMP/s14"
seed_signature_md
event=$(python3 -c "
import json
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'ls'}}))
")
out=$(printf "%s" "$event" | bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "PostToolUse mode: Bash event skipped silently"
else
    record_fail "PostToolUse Bash wrong: rc=$rc out='$out'"
fi

# ─── 15. filename with spaces still checked (regression from D6) ───
new_repo "$TMP/s15"
seed_signature_md
mkdir -p templates/marketing
cat > "templates/marketing/hero page.html" <<'HTML'
<div>generic no signature</div>
HTML
git add docs/design/SIGNATURE.md "templates/marketing/hero page.html"
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "hero page.html"; then
    record_pass "filename with spaces on flagship path still BLOCKS"
else
    record_fail "space-in-filename bypass on flagship: rc=$rc out='$out'"
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
