#!/usr/bin/env bash
# cache-hygiene-warn.sh — TOK1 advisory hook: warn when a Write / Edit
# mutates the loaded prompt prefix (CLAUDE.md, agent .md, rules .md)
# mid-session, which BREAKS Anthropic's ~90% prompt-cache discount for
# the rest of the session.
#
# Advisory only — exits 0 always. Fires on PostToolUse for
# Write / Edit / MultiEdit against known prefix files. Not chatty:
# only fires once per prefix file per session (state under
# .pe/cache-hygiene-seen.state).
#
# The engine's principle:
#   Prompt cache is FREE money — but only if the prefix stays stable.
#   Batch prefix edits to session end. Mid-session prefix mutations
#   force the whole prefix to be re-billed on every subsequent turn
#   at full input-token rates (~10× the cache-hit rate).

set -uo pipefail

STATE_DIR=".pe"
STATE_FILE="$STATE_DIR/cache-hygiene-seen.state"

if [ -t 0 ]; then
    exit 0
fi

event=$(cat 2>/dev/null || true)
[ -z "$event" ] && exit 0

# Extract tool + file path (best-effort grep; no jq requirement).
tool_name=$(printf '%s' "$event" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"tool_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
case "$tool_name" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
esac

file_path=$(PONYTAIL_EVENT="$event" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
try:
    ev = json.loads(os.environ.get("PONYTAIL_EVENT", ""))
except Exception:
    sys.exit(0)
params = ev.get("tool_input") or ev.get("params") or {}
p = params.get("file_path") or params.get("path") or ""
print(p, end="")
PY
)

# Match prefix files by basename or path pattern.
# CLAUDE.md at any level, agent .md files, rules .md files.
case "$file_path" in
    */CLAUDE.md|CLAUDE.md) is_prefix=1 ;;
    */.claude/agents/*.md|*/agents/*.md) is_prefix=1 ;;
    */.claude/CLAUDE.md) is_prefix=1 ;;
    */rules/*.md|*/.claude/rules/*.md) is_prefix=1 ;;
    *) is_prefix=0 ;;
esac

[ "$is_prefix" -eq 0 ] && exit 0

# Dedupe per prefix file — one nudge per file per session.
mkdir -p "$STATE_DIR" 2>/dev/null || true
if [ -f "$STATE_FILE" ] && grep -qxF "$file_path" "$STATE_FILE" 2>/dev/null; then
    exit 0
fi
echo "$file_path" >> "$STATE_FILE" 2>/dev/null || true

cat <<EOF
[cache-hygiene] Editing $file_path breaks the prompt cache for the
rest of this session. Every subsequent turn re-bills the whole
prefix at full input-token rates (~10× the cache-hit rate).

Prefer: batch prefix edits to session end. If you MUST edit
mid-session, the next few turns will be materially more expensive —
factor that into whether to keep the session or start fresh.

See docs/OPERATOR_WORKFLOW_V3.md § Cache hygiene.
EOF

exit 0
