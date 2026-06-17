#!/usr/bin/env bash
# docs-updated-trailer — commit-msg hook that blocks structural commits
# (those changing CLAUDE.md, README.md, schema files, or `docs/architecture.md`)
# without one of:
#
#   Docs-updated: <paths-or-rationale>
#   Docs-skip-reason: <short reason>
#
# Structural files default: CLAUDE.md, README.md, docs/architecture.md,
# docs/schema*.md, schema.sql. Override via ENGINE_STRUCTURAL_FILES (regex).
#
# Install:
#   - id: docs-updated-trailer
#     entry: hooks/docs-updated-trailer.sh
#     language: script
#     stages: [commit-msg]

set -euo pipefail

MSG_FILE="${1:?Usage: $0 <commit-msg-file>}"
DEFAULT_RE='^(CLAUDE\.md|README\.md|docs/architecture\.md|docs/schema.*\.md|schema\.sql)$'
STRUCTURAL_RE="${ENGINE_STRUCTURAL_FILES:-$DEFAULT_RE}"

STRUCTURAL_HITS=$(git diff --cached --name-only | grep -E "$STRUCTURAL_RE" || true)
if [ -z "$STRUCTURAL_HITS" ]; then
    exit 0
fi

MSG=$(cat "$MSG_FILE")
if echo "$MSG" | grep -qE '^(Docs-updated:|Docs-skip-reason:)'; then
    exit 0
fi

cat >&2 <<EOF
✗ docs-updated-trailer: this commit changes structural docs:

$(echo "$STRUCTURAL_HITS" | sed 's/^/    /')

…but the commit message lacks a Docs-updated trailer.

Add ONE of these as a trailer:

  Docs-updated: <comma-separated paths or short rationale>
  Docs-skip-reason: <short reason>

This catches the case where you changed CLAUDE.md or the schema doc
but forgot to update the section that consumes it.

To bypass for a hotfix: git commit --no-verify
EOF
exit 1
