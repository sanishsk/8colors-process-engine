#!/usr/bin/env bash
# tests/test_hooks.sh
#
# Smoke tests for the Claude Code hooks bundle (P1.1).
# Proves the load-bearing safety contract of pre-commit-envelope-check.sh:
#   (1) non-git-commit Bash calls are allowed through unchanged
#   (2) git commit with NO envelope record is blocked
#   (3) git commit with a stale diff_sha (differs from HEAD staging) is blocked
#   (4) git commit with a fresh PASS envelope matching staged diff is allowed
#   (5) git commit with a FAIL envelope is blocked
#   (6) --dry-run bypasses
#   (7) PE_SKIP_COMMIT_GATE=1 bypasses (with stderr notice)
# And post-edit-lint.sh:
#   (8) fires on Edit tool events, never fails the call
# And stop-uncommitted-reminder.sh:
#   (9) advises on dirty repo, silent on clean repo
#
# Run: bash tests/test_hooks.sh
# Exits 0 if all assertions pass; non-zero on first failure.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$ENGINE_DIR/hooks"
PE_GATE="$ENGINE_DIR/scripts/pe_gate.py"
TMP="$(mktemp -d -t pe_hooks_test.XXXXXX)"
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

# Pick a python3 that has hasattr(sys.version_info, "major") >= 3.
PY="${PE_PYTHON:-python3}"
export PE_PYTHON="$PY"

# Scaffold a fresh git repo with one staged file.
REPO="$TMP/repo"
mkdir -p "$REPO"
cd "$REPO"
git init -q
git config user.email "test@example.com"
git config user.name "test"
echo "hello" > file.txt
git add file.txt
export CLAUDE_PROJECT_DIR="$REPO"

STAGED_SHA=$(git diff --cached | git hash-object --stdin)

# Helper: fake tool event JSON.
event_json() {
    local tool="$1" cmd_or_file="$2"
    case "$tool" in
        Bash)
            "$PY" -c '
import json, sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1],"description":""}}))
' "$cmd_or_file" ;;
        Edit|Write)
            "$PY" -c '
import json, sys
print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))
' "$tool" "$cmd_or_file" ;;
    esac
}

# ─── Test 1: non-commit Bash call passes through ─────────────────────────
echo "Test 1: non-commit Bash call passes through"
if event_json Bash "ls -la" | "$HOOKS/pre-commit-envelope-check.sh" >/dev/null 2>&1; then
    assert "ls allowed (exit 0)" "true"
else
    assert "ls allowed (exit 0)" "false"
fi

# ─── Test 2: git commit with no envelope record is blocked ───────────────
echo "Test 2: git commit with no envelope record is blocked"
rm -rf "$REPO/.claude"
if event_json Bash 'git commit -m "test"' | "$HOOKS/pre-commit-envelope-check.sh" >/dev/null 2>&1; then
    assert "git commit blocked (exit 2)" "false"
else
    rc=$?
    assert "git commit blocked with exit 2" "[ $rc -eq 2 ]"
fi

# ─── Test 3: git commit with stale diff_sha is blocked ───────────────────
echo "Test 3: git commit with stale diff_sha is blocked"
# Build a PASS transcript that pe gate parse will accept, then record it
# against a WRONG diff_sha, then simulate git commit.
cat > "$TMP/transcript.md" <<'EOF'
Some agent output.

Envelope key values
  schema_version: 1.0.0
  gate_name: code-reviewer
  verdict: PASS
  failure_class: none
  model_used: test-model
  timestamp: 2026-07-02T12:00:00Z

```json gate-envelope
{
  "schema_version": "1.0.0",
  "gate_name": "code-reviewer",
  "verdict": "PASS",
  "failure_class": "none",
  "model_used": "test-model",
  "timestamp": "2026-07-02T12:00:00Z",
  "findings": []
}
```
EOF
mkdir -p "$REPO/.claude/gates"
"$PY" "$PE_GATE" --record "$REPO/.claude/gates/last-gate.json" --diff-sha "wrong0000000000000000000000000000000000" "$TMP/transcript.md" >/dev/null 2>&1
if event_json Bash 'git commit -m "test"' | "$HOOKS/pre-commit-envelope-check.sh" >/dev/null 2>&1; then
    assert "git commit blocked on stale diff_sha" "false"
else
    rc=$?
    assert "git commit blocked with exit 2 on stale sha" "[ $rc -eq 2 ]"
fi

# ─── Test 4: git commit with fresh PASS envelope is allowed ──────────────
echo "Test 4: git commit with fresh PASS envelope is allowed"
"$PY" "$PE_GATE" --record "$REPO/.claude/gates/last-gate.json" --diff-sha "$STAGED_SHA" "$TMP/transcript.md" >/dev/null 2>&1
if event_json Bash 'git commit -m "test"' | "$HOOKS/pre-commit-envelope-check.sh" >/dev/null 2>&1; then
    assert "git commit allowed with fresh PASS envelope" "true"
else
    assert "git commit allowed with fresh PASS envelope" "false"
fi

# ─── Test 5: git commit with FAIL envelope is blocked ────────────────────
echo "Test 5: git commit with FAIL envelope is blocked"
cat > "$TMP/transcript_fail.md" <<'EOF'
Some agent output.

Envelope key values
  schema_version: 1.0.0
  gate_name: code-reviewer
  verdict: FAIL
  failure_class: worker_quality
  model_used: test-model
  timestamp: 2026-07-02T12:00:00Z

```json gate-envelope
{
  "schema_version": "1.0.0",
  "gate_name": "code-reviewer",
  "verdict": "FAIL",
  "failure_class": "worker_quality",
  "model_used": "test-model",
  "timestamp": "2026-07-02T12:00:00Z",
  "findings": []
}
```
EOF
# --record only fires on PASS/WARN, so a FAIL parse won't overwrite;
# reset to a stale/FAIL sidecar by hand.
"$PY" -c '
import json
open("'"$REPO/.claude/gates/last-gate.json"'","w").write(json.dumps({
  "envelope": {"verdict":"FAIL"},
  "verdict": "FAIL",
  "gate_name": "code-reviewer",
  "diff_sha": "'"$STAGED_SHA"'",
  "recorded_at": "2026-07-02T12:00:00Z"
}))
'
if event_json Bash 'git commit -m "test"' | "$HOOKS/pre-commit-envelope-check.sh" >/dev/null 2>&1; then
    assert "git commit blocked on FAIL verdict" "false"
else
    rc=$?
    assert "git commit blocked with exit 2 on FAIL" "[ $rc -eq 2 ]"
fi

# ─── Test 6: --dry-run bypasses ──────────────────────────────────────────
echo "Test 6: --dry-run bypasses"
rm -f "$REPO/.claude/gates/last-gate.json"
if event_json Bash 'git commit --dry-run' | "$HOOKS/pre-commit-envelope-check.sh" >/dev/null 2>&1; then
    assert "--dry-run allowed even with no envelope" "true"
else
    assert "--dry-run allowed even with no envelope" "false"
fi

# ─── Test 7: PE_SKIP_COMMIT_GATE=1 bypasses ──────────────────────────────
echo "Test 7: PE_SKIP_COMMIT_GATE=1 bypasses"
if PE_SKIP_COMMIT_GATE=1 event_json Bash 'git commit -m "test"' | PE_SKIP_COMMIT_GATE=1 "$HOOKS/pre-commit-envelope-check.sh" 2>/tmp/pe_hooks_bypass_err >/dev/null; then
    assert "PE_SKIP_COMMIT_GATE=1 allows" "true"
    assert "bypass logs to stderr" "grep -q 'PE_SKIP_COMMIT_GATE' /tmp/pe_hooks_bypass_err"
else
    assert "PE_SKIP_COMMIT_GATE=1 allows" "false"
fi

# ─── Test 8: post-edit-lint never fails ──────────────────────────────────
echo "Test 8: post-edit-lint never fails on any input"
echo "print('hi')" > "$TMP/sample.py"
if event_json Edit "$TMP/sample.py" | "$HOOKS/post-edit-lint.sh" >/dev/null 2>&1; then
    assert "post-edit-lint exits 0 on valid python" "true"
else
    assert "post-edit-lint exits 0 on valid python" "false"
fi
# Malformed JSON stdin should still not crash
if echo "not json" | "$HOOKS/post-edit-lint.sh" >/dev/null 2>&1; then
    assert "post-edit-lint tolerates malformed input" "true"
else
    assert "post-edit-lint tolerates malformed input" "false"
fi

# ─── Test 9: stop-uncommitted-reminder ───────────────────────────────────
echo "Test 9: stop-uncommitted-reminder"
# Dirty repo (file.txt still staged) → should exit 0 and print something
OUT_LEN=$(echo "{}" | "$HOOKS/stop-uncommitted-reminder.sh" 2>&1 | wc -c | tr -d ' ')
assert "stop hook emits advisory on dirty repo" "[ $OUT_LEN -gt 0 ]"
# Commit + clean repo → should be silent
git -c commit.gpgsign=false commit -q -m "clean" 2>/dev/null || true
OUT2_LEN=$(echo "{}" | "$HOOKS/stop-uncommitted-reminder.sh" 2>&1 | wc -c | tr -d ' ')
assert "stop hook silent on clean repo" "[ $OUT2_LEN -eq 0 ]"

echo ""
echo "─────────────────────────────────────"
echo "  passed: $pass"
echo "  failed: $fail"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
