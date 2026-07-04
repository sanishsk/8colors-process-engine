#!/usr/bin/env bash
# tests/test_sast_scan.sh — S1 sast-scan hook, focused on the
# v0.36.0 "no tool installed → fail visibly" fix.
#
# Before this release, staged security-sensitive files with zero
# installed SAST tools produced ONE advisory line and then exit 0.
# That was false confidence on the #1-priority security gate.
# v0.36.0 refuses the commit in that state unless PE_SKIP_SAST=1
# is set explicitly (audit trail).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ENGINE_DIR/hooks/sast-scan.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_sast_scan.sh — $HOOK"
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

# We simulate "no SAST tools installed" by prepending an empty PATH
# entry so `command -v semgrep/bandit/gosec/npx` all return failure.
# Keep /bin + /usr/bin so basic shell / git still work.
NO_TOOLS_PATH="/bin:/usr/bin"

# ─── 1. non-source commit passes silently ───────────────────────────
new_repo "$TMP/s1"
echo hi > README.md
git add README.md
out=$(PATH="$NO_TOOLS_PATH" bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "no source files → silent pass (no SAST needed)"
else
    record_fail "non-source commit misfired: rc=$rc out='$out'"
fi

# ─── 2. Python file staged + no tools → BLOCK (the fix) ─────────────
new_repo "$TMP/s2"
echo "def x(): return 1" > module.py
git add module.py
out=$(PATH="$NO_TOOLS_PATH" bash "$HOOK" 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "BLOCK"; then
    record_pass "Python source + no tools → BLOCK with hint"
else
    record_fail "silent-pass regressed (reviewer fix broken): rc=$rc out='$out'"
fi

# ─── 3. block message names PE_SKIP_SAST bypass ─────────────────────
if echo "$out" | grep -q "PE_SKIP_SAST=1"; then
    record_pass "block message advertises PE_SKIP_SAST=1 bypass"
else
    record_fail "block message missing bypass hint: '$out'"
fi

# ─── 4. block message names install commands ────────────────────────
if echo "$out" | grep -q "pipx install semgrep bandit"; then
    record_pass "block message advertises install commands"
else
    record_fail "block message missing install hint"
fi

# ─── 5. block message names the detected surface ────────────────────
if echo "$out" | grep -q "module.py"; then
    record_pass "block message names the staged surface"
else
    record_fail "block message doesn't name staged surface: '$out'"
fi

# ─── 6. PE_SKIP_SAST=1 bypass exits 0 (audit trail) ─────────────────
out=$(PATH="$NO_TOOLS_PATH" PE_SKIP_SAST=1 bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "PE_SKIP_SAST=1"; then
    record_pass "PE_SKIP_SAST=1 bypasses cleanly with stderr notice"
else
    record_fail "PE_SKIP_SAST bypass wrong: rc=$rc out='$out'"
fi

# ─── 7. Go file + no tools → BLOCK ──────────────────────────────────
new_repo "$TMP/s7"
echo "package main" > main.go
git add main.go
out=$(PATH="$NO_TOOLS_PATH" bash "$HOOK" 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "BLOCK"; then
    record_pass "Go source + no tools → BLOCK"
else
    record_fail "Go path missed block: rc=$rc"
fi

# ─── 8. JS file + no tools → BLOCK ──────────────────────────────────
new_repo "$TMP/s8"
echo "const x=1;" > app.js
git add app.js
out=$(PATH="$NO_TOOLS_PATH" bash "$HOOK" 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "BLOCK"; then
    record_pass "JS source + no tools → BLOCK"
else
    record_fail "JS path missed block: rc=$rc"
fi

# ─── 9. sast_gate.enabled=false disables the gate cleanly ───────────
new_repo "$TMP/s9"
echo "def x(): return 1" > module.py
git add module.py
cat > .process-engine.yaml <<'EOF'
sast_gate:
  enabled: false
EOF
out=$(PATH="$NO_TOOLS_PATH" bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "sast_gate.enabled=false in yaml → silent exit 0"
else
    record_fail "yaml-disabled gate still fired: rc=$rc out='$out'"
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
