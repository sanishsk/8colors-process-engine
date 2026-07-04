#!/usr/bin/env bash
# tests/test_motion_lint.sh — D6 motion-craft gate coverage.
#
# The hook has three responsibilities:
#   1. Detect motion signals across CSS / Tailwind / GSAP / Framer /
#      Motion / Lenis families.
#   2. Require a prefers-reduced-motion guard when motion is added —
#      either in the same file OR in a project-declared global guard
#      file.
#   3. WARN on effect-stacking (motion signals > cap).
#
# All checks are run through the pre-commit code path (staged files
# from git diff --cached), so each scenario stages a fresh file in an
# isolated git repo.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ENGINE_DIR/hooks/motion-lint.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_motion_lint.sh — $HOOK"
echo ""

new_repo() {
    # Fresh git repo, seeded with a base commit so `git diff --cached`
    # returns only the second-commit staging.
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

# ─── 1. non-UI commit passes silently ───────────────────────────────
new_repo "$TMP/s1"
echo "hello" > NOTES.md
git add NOTES.md
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "non-UI file → silent pass"
else
    record_fail "non-UI misfired: rc=$rc out='$out'"
fi

# ─── 2. UI file with no motion → silent pass ────────────────────────
new_repo "$TMP/s2"
cat > page.html <<'HTML'
<div class="text-lg font-semibold">Static content — no animation.</div>
HTML
git add page.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "UI file with zero motion signals → silent pass"
else
    record_fail "static UI misfired: rc=$rc out='$out'"
fi

# ─── 3. Tailwind animate-* without guard → BLOCK ────────────────────
new_repo "$TMP/s3"
cat > hero.html <<'HTML'
<div class="animate-pulse">Loading…</div>
HTML
git add hero.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "prefers-reduced-motion" \
                 && echo "$out" | grep -q "tw:animate-\*"; then
    record_pass "Tailwind animate-* + no guard → BLOCK naming the family"
else
    record_fail "animate-* miss: rc=$rc out='$out'"
fi

# ─── 4. Tailwind motion-safe: prefix on same class → guard OK ───────
new_repo "$TMP/s4"
cat > hero.html <<'HTML'
<div class="motion-safe:animate-pulse">Loading…</div>
HTML
git add hero.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "Tailwind motion-safe: prefix counts as authored guard"
else
    record_fail "motion-safe: not recognized: rc=$rc out='$out'"
fi

# ─── 5. CSS @keyframes + no guard → BLOCK ───────────────────────────
new_repo "$TMP/s5"
cat > animation.css <<'CSS'
@keyframes float {
  0% { transform: translateY(0) }
  50% { transform: translateY(-10px) }
  100% { transform: translateY(0) }
}
.hero { animation: float 3s ease-in-out infinite; }
CSS
git add animation.css
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "css:@keyframes"; then
    record_pass "CSS @keyframes + no guard → BLOCK"
else
    record_fail "@keyframes miss: rc=$rc out='$out'"
fi

# ─── 6. CSS @keyframes + @media guard in same file → OK ─────────────
new_repo "$TMP/s6"
cat > animation.css <<'CSS'
@keyframes float { 0% { transform: translateY(0) } 100% { transform: translateY(-10px) } }
.hero { animation: float 3s ease-in-out infinite; }

@media (prefers-reduced-motion: reduce) {
  .hero { animation: none; }
}
CSS
git add animation.css
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "CSS @keyframes + same-file @media guard → OK"
else
    record_fail "same-file guard not recognized: rc=$rc out='$out'"
fi

# ─── 7. GSAP + no guard → BLOCK ─────────────────────────────────────
new_repo "$TMP/s7"
cat > hero.jsx <<'JSX'
import gsap from "gsap";
export function Hero() {
  useEffect(() => { gsap.to(".hero", { y: -20, duration: 1 }); }, []);
  return <div className="hero">Hero</div>;
}
JSX
git add hero.jsx
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "gsap"; then
    record_pass "GSAP call + no guard → BLOCK naming gsap"
else
    record_fail "gsap miss: rc=$rc out='$out'"
fi

# ─── 8. matchMedia guard in JS → OK ─────────────────────────────────
new_repo "$TMP/s8"
cat > hero.jsx <<'JSX'
import gsap from "gsap";
const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
export function Hero() {
  useEffect(() => {
    if (!reduced) gsap.to(".hero", { y: -20, duration: 1 });
  }, []);
  return <div className="hero">Hero</div>;
}
JSX
git add hero.jsx
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "matchMedia prefers-reduced-motion check → guard OK"
else
    record_fail "matchMedia guard not recognized: rc=$rc out='$out'"
fi

# ─── 9. Framer-motion import + guard → OK ───────────────────────────
new_repo "$TMP/s9"
cat > modal.tsx <<'TSX'
import { motion, AnimatePresence } from "framer-motion";
const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
export function Modal() {
  const initial = reduced ? {} : { opacity: 0, y: 20 };
  const animate = reduced ? {} : { opacity: 1, y: 0 };
  return (
    <AnimatePresence>
      <motion.div initial={initial} animate={animate} />
    </AnimatePresence>
  );
}
TSX
git add modal.tsx
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "framer-motion + JS guard → OK"
else
    record_fail "framer-motion guard miss: rc=$rc out='$out'"
fi

# ─── 10. transition-colors alone does NOT trigger the gate ──────────
# transition-colors is used for hover-state color changes and doesn't
# meet the WCAG motion threshold on its own. If it's the ONLY motion
# signal, no guard should be required.
new_repo "$TMP/s10"
cat > button.html <<'HTML'
<button class="transition-colors hover:bg-blue-500">Click</button>
HTML
git add button.html
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "transition-colors alone → no gate fire"
else
    record_fail "transition-colors falsely fired: rc=$rc out='$out'"
fi

# ─── 11. global guard file resolves the requirement ─────────────────
# Project declares a global CSS file that holds the reduced-motion
# rules. Individual files that add motion should NOT need a per-file
# guard when the global file is declared + present + contains the rule.
new_repo "$TMP/s11"
mkdir -p static/css
cat > static/css/reduced-motion.css <<'CSS'
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
}
CSS
cat > .process-engine.yaml <<'YAML'
motion_gate:
  enabled: true
  global_guard_file: static/css/reduced-motion.css
YAML
cat > hero.html <<'HTML'
<div class="animate-pulse">Loading…</div>
HTML
git add hero.html static/css/reduced-motion.css .process-engine.yaml
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "global_guard_file → per-file guard no longer required"
else
    record_fail "global guard file not honored: rc=$rc out='$out'"
fi

# ─── 12. effect-stacking WARN when signals exceed cap ───────────────
new_repo "$TMP/s12"
cat > hero.html <<'HTML'
<div class="motion-safe:transition-all motion-safe:animate-pulse motion-safe:animate-bounce motion-safe:animate-ping motion-safe:animate-fade-in motion-safe:animate-slide-in motion-safe:transition-transform motion-safe:transition-opacity motion-safe:animate-spin motion-safe:animate-wiggle motion-safe:animate-float motion-safe:transition-colors">
  many effects, all guarded
</div>
HTML
git add hero.html
out=$(bash "$HOOK" 2>&1)
rc=$?
# Guarded (motion-safe: everywhere) so no BLOCK — but effect count
# exceeds default cap of 10 → WARN.
if [ $rc -eq 0 ] && echo "$out" | grep -q "effect-stacking"; then
    record_pass "many signals but guarded → WARN on effect-stacking, exit 0"
else
    record_fail "effect-stacking WARN missing: rc=$rc out='$out'"
fi

# ─── 13. PE_SKIP_MOTION_LINT=1 bypass ───────────────────────────────
new_repo "$TMP/s13"
cat > hero.html <<'HTML'
<div class="animate-pulse">unguarded</div>
HTML
git add hero.html
out=$(PE_SKIP_MOTION_LINT=1 bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "PE_SKIP_MOTION_LINT"; then
    record_pass "PE_SKIP_MOTION_LINT=1 bypass with stderr notice"
else
    record_fail "bypass wrong: rc=$rc out='$out'"
fi

# ─── 14. motion_gate.enabled=false disables the gate ────────────────
new_repo "$TMP/s14"
cat > .process-engine.yaml <<'YAML'
motion_gate:
  enabled: false
YAML
cat > hero.html <<'HTML'
<div class="animate-pulse">unguarded but disabled</div>
HTML
git add hero.html .process-engine.yaml
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "motion_gate.enabled=false → silent exit 0"
else
    record_fail "disabled gate still fired: rc=$rc out='$out'"
fi

# ─── 15. PostToolUse: Write event for UI file with motion → BLOCK ────
new_repo "$TMP/s15"
cat > hero.html <<'HTML'
<div class="animate-pulse">unguarded</div>
HTML
git add hero.html
# Build a Claude Code PostToolUse event JSON on stdin.
event=$(python3 -c '
import json
print(json.dumps({
  "tool_name": "Write",
  "tool_input": {"file_path": "'"$PWD/hero.html"'"},
}))
')
out=$(printf "%s" "$event" | bash "$HOOK" 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "prefers-reduced-motion"; then
    record_pass "PostToolUse mode: Write event on motion-only file → BLOCK"
else
    record_fail "PostToolUse mode miss: rc=$rc out='$out'"
fi

# ─── 16. PostToolUse: Bash event ignored ────────────────────────────
new_repo "$TMP/s16"
cat > hero.html <<'HTML'
<div class="animate-pulse">unguarded</div>
HTML
git add hero.html
event=$(python3 -c '
import json
print(json.dumps({
  "tool_name": "Bash",
  "tool_input": {"command": "ls"},
}))
')
out=$(printf "%s" "$event" | bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    record_pass "PostToolUse mode: Bash event skipped silently"
else
    record_fail "PostToolUse Bash misfired: rc=$rc out='$out'"
fi

# ─── 17. filename with spaces still checked (WCAG bypass regression) ─
# Reviewer flag: unquoted argv expansion would silently drop this file
# and pass a commit that should BLOCK. File list now travels via env
# var so filenames with spaces survive intact.
new_repo "$TMP/s17"
cat > "my animated hero.html" <<'HTML'
<div class="animate-spin">unguarded motion in a spaced filename</div>
HTML
git add "my animated hero.html"
out=$(bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "my animated hero.html"; then
    record_pass "filename with spaces still triggers BLOCK (space-in-name regression)"
else
    record_fail "space-in-filename bypass: rc=$rc out='$out'"
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
