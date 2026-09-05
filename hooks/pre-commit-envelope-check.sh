#!/usr/bin/env bash
# pre-commit-envelope-check — Claude Code PreToolUse hook (P1.1).
#
# Fires on every Bash tool use. If the command is a git commit, requires
# a fresh code-reviewer envelope (PASS or WARN) at .claude/gates/last-gate.json
# whose diff_sha matches the currently-staged diff. Blocks the commit
# otherwise via exit code 2 (Claude Code's "deny" contract).
#
# The staged-diff SHA is computed from `git diff --cached` bytes, so any
# further edit invalidates the recorded envelope — the human/agent must
# re-run the code-reviewer gate.
#
# Bypass: an operator running `git commit --no-verify` would bypass the
# git-side pre-commit framework; this hook (Claude Code side) still fires.
# To bypass THIS hook, set PE_SKIP_COMMIT_GATE=1 in the environment for
# the session — logged in stderr so the bypass is observable.
#
# Reads tool event JSON on stdin:
#   {"tool_name":"Bash","tool_input":{"command":"...","description":"..."}}
#
# Contract:
#   exit 0        — allow (not a git commit, or gate satisfied)
#   exit 2 + JSON — deny with reason surfaced to Claude

set -euo pipefail

# --- Read tool event JSON from stdin ---
INPUT="$(cat)"

# Extract tool_input.command via python (stdlib only, portable)
CMD=$("${PE_PYTHON:-python3}" -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print(data.get("tool_input", {}).get("command", ""))
except Exception:
    pass
' <<<"$INPUT")

# Only intervene on git commit invocations. Match `git commit`, `git  commit`,
# `git -c ... commit`, but NOT `git log --author=... commit=...`.
case "$CMD" in
    *"git commit"*|*"git commit "*)
        ;;
    *)
        exit 0 ;;
esac

# Skip commit-message-only invocations that don't actually create a commit
# (e.g. `git commit --dry-run`, `git commit -h`, `git commit --help`).
case "$CMD" in
    *"--dry-run"*|*"--help"*|*" -h"*)
        exit 0 ;;
esac

# Bypass env var — logged, not silent.
if [ "${PE_SKIP_COMMIT_GATE:-0}" = "1" ]; then
    echo "pre-commit-envelope-check: PE_SKIP_COMMIT_GATE=1 — allowing without gate" >&2
    exit 0
fi

# Project root — the Claude Code cwd. Fall back to git if unset.
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# ─── Path exemption — opt-in, fail-closed ───────────────────────────────
# This hook gates ANY non-empty staged diff, so a CLAUDE.md typo or a plan
# update waits on a code review of prose. An adopter hit that and wrote a
# local wrapper re-implementing the block with a path filter; every adopter
# who cares would write that wrapper and draw the line differently, which is
# the engine saying its default is wrong.
#
# EXEMPT list, not an include list. The wrapper asked "does this commit
# touch behaviour?" — fail-OPEN, because a source directory nobody added to
# the regex sails through unreviewed, silently and permanently. This asks
# "has the operator declared this exempt?", so anything unlisted is still
# gated and a forgotten path fails closed.
#
# Resolution: ENGINE_REVIEW_EXEMPT_PATHS → review_gate.exempt_paths in
# .process-engine.yaml → unset. Unset means nothing is exempt, so an engine
# upgrade never narrows a gate the adopter already installed.
EXEMPT_RE="${ENGINE_REVIEW_EXEMPT_PATHS:-}"
if [ -z "$EXEMPT_RE" ] && [ -f "$PROJECT_ROOT/.process-engine.yaml" ]; then
    _ENGINE_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || _ENGINE_DIR=""
    if [ -n "$_ENGINE_DIR" ] && [ -f "$_ENGINE_DIR/scripts/_yaml.sh" ]; then
        # shellcheck source=../scripts/_yaml.sh
        . "$_ENGINE_DIR/scripts/_yaml.sh"
        EXEMPT_RE=$(yaml_get review_gate.exempt_paths \
                        "$PROJECT_ROOT/.process-engine.yaml" 2>/dev/null || true)
    fi
fi

if [ -n "$EXEMPT_RE" ]; then
    STAGED_PATHS=$(cd "$PROJECT_ROOT" && git diff --cached --name-only 2>/dev/null || true)
    if [ -n "$STAGED_PATHS" ]; then
        # grep: 0 matched, 1 no match, >=2 error. An invalid regex must not
        # read as "nothing left unexempt" — that is the one way a typo could
        # open the gate, so the error code is checked separately from the
        # empty output it also produces.
        set +e
        UNEXEMPT=$(printf '%s\n' "$STAGED_PATHS" | grep -vE "$EXEMPT_RE" 2>/dev/null)
        _grep_rc=$?
        set -e
        if [ "$_grep_rc" -lt 2 ] && [ -z "$UNEXEMPT" ]; then
            # Every staged path is exempt. Note it — a gate that stops
            # firing should say so, or the next person reads silence as
            # "reviewed".
            echo "pre-commit-envelope-check: all staged paths match review_gate.exempt_paths — no review required" >&2
            exit 0
        fi
    fi
fi

RECORD="$PROJECT_ROOT/.claude/gates/last-gate.json"

deny() {
    local reason="$1"
    # Claude Code deny contract: exit code 2, JSON with `decision:"block"` +
    # `reason` surfaces to the model. Fall back to plain-stderr if jq/python
    # aren't available.
    "${PE_PYTHON:-python3}" -c '
import json, sys
print(json.dumps({
    "decision": "block",
    "reason": sys.argv[1],
}))
' "$reason" 2>/dev/null || echo "BLOCK: $reason" >&2
    exit 2
}

if [ ! -f "$RECORD" ]; then
    deny "code-review gate missing: no envelope recorded at .claude/gates/last-gate.json. Run the code-reviewer agent on the staged diff, then \`pe gate parse --record .claude/gates/last-gate.json --diff-sha <sha>\` on its transcript. See docs/E1_GATE_ENVELOPE.md."
fi

# Current staged-diff hash (git object-id of the diff). Empty diff → skip.
STAGED_SHA=$(cd "$PROJECT_ROOT" && git diff --cached | git hash-object --stdin 2>/dev/null || echo "")

if [ -z "$STAGED_SHA" ] || [ "$STAGED_SHA" = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" ]; then
    # Empty staging area — nothing to gate. Allow.
    exit 0
fi

# Parse the record for verdict + diff_sha.
RECORD_INFO=$("${PE_PYTHON:-python3}" -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("verdict",""))
    print(data.get("diff_sha",""))
    print(data.get("gate_name",""))
except Exception as exc:
    print("PARSE_ERROR")
    print(str(exc))
    print("")
' "$RECORD")

VERDICT=$(echo "$RECORD_INFO" | sed -n '1p')
REC_SHA=$(echo "$RECORD_INFO" | sed -n '2p')
GATE_NAME=$(echo "$RECORD_INFO" | sed -n '3p')

if [ "$VERDICT" = "PARSE_ERROR" ]; then
    deny "code-review gate corrupt: could not parse .claude/gates/last-gate.json. Re-record it via \`pe gate parse --record ...\`."
fi

case "$VERDICT" in
    PASS|WARN)
        ;;
    *)
        deny "code-review gate not PASS/WARN (recorded verdict: $VERDICT). Fix the CRITICAL/HIGH findings from ${GATE_NAME:-code-reviewer} and re-run the gate before committing."
        ;;
esac

if [ -z "$REC_SHA" ]; then
    deny "code-review envelope missing diff_sha — re-record with \`pe gate parse --record .claude/gates/last-gate.json --diff-sha \$(git diff --cached | git hash-object --stdin) <transcript>\`."
fi

if [ "$REC_SHA" != "$STAGED_SHA" ]; then
    deny "code-review envelope is stale: recorded diff_sha ${REC_SHA:0:12}… does not match currently-staged ${STAGED_SHA:0:12}…. Re-run the code-reviewer gate on the current diff."
fi

# Allow — envelope PASS/WARN and matches staged diff.
exit 0
