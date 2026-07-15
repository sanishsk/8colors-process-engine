#!/usr/bin/env bash
# stop-uncommitted-reminder — Claude Code Stop hook (P1.1).
#
# Fires when Claude wraps up its turn. If the project has uncommitted
# changes and no /end-session has been run in the current turn, nudges
# the operator to close out. Advisory only — never blocks.
#
# Silent when:
#   - not inside a git repo
#   - no uncommitted changes
#   - PE_SKIP_STOP_HINT=1 in the env

set -uo pipefail

if [ "${PE_SKIP_STOP_HINT:-0}" = "1" ]; then
    exit 0
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Not a git repo → nothing to remind.
if ! git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

# Read tool event JSON (we don't use the fields today, but drain stdin
# so the parent hook contract stays clean).
cat >/dev/null || true

DIRTY=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | head -5)
if [ -z "$DIRTY" ]; then
    exit 0
fi

COUNT=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

MSG="Session wrap: $COUNT uncommitted change(s) in this repo. Consider \`/end-session\` to close out cleanly, or commit + push if this work is ready."

# Advisory Stop response — Claude sees this as guidance, does not block turn end.
# Stop-hook schema has no "allow" decision; use systemMessage for advisory notes.
"${PE_PYTHON:-python3}" -c '
import json, sys
print(json.dumps({"systemMessage": sys.argv[1]}))
' "$MSG" 2>/dev/null || echo "$MSG" >&2

exit 0
