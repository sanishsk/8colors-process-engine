#!/usr/bin/env bash
# tests/test_trailer_pipefail.sh — a trailer hook must survive an absent
# trailer AND an empty staged set, and must never answer twice.
#
# Two defects of the same family, both found by wiring the hooks into a real
# project for the first time (2026-09-04):
#
#   1. `set -euo pipefail` + a grep for an absent OPTIONAL trailer killed the
#      script at exit 1 with NO diagnostic, before it could read the valid
#      trailer on the line above. It rejected every commit, silently.
#   2. `NUM_FILES=$(... | grep -c . || echo 0)` printed TWO lines when nothing
#      was staged — grep -c already prints "0" and then exits 1, so the
#      fallback appended a second "0". `[ "0\n0" -lt 5 ]` died with
#      "integer expression expected", the threshold fast-path was skipped,
#      and a zero-file commit was asked for an envelope sha.
#
# An absent optional trailer is the normal case, not an error. A counter that
# already answered must not be given a fallback.
#
# This test drives the hooks inside a throwaway fixture repo. The previous
# version ran them in whatever directory the suite was launched from, so its
# assertions depended on the engine repo's own staged set.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(cd "$SELF_DIR/.." && pwd)/hooks"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
echo "test_trailer_pipefail"

# ─── fixture: a repo with enough staged behaviour files to clear the
#     default ENGINE_REVIEW_THRESHOLD of 5, plus a resolvable PASS record.
mkdir -p "$REPO/src" "$REPO/templates" "$REPO/.claude/gates"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'x\n' > "$REPO/seed"
git -C "$REPO" add -A && git -C "$REPO" commit -qm seed --no-verify
for i in 1 2 3 4 5 6; do printf 'v = %s\n' "$i" > "$REPO/src/mod$i.py"; done
printf '<p>ui</p>\n' > "$REPO/templates/page.html"
git -C "$REPO" add -A

printf '{"verdict": "PASS", "gate_name": "code-reviewer"}\n' \
    > "$REPO/.claude/gates/last-gate.json"
SHA=$(shasum -a 256 "$REPO/.claude/gates/last-gate.json" | awk '{print $1}')
cp "$REPO/.claude/gates/last-gate.json" "$REPO/.claude/gates/last-design-review.json"

run() { printf '%b' "$2" > "$TMP/msg"; (cd "$REPO" && "$HOOKS/$1" "$TMP/msg" >/dev/null 2>&1); echo $?; }

# ─── 1. a resolvable sha trailer alone must pass — the case defect 1 broke.
rc=$(run code-review-trailer.sh "x\n\nCode-reviewed: $SHA\n")
[ "$rc" = "0" ] && ok "Code-reviewed alone passes" \
                || bad "Code-reviewed alone rejected (exit $rc) — pipefail regression"

# ─── 2. an explicit skip alone must pass.
rc=$(run code-review-trailer.sh 'x\n\nCode-skip-reason: hotfix\n')
[ "$rc" = "0" ] && ok "Code-skip-reason alone passes" \
                || bad "Code-skip-reason alone rejected (exit $rc) — pipefail regression"

# ─── 3. neither trailer on a 6-file commit must be rejected, WITH a message.
printf 'x\n' > "$TMP/msg"
out=$(cd "$REPO" && "$HOOKS/code-review-trailer.sh" "$TMP/msg" 2>&1)
printf '%s' "$out" | grep -q "Code-reviewed" \
    && ok "missing trailer is refused with a diagnostic" \
    || bad "refusal is silent — indistinguishable from a crash"

# ─── 4. every trailer hook must survive a message carrying none of its
#     trailers without dying wordlessly. Exit 1 is fine; exit 1 with no
#     output is the bug signature.
for h in code-review-trailer docs-updated-trailer security-review-trailer \
         design-review-trailer perf-gate; do
    [ -f "$HOOKS/$h.sh" ] || continue
    printf 'x\n' > "$TMP/msg"
    out=$(cd "$REPO" && "$HOOKS/$h.sh" "$TMP/msg" 2>&1); rc=$?
    if [ -n "$out" ] || [ "$rc" = "0" ]; then
        ok "$h speaks or passes on a bare message"
    else
        bad "$h exits silently on a bare message — pipefail shape"
    fi
done

# ─── 5. defect 2: no hook may emit a shell diagnostic. A counter that
#     answered twice shows up here as "integer expression expected", and
#     that line is on stderr where a passing exit code hides it.
#     Run with an EMPTY staged set — the path that produced "0\n0".
git -C "$REPO" reset -q
for h in code-review-trailer docs-updated-trailer security-review-trailer \
         design-review-trailer perf-gate; do
    [ -f "$HOOKS/$h.sh" ] || continue
    printf 'x\n\nCode-reviewed: %s\n' "$SHA" > "$TMP/msg"
    out=$(cd "$REPO" && "$HOOKS/$h.sh" "$TMP/msg" 2>&1 || true)
    if printf '%s' "$out" | grep -qE 'integer expression expected|unary operator expected|: \[: '; then
        bad "$h emits a shell diagnostic on an empty staged set: $(printf '%s' "$out" | head -1)"
    else
        ok "$h is quiet on an empty staged set"
    fi
done

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
