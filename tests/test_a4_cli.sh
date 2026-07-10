#!/usr/bin/env bash
# tests/test_a4_cli.sh — A4 CLI shape checks (v0.42.0).
#
# The A4 loop's runtime is unit-tested in test_a4_loop.py (deterministic
# invoker mocks). This script covers the CLI surface only:
#   - flags present in `pe shadow decide --help`
#   - --auto-execute without --enforce returns exit 2 with actionable stderr
#   - --auto-execute without --agent returns exit 2

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
. "$(dirname "$0")/_py.sh"
PE="$ENGINE_DIR/scripts/pe"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_a4_cli.sh — A4 CLI shape checks"
echo ""

# ─── 1. --auto-execute advertised ────────────────────────────────
help_out=$("$PY" "$ENGINE_DIR/scripts/pe_orchestrator.py" decide --help 2>&1)
if echo "$help_out" | grep -q -- "--auto-execute"; then
    record_pass "shadow decide --help lists --auto-execute"
else
    record_fail "--auto-execute missing from help"
fi

if echo "$help_out" | grep -q -- "--agent"; then
    record_pass "shadow decide --help lists --agent"
else
    record_fail "--agent missing from help"
fi

if echo "$help_out" | grep -q -- "--max-iterations"; then
    record_pass "shadow decide --help lists --max-iterations"
else
    record_fail "--max-iterations missing from help"
fi

# ─── 2. Seed a minimal valid envelope for the following cases ───
cat > "$TMP/env.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "gate_name": "code-reviewer",
  "verdict": "FAIL",
  "failure_class": "worker_quality",
  "confidence": 0.9,
  "model_used": "claude-sonnet-4-6",
  "tier": "sonnet",
  "timestamp": "2026-07-04T00:00:00Z",
  "summary": "test",
  "findings": [{"severity": "HIGH", "rule": "x", "message": "y"}]
}
JSON

# ─── 3. --auto-execute without --enforce → exit 2 ──────────────
cd "$TMP"
out=$("$PY" "$ENGINE_DIR/scripts/pe_orchestrator.py" decide \
    --envelope env.json \
    --slot-id t \
    --iteration 1 \
    --current-tier haiku \
    --bare \
    --auto-execute \
    --agent code-reviewer 2>&1)
rc=$?
if [ $rc -eq 2 ] && echo "$out" | grep -q "requires --enforce"; then
    record_pass "--auto-execute w/o --enforce → exit 2 with actionable message"
else
    record_fail "auto-execute-no-enforce case wrong: rc=$rc out='$out'"
fi

# ─── 4. --auto-execute without --agent → exit 2 ───────────────
out=$("$PY" "$ENGINE_DIR/scripts/pe_orchestrator.py" decide \
    --envelope env.json \
    --slot-id t \
    --iteration 1 \
    --current-tier haiku \
    --bare \
    --auto-execute \
    --enforce 2>&1)
rc=$?
if [ $rc -eq 2 ] && echo "$out" | grep -q "requires --agent"; then
    record_pass "--auto-execute w/o --agent → exit 2 with actionable message"
else
    record_fail "auto-execute-no-agent case wrong: rc=$rc out='$out'"
fi

# ─── 5. shadow-only mode (no --auto-execute) still exits 0 ────
out=$("$PY" "$ENGINE_DIR/scripts/pe_orchestrator.py" decide \
    --envelope env.json \
    --slot-id t \
    --iteration 1 \
    --current-tier haiku \
    --bare 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "legacy shadow mode (no --auto-execute) unchanged (exit 0)"
else
    record_fail "shadow-only regressed: rc=$rc out='$out'"
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
