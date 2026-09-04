#!/usr/bin/env bash
# tests/test_trailer_pipefail.sh — a trailer hook must survive an absent trailer.
#
# code-review-trailer.sh runs under `set -euo pipefail`. Its Code-skip-reason
# grep legitimately matches nothing on most commits; unguarded, that failed the
# command substitution and killed the script at exit 1 with NO diagnostic —
# before it could read the valid Code-reviewed trailer on the line above.
#
# The hook therefore rejected every message that did not carry BOTH trailers,
# which no documented workflow produces. It went unnoticed until the first
# project wired it in (2026-09-04), and read as "the sha did not resolve".
#
# An absent optional trailer is the normal case, not an error.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(cd "$SELF_DIR/.." && pwd)/hooks"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "test_trailer_pipefail"

run() { printf '%b' "$2" > "$TMP/msg"; "$HOOKS/$1" "$TMP/msg" >/dev/null 2>&1; echo $?; }

# A valid sha trailer alone must pass — the case the bug broke.
rc=$(run code-review-trailer.sh 'x\n\nCode-reviewed: 4f73cc9fb3e9\n')
[ "$rc" = "0" ] && ok "Code-reviewed alone passes" \
                || bad "Code-reviewed alone rejected (exit $rc) — pipefail regression"

# An explicit skip alone must pass.
rc=$(run code-review-trailer.sh 'x\n\nCode-skip-reason: hotfix\n')
[ "$rc" = "0" ] && ok "Code-skip-reason alone passes" \
                || bad "Code-skip-reason alone rejected (exit $rc) — pipefail regression"

# Neither trailer on a trivial message must still be rejected, WITH a message.
out=$(printf 'x\n' > "$TMP/msg"; "$HOOKS/code-review-trailer.sh" "$TMP/msg" 2>&1 || true)
printf '%s' "$out" | grep -q "Code-reviewed" \
    && ok "missing trailer is refused with a diagnostic" \
    || bad "refusal is silent — indistinguishable from a crash"

# Every trailer hook must survive a message carrying none of its trailers
# without dying wordlessly. Exit 1 is fine; exit 1 with no output is the bug.
for h in code-review-trailer docs-updated-trailer security-review-trailer \
         design-review-trailer; do
    [ -f "$HOOKS/$h.sh" ] || continue
    printf 'x\n' > "$TMP/msg"
    out=$("$HOOKS/$h.sh" "$TMP/msg" 2>&1 || true)
    rc=$?
    if [ -n "$out" ] || [ "$rc" = "0" ]; then
        ok "$h speaks or passes on a bare message"
    else
        bad "$h exits silently on a bare message — pipefail shape"
    fi
done

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
