#!/usr/bin/env bash
# tests/test_security_review_trailer.sh
#
# Coverage for hooks/security-review-trailer.sh, including the S3
# test-evidence gate shipped in v0.29.0.
#
# The hook is a commit-msg hook: it reads the message from arg $1 and
# inspects `git diff --cached --name-only`. We drive it here by
# staging real files in an ephemeral repo, writing a fake commit
# message file, and invoking the hook directly.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ENGINE_DIR/hooks/security-review-trailer.sh"
TMP="$(mktemp -d -t pe_srt_test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_security_review_trailer.sh — $HOOK"
echo ""

# ─── scenario helpers ───────────────────────────────────────────────
new_repo() {
    local d="$1"
    mkdir -p "$d"
    cd "$d"
    git init -q
    git config user.email "t@t"
    git config user.name t
    # Seed a base commit so `git diff --cached` behaves normally.
    echo seed > seed.txt
    git add seed.txt
    git -c commit.gpgsign=false commit -qm seed
}

msg_file() {
    local body="$1"
    local f
    f="$(mktemp -p "$TMP")"
    printf '%s\n' "$body" > "$f"
    echo "$f"
}

# ─── 1. non-security-touching commit passes silently ────────────────
new_repo "$TMP/s1"
echo hi > README.md
git add README.md
MSG=$(msg_file "docs: tweak readme")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "non-security paths pass silently (no trailer needed)"
else
    record_fail "non-security paths blocked (should be silent)"
fi

# ─── 2. auth path + no trailer → BLOCK ──────────────────────────────
new_repo "$TMP/s2"
mkdir -p modules/auth
echo "def login(): pass" > modules/auth/blueprints.py
git add modules/auth/blueprints.py
MSG=$(msg_file "feat: login endpoint")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_fail "auth+no-trailer accepted (should block)"
else
    record_pass "auth+no-trailer blocked"
fi

# ─── 3. auth path + Security-reviewed: security-reviewer → PASS ─────
new_repo "$TMP/s3"
mkdir -p modules/auth
echo "def login(): pass" > modules/auth/blueprints.py
git add modules/auth/blueprints.py
MSG=$(msg_file "feat: login endpoint

Security-reviewed: security-reviewer")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "auth+legacy-self-attest accepted"
else
    record_fail "auth+legacy-self-attest blocked (should accept)"
fi

# ─── 4. auth path + Security-skip-reason → PASS ─────────────────────
new_repo "$TMP/s4"
mkdir -p modules/auth
echo "def login(): pass" > modules/auth/blueprints.py
git add modules/auth/blueprints.py
MSG=$(msg_file "feat: login endpoint

Security-skip-reason: rename-only, no behavior change")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "auth+Security-skip-reason accepted"
else
    record_fail "auth+Security-skip-reason blocked (should accept)"
fi

# ─── 5. S3: payment path + trailer but NO tests → BLOCK ─────────────
new_repo "$TMP/s5"
mkdir -p modules/billing
echo "def charge(): pass" > modules/billing/service.py
git add modules/billing/service.py
MSG=$(msg_file "feat: billing service

Security-reviewed: security-reviewer")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_fail "billing+trailer+no-tests accepted (S3 gate broken)"
else
    record_pass "billing+trailer+no-tests blocked by S3 test-evidence gate"
fi

# ─── 6. S3: payment path + trailer + co-staged tests → PASS ─────────
new_repo "$TMP/s6"
mkdir -p modules/billing tests
echo "def charge(): pass" > modules/billing/service.py
echo "def test_charge(): pass" > tests/test_billing.py
git add modules/billing/service.py tests/test_billing.py
MSG=$(msg_file "feat: billing service + tests

Security-reviewed: security-reviewer")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "billing+trailer+co-staged-tests accepted"
else
    record_fail "billing+trailer+co-staged-tests blocked (should accept)"
fi

# ─── 7. S3: webhook path + trailer + Security-tests-skip-reason → PASS ─
new_repo "$TMP/s7"
mkdir -p modules/billing/webhooks
echo "# webhook shell" > modules/billing/webhooks/stripe.py
git add modules/billing/webhooks/stripe.py
MSG=$(msg_file "chore: rename webhook module

Security-reviewed: security-reviewer
Security-tests-skip-reason: rename-only, no behavior")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "webhook+Security-tests-skip-reason accepted"
else
    record_fail "webhook+Security-tests-skip-reason blocked (should accept)"
fi

# ─── 8. S3: payment path + Security-skip-reason blanket-skips test gate ─
new_repo "$TMP/s8"
mkdir -p modules/billing
echo "revert" > modules/billing/service.py
git add modules/billing/service.py
MSG=$(msg_file "revert: bad billing patch

Security-skip-reason: revert of e3c7a91")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "billing+Security-skip-reason blanket-skips test gate"
else
    record_fail "billing+Security-skip-reason blocked (blanket skip broken)"
fi

# ─── 9. S3: auth-only (no money) path does NOT require tests ────────
new_repo "$TMP/s9"
mkdir -p modules/auth
echo "def rotate_session(): pass" > modules/auth/blueprints.py
git add modules/auth/blueprints.py
MSG=$(msg_file "feat: session rotation

Security-reviewed: security-reviewer")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "auth-only path passes without tests (test gate is money-only)"
else
    record_fail "auth-only path required tests (should be money-only)"
fi

# ─── 10. S3 override: ENGINE_SECURITY_TEST_PATHS narrower regex ─────
new_repo "$TMP/s10"
mkdir -p modules/billing
echo "def charge(): pass" > modules/billing/service.py
git add modules/billing/service.py
MSG=$(msg_file "feat: billing

Security-reviewed: security-reviewer")
if ENGINE_SECURITY_TEST_PATHS='(this-will-never-match)' \
   bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "ENGINE_SECURITY_TEST_PATHS override respected"
else
    record_fail "override did not disengage test gate"
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
