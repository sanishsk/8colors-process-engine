#!/usr/bin/env bash
# tests/test_hooks_documented.sh — every hook must appear in the catalogue.
#
# hooks/README.md called itself "the hook catalogue" while listing 14 of the
# 29 hooks that ship. Every hook the engine runs on ITSELF — complexity-gate,
# duplication-gate, size-budget — was missing, as was every design/motion
# hook and the whole trailer family bar three. Nobody noticed because nothing
# compared the table to the directory.
#
# Two assertions, both cheap:
#   1. Every hooks/*.sh (excluding _-prefixed libraries) is named in
#      hooks/README.md.
#   2. Every hook named in hooks/README.md still exists on disk.
#
# A hook that is deliberately wired nowhere still needs a row — put it under
# "Wired nowhere" and say so. Silence is what this test exists to prevent.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
README="$ROOT/hooks/README.md"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_hooks_documented"

[ -f "$README" ] || { echo "  ✗ hooks/README.md missing"; exit 1; }

missing=""
for h in "$ROOT"/hooks/*.sh; do
    b=$(basename "$h" .sh)
    case "$b" in _*) continue ;; esac
    grep -qF "\`$b\`" "$README" || missing="$missing $b"
done
if [ -z "$missing" ]; then
    ok "every hooks/*.sh has a catalogue row"
else
    bad "undocumented hooks:$missing"
fi

stale=""
for b in $(grep -oE '`[a-z0-9-]+`' "$README" | tr -d '`' | sort -u); do
    # Only names that look like hook ids and are claimed as such.
    [ -f "$ROOT/hooks/$b.sh" ] && continue
    grep -qE "^\| \`$b\`" "$README" && stale="$stale $b"
done
if [ -z "$stale" ]; then
    ok "no catalogue row names a hook that no longer exists"
else
    bad "catalogue rows without a script:$stale"
fi

# The size-guard row is the one that demonstrably misled an adopter into
# hand-rolling its own gate. Pin its numbers to the script's actual defaults.
warn_default=$(grep -oE 'ENGINE_CLAUDE_MD_WARN:-[0-9]+' "$ROOT/hooks/claude-md-size.sh" | head -1 | grep -oE '[0-9]+')
fail_default=$(grep -oE 'ENGINE_CLAUDE_MD_FAIL:-[0-9]+' "$ROOT/hooks/claude-md-size.sh" | head -1 | grep -oE '[0-9]+')
# An empty default would make both greps below match everything — the exact
# vacuous-pass shape this suite is here to catch.
if [ -z "$warn_default" ] || [ -z "$fail_default" ]; then
    bad "could not read the size guard's defaults out of claude-md-size.sh"
elif grep -q "$warn_default" "$README" && grep -q "$fail_default" "$README"; then
    ok "catalogue quotes the size guard's real thresholds ($warn_default / $fail_default)"
else
    bad "catalogue does not quote ENGINE_CLAUDE_MD_WARN=$warn_default / FAIL=$fail_default"
fi

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
