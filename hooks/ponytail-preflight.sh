#!/usr/bin/env bash
# ponytail-preflight.sh — PreToolUse hook that surfaces the Ponytail
# decision-ladder BEFORE Write / Edit / MultiEdit actually touches disk (A5).
#
# The hook is ADVISORY, not blocking. It exits 0 always so no operator
# ever hits a "hook rejected my Write" cycle they can't diagnose. What
# it does emit is a short reminder of the ladder, plus a heuristic
# warning when the pending write is unusually large (new file over
# LARGE_FILE_THRESHOLD lines OR modification adding a big block) —
# those are the moments the ladder is easiest to skip and the
# consequences are worst.
#
# Contract with Claude Code:
#   - Reads the PreToolUse event JSON from stdin (tool name, params).
#   - Fires only for Write / Edit / MultiEdit.
#   - Emits ladder text to stdout (advisory) and returns 0.
#   - Never mutates any file.
#
# Wired into hooks/hooks.json PreToolUse. Skipped silently if:
#   - No JSON on stdin (dry-run / probe).
#   - The tool isn't a code-writing tool.
#   - The pending write is small AND the ladder was already surfaced
#     in this session (deduped via .pe/ponytail-preflight-seen.state
#     with a 10-minute TTL — keeps the reminder from spamming a
#     long edit session).

set -u
# NOT -e — we do NOT want a hook failure to look like a Write rejection.

LARGE_FILE_THRESHOLD=50
STATE_TTL_SEC=600
STATE_DIR=".pe"
STATE_FILE="$STATE_DIR/ponytail-preflight-seen.state"

# Fast bail-out if we can't read stdin (e.g. hook invoked without an event).
if [ -t 0 ]; then
    exit 0
fi

# Buffer the whole event — small (a few KB).
event=$(cat 2>/dev/null || true)
if [ -z "$event" ]; then
    exit 0
fi

# Extract tool_name (fallback grep — pure bash, no jq requirement).
tool_name=$(printf '%s' "$event" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"tool_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

case "$tool_name" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
esac

# Estimate write-size — look at content / new_string length. Rough
# line-count via newline grep. The two shapes we care about:
#   Write: {"content": "..."}
#   Edit / MultiEdit: {"new_string": "..."}
# Pass the event via env var — piping + heredoc both compete for
# python's stdin and the heredoc wins, silently dropping the event.
new_content=$(PONYTAIL_EVENT="$event" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
try:
    ev = json.loads(os.environ.get("PONYTAIL_EVENT", ""))
except Exception:
    sys.exit(0)
params = ev.get("tool_input") or ev.get("params") or {}
# Write
if "content" in params:
    print(params["content"], end="")
    sys.exit(0)
# Edit
if "new_string" in params:
    print(params["new_string"], end="")
    sys.exit(0)
# MultiEdit — sum all new_strings
edits = params.get("edits") or []
if edits:
    out = []
    for e in edits:
        ns = e.get("new_string")
        if isinstance(ns, str):
            out.append(ns)
    print("\n".join(out), end="")
PY
)

# Cheap line-count. Empty → 0.
if [ -z "$new_content" ]; then
    line_count=0
else
    # `|| true`, not `|| echo 0` — see code-review-trailer.sh:32.
    line_count=$(printf '%s' "$new_content" | grep -c '' 2>/dev/null || true)
fi

# Session-dedupe — surface once per project per 10 minutes unless the
# write is LARGE (large writes always get the reminder).
already_shown=0
if [ "$line_count" -lt "$LARGE_FILE_THRESHOLD" ] && [ -f "$STATE_FILE" ]; then
    last_ts=$(cat "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$last_ts" ]; then
        now=$(date +%s 2>/dev/null || echo 0)
        # Guard: last_ts must be numeric
        case "$last_ts" in
            ''|*[!0-9]*) last_ts=0 ;;
        esac
        delta=$((now - last_ts))
        if [ "$delta" -lt "$STATE_TTL_SEC" ] && [ "$delta" -ge 0 ]; then
            already_shown=1
        fi
    fi
fi

if [ "$already_shown" -eq 1 ]; then
    exit 0
fi

# Record surface timestamp (best-effort, ignore mkdir/permission errors).
mkdir -p "$STATE_DIR" 2>/dev/null || true
date +%s > "$STATE_FILE" 2>/dev/null || true

# Emit the advisory.
if [ "$line_count" -ge "$LARGE_FILE_THRESHOLD" ]; then
    cat <<EOF
[ponytail] Large write pending (~${line_count} lines).

Walk the decision-ladder BEFORE saving:
  needs to exist?  →  stdlib?  →  platform-native?  →
  installed dep?   →  one line?  →  only then write minimum.

Fewer lines is less attack surface (S) and fewer bugs. If a new
dependency is required, an explicit "Ponytail: allow <reason>" line
belongs in your envelope so the size-budget hook doesn't flag it.
EOF
else
    cat <<'EOF'
[ponytail] Reminder: needs to exist? → stdlib? → platform-native? → installed dep? → one line? → only then write minimum.
EOF
fi

exit 0
