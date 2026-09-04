#!/usr/bin/env bash
# tests/test_pe_install_reconcile.sh
#
# Smoke tests for E1.c.2 reconciling `pe install`:
#   (1) BROKEN symlink in .claude/agents/ (target vanished from engine)
#       is silently removed on re-install.
#   (2) Real files (operator customizations) at .claude/agents/*.md
#       are NEVER removed, even if they share a name with an agent
#       that isn't in the engine anymore.
#   (3) Valid symlinks (target still exists) are left untouched.
#   (4) Same reconciliation applies to .claude/commands/.
#   (5) Every workflows/*.js in the engine lands in .claude/workflows/,
#       as a copy, and a locally modified one is backed up before being
#       overwritten rather than clobbered.
#
# Not a comprehensive install.sh test — just the reconciling contract, plus
# (5), which is here because this is the only test that runs a real install
# into a real target and can therefore ask what actually arrived.
# Run: bash tests/test_pe_install_reconcile.sh
# Exits 0 if all assertions pass; non-zero on first failure.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
INSTALL="$ENGINE_DIR/scripts/install.sh"
TMP="$(mktemp -d -t pe_install_reconcile.XXXXXX)"
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

PROJECT="$TMP/fakeproject"
mkdir -p "$PROJECT"

echo "Setup: run initial install to populate .claude/agents + .claude/commands"
bash "$INSTALL" --subset gate-only "$PROJECT" > "$TMP/install1.out" 2>&1

# Sanity: at least one agent symlink was created
assert "initial install: .claude/agents/code-reviewer.md is a symlink" \
       "[ -L \"$PROJECT/.claude/agents/code-reviewer.md\" ]"

# ─── Test 1: BROKEN symlink gets silently removed ────────────────────────
echo ""
echo "Test 1: broken symlink removed on re-install"

# Simulate an agent that USED to exist in a prior engine SHA
ln -s "$ENGINE_DIR/agents/DOES-NOT-EXIST.md" "$PROJECT/.claude/agents/vanished.md"
assert "before re-install: vanished.md is a symlink (broken)" \
       "[ -L \"$PROJECT/.claude/agents/vanished.md\" ] && [ ! -e \"$PROJECT/.claude/agents/vanished.md\" ]"

bash "$INSTALL" --subset gate-only "$PROJECT" > "$TMP/install2.out" 2>&1

assert "after re-install: broken symlink vanished.md is REMOVED" \
       "[ ! -L \"$PROJECT/.claude/agents/vanished.md\" ] && [ ! -e \"$PROJECT/.claude/agents/vanished.md\" ]"
assert "install output mentions Reconciled/broken removal" \
       "grep -q 'Reconciled' \"$TMP/install2.out\""

# ─── Test 2: real file (operator customization) is NEVER removed ─────────
echo ""
echo "Test 2: real file with vanished-name is preserved"

CUSTOM_MARKER="### OPERATOR CUSTOMIZATION — MUST NOT BE DELETED ###"
CUSTOM_PATH="$PROJECT/.claude/agents/custom-agent.md"
cat > "$CUSTOM_PATH" <<EOF
$CUSTOM_MARKER
This file is a real file, not a symlink. It has no counterpart in the engine.
It must survive a reconciling re-install.
EOF
assert "before re-install: custom-agent.md is a REAL FILE (not a symlink)" \
       "[ -f \"$CUSTOM_PATH\" ] && [ ! -L \"$CUSTOM_PATH\" ]"

bash "$INSTALL" --subset gate-only "$PROJECT" > "$TMP/install3.out" 2>&1

assert "after re-install: custom-agent.md still exists as real file" \
       "[ -f \"$CUSTOM_PATH\" ] && [ ! -L \"$CUSTOM_PATH\" ]"
assert "after re-install: custom-agent.md still has the marker line" \
       "grep -q \"$CUSTOM_MARKER\" \"$CUSTOM_PATH\""

# ─── Test 3: valid symlinks are left in place ────────────────────────────
echo ""
echo "Test 3: valid symlinks untouched"

# code-reviewer is in gate-only subset — should stay symlinked after re-install
assert "after re-install: code-reviewer.md is still a valid symlink" \
       "[ -L \"$PROJECT/.claude/agents/code-reviewer.md\" ] && [ -e \"$PROJECT/.claude/agents/code-reviewer.md\" ]"

# ─── Test 4: commands directory reconciles the same way ──────────────────
echo ""
echo "Test 4: broken command symlink removed on re-install"

ln -s "$ENGINE_DIR/commands/DOES-NOT-EXIST.md" "$PROJECT/.claude/commands/vanished-cmd.md"
assert "before re-install: vanished-cmd.md is a broken symlink in commands/" \
       "[ -L \"$PROJECT/.claude/commands/vanished-cmd.md\" ] && [ ! -e \"$PROJECT/.claude/commands/vanished-cmd.md\" ]"

bash "$INSTALL" --subset gate-only "$PROJECT" > "$TMP/install4.out" 2>&1

assert "after re-install: broken command symlink is REMOVED" \
       "[ ! -L \"$PROJECT/.claude/commands/vanished-cmd.md\" ]"

# ─── Test 5: workflows are delivered, not left in the engine ─────────────
echo ""
echo "Test 5: .claude/workflows/ receives every engine workflow"

# Derived from the engine, not from a list kept here — a workflow added
# without an installer change must turn this red rather than ship undelivered.
# /gate-review is executable gate logic that decides what reaches
# .claude/gates/last-gate.json; before v0.52.0 `pe install` never copied it
# and the only route into a project was a `cp` in docs/RUNNING_AGENTS.md.
for wf in "$ENGINE_DIR"/workflows/*.js; do
    [ -f "$wf" ] || continue
    wf_name="$(basename "$wf")"
    assert "install delivered workflows/$wf_name" \
           "[ -f \"$PROJECT/.claude/workflows/$wf_name\" ]"
    assert "workflows/$wf_name is a copy, not a symlink (2.1.216+ won't write through one)" \
           "[ ! -L \"$PROJECT/.claude/workflows/$wf_name\" ]"
    assert "workflows/$wf_name matches the engine's copy byte for byte" \
           "cmp -s \"$wf\" \"$PROJECT/.claude/workflows/$wf_name\""
done

# A locally edited workflow must not be silently destroyed by the overwrite.
FIRST_WF="$(basename "$(ls "$ENGINE_DIR"/workflows/*.js | head -1)")"
printf '\n// operator edit\n' >> "$PROJECT/.claude/workflows/$FIRST_WF"
bash "$INSTALL" --subset gate-only "$PROJECT" > "$TMP/install5.out" 2>&1

assert "modified workflow is restored to the engine version" \
       "cmp -s \"$ENGINE_DIR/workflows/$FIRST_WF\" \"$PROJECT/.claude/workflows/$FIRST_WF\""
assert "the operator's edit is preserved as a .local-backup" \
       "grep -q 'operator edit' \"$PROJECT/.claude/workflows/$FIRST_WF.local-backup\""
assert "install output reports the replacement rather than doing it silently" \
       "grep -qi 'Replaced' \"$TMP/install5.out\""

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
