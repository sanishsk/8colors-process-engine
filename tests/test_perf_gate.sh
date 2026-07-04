#!/usr/bin/env bash
# tests/test_perf_gate.sh — PF1 perf-gate commit-msg trailer hook.
#
# Contract:
#   - Non-ORM path commit passes silently (no trailer required).
#   - ORM / query / migration path staged + no trailer → BLOCKS with
#     a message pointing at the query-count template.
#   - `Perf-tested: query-count` legacy self-attest → ACCEPTED.
#   - `Perf-tested: <sha>` resolves against .claude/gates/perf.json
#     or last-gate.json → ACCEPTED on PASS/WARN verdict.
#   - `Perf-skip-reason: <text>` → ACCEPTED (explicit skip).
#   - Path regex overridable via ENGINE_PERF_PATHS.
#   - Test files under tests/ do NOT trigger the gate (they're the
#     evidence, not the risk).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ENGINE_DIR/hooks/perf-gate.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_perf_gate.sh — $HOOK"
echo ""

new_repo() {
    local d="$1"
    mkdir -p "$d"
    cd "$d"
    git init -q
    git config user.email "t@t"
    git config user.name t
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

# ─── 1. non-ORM path commit passes silently ─────────────────────────
new_repo "$TMP/s1"
echo hi > README.md
git add README.md
MSG=$(msg_file "docs: readme tweak")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "non-ORM paths pass silently (no trailer needed)"
else
    record_fail "non-ORM paths blocked (should be silent)"
fi

# ─── 2. model path + no trailer → BLOCKED ────────────────────────────
new_repo "$TMP/s2"
mkdir -p modules/billing/models
echo "class Charge: pass" > modules/billing/models/payment.py
git add modules/billing/models/payment.py
MSG=$(msg_file "feat: charge model")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_fail "model+no-trailer accepted (should block)"
else
    record_pass "model+no-trailer blocked with hint"
fi

# ─── 3. migration path + Perf-tested: query-count → ACCEPTED ────────
new_repo "$TMP/s3"
mkdir -p modules/billing/migrations
echo "-- sql" > modules/billing/migrations/migrate_charges.py
git add modules/billing/migrations/migrate_charges.py
MSG=$(msg_file "feat: migration

Perf-tested: query-count")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "migration+legacy-self-attest accepted"
else
    record_fail "migration+legacy-self-attest blocked (should accept)"
fi

# ─── 4. ORM path + Perf-skip-reason → ACCEPTED ──────────────────────
new_repo "$TMP/s4"
mkdir -p modules/billing
echo "def q(): pass" > modules/billing/query.py
git add modules/billing/query.py
MSG=$(msg_file "chore: rename

Perf-skip-reason: rename-only, no query change")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "ORM+Perf-skip-reason accepted"
else
    record_fail "Perf-skip-reason blocked (should accept)"
fi

# ─── 5. serializer path + no trailer → BLOCKED ──────────────────────
new_repo "$TMP/s5"
mkdir -p modules/orders
echo "class OrderSerializer: pass" > modules/orders/serializer.py
git add modules/orders/serializer.py
MSG=$(msg_file "feat: order list serializer")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_fail "serializer+no-trailer accepted (indirect N+1 risk)"
else
    record_pass "serializer+no-trailer blocked (indirect N+1 catch)"
fi

# ─── 6. tests/ path NOT triggering the gate ─────────────────────────
new_repo "$TMP/s6"
mkdir -p tests
echo "def test_x(): pass" > tests/test_billing_models.py
git add tests/test_billing_models.py
MSG=$(msg_file "test: cover charge model")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "tests/ path exempt (evidence, not risk)"
else
    record_fail "tests/ path wrongly gated"
fi

# ─── 7. ENGINE_PERF_PATHS override disengages the gate ──────────────
new_repo "$TMP/s7"
mkdir -p modules/billing
echo "x=1" > modules/billing/models.py
git add modules/billing/models.py
MSG=$(msg_file "feat: model")
if ENGINE_PERF_PATHS='(will-not-match)' bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "ENGINE_PERF_PATHS override respected"
else
    record_fail "override did not disengage gate"
fi

# ─── 8. bogus sha in Perf-tested → BLOCKED ──────────────────────────
new_repo "$TMP/s8"
mkdir -p modules/billing
echo "x=1" > modules/billing/models.py
git add modules/billing/models.py
MSG=$(msg_file "feat: model

Perf-tested: not-a-real-sha!!!")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_fail "bogus trailer sha accepted"
else
    record_pass "bogus trailer sha rejected"
fi

# ─── 9. valid sha resolving to PASS envelope → ACCEPTED ─────────────
new_repo "$TMP/s9"
mkdir -p modules/billing .claude/gates
echo "x=1" > modules/billing/models.py
git add modules/billing/models.py
# Build a fake gate envelope, capture its sha256 prefix.
echo '{"verdict":"PASS","gate_name":"perf"}' > .claude/gates/perf.json
git add .claude/gates/perf.json
SHA=$(shasum -a 256 .claude/gates/perf.json | awk '{print $1}')
SHA_PREFIX="${SHA:0:16}"
MSG=$(msg_file "feat: model

Perf-tested: $SHA_PREFIX")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "Perf-tested: <sha> resolves to PASS envelope"
else
    record_fail "valid sha not resolving: sha=$SHA_PREFIX"
fi

# ─── 10. valid sha resolving to FAIL envelope → BLOCKED ─────────────
new_repo "$TMP/s10"
mkdir -p modules/billing .claude/gates
echo "x=1" > modules/billing/models.py
git add modules/billing/models.py
echo '{"verdict":"FAIL","gate_name":"perf"}' > .claude/gates/perf.json
git add .claude/gates/perf.json
SHA=$(shasum -a 256 .claude/gates/perf.json | awk '{print $1}')
SHA_PREFIX="${SHA:0:16}"
MSG=$(msg_file "feat: model

Perf-tested: $SHA_PREFIX")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_fail "FAIL-verdict envelope accepted (should block)"
else
    record_pass "FAIL-verdict envelope blocks the commit"
fi

# ─── 11. valid sha resolving to envelope with NO verdict → BLOCKED ──
new_repo "$TMP/s11"
mkdir -p modules/billing .claude/gates
echo "x=1" > modules/billing/models.py
git add modules/billing/models.py
echo '{"gate_name":"perf"}' > .claude/gates/perf.json
git add .claude/gates/perf.json
SHA=$(shasum -a 256 .claude/gates/perf.json | awk '{print $1}')
SHA_PREFIX="${SHA:0:16}"
MSG=$(msg_file "feat: model

Perf-tested: $SHA_PREFIX")
out=$(bash "$HOOK" "$MSG" 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "missing or has an empty"; then
    record_pass "missing verdict → block with sharpened message (reviewer MEDIUM)"
else
    record_fail "missing-verdict handling wrong: rc=$rc out='$out'"
fi

# ─── 12. openapi.json / JSON schema files do NOT trigger the gate ───
# Reviewer HIGH: `schema` bare-match false-positived on API docs and
# JSON-schema validator libraries. Regex is now scoped to Python /
# SQL data-layer conventions.
new_repo "$TMP/s12"
mkdir -p src/schemas
echo '{"openapi":"3.0"}' > src/schemas/openapi.json
git add src/schemas/openapi.json
MSG=$(msg_file "docs: bump openapi spec")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass "openapi.json under schemas/ does NOT trigger perf-gate"
else
    record_fail "openapi.json false-positived (reviewer HIGH regressed)"
fi

# ─── 13. protobuf .proto file also exempt ───────────────────────────
new_repo "$TMP/s13"
mkdir -p proto
echo 'message User { }' > proto/user.proto
git add proto/user.proto
MSG=$(msg_file "chore: proto tweak")
if bash "$HOOK" "$MSG" >/dev/null 2>&1; then
    record_pass ".proto files do NOT trigger perf-gate"
else
    record_fail ".proto false-positived"
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
