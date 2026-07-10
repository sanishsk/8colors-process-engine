#!/usr/bin/env bash
# Smoke: pe audit runs full-repo (not staged) + prints the agent-sweep guidance.
set -uo pipefail
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
out=$(cd "$ENGINE_DIR" && bash scripts/pe audit 2>&1)
fail=0
echo "$out" | grep -q "full-repo" || { echo "✗ no full-repo header"; fail=1; }
echo "$out" | grep -q "design-critic over" || { echo "✗ no design-critic sweep"; fail=1; }
echo "$out" | grep -q "security-reviewer over" || { echo "✗ no security sweep"; fail=1; }
so=$(cd "$ENGINE_DIR" && bash scripts/pe audit --screens-only 2>&1)
echo "$so" | grep -q "security-reviewer over" && { echo "✗ --screens-only leaked security sweep"; fail=1; }
[ "$fail" = 0 ] && echo "test_audit: PASS" || { echo "test_audit: FAIL"; exit 1; }
