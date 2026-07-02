#!/usr/bin/env bash
# claude-md-size — dual-mode CLAUDE.md size guard.
#
# Runs in two modes with the same thresholds:
#
#   1. PRE-COMMIT (git-side, pre-commit framework):
#      Invoked with no stdin; scans CLAUDE.md in the working tree.
#      Above WARN threshold: prints warning, exit 0 (advisory).
#      Above FAIL threshold: prints error, exit 1 (blocks commit).
#
#   2. POSTTOOLUSE (Claude Code, Edit/Write/MultiEdit):
#      Invoked with a JSON tool event on stdin. If the edited file is
#      CLAUDE.md (root or nested), the size check fires with the same
#      thresholds. Warnings go to stderr so Claude sees them in the
#      turn's tool feedback.
#
# Thresholds (bytes):
#   WARN — ENGINE_CLAUDE_MD_WARN, default 12000 (~12 KB, ~3k tokens)
#   FAIL — ENGINE_CLAUDE_MD_FAIL, default 20000 (~20 KB, ~5k tokens)
#
# Rationale: CLAUDE.md is re-loaded into every session turn. A 74KB
# CLAUDE.md (the incident that motivated this hook) burns ~19k input
# tokens per turn. 12KB / 20KB keep per-turn overhead bounded.
#
# Suppress in an emergency:
#   PE_SKIP_CLAUDE_MD_SIZE=1 git commit ...

set -euo pipefail

# Back-compat: if ENGINE_CLAUDE_MD_LIMIT is set (legacy single-threshold
# var), map it to FAIL. Deprecated but respected for one release cycle.
if [ -n "${ENGINE_CLAUDE_MD_LIMIT:-}" ] && [ -z "${ENGINE_CLAUDE_MD_FAIL:-}" ]; then
    ENGINE_CLAUDE_MD_FAIL="$ENGINE_CLAUDE_MD_LIMIT"
fi

WARN="${ENGINE_CLAUDE_MD_WARN:-12000}"
FAIL="${ENGINE_CLAUDE_MD_FAIL:-20000}"

if [ "${PE_SKIP_CLAUDE_MD_SIZE:-0}" = "1" ]; then
    exit 0
fi

# Detect invocation mode. PostToolUse hooks receive JSON on stdin.
MODE="pre-commit"
STDIN_JSON=""
if [ ! -t 0 ]; then
    STDIN_JSON="$(cat 2>/dev/null || true)"
    if [ -n "$STDIN_JSON" ] && printf '%s' "$STDIN_JSON" | grep -q '"tool_name"'; then
        MODE="posttooluse"
    fi
fi

# Resolve which CLAUDE.md to check.
target_file=""

if [ "$MODE" = "posttooluse" ]; then
    # Extract file_path from tool_input. Only fire when the edit
    # touched a CLAUDE.md.
    edited_path="$(printf '%s' "$STDIN_JSON" \
        | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    ti=d.get("tool_input",{}) or {}
    print(ti.get("file_path","") or ti.get("path",""))
except Exception:
    print("")' 2>/dev/null || printf '')"
    case "$(basename -- "$edited_path" 2>/dev/null)" in
        CLAUDE.md) target_file="$edited_path" ;;
        *) exit 0 ;;
    esac
else
    if [ -f CLAUDE.md ]; then
        target_file="CLAUDE.md"
    else
        exit 0
    fi
fi

if [ ! -f "$target_file" ]; then
    exit 0
fi

SIZE=$(wc -c < "$target_file" | tr -d ' ')

if [ "$SIZE" -le "$WARN" ]; then
    exit 0
fi

human_size=$(awk -v s="$SIZE" 'BEGIN{printf "%.1f KB", s/1024}')

if [ "$SIZE" -gt "$FAIL" ]; then
    cat >&2 <<EOF
✗ claude-md-size: $target_file is $human_size ($SIZE bytes) — HARD LIMIT $FAIL bytes.

CLAUDE.md is re-loaded into every session turn. Above $FAIL bytes,
per-turn context cost becomes measurable (>5k tokens/turn just for
this file). Break it up:

  - Milestone history      → docs/PHASE_HISTORY.md
  - Detailed rules         → docs/RULES_DETAIL.md or ~/.claude/skills/
  - Session logs           → docs/sessions/SESSION_*.md
  - Domain-specific spec   → docs/<domain>.md, imported on demand

Bypass this commit (logged):
  PE_SKIP_CLAUDE_MD_SIZE=1 git commit ...

Or raise the hard cap (not recommended):
  ENGINE_CLAUDE_MD_FAIL=$SIZE git commit ...
EOF
    exit 1
fi

# WARN < SIZE <= FAIL — advisory
cat >&2 <<EOF
⚠ claude-md-size: $target_file is $human_size ($SIZE bytes) — over soft limit $WARN bytes.

Consider trimming toward $WARN bytes before this file crosses the hard
limit at $FAIL bytes. Common moves:

  - Milestone history      → docs/PHASE_HISTORY.md
  - Detailed rules         → docs/RULES_DETAIL.md or ~/.claude/skills/
  - Session logs           → docs/sessions/SESSION_*.md

This is a WARNING, not a block. Commit proceeds.
EOF
exit 0
