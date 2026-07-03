#!/usr/bin/env bash
# test_pe_new.sh — smoke tests for A6 (pe new + pe module add).
#
# Uses tempdirs; never touches the operator's real project tree.
# Every scenario passes --no-install so we don't chain into pe install
# (that's covered by test_pe_install_reconcile.sh separately).

set -uo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PE="$ENGINE_DIR/scripts/pe"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_pe_new.sh — $PE"
echo ""

# ─── 1. pe new python-flask ─────────────────────────────────────────────
scenario1="$WORK/s1"
mkdir -p "$scenario1"
cd "$scenario1"

if "$PE" new "Smoke Test" --stack python-flask --no-install --tagline "one-line" \
     > /dev/null 2>&1; then
    if [ -d "smoke-test" ]; then
        record_pass "python-flask scaffold creates slugified directory"
    else
        record_fail "python-flask: smoke-test/ not created"
    fi
    for expected in README.md pyproject.toml run.py CLAUDE.md .gitignore .env.example \
                    modules/__init__.py tests/__init__.py tests/test_smoke.py; do
        if [ -f "smoke-test/$expected" ]; then
            record_pass "python-flask ships $expected"
        else
            record_fail "python-flask MISSING $expected"
        fi
    done
    # Placeholder substitution: README should include the display name.
    if grep -q "Smoke Test" smoke-test/README.md; then
        record_pass "PROJECT_NAME substituted into README"
    else
        record_fail "PROJECT_NAME not substituted"
    fi
    if grep -q "one-line" smoke-test/README.md; then
        record_pass "PROJECT_TAGLINE substituted into README"
    else
        record_fail "PROJECT_TAGLINE not substituted"
    fi
    if grep -q "smoke-test" smoke-test/pyproject.toml; then
        record_pass "PROJECT_SLUG substituted into pyproject.toml"
    else
        record_fail "PROJECT_SLUG not substituted"
    fi
    # git init should have happened.
    if [ -d "smoke-test/.git" ]; then
        record_pass "git init ran"
    else
        record_fail "git init did not run"
    fi
else
    record_fail "python-flask scaffold exited non-zero"
fi

# ─── 2. pe new generic ──────────────────────────────────────────────────
scenario2="$WORK/s2"
mkdir -p "$scenario2"
cd "$scenario2"
if "$PE" new "Generic Proj" --stack generic --no-install > /dev/null 2>&1; then
    if [ -f "generic-proj/README.md" ] && [ -f "generic-proj/CLAUDE.md" ]; then
        record_pass "generic scaffold ships baseline files"
    else
        record_fail "generic scaffold missing baseline files"
    fi
    # Generic must NOT ship python-specific pyproject.toml.
    if [ ! -f "generic-proj/pyproject.toml" ]; then
        record_pass "generic scaffold excludes python-specific files"
    else
        record_fail "generic scaffold leaked python-specific files"
    fi
else
    record_fail "generic scaffold exited non-zero"
fi

# ─── 3. refuse to overwrite non-empty target ────────────────────────────
scenario3="$WORK/s3"
mkdir -p "$scenario3/dup-target"
touch "$scenario3/dup-target/existing.txt"
cd "$scenario3"
set +e
"$PE" new "Dup Target" --stack generic --no-install > /dev/null 2>&1
rc=$?
set -e
if [ $rc -eq 1 ]; then
    record_pass "refuses to overwrite non-empty target"
else
    record_fail "did not refuse overwrite (rc=$rc)"
fi

# ─── 4. unknown stack rejected ──────────────────────────────────────────
scenario4="$WORK/s4"
mkdir -p "$scenario4"
cd "$scenario4"
set +e
"$PE" new "X" --stack nonexistent-stack --no-install > /dev/null 2>&1
rc=$?
set -e
if [ $rc -eq 3 ]; then
    record_pass "unknown --stack rejected with exit 3"
else
    record_fail "unknown --stack did not return exit 3 (got $rc)"
fi

# ─── 5. pe module add materializes files ────────────────────────────────
scenario5="$WORK/s5"
mkdir -p "$scenario5"
cd "$scenario5"
"$PE" new "Mod Target" --stack python-flask --no-install > /dev/null 2>&1
cd mod-target
if "$PE" module add api-credentials > /dev/null 2>&1; then
    for expected in README.md credential_service.py \
                    models/api_credential.py \
                    blueprints/admin_credentials.py \
                    templates_admin/api_credentials.html \
                    migrations/migrate_api_credentials.py \
                    tests/test_api_credentials.py; do
        if [ -f "modules/api_credentials/$expected" ]; then
            record_pass "module add materialized $expected"
        else
            record_fail "module add MISSING $expected"
        fi
    done
else
    record_fail "pe module add api-credentials exited non-zero"
fi

# ─── 6. pe module add is idempotent (skips existing) ────────────────────
cd "$WORK/s5/mod-target"
set +e
out=$("$PE" module add api-credentials 2>&1)
set -e
if echo "$out" | grep -qi "skipped"; then
    record_pass "second module add reports skipped (no overwrite)"
else
    record_fail "second module add did not skip existing files"
fi

# ─── 7. unknown module rejected ─────────────────────────────────────────
set +e
"$PE" module add no-such-module > /dev/null 2>&1
rc=$?
set -e
if [ $rc -eq 3 ]; then
    record_pass "unknown module rejected with exit 3"
else
    record_fail "unknown module did not return exit 3 (got $rc)"
fi

# ─── 8. pycache in template does not break scaffold ─────────────────────
# Regression: v0.25.0 reviewer caught a stray __pycache__/ in a
# template that would crash `pe module add` with UnicodeDecodeError.
# The walker now prunes __pycache__ before descent — verify a rogue
# pycache in an ad-hoc template location doesn't leak into the output.
scenario8="$WORK/s8"
mkdir -p "$scenario8"
cd "$scenario8"
"$PE" new "Pycache Test" --stack python-flask --no-install > /dev/null 2>&1
# Deliberately create a __pycache__ inside the SCAFFOLDED tree; then
# re-run pe module add — the module add must not choke on the tree
# and must not copy __pycache__ into modules/api_credentials/.
mkdir -p pycache-test/__pycache__
touch pycache-test/__pycache__/leaked.pyc
cd pycache-test
set +e
"$PE" module add api-credentials > /dev/null 2>&1
rc=$?
set -e
if [ $rc -eq 0 ] && [ ! -d "modules/api_credentials/__pycache__" ]; then
    record_pass "walker skips __pycache__ (no crash, no leak)"
else
    record_fail "walker did not skip __pycache__ (rc=$rc)"
fi

# ─── summary ────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  passed: $pass"
echo "  failed: $fail"
if [ $fail -gt 0 ]; then
    for f in "${failures[@]}"; do echo "    - $f"; done
    exit 1
fi
exit 0
