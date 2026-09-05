#!/usr/bin/env bash
# tests/test_claude_md_size_config.sh — one threshold, both modes.
#
# claude-md-size is dual-mode and its own header promises the two modes run
# "with the same thresholds". They could not. The only way to set a threshold
# was ENGINE_CLAUDE_MD_WARN / _FAIL, and the natural place an adopter writes
# those is the pre-commit entry line:
#
#     entry: env ENGINE_CLAUDE_MD_WARN=30000 ENGINE_CLAUDE_MD_FAIL=45000
#            scripts/hooks/engine.sh claude-md-size.sh
#
# That assignment exists only for the pre-commit invocation. The PostToolUse
# copy is launched by Claude Code and never sees it, so it silently falls
# back to 12000/20000. Measured on Origyn — CLAUDE.md at 40,693 bytes, raised
# to 30k/45k while a split finishes — the two modes return OPPOSITE verdicts
# on the same file: git-side passes, Claude-side hard-fails.
#
# A threshold that can only be expressed where half the hook cannot read it
# is the engine's own recurring defect: a documented control with no
# mechanism behind it. The fix is a config file both modes can read.
#
# Precedence, asserted below: env var > .process-engine.yaml > default.
# Env stays on top because the pre-commit entry line above is already in the
# field and must keep working.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ROOT/hooks/claude-md-size.sh"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "test_claude_md_size_config"

OUT="$TMP/.out"

# Build a project whose CLAUDE.md is over the engine default (20k) but under
# a raised local limit — the exact shape of the collision.
make_proj() {   # $1=dir  $2=bytes  [$3=yaml body]
    mkdir -p "$1"
    "${PE_PYTHON:-python3}" -c "
import sys
open(sys.argv[1] + '/CLAUDE.md','w').write('x' * int(sys.argv[2]))
" "$1" "$2"
    [ -n "${3:-}" ] && printf '%s' "$3" > "$1/.process-engine.yaml"
    return 0
}

# pre-commit mode: no stdin JSON, cwd is the project.
run_precommit() {   # $1=project  [env...]
    local proj="$1"; shift
    ( cd "$proj" && env "$@" bash "$HOOK" </dev/null ) >"$OUT" 2>&1
}

# PostToolUse mode: a tool event naming the edited CLAUDE.md.
run_posttooluse() {   # $1=project  [env...]
    local proj="$1"; shift
    printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/CLAUDE.md"}}' "$proj" \
      | ( cd "$proj" && env CLAUDE_PROJECT_DIR="$proj" "$@" bash "$HOOK" ) >"$OUT" 2>&1
}

YAML='claude_md:
  warn_bytes: 30000
  fail_bytes: 45000
'

# ─── 1. the collision itself ────────────────────────────────────────
# 40,693 bytes — Origyn's real size — against a project that has declared
# 30k/45k. Both modes must agree, and both must allow.
P1="$TMP/p1"; make_proj "$P1" 40693 "$YAML"

run_precommit "$P1"; rc=$?
[ "$rc" -eq 0 ] \
    && ok "pre-commit mode honours .process-engine.yaml (40693 < 45000)" \
    || bad "pre-commit mode blocked at the declared limit (rc=$rc): $(cat "$OUT")"

run_posttooluse "$P1"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "PostToolUse mode reads the SAME config — no opposite verdict"
else
    bad "PostToolUse mode fell back to the 20000 default (rc=$rc): $(cat "$OUT")"
fi

# ─── 2. the config must not disarm the gate ─────────────────────────
# Raising a limit is a decision an adopter is allowed to make; ignoring it
# is not. Over the DECLARED limit, both modes still fail.
P2="$TMP/p2"; make_proj "$P2" 50000 "$YAML"

run_precommit "$P2"; rc=$?
[ "$rc" -ne 0 ] \
    && ok "pre-commit still fails past the declared limit (50000 > 45000)" \
    || bad "the config disarmed the gate instead of moving it"

run_posttooluse "$P2"; rc=$?
[ "$rc" -ne 0 ] \
    && ok "PostToolUse still fails past the declared limit" \
    || bad "PostToolUse passed a file over the declared hard limit"

# ─── 3. precedence: env wins, because the field already uses it ─────
# The pre-commit entry line in Origyn sets env directly. That must keep
# working and must keep winning, or this fix breaks the installed base.
P3="$TMP/p3"; make_proj "$P3" 40693 "$YAML"
run_precommit "$P3" ENGINE_CLAUDE_MD_FAIL=25000; rc=$?
[ "$rc" -ne 0 ] \
    && ok "env overrides the yaml — the installed pre-commit line still wins" \
    || bad "yaml silently overrode an explicit env threshold"

# ─── 4. no config = the engine's own standard, unchanged ────────────
P4="$TMP/p4"; make_proj "$P4" 40693
run_precommit "$P4"; rc=$?
[ "$rc" -ne 0 ] \
    && ok "with no config the 20000 default still applies — standard intact" \
    || bad "removing the config also removed the default"

P5="$TMP/p5"; make_proj "$P5" 5000
run_precommit "$P5"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$OUT" ] \
    && ok "a small CLAUDE.md is silent in both the default and config cases" \
    || bad "spoke about a 5KB CLAUDE.md (rc=$rc): $(cat "$OUT")"

# ─── 5. a malformed config must not brick the hook ──────────────────
# This runs on every Edit and on every commit. Unreadable config falls back
# to the default; it never crashes and never silently allows.
P6="$TMP/p6"; make_proj "$P6" 40693 'claude_md: [this is not: valid'
run_precommit "$P6"; rc=$?
[ "$rc" -eq 1 ] \
    && ok "a malformed config falls back to the default, still gating" \
    || bad "malformed config produced rc=$rc — crashed or allowed silently"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
