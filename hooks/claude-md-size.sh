#!/usr/bin/env bash
# claude-md-size — pre-commit hook that warns (does not block) when
# CLAUDE.md exceeds the configured size threshold.
#
# Default: 40,000 chars (the Claude Code performance soft-threshold).
# Override via ENGINE_CLAUDE_MD_LIMIT.
#
# Install:
#   - id: claude-md-size
#     entry: hooks/claude-md-size.sh
#     language: script
#     stages: [pre-commit]

set -euo pipefail

LIMIT="${ENGINE_CLAUDE_MD_LIMIT:-40000}"

if [ ! -f CLAUDE.md ]; then
    exit 0
fi

SIZE=$(wc -c < CLAUDE.md | tr -d ' ')

if [ "$SIZE" -le "$LIMIT" ]; then
    exit 0
fi

cat >&2 <<EOF
⚠ claude-md-size: CLAUDE.md is $SIZE chars (limit: $LIMIT).

Large CLAUDE.md files slow every session start (Claude re-loads the
file each turn). Consider:

  - Moving milestone history → docs/PHASE_HISTORY.md
  - Moving rule detail → docs/RULES_DETAIL.md
  - Moving session logs → docs/SESSION_*.md

This is a WARNING, not a block. Commit proceeds.

To suppress: set ENGINE_CLAUDE_MD_LIMIT to your acceptable threshold.
EOF
exit 0
