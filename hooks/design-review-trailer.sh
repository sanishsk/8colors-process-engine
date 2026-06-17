#!/usr/bin/env bash
# design-review-trailer — commit-msg hook that blocks UI/visual commits
# (templates, static JS/CSS, design tokens) without one of:
#
#   Design-reviewed: <agent-name or "self">
#   Design-skip-reason: <short reason>
#
# UI files default: templates/**.html, static/js/**.js, static/css/**.css,
# and any docs/design*. Override via ENGINE_UI_FILES (regex).
#
# Origin: 8CStudio Design Engine — every visual change must pass through
# the ui-ux-design-agent (or have a logged skip reason) to prevent drift.
#
# Install:
#   - id: design-review-trailer
#     entry: hooks/design-review-trailer.sh
#     language: script
#     stages: [commit-msg]

set -euo pipefail

MSG_FILE="${1:?Usage: $0 <commit-msg-file>}"
DEFAULT_RE='^(templates/.*\.html|static/js/.*\.js|static/css/.*\.css|docs/design.*\.md)$'
UI_RE="${ENGINE_UI_FILES:-$DEFAULT_RE}"

UI_HITS=$(git diff --cached --name-only | grep -E "$UI_RE" || true)
if [ -z "$UI_HITS" ]; then
    exit 0
fi

MSG=$(cat "$MSG_FILE")
if echo "$MSG" | grep -qE '^(Design-reviewed:|Design-skip-reason:)'; then
    exit 0
fi

cat >&2 <<EOF
✗ design-review-trailer: this commit changes UI files:

$(echo "$UI_HITS" | sed 's/^/    /')

…but the commit message lacks a Design-reviewed trailer.

Add ONE of these as a trailer:

  Design-reviewed: ui-ux-design-agent
  Design-reviewed: self
  Design-skip-reason: <short reason — e.g. "bug fix, no visual change">

Use 'self' when you've reviewed your own diff in the browser. Use
the agent name when the ui-ux-design-agent has reviewed.

To bypass for a hotfix: git commit --no-verify
EOF
exit 1
