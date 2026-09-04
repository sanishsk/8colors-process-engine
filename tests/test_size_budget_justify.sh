#!/usr/bin/env bash
# tests/test_size_budget_justify.sh — the escape hatch must work, and must
# not fire on the wrong commit.
#
# size-budget runs at the PRE-COMMIT stage, where the commit message being
# written does not exist yet. It used to guess at .git/COMMIT_EDITMSG, which
# at that moment holds the PREVIOUS commit's message. Two faults at once:
#
#   1. `Size-justified:` never worked for `git commit -m` or `-F`, because
#      git writes COMMIT_EDITMSG only after the pre-commit hook has run. The
#      hook printed instructions that could not be followed.
#   2. When the PREVIOUS commit carried `Size-justified:`, the NEXT commit
#      passed the net-lines gate without one. A gate that lets a change
#      through because of something the last change said is worse than no
#      gate — and it fails OPEN, so nothing ever looks wrong.
#
# Found 2026-09-04 by following the hook's own instructions and watching
# them not work.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$SELF_DIR/.." && pwd)/hooks/size-budget.sh"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
echo "test_size_budget_justify"

mkdir -p "$REPO/src"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/seed"
git -C "$REPO" add -A && git -C "$REPO" commit -qm seed --no-verify

# A staged change comfortably over the default fail_net_lines=600, spread
# across many SMALL files. One 900-line file would also trip the per-file
# budget, which always blocks and is not what this test is about.
i=1
while [ "$i" -le 20 ]; do
    n=1
    : > "$REPO/src/mod$i.py"
    while [ "$n" -le 40 ]; do
        echo "x$n = $n" >> "$REPO/src/mod$i.py"
        n=$((n + 1))
    done
    i=$((i + 1))
done
git -C "$REPO" add -A

run() { (cd "$REPO" && env "$@" bash "$HOOK" >/dev/null 2>&1); echo $?; }

rc=$(run PE_NOTHING=1)
[ "$rc" -ne 0 ] && ok "an unjustified 800-line net add is blocked" \
                || bad "the net-lines gate did not fire at all"

rc=$(run PE_SIZE_JUSTIFIED="a vendored file")
[ "$rc" -eq 0 ] && ok "PE_SIZE_JUSTIFIED lets it through" \
                || bad "PE_SIZE_JUSTIFIED did not work (exit $rc)"

# commit-msg stage: the message file arrives as $1.
printf 'feat: big\n\nSize-justified: two documents\n' > "$TMP/msg"
(cd "$REPO" && bash "$HOOK" "$TMP/msg" >/dev/null 2>&1)
[ $? -eq 0 ] && ok "a Size-justified trailer in \$1 lets it through" \
             || bad "the trailer in \$1 was not honoured"

printf 'feat: big\n\nno trailer here\n' > "$TMP/msg"
(cd "$REPO" && bash "$HOOK" "$TMP/msg" >/dev/null 2>&1)
[ $? -ne 0 ] && ok "a message without the trailer is still blocked" \
             || bad "any \$1 at all was treated as justification"

# THE REGRESSION: a justified PREVIOUS commit must not justify this one.
printf 'chore: previous commit\n\nSize-justified: something else entirely\n' \
    > "$REPO/.git/COMMIT_EDITMSG"
rc=$(run PE_NOTHING=1)
[ "$rc" -ne 0 ] \
    && ok "a Size-justified trailer in the PREVIOUS message does not carry over" \
    || bad "stale .git/COMMIT_EDITMSG justified this commit — the gate fails open"

# The refusal must name a way out that actually exists.
out=$( (cd "$REPO" && bash "$HOOK" 2>&1 >/dev/null) )
printf '%s' "$out" | grep -q 'PE_SIZE_JUSTIFIED' \
    && ok "the refusal names an escape hatch that works at this stage" \
    || bad "the refusal still tells the operator to do something impossible"

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
