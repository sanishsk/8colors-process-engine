#!/usr/bin/env bash
# tests/test_pe_pin.sh — A8 per-project engine version pinning.
#
# Contract:
#   - `pe pin show` prints pin contents + drift verdict; exit 0.
#   - `pe pin verify` exits 0 on match, 1 on drift, 2 on missing pin.
#   - `pe pin bump` rewrites the pin to the engine's current
#     version + HEAD SHA.
#   - `install.sh` writes the pin file as part of a normal install.
#   - Detects drift categories: pinned, engine_ahead, sha_orphan,
#     ok_no_git.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
PE="$ENGINE_DIR/scripts/pe"
PY="${PE_PYTHON:-python3}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_pe_pin.sh — $PE pin"
echo ""

ENGINE_VER=$(cat "$ENGINE_DIR/VERSION")
ENGINE_SHA=$(git -C "$ENGINE_DIR" rev-parse HEAD 2>/dev/null || echo "")

# ─── 1. missing pin → verify exit 2 ─────────────────────────────────
mkdir -p "$TMP/no_pin"
out=$("$PE" pin verify --project "$TMP/no_pin" 2>&1)
rc=$?
if [ $rc -eq 2 ] && echo "$out" | grep -q "no pin file"; then
    record_pass "verify: missing pin → exit 2"
else
    record_fail "missing pin wrong: rc=$rc out='$out'"
fi

# ─── 2. missing pin → show is informational (exit 0) ────────────────
out=$("$PE" pin show --project "$TMP/no_pin" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "no pin file"; then
    record_pass "show: missing pin → exit 0 with hint"
else
    record_fail "show on missing pin wrong: rc=$rc out='$out'"
fi

# ─── 3. pin matching HEAD → verify verdict=pinned ───────────────────
proj_ok="$TMP/pin_ok"
mkdir -p "$proj_ok/.claude"
cat > "$proj_ok/.claude/.engine-pin.json" <<EOF
{
  "engine_path": "$ENGINE_DIR",
  "engine_sha": "$ENGINE_SHA",
  "engine_version": "$ENGINE_VER",
  "install_mode": "symlink",
  "installed_at": "2026-07-03T00:00:00Z"
}
EOF
out=$("$PE" pin verify --project "$proj_ok" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "OK"; then
    record_pass "verify: pin at HEAD → exit 0 (pinned)"
else
    record_fail "matching pin misread: rc=$rc out='$out'"
fi

# ─── 4. pin at older version → verdict=engine_ahead, exit 1 ─────────
proj_ahead="$TMP/pin_ahead"
mkdir -p "$proj_ahead/.claude"
cat > "$proj_ahead/.claude/.engine-pin.json" <<EOF
{
  "engine_path": "$ENGINE_DIR",
  "engine_sha": "0000000000000000000000000000000000000000",
  "engine_version": "0.10.0",
  "install_mode": "symlink",
  "installed_at": "2026-01-01T00:00:00Z"
}
EOF
out=$("$PE" pin verify --project "$proj_ahead" 2>&1)
rc=$?
if [ $rc -eq 1 ] && (echo "$out" | grep -q "engine_ahead" \
                    || echo "$out" | grep -q "sha_orphan"); then
    record_pass "verify: pin behind engine → exit 1 (drift detected)"
else
    record_fail "engine_ahead drift missed: rc=$rc out='$out'"
fi

# ─── 5. orphan SHA (unreachable) → verdict=sha_orphan ───────────────
proj_orphan="$TMP/pin_orphan"
mkdir -p "$proj_orphan/.claude"
cat > "$proj_orphan/.claude/.engine-pin.json" <<EOF
{
  "engine_path": "$ENGINE_DIR",
  "engine_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  "engine_version": "$ENGINE_VER",
  "install_mode": "symlink",
  "installed_at": "2026-01-01T00:00:00Z"
}
EOF
out=$("$PE" pin show --project "$proj_orphan" 2>&1)
if echo "$out" | grep -q "sha_orphan"; then
    record_pass "show: unreachable SHA → sha_orphan verdict"
else
    record_fail "sha_orphan not surfaced: '$out'"
fi

# ─── 6. --json emits parseable payload with drift_verdict ───────────
out=$("$PE" pin show --project "$proj_ok" --json 2>&1)
verdict=$(echo "$out" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["drift_verdict"])' 2>/dev/null || echo "PARSE_ERROR")
if [ "$verdict" = "pinned" ]; then
    record_pass "--json emits drift_verdict=pinned for matching pin"
else
    record_fail "--json shape wrong: verdict='$verdict'"
fi

# ─── 7. bump rewrites pin to engine's current version + SHA ─────────
proj_bump="$TMP/pin_bump"
mkdir -p "$proj_bump/.claude"
cat > "$proj_bump/.claude/.engine-pin.json" <<EOF
{"engine_version":"0.10.0","engine_sha":"stale","installed_at":"2026-01-01T00:00:00Z","install_mode":"symlink","engine_path":"$ENGINE_DIR"}
EOF
"$PE" pin bump --project "$proj_bump" >/dev/null 2>&1
new_ver=$("$PY" -c 'import json; print(json.load(open("'"$proj_bump"'/.claude/.engine-pin.json"))["engine_version"])')
prev_ver=$("$PY" -c 'import json; print(json.load(open("'"$proj_bump"'/.claude/.engine-pin.json"))["previous_version"])')
if [ "$new_ver" = "$ENGINE_VER" ] && [ "$prev_ver" = "0.10.0" ]; then
    record_pass "bump: pin rewritten to engine's current VERSION, previous_version preserved"
else
    record_fail "bump wrong: new='$new_ver' prev='$prev_ver'"
fi

# ─── 8. bump verify roundtrip → exit 0 ──────────────────────────────
out=$("$PE" pin verify --project "$proj_bump" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    record_pass "bump → verify roundtrip is clean (exit 0)"
else
    record_fail "roundtrip failed: rc=$rc out='$out'"
fi

# ─── 9. bump --to mismatch → exit 2 ─────────────────────────────────
out=$("$PE" pin bump --project "$proj_bump" --to "99.99.99" 2>&1)
rc=$?
if [ $rc -eq 2 ] && echo "$out" | grep -q "does not match"; then
    record_pass "bump --to mismatch → exit 2 (safety guard)"
else
    record_fail "bump --to mismatch not caught: rc=$rc out='$out'"
fi

# ─── 10. install.sh writes the pin file (A8 integration) ────────────
proj_install="$TMP/pin_install"
mkdir -p "$proj_install"
# Minimal install with --no-claude-hooks / --no-git-hooks so we don't
# touch settings.json or run pre-commit — just prove the pin write.
"$ENGINE_DIR/scripts/install.sh" --subset gate-only \
    --no-claude-hooks --no-git-hooks "$proj_install" >/dev/null 2>&1
if [ -f "$proj_install/.claude/.engine-pin.json" ]; then
    installed_ver=$("$PY" -c 'import json; print(json.load(open("'"$proj_install"'/.claude/.engine-pin.json"))["engine_version"])')
    if [ "$installed_ver" = "$ENGINE_VER" ]; then
        record_pass "install.sh writes .engine-pin.json with current VERSION"
    else
        record_fail "install pin wrong version: '$installed_ver' != '$ENGINE_VER'"
    fi
else
    record_fail "install.sh did not write .engine-pin.json"
fi

# ─── 11. corrupt pin file → verify exit 2 ───────────────────────────
proj_corrupt="$TMP/pin_corrupt"
mkdir -p "$proj_corrupt/.claude"
echo "not valid json" > "$proj_corrupt/.claude/.engine-pin.json"
out=$("$PE" pin verify --project "$proj_corrupt" 2>&1)
rc=$?
if [ $rc -eq 2 ]; then
    record_pass "verify: corrupt pin → exit 2 (treated as missing)"
else
    record_fail "corrupt pin not caught: rc=$rc"
fi

# ─── 12. .claude-plugin/plugin.json present + valid ─────────────────
CP="$ENGINE_DIR/.claude-plugin/plugin.json"
if [ -f "$CP" ]; then
    name=$("$PY" -c 'import json; print(json.load(open("'"$CP"'"))["name"])')
    ver=$("$PY" -c 'import json; print(json.load(open("'"$CP"'"))["version"])')
    if [ "$name" = "8colors-process-engine" ] && [ "$ver" = "$ENGINE_VER" ]; then
        record_pass ".claude-plugin/plugin.json present, name + version aligned"
    else
        record_fail ".claude-plugin/plugin.json misaligned: name='$name' ver='$ver'"
    fi
else
    record_fail ".claude-plugin/plugin.json missing"
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
