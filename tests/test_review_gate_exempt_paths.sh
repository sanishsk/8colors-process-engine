#!/usr/bin/env bash
# tests/test_review_gate_exempt_paths.sh — narrowing the review gate safely.
#
# pre-commit-envelope-check blocks `git commit` on ANY non-empty staged diff.
# A CLAUDE.md typo, a plan update or a release-build commit all wait on a
# code review of prose. A live adopter (Origyn) hit this and wrote a local
# wrapper around the hook that re-implements the block and narrows it by
# path. Every adopter who cares will write that wrapper, and each will draw
# the line differently — a workaround in the field is the engine saying its
# default is wrong.
#
# POLARITY. The wrapper uses an INCLUDE list: gate only when the diff touches
# behaviour-carrying paths. That is fail-OPEN — a source directory nobody
# added to the regex sails through unreviewed, and the failure is silent and
# permanent. This ships the inverse: an EXEMPT list. Anything not explicitly
# exempted is still gated, so a path nobody thought about fails closed.
#
# Every assertion below is about that direction. The gate must narrow only
# where an operator has said so in writing, and every ambiguity — no config,
# a typo, an unreadable file, a mixed commit — must resolve to BLOCKED.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ROOT/hooks/pre-commit-envelope-check.sh"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "test_review_gate_exempt_paths"

# A project with staged files and NO recorded envelope. Without an exemption
# the hook denies — so exit 0 means "the exemption applied" and exit 2 means
# "still gated", with no other path to a pass.
make_repo() {   # $1=dir  $2..=files to stage
    local d="$1"; shift
    mkdir -p "$d/.claude/gates"
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    for f in "$@"; do
        mkdir -p "$d/$(dirname "$f")" 2>/dev/null
        echo "content of $f" > "$d/$f"
        git -C "$d" add "$f"
    done
}

set_cfg() { printf 'review_gate:\n  exempt_paths: "%s"\n' "$2" > "$1/.process-engine.yaml"; }

# Returns the hook's exit code. Output to a file — a command substitution
# would swallow the code, which is the exact trap this suite has hit before.
OUT="$TMP/.out"
run_commit() {   # $1=project  [env...]
    local d="$1"; shift
    printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' \
      | ( cd "$d" && env CLAUDE_PROJECT_DIR="$d" "$@" bash "$HOOK" ) >"$OUT" 2>&1
}

# ─── 1. the installed base does not move ────────────────────────────
# No config means nothing is exempt. An adopter upgrading the engine must
# not silently get a narrower gate than the one they installed.
P1="$TMP/p1"; make_repo "$P1" "docs/PLAN.md"
run_commit "$P1"; rc=$?
[ "$rc" -eq 2 ] \
    && ok "no config: a docs-only commit is still blocked — default unchanged" \
    || bad "upgrading silently narrowed the gate (rc=$rc)"

# ─── 2. it narrows when asked, in writing ───────────────────────────
P2="$TMP/p2"; make_repo "$P2" "docs/PLAN.md" "CLAUDE.md"
set_cfg "$P2" '^(docs/|CLAUDE\.md$)'
run_commit "$P2"; rc=$?
[ "$rc" -eq 0 ] \
    && ok "a fully-exempt commit passes without an envelope" \
    || bad "declared exemption did not apply (rc=$rc): $(cat "$OUT")"

# ─── 3. the decisive case: a mixed commit is still gated ────────────
# One exempt path plus one source file. Reviewing "the parts that matter"
# is not a thing git offers — the commit lands whole, so it gates whole.
P3="$TMP/p3"; make_repo "$P3" "docs/PLAN.md" "src/auth.py"
set_cfg "$P3" '^(docs/|CLAUDE\.md$)'
run_commit "$P3"; rc=$?
[ "$rc" -eq 2 ] \
    && ok "docs + source in one commit is still blocked — exemption is not per-file" \
    || bad "a commit carrying source code escaped the gate (rc=$rc)"

# ─── 4. every ambiguity resolves to BLOCKED ─────────────────────────
# A regex that matches nothing exempts nothing. The failure mode of a typo
# must be a gate that still fires, never one that stops firing.
P4="$TMP/p4"; make_repo "$P4" "docs/PLAN.md"
set_cfg "$P4" '^nothing-matches-this/'
run_commit "$P4"; rc=$?
[ "$rc" -eq 2 ] \
    && ok "a regex that matches nothing exempts nothing" \
    || bad "a non-matching exemption disarmed the gate (rc=$rc)"

# An empty value is a half-finished edit, not "exempt everything".
P5="$TMP/p5"; make_repo "$P5" "docs/PLAN.md"
printf 'review_gate:\n  exempt_paths: ""\n' > "$P5/.process-engine.yaml"
run_commit "$P5"; rc=$?
[ "$rc" -eq 2 ] \
    && ok "an empty exempt_paths exempts nothing, it does not exempt all" \
    || bad "empty config was read as a wildcard (rc=$rc)"

# An unreadable config must not become an open gate. This hook is the last
# thing between an unreviewed diff and a commit.
P6="$TMP/p6"; make_repo "$P6" "docs/PLAN.md"
printf 'review_gate: [ broken: yaml\n' > "$P6/.process-engine.yaml"
run_commit "$P6"; rc=$?
[ "$rc" -eq 2 ] \
    && ok "an unparseable config falls back to gating everything" \
    || bad "malformed config produced rc=$rc — crashed or opened the gate"

# A regex that would match everything is a decision an operator can make,
# but they have to write it. Asserted so the distinction from #5 is real.
P7="$TMP/p7"; make_repo "$P7" "src/auth.py"
set_cfg "$P7" '.'
run_commit "$P7"; rc=$?
[ "$rc" -eq 0 ] \
    && ok "an explicit match-all exemption is honoured — narrowing is the operator's call" \
    || bad "an explicit exemption was overridden (rc=$rc)"

# ─── 5. precedence and blast radius ─────────────────────────────────
P8="$TMP/p8"; make_repo "$P8" "docs/PLAN.md"
set_cfg "$P8" '^nothing/'
run_commit "$P8" ENGINE_REVIEW_EXEMPT_PATHS='^docs/'; rc=$?
[ "$rc" -eq 0 ] \
    && ok "env overrides the yaml, matching ENGINE_PERF_PATHS precedent" \
    || bad "env exemption ignored (rc=$rc)"

# The filter must not leak into the rest of the hook's contract: a
# non-commit command is still allowed, and a real envelope still governs.
P9="$TMP/p9"; make_repo "$P9" "src/auth.py"
set_cfg "$P9" '^docs/'
printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
  | ( cd "$P9" && CLAUDE_PROJECT_DIR="$P9" bash "$HOOK" ) >"$OUT" 2>&1; rc=$?
[ "$rc" -eq 0 ] \
    && ok "a non-commit command is untouched by the filter" \
    || bad "the filter broke the allow path for ordinary commands (rc=$rc)"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
