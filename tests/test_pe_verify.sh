#!/usr/bin/env bash
# tests/test_pe_verify.sh — S4 supply-chain integrity check.
#
# Contract:
#   - `pe verify` with a clean tree exits 0.
#   - Tampering with an agent/hook/script surface exits 1.
#   - Missing manifest exits 2.
#   - `pe verify --update` regenerates the manifest cleanly.
#   - `--json` emits parseable JSON with a verdict field.
#
# Uses a full copy of the engine tree in a tempdir so the tampering
# tests don't corrupt the real MANIFEST.sha256.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
PE="$ENGINE_DIR/scripts/pe"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_pe_verify.sh — $PE verify"
echo ""

# Copy just the load-bearing surfaces into a fake engine so mutation
# doesn't touch the real repo. We include the pe wrapper + pe_verify.py
# so the CLI works end-to-end.
FAKE="$TMP/fake_engine"
mkdir -p "$FAKE"
# Copy the whole engine tree except .git, tests, and the real
# MANIFEST.sha256 (we regenerate it below). Preserves scripts/ helper
# files that scripts/pe sources at startup.
for entry in agents commands hooks skills scripts docs schemas templates; do
    [ -e "$ENGINE_DIR/$entry" ] || continue
    cp -R "$ENGINE_DIR/$entry" "$FAKE/"
done
cp "$ENGINE_DIR/plugin.json" "$FAKE/"
cp "$ENGINE_DIR/VERSION" "$FAKE/"

# ─── 0. --update REFUSED without PE_VERIFY_ALLOW_UPDATE=1 ───────────
out=$("$PE" verify --update --engine "$FAKE" 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "PE_VERIFY_ALLOW_UPDATE"; then
    record_pass "--update refused without PE_VERIFY_ALLOW_UPDATE=1 (S4 gate)"
else
    record_fail "--update ran without gate: rc=$rc out='$out'"
fi

# ─── 0b. --update REFUSED even with env var when engine != script parent ─
out=$(PE_VERIFY_ALLOW_UPDATE=1 "$PE" verify --update --engine "$FAKE" 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "outside the engine source tree"; then
    record_pass "--update refuses to overwrite adopter-tree manifest"
else
    record_fail "--update on foreign tree not caught: rc=$rc out='$out'"
fi

# Use pe_verify.py directly from a copy inside the FAKE tree so the
# script-parent check passes. This simulates release-time from the
# engine repo itself.
FAKE_PE="$FAKE/scripts/pe"
# ─── 1. --update writes a manifest when called via the FAKE tree ────
out=$(PE_VERIFY_ALLOW_UPDATE=1 "$FAKE_PE" verify --update --engine "$FAKE" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -f "$FAKE/MANIFEST.sha256" ]; then
    record_pass "--update writes MANIFEST.sha256 (release-time)"
else
    record_fail "--update failed: rc=$rc out='$out'"
fi

# ─── 2. clean verify passes ─────────────────────────────────────────
out=$("$PE" verify --engine "$FAKE" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "manifest clean"; then
    record_pass "clean tree verifies (exit 0)"
else
    record_fail "clean tree rejected: rc=$rc out='$out'"
fi

# ─── 3. tampered hook diverges (exit 1) ─────────────────────────────
echo "# tampered" >> "$FAKE/hooks/post-edit-lint.sh"
out=$("$PE" verify --engine "$FAKE" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "post-edit-lint.sh"; then
    record_pass "tampered hook detected (exit 1, path reported)"
else
    record_fail "tampered hook not caught: rc=$rc out='$out'"
fi

# ─── 4. --json emits parseable output ───────────────────────────────
out=$("$PE" verify --engine "$FAKE" --json 2>&1)
rc=$?
verdict=$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])' 2>/dev/null || echo "PARSE_ERROR")
if [ "$verdict" = "FAIL" ]; then
    record_pass "--json emits FAIL verdict on tampered tree"
else
    record_fail "--json output invalid: verdict='$verdict'"
fi

# ─── 5. restore + rebuild manifest → PASS again ─────────────────────
cp "$ENGINE_DIR/hooks/post-edit-lint.sh" "$FAKE/hooks/post-edit-lint.sh"
PE_VERIFY_ALLOW_UPDATE=1 "$FAKE_PE" verify --update --engine "$FAKE" >/dev/null 2>&1
out=$("$PE" verify --engine "$FAKE" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "restored file + --update → clean again"
else
    record_fail "post-restore verify still failing: rc=$rc"
fi

# ─── 6. missing manifest → exit 2 ───────────────────────────────────
rm -f "$FAKE/MANIFEST.sha256"
out=$("$PE" verify --engine "$FAKE" 2>&1)
rc=$?
if [ $rc -eq 2 ] || echo "$out" | grep -qi "missing manifest"; then
    record_pass "missing manifest → error exit"
else
    record_fail "missing manifest not surfaced: rc=$rc out='$out'"
fi

# ─── 7. new file → advisory (not fatal) ─────────────────────────────
PE_VERIFY_ALLOW_UPDATE=1 "$FAKE_PE" verify --update --engine "$FAKE" >/dev/null 2>&1
touch "$FAKE/agents/new-experimental.md"
out=$("$PE" verify --engine "$FAKE" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "new-experimental.md"; then
    record_pass "new-on-disk file → advisory, still exit 0"
else
    record_fail "new file handling wrong: rc=$rc out='$out'"
fi

# ─── 8. missing-from-disk file → FAIL ───────────────────────────────
rm -f "$FAKE/agents/new-experimental.md"
PE_VERIFY_ALLOW_UPDATE=1 "$FAKE_PE" verify --update --engine "$FAKE" >/dev/null 2>&1
# Manifest now includes new-experimental.md. Delete it and verify.
rm -f "$FAKE/agents/new-experimental.md"  # already gone
# Add a fresh file, capture manifest, then delete → verify must fail.
touch "$FAKE/agents/will-vanish.md"
PE_VERIFY_ALLOW_UPDATE=1 "$FAKE_PE" verify --update --engine "$FAKE" >/dev/null 2>&1
rm -f "$FAKE/agents/will-vanish.md"
out=$("$PE" verify --engine "$FAKE" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "will-vanish.md"; then
    record_pass "missing-on-disk file → exit 1"
else
    record_fail "missing file not caught: rc=$rc out='$out'"
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
