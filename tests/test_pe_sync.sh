#!/usr/bin/env bash
# tests/test_pe_sync.sh
#
# Smoke tests for `pe sync` — proves the safety contract:
#   (1) a stale symlink (pointing at a different engine path) gets
#       re-pointed at the current engine on confirmation.
#   (2) a project-local regular file that DIFFERS from the engine
#       version is NOT overwritten when the prompt is declined.
#
# Not a comprehensive scripts/pe test — just the two paths whose
# failure mode is data loss (clobbered customized agent).
#
# Run: bash tests/test_pe_sync.sh
# Exits 0 if all assertions pass; non-zero on first failure.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
PE="$ENGINE_DIR/scripts/pe"
TMP="$(mktemp -d -t pe_sync_test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail=0
pass=0

assert() {
    local desc="$1" cond="$2"
    if eval "$cond"; then
        echo "  ✓ $desc"
        pass=$((pass + 1))
    else
        echo "  ✗ $desc"
        echo "      cond: $cond"
        fail=$((fail + 1))
    fi
}

# Pick a real engine agent to test against. code-reviewer is part of
# every subset including gate-only, so it's always installed.
TEST_AGENT="code-reviewer.md"
ENGINE_AGENT="$ENGINE_DIR/agents/$TEST_AGENT"
if [ ! -f "$ENGINE_AGENT" ]; then
    echo "ERROR: $ENGINE_AGENT does not exist — engine repo malformed" >&2
    exit 1
fi

# ─── Scaffold a fake project with .process-engine.yaml ────────────────────
PROJECT="$TMP/fakeproject"
mkdir -p "$PROJECT/.claude/agents"
cat > "$PROJECT/.process-engine.yaml" <<EOF
schema_version: 1
project:
  org_tag: testorg
  root: $PROJECT
install:
  subset: gate-only
EOF

echo "Test 1: stale symlink gets re-pointed on confirmation"

# Create a fake "other engine" location and make the project symlink point there
FAKE_OTHER_ENGINE="$TMP/other-engine/agents"
mkdir -p "$FAKE_OTHER_ENGINE"
cp "$ENGINE_AGENT" "$FAKE_OTHER_ENGINE/$TEST_AGENT"
ln -s "$FAKE_OTHER_ENGINE/$TEST_AGENT" "$PROJECT/.claude/agents/$TEST_AGENT"

# Sanity: before sync, symlink resolves to the OTHER engine
BEFORE_TARGET="$(readlink "$PROJECT/.claude/agents/$TEST_AGENT")"
assert "before sync: symlink points at OTHER engine" \
       "[ \"$BEFORE_TARGET\" = \"$FAKE_OTHER_ENGINE/$TEST_AGENT\" ]"

# Run sync with `y` on stdin to accept the re-point prompt
echo "y" | bash "$PE" sync "$PROJECT" > "$TMP/sync1.out" 2>&1 || true

AFTER_TARGET="$(readlink "$PROJECT/.claude/agents/$TEST_AGENT" 2>/dev/null || echo "")"
assert "after sync: symlink re-pointed at current engine" \
       "[ \"$AFTER_TARGET\" = \"$ENGINE_AGENT\" ]"

# ─── Test 2: differing regular file is NOT overwritten on decline ────────
echo ""
echo "Test 2: differing regular file NOT overwritten when prompt declined"

# Use a different always-in-gate-only agent so test 1 doesn't interfere
TEST_AGENT_2="tdd-guide.md"
ENGINE_AGENT_2="$ENGINE_DIR/agents/$TEST_AGENT_2"
PROJECT_AGENT_2="$PROJECT/.claude/agents/$TEST_AGENT_2"

# Remove any pre-existing symlink, write a customized regular file
rm -f "$PROJECT_AGENT_2"
CUSTOM_MARKER="### LOCAL CUSTOMIZATION — DO NOT OVERWRITE ###"
{
    echo "$CUSTOM_MARKER"
    cat "$ENGINE_AGENT_2"
} > "$PROJECT_AGENT_2"

# Sanity: file is a regular file (not a symlink) and contains the marker
assert "before sync: tdd-guide.md is a regular file with the marker" \
       "[ ! -L \"$PROJECT_AGENT_2\" ] && grep -q \"$CUSTOM_MARKER\" \"$PROJECT_AGENT_2\""

# Run sync with `n` on stdin to DECLINE the overwrite prompt.
# Capture the exit code — a crash mid-run (the historical diff|head
# errexit bug) also leaves the file untouched, so file-preservation
# assertions alone would pass on broken behavior.
SYNC2_EXIT=0
echo "n" | bash "$PE" sync "$PROJECT" > "$TMP/sync2.out" 2>&1 || SYNC2_EXIT=$?

# After sync: file must still be a regular file and still contain the marker
assert "after sync (declined): tdd-guide.md is STILL a regular file" \
       "[ ! -L \"$PROJECT_AGENT_2\" ]"
assert "after sync (declined): tdd-guide.md still contains the local marker" \
       "grep -q \"$CUSTOM_MARKER\" \"$PROJECT_AGENT_2\""

# Sanity check the output mentioned the diff prompt
assert "sync output mentioned 'differs from engine' for the declined file" \
       "grep -q 'differs from engine' \"$TMP/sync2.out\""

# The decline must be a clean decline, not a crash: sync ran to completion
# (Summary printed), exited 0, and recorded the kept file.
assert "sync ran to completion (Summary line present)" \
       "grep -q 'Summary' \"$TMP/sync2.out\""
assert "sync exited 0 after a declined overwrite" \
       "[ \"$SYNC2_EXIT\" -eq 0 ]"
assert "sync reported the file was kept" \
       "grep -q 'kept project version' \"$TMP/sync2.out\""

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
