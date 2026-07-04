#!/usr/bin/env bash
# _trailer-contract.sh — shared envelope-resolution + verdict parsing
# for the trailer hooks (code-review, security-review, design-review,
# perf-gate).
#
# The four hooks each carried ~30–40 lines of near-identical logic to:
#   1. Validate the trailer value looks like a hex sha256 prefix.
#   2. Resolve the sha against `.claude/gates/last-gate.json` (or a
#      per-hook named record like `perf.json`, `security.json`,
#      `last-design-review.json`).
#   3. Fall back to `.claude/gates/<sha>.json`.
#   4. Parse the record's `verdict` field with a small python one-liner.
#   5. Accept PASS/WARN; block anything else.
#
# Bugs in that block had to be fixed in four places. Extract it once,
# preserving each hook's per-scope named-record precedence, and shrink
# each hook's envelope path to ~8 lines.
#
# Contract (source this file, then call):
#
#   pe_trailer_is_sha "<trailer-value>"
#       Exit 0 if the value is 8–64 hex chars, else 1. No output.
#
#   pe_trailer_resolve_record "<sha>" [<named-record>] [<named-record>...]
#       Iterate named-record paths (relative to repo root) in the given
#       precedence order, plus the always-present fallback
#       `.claude/gates/<sha>.json`. First candidate whose sha256 prefix
#       matches OR whose filename matches is echoed to stdout; nothing
#       is echoed on no-match. Never fails; caller checks for empty.
#
#   pe_trailer_verdict "<record-path>"
#       Echo the record's `verdict` field. Echo "PARSE_ERROR" if the
#       file can't be read as JSON. Echo empty string if the field is
#       absent. Never fails.
#
# All three helpers are pure — no side effects, no exits, no globals
# beyond the standard shell env. Safe to source multiple times.

# ─── validators ────────────────────────────────────────────────────

pe_trailer_is_sha() {
    local candidate="${1:-}"
    printf '%s' "$candidate" | grep -qE '^[0-9a-fA-F]{8,64}$'
}

# ─── record resolution ─────────────────────────────────────────────

pe_trailer_resolve_record() {
    local sha="$1"
    shift || true

    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    local sha_len="${#sha}"

    # Iterate the per-hook named records in precedence order. Each is
    # relative to the repo root.
    local named
    for named in "$@"; do
        [ -z "$named" ] && continue
        local path="$repo_root/$named"
        [ -f "$path" ] || continue
        local file_sha
        file_sha=$(shasum -a 256 "$path" 2>/dev/null | awk '{print $1}')
        if [ -z "$file_sha" ]; then
            continue
        fi
        if [ "${file_sha:0:$sha_len}" = "$sha" ]; then
            printf '%s\n' "$path"
            return 0
        fi
    done

    # Always-present fallback: `.claude/gates/<sha>.json` (a
    # per-envelope named record).
    local direct="$repo_root/.claude/gates/$sha.json"
    if [ -f "$direct" ]; then
        printf '%s\n' "$direct"
        return 0
    fi

    return 0
}

# ─── verdict parsing ───────────────────────────────────────────────

pe_trailer_verdict() {
    local record="${1:-}"
    [ -z "$record" ] && { printf '' ; return 0; }
    # Reads `verdict` at the top level first, falling back to
    # `envelope.verdict` (the design-review record shape). Uppercases
    # the result so downstream case-matches don't have to normalize.
    "${PE_PYTHON:-python3}" -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    v = data.get("verdict")
    if not isinstance(v, str) or not v:
        env = data.get("envelope")
        if isinstance(env, dict):
            v = env.get("verdict")
    print((v or "").upper() if isinstance(v, str) else "")
except Exception:
    print("PARSE_ERROR")
' "$record"
}
