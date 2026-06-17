#!/usr/bin/env bash
# code-review-trailer — commit-msg hook that blocks commits ≥THRESHOLD files
# without one of these trailers:
#
#   Code-reviewed: <agent-name>
#   Code-skip-reason: <short reason>
#
# Defaults to threshold=5. Override via the env var ENGINE_REVIEW_THRESHOLD.
#
# Install via .pre-commit-config.yaml:
#
#   - repo: local
#     hooks:
#       - id: code-review-trailer
#         name: Code-reviewed trailer required on multi-file commits
#         entry: hooks/code-review-trailer.sh
#         language: script
#         stages: [commit-msg]
#
# Origin: 8CStudio Wave 1H/1M pattern — code-reviewer agent CRITICAL/HIGH
# blocks made mandatory, with explicit skip-reason logged when skipped.

set -euo pipefail

MSG_FILE="${1:?Usage: $0 <commit-msg-file>}"
THRESHOLD="${ENGINE_REVIEW_THRESHOLD:-5}"

# Count files staged for this commit
NUM_FILES=$(git diff --cached --name-only | wc -l | tr -d ' ')

if [ "$NUM_FILES" -lt "$THRESHOLD" ]; then
    exit 0
fi

MSG=$(cat "$MSG_FILE")
if echo "$MSG" | grep -qE '^(Code-reviewed:|Code-skip-reason:)'; then
    exit 0
fi

cat >&2 <<EOF
✗ code-review-trailer: commit touches $NUM_FILES files (≥$THRESHOLD threshold)
  but lacks a code-review trailer.

Add ONE of these as a trailer in your commit message:

  Code-reviewed: code-reviewer
  Code-skip-reason: <short reason, e.g. "single-file refactor, no behavior change">

The code-reviewer agent is your gate against CRITICAL / HIGH findings
landing in master. Skipping is allowed but must be explicit.

To bypass this hook for a hotfix: git commit --no-verify
(but log the bypass in your session log).
EOF
exit 1
