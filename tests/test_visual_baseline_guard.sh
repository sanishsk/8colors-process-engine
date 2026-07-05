#!/usr/bin/env bash
# tests/test_visual_baseline_guard.sh — D3 reference-must-exist gate
# coverage (v0.45.0).
#
# The hook is ADVISORY only — always exit 0. What matters is the WARN
# text firing under the right conditions, so tests assert on stderr
# content instead of exit codes.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ENGINE_DIR/hooks/visual-baseline-guard.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_visual_baseline_guard.sh — $HOOK"
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

seed_optin() {
    mkdir -p docs/design/reference
    cat > docs/design/reference/README.md <<'MD'
# reference lock
(opt-in signal — presence turns the guard on)
MD
}

seed_flagship_config() {
    cat > .process-engine.yaml <<'YAML'
visual_baseline:
  enabled: true
  flagship_pages:
    - home
    - pricing
    - dashboard
  reference_dir: docs/design/reference
YAML
}

# ─── 1. no reference README → gate inert (silent exit 0) ────────────
new_repo "$TMP/s1"
seed_flagship_config
mkdir -p templates
echo "<div>home</div>" > templates/home.html
git add .process-engine.yaml templates/home.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "no docs/design/reference/README.md → gate inert (silent)"
else
    record_fail "opt-out case wrong: rc=$rc out='$out'"
fi

# ─── 2. no flagship_pages declared → nothing to guard ───────────────
new_repo "$TMP/s2"
seed_optin
mkdir -p templates
echo "<div>home</div>" > templates/home.html
git add docs/design/reference/README.md templates/home.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "opt-in signal present but no flagship_pages → silent"
else
    record_fail "no-flagship-pages case wrong: rc=$rc out='$out'"
fi

# ─── 3. flagship page edited, no reference PNG → WARN ───────────────
new_repo "$TMP/s3"
seed_optin
seed_flagship_config
mkdir -p templates
echo "<div>home page</div>" > templates/home.html
git add docs/design/reference/README.md .process-engine.yaml templates/home.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "no locked reference exists"; then
    record_pass "flagship page + no ref PNG → WARN (still exit 0)"
else
    record_fail "warn case wrong: rc=$rc out='$out'"
fi

# ─── 4. flagship page + reference PNG present → silent OK ──────────
new_repo "$TMP/s4"
seed_optin
seed_flagship_config
# Create a fake reference PNG for the "home" slug
: > docs/design/reference/home.png
mkdir -p templates
echo "<div>home page</div>" > templates/home.html
git add docs/design/reference/README.md docs/design/reference/home.png \
    .process-engine.yaml templates/home.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "flagship page + ref PNG exists → silent OK"
else
    record_fail "ref-present case wrong: rc=$rc out='$out'"
fi

# ─── 5. non-flagship page → silent even without ref ────────────────
new_repo "$TMP/s5"
seed_optin
seed_flagship_config
mkdir -p templates
echo "<div>not a flagship</div>" > templates/random.html
git add docs/design/reference/README.md .process-engine.yaml templates/random.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "non-flagship page → not guarded (silent)"
else
    record_fail "non-flagship case wrong: rc=$rc out='$out'"
fi

# ─── 6. parent-dir slug match (templates/pricing/index.html) ──────
new_repo "$TMP/s6"
seed_optin
seed_flagship_config
mkdir -p templates/pricing
echo "<div>pricing page</div>" > templates/pricing/index.html
git add docs/design/reference/README.md .process-engine.yaml templates/pricing/index.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "'pricing'"; then
    record_pass "parent-dir slug match — templates/pricing/index.html hits pricing"
else
    record_fail "parent-dir match wrong: rc=$rc out='$out'"
fi

# ─── 7. multiple flagship pages missing refs → multiple WARNs ─────
new_repo "$TMP/s7"
seed_optin
seed_flagship_config
mkdir -p templates
echo "<div>home</div>" > templates/home.html
echo "<div>dashboard</div>" > templates/dashboard.html
git add docs/design/reference/README.md .process-engine.yaml templates/home.html templates/dashboard.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] \
   && echo "$out" | grep -q "'home'" \
   && echo "$out" | grep -q "'dashboard'" \
   && echo "$out" | grep -q "2 flagship page(s) edited"; then
    record_pass "multiple flagship warnings surfaced + counter correct"
else
    record_fail "multi-warn case wrong: rc=$rc out='$out'"
fi

# ─── 8. gate can be disabled via enabled=false ────────────────────
new_repo "$TMP/s8"
seed_optin
cat > .process-engine.yaml <<'YAML'
visual_baseline:
  enabled: false
  flagship_pages:
    - home
YAML
mkdir -p templates
echo "<div>home</div>" > templates/home.html
git add docs/design/reference/README.md .process-engine.yaml templates/home.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "visual_baseline.enabled=false → silent"
else
    record_fail "disabled case wrong: rc=$rc out='$out'"
fi

# ─── 9. bypass env var ────────────────────────────────────────────
new_repo "$TMP/s9"
seed_optin
seed_flagship_config
mkdir -p templates
echo "<div>home</div>" > templates/home.html
git add docs/design/reference/README.md .process-engine.yaml templates/home.html
out=$(PE_SKIP_VISUAL_BASELINE=1 bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "PE_SKIP_VISUAL_BASELINE=1"; then
    record_pass "PE_SKIP_VISUAL_BASELINE=1 bypass with stderr notice"
else
    record_fail "bypass wrong: rc=$rc out='$out'"
fi

# ─── 10. PostToolUse Write event on flagship path → WARN ─────────
new_repo "$TMP/s10"
seed_optin
seed_flagship_config
mkdir -p templates
echo "<div>home</div>" > templates/home.html
event=$(python3 -c "
import json, os
print(json.dumps({
  'tool_name': 'Write',
  'tool_input': {'file_path': os.path.abspath('templates/home.html')},
}))
")
out=$(printf "%s" "$event" | bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "no locked reference exists"; then
    record_pass "PostToolUse Write on flagship → WARN"
else
    record_fail "PostToolUse Write wrong: rc=$rc out='$out'"
fi

# ─── 11. PostToolUse Bash event → silent ─────────────────────────
event=$(python3 -c "
import json
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'ls'}}))
")
out=$(printf "%s" "$event" | bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "PostToolUse Bash event skipped silently"
else
    record_fail "PostToolUse Bash wrong: rc=$rc out='$out'"
fi

# ─── 12. filename with spaces still checked (D6 regression pattern) ─
new_repo "$TMP/s12"
seed_optin
seed_flagship_config
mkdir -p templates
cat > "templates/home page.html" <<'HTML'
<div>home with spaces</div>
HTML
git add docs/design/reference/README.md .process-engine.yaml "templates/home page.html"
out=$(bash "$HOOK" 2>&1)
rc=$?
# Slug is "home page" not "home" — so this specific file doesn't match
# the flagship list. Correct behavior is silent. This locks in the
# stem-based slug rule and verifies filenames with spaces don't crash.
if [ $rc -eq 0 ]; then
    record_pass "filename with spaces doesn't crash the hook"
else
    record_fail "space-in-filename crashed: rc=$rc out='$out'"
fi

# ─── 13. path-traversal slug rejected (v0.45.0 reviewer HIGH) ────
new_repo "$TMP/s13"
seed_optin
cat > .process-engine.yaml <<'YAML'
visual_baseline:
  enabled: true
  flagship_pages:
    - "../../../etc/passwd"
    - home
YAML
mkdir -p templates
echo "<div>home</div>" > templates/home.html
# The traversal slug in flagship_pages ("../../../etc/passwd") is what's
# under test — the guard must NOT resolve <ref_dir>/../../../etc/passwd.png
# and must NOT emit stderr mentioning that path. `home` in the list still
# matches templates/home.html and produces the expected WARN.
git add docs/design/reference/README.md .process-engine.yaml templates/home.html
out=$(bash "$HOOK" 2>&1)
rc=$?
# Expect: home WARN emitted, traversal slug skipped or rejected — the
# stderr must NOT show `etc/passwd` as an accessed file.
if [ $rc -eq 0 ] \
   && echo "$out" | grep -q "'home'" \
   && ! echo "$out" | grep -q "docs/design/reference/etc/passwd"; then
    record_pass "path-traversal flagship slug does not resolve outside reference_dir"
else
    record_fail "path-traversal case wrong: rc=$rc out='$out'"
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
