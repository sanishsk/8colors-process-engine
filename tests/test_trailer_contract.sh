#!/usr/bin/env bash
# tests/test_trailer_contract.sh — hooks/_trailer-contract.sh helpers.
#
# The extraction from four trailer hooks (code / security / design /
# perf) into a single shared file is only safe if the contract-level
# behavior is preserved. These tests fire the helpers directly (via
# source) instead of driving each hook so we can cover corners the
# per-hook tests don't reach.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
HELPER="$ENGINE_DIR/hooks/_trailer-contract.sh"

# shellcheck source=/dev/null
. "$HELPER"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_trailer_contract.sh — $HELPER"
echo ""

# ─── pe_trailer_is_sha ──────────────────────────────────────────────
if pe_trailer_is_sha "0123456789abcdef"; then
    record_pass "is_sha accepts 16-char hex"
else
    record_fail "is_sha rejected 16-char hex"
fi

if pe_trailer_is_sha "0A1B2C3D"; then
    record_pass "is_sha accepts 8-char (mixed case)"
else
    record_fail "is_sha rejected 8-char mixed case"
fi

if ! pe_trailer_is_sha "not-a-sha"; then
    record_pass "is_sha rejects non-hex"
else
    record_fail "is_sha accepted non-hex"
fi

if ! pe_trailer_is_sha "0123456"; then
    record_pass "is_sha rejects 7-char (below 8-char floor)"
else
    record_fail "is_sha accepted too-short input"
fi

if ! pe_trailer_is_sha ""; then
    record_pass "is_sha rejects empty"
else
    record_fail "is_sha accepted empty"
fi

# ─── pe_trailer_resolve_record ──────────────────────────────────────
proj="$TMP/proj"
mkdir -p "$proj/.claude/gates"
cd "$proj"
git init -q
# macOS: /var/folders/... is a symlink to /private/var/folders/...
# git rev-parse --show-toplevel canonicalizes; match here.
proj=$(git rev-parse --show-toplevel)
git config user.email t@t
git config user.name t

# Named record — sha prefix matches
echo '{"verdict":"PASS"}' > .claude/gates/named-a.json
NAMED_A_SHA=$(shasum -a 256 .claude/gates/named-a.json | awk '{print $1}')
NAMED_A_PREFIX="${NAMED_A_SHA:0:12}"

RECORD=$(pe_trailer_resolve_record "$NAMED_A_PREFIX" ".claude/gates/named-a.json")
if [ "$RECORD" = "$proj/.claude/gates/named-a.json" ]; then
    record_pass "resolve: named record with matching sha prefix returns path"
else
    record_fail "named-a lookup wrong: got '$RECORD'"
fi

# Named record — sha prefix doesn't match → falls through
RECORD=$(pe_trailer_resolve_record "deadbeefdead" ".claude/gates/named-a.json")
if [ -z "$RECORD" ]; then
    record_pass "resolve: non-matching sha returns empty (no false positive)"
else
    record_fail "resolve gave false positive: '$RECORD'"
fi

# Precedence — first candidate wins
echo '{"verdict":"WARN"}' > .claude/gates/named-b.json
NAMED_B_SHA=$(shasum -a 256 .claude/gates/named-b.json | awk '{print $1}')
NAMED_B_PREFIX="${NAMED_B_SHA:0:12}"
RECORD=$(pe_trailer_resolve_record "$NAMED_B_PREFIX" \
    ".claude/gates/named-a.json" \
    ".claude/gates/named-b.json")
if [ "$RECORD" = "$proj/.claude/gates/named-b.json" ]; then
    record_pass "resolve: iterates all candidates until sha match found"
else
    record_fail "resolve stopped early: got '$RECORD'"
fi

# Direct fallback (.claude/gates/<sha>.json)
DIRECT_SHA="abcdef1234567890"
echo '{"verdict":"PASS"}' > ".claude/gates/$DIRECT_SHA.json"
RECORD=$(pe_trailer_resolve_record "$DIRECT_SHA")
if [ "$RECORD" = "$proj/.claude/gates/$DIRECT_SHA.json" ]; then
    record_pass "resolve: direct .claude/gates/<sha>.json fallback works"
else
    record_fail "direct fallback wrong: '$RECORD'"
fi

# Missing everything
RECORD=$(pe_trailer_resolve_record "0000000000000000")
if [ -z "$RECORD" ]; then
    record_pass "resolve: unknown sha returns empty"
else
    record_fail "resolve should have returned empty: '$RECORD'"
fi

# ─── pe_trailer_verdict ─────────────────────────────────────────────
echo '{"verdict":"PASS"}' > .claude/gates/plain-pass.json
V=$(pe_trailer_verdict "$proj/.claude/gates/plain-pass.json")
if [ "$V" = "PASS" ]; then
    record_pass "verdict: reads top-level verdict"
else
    record_fail "top-level verdict wrong: '$V'"
fi

# Uppercase normalization
echo '{"verdict":"warn"}' > .claude/gates/lower.json
V=$(pe_trailer_verdict "$proj/.claude/gates/lower.json")
if [ "$V" = "WARN" ]; then
    record_pass "verdict: uppercases result so hooks case-match cleanly"
else
    record_fail "uppercase normalization broken: '$V'"
fi

# Wrapped envelope shape (design record)
cat > .claude/gates/wrapped.json <<'EOF'
{"envelope":{"verdict":"FAIL"}}
EOF
V=$(pe_trailer_verdict "$proj/.claude/gates/wrapped.json")
if [ "$V" = "FAIL" ]; then
    record_pass "verdict: falls back to envelope.verdict for wrapped shape"
else
    record_fail "envelope.verdict fallback broken: '$V'"
fi

# Missing verdict entirely
echo '{"gate_name":"foo"}' > .claude/gates/no-verdict.json
V=$(pe_trailer_verdict "$proj/.claude/gates/no-verdict.json")
if [ -z "$V" ]; then
    record_pass "verdict: missing field returns empty"
else
    record_fail "missing verdict didn't return empty: '$V'"
fi

# Corrupt JSON
echo 'not json' > .claude/gates/bad.json
V=$(pe_trailer_verdict "$proj/.claude/gates/bad.json")
if [ "$V" = "PARSE_ERROR" ]; then
    record_pass "verdict: corrupt file returns PARSE_ERROR"
else
    record_fail "corrupt file wrong: '$V'"
fi

# Missing file
V=$(pe_trailer_verdict "$proj/.claude/gates/nonexistent.json")
if [ "$V" = "PARSE_ERROR" ]; then
    record_pass "verdict: missing file returns PARSE_ERROR"
else
    record_fail "missing file wrong: '$V'"
fi

# Empty argument
V=$(pe_trailer_verdict "")
if [ -z "$V" ]; then
    record_pass "verdict: empty arg returns empty"
else
    record_fail "empty-arg wrong: '$V'"
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
