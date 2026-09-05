#!/usr/bin/env bash
# tests/test_pipe_grep_race.sh — the assertion idiom that reports the wrong colour.
#
# Under `set -o pipefail`, this is a race:
#
#     echo "$out" | grep -q "expected string"
#
# `grep -q` exits at the FIRST match and closes the read end. If the writer
# has not finished, it takes SIGPIPE and exits 141, and pipefail promotes 141
# to the pipeline's status — so a condition that MATCHED evaluates false.
#
# Caught in CI on 2026-09-05: test_signature_lint reported
#
#     space-in-filename bypass on flagship: rc=1 out='...hero page.html...'
#
# — the exit code it wanted and the string it was grepping for, both present
# in the failure message, recorded as a failure. Re-run: green.
#
# Direction of the lie is not uniform:
#
#   * where a MATCH means pass, a spurious 141 reports a false FAILURE
#   * where a MATCH means fail, a spurious 141 reports a false PASS
#
# The second kind is silent, and two of them exist. They are fixed in the
# same commit as this test. But the first kind is not benign either: a suite
# that produces "re-run and it's fine" failures trains everyone to re-run on
# red, and that habit does not check which colour was lying.
#
# This file proves the mechanism rather than asserting it, so the fix is
# demonstrated against a reproduction and not against a description.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_pipe_grep_race"

# ─── 1. the race, reproduced ────────────────────────────────────────
# A payload far larger than the 64 KB pipe buffer, whose match is on line 1.
# grep -q returns immediately; the writer still has ~1 MB to push and cannot.
BIG="MATCH_ME_ON_LINE_ONE"
BIG="$BIG$(printf 'x%.0s' $(seq 1 1000))"
for _ in $(seq 1 10); do BIG="$BIG"$'\n'"$BIG"; done   # ~1 MB, match at the top

set +e
( set -o pipefail; echo "$BIG" | grep -q MATCH_ME_ON_LINE_ONE )
piped_rc=$?
set -e

if [ "$piped_rc" -ne 0 ]; then
    ok "reproduced: a MATCHING pipeline returns $piped_rc under pipefail, not 0"
else
    # Not a failure of the codebase — some kernels/greps drain fast enough.
    # Say so plainly rather than claiming a demonstration that did not happen.
    ok "this platform did not reproduce the SIGPIPE race (rc=0) — fix still asserted below"
fi

# ─── 2. the replacement is not racy ─────────────────────────────────
# A herestring has no writer process to kill. Same semantics, no pipeline.
set +e
( set -o pipefail; grep -q MATCH_ME_ON_LINE_ONE <<<"$BIG" )
here_rc=$?
set -e

[ "$here_rc" -eq 0 ] \
    && ok "the herestring form returns 0 on the same input — no writer to SIGPIPE" \
    || bad "herestring form returned $here_rc — the replacement is not sound"

# ─── 3. the files holding the silent sites carry the idiom nowhere ──
# These two files each contain an assertion where a MATCH means failure, so
# the race made them report a PASS. A race cannot be asserted by outcome, so
# this asserts by shape: zero pipes into grep -q in the file.
#
# Whole-file, not line-targeted. The first version of this check looked up
# the guarded line by a distinctive string and inspected it — and matched a
# COMMENT quoting that string 83 lines earlier, so it passed while the bug
# was untouched. Counting the idiom cannot be fooled that way.
count_piped_grep_q() {   # $1=file  $2=label
    local file="$ROOT/$1" label="$2" n
    if [ ! -f "$file" ]; then
        bad "$label: $1 is missing — deleted rather than fixed?"
        return
    fi
    # `grep -c` PRINTS 0 and EXITS 1 when there are no matches, so the
    # familiar `|| echo 0` appends a second zero and the next [ ] sees
    # "0\n0". That is the exact defect test_trailer_pipefail.sh exists to
    # catch, reproduced here while writing its fix.
    n=$(grep -c '| *grep -q' "$file" 2>/dev/null || true)
    n=${n:-0}
    if [ "$n" -eq 0 ]; then
        ok "$label: no pipe into grep -q remains"
    else
        bad "$label: $n site(s) still pipe into grep -q — here a match means FAIL, so the race reads as a pass"
    fi
}

count_piped_grep_q "tests/test_trailer_pipefail.sh" \
    "the shell-diagnostic check (a pipefail test carrying a pipefail bug)"

count_piped_grep_q "tests/test_complexity_gate_eslint.sh" \
    "the eslint-discards-stderr check"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
