#!/usr/bin/env bash
# test_ponytail_preflight.sh — smoke tests for the A5 PreToolUse hook.
#
# The hook is advisory: never blocks, never mutates. Verify:
#   1. Small Write emits the short reminder + exits 0.
#   2. Large Write (≥50 lines of new content) emits the verbose block.
#   3. Non-writing tools (Bash, Read) emit nothing.
#   4. Empty stdin → silent exit 0 (probe / no-event case).
#   5. Dedup: back-to-back small writes within TTL suppress reminder 2.
#   6. Malformed JSON → silent exit 0 (never surface an error to the operator).

set -uo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ENGINE_DIR/hooks/ponytail-preflight.sh"
WORK=$(mktemp -d)
STATE="$WORK/.pe/ponytail-preflight-seen.state"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cd "$WORK"

pass=0; fail=0
declare -a failures=()
record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_ponytail_preflight.sh — $HOOK"
echo ""

# 1. small Write emits short reminder
rm -f "$STATE"
out=$(echo '{"tool_name":"Write","tool_input":{"content":"x=1\ny=2"}}' | "$HOOK")
if echo "$out" | grep -q "Reminder: needs to exist"; then
    record_pass "small Write emits short reminder"
else
    record_fail "small Write did not emit short reminder (got: $out)"
fi

# 2. large Write emits verbose block
rm -f "$STATE"
content=$(python3 -c 'print("\n".join(["line" + str(i) for i in range(60)]))')
event=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'content':'''$content'''}}))")
out=$(printf '%s' "$event" | "$HOOK")
if echo "$out" | grep -q "Large write pending"; then
    record_pass "large Write (≥50 lines) emits verbose block"
else
    record_fail "large Write did not emit verbose block"
fi

# 3. non-writing tool suppressed
rm -f "$STATE"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | "$HOOK")
if [ -z "$out" ]; then
    record_pass "Bash tool suppressed"
else
    record_fail "Bash tool leaked output: $out"
fi

# 4. empty stdin
out=$("$HOOK" < /dev/null)
if [ -z "$out" ]; then
    record_pass "empty stdin silent"
else
    record_fail "empty stdin emitted: $out"
fi

# 5. dedup for small back-to-back writes
rm -f "$STATE"
out1=$(echo '{"tool_name":"Write","tool_input":{"content":"a=1"}}' | "$HOOK")
out2=$(echo '{"tool_name":"Write","tool_input":{"content":"b=2"}}' | "$HOOK")
if [ -n "$out1" ] && [ -z "$out2" ]; then
    record_pass "dedup: second small write within TTL suppressed"
else
    record_fail "dedup broken (out1=$out1, out2=$out2)"
fi

# 6. malformed JSON never surfaces error
rm -f "$STATE"
out=$(echo 'not-json,,, }' | "$HOOK" 2>&1)
ec=$?
if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "error\|traceback"; then
    record_pass "malformed JSON exits 0 without error"
else
    record_fail "malformed JSON leaked error (ec=$ec, out=$out)"
fi

# 7. hook never blocks — always exits 0
set +e
echo '{"tool_name":"Write","tool_input":{"content":"x"}}' | "$HOOK" > /dev/null
ec=$?
set -e
if [ $ec -eq 0 ]; then
    record_pass "hook always exits 0 (never blocks)"
else
    record_fail "hook returned non-zero exit (ec=$ec)"
fi

echo ""
echo "─────────────────────────────────────"
echo "  passed: $pass"
echo "  failed: $fail"
if [ $fail -gt 0 ]; then
    for f in "${failures[@]}"; do echo "    - $f"; done
    exit 1
fi
exit 0
