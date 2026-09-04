#!/usr/bin/env bash
# code-review-trailer — commit-msg hook that requires an evidence-backed
# code-review trailer on any commit that touches behavior code, and on
# any multi-file commit.
#
# Trailer contract (v0.10.0, P1.5 — evidence not self-attestation):
#
#   Code-reviewed: <envelope-sha>       ← preferred; must resolve to a
#                                          record in .claude/gates/
#   Code-reviewed: code-reviewer        ← legacy self-attest — allowed
#                                          only for BEHAVIOR-EXEMPT paths
#   Code-skip-reason: <short reason>    ← explicit skip; must be non-empty
#
# When set, `<envelope-sha>` is expected to name a file at
# `.claude/gates/<sha>.json` OR match `.claude/gates/last-gate.json`'s
# top-level "sha256" field. The hook verifies existence and PASS/WARN.
#
# Thresholds (env vars):
#   ENGINE_REVIEW_THRESHOLD=5            multi-file commit floor
#   ENGINE_REVIEW_BEHAVIOR_PATHS=<re>    always-require regex (default:
#                                        ^(src|app|modules|lib|scripts|hooks)/)
#
# Bypass: git commit --no-verify (logged in operator's session).

set -euo pipefail

MSG_FILE="${1:?Usage: $0 <commit-msg-file>}"
THRESHOLD="${ENGINE_REVIEW_THRESHOLD:-5}"
BEHAVIOR_RE="${ENGINE_REVIEW_BEHAVIOR_PATHS:-^(src|app|modules|lib|scripts|hooks)/}"

STAGED=$(git diff --cached --name-only)
# `grep -c` ALWAYS prints a count, and exits 1 when that count is zero.
# `|| echo 0` therefore appends a SECOND line on the empty-staged path, so
# NUM_FILES becomes "0\n0" and the `-lt` test below dies with
#   [: 0\n0: integer expression expected
# — the threshold fast-path is skipped and a zero-file commit is asked for
# an envelope sha. Same family as the pipefail bug above: a fallback bolted
# onto a command that had already answered. `|| true` swallows the exit
# status without adding output.
NUM_FILES=$(printf '%s' "$STAGED" | grep -c . || true)

BEHAVIOR_HITS=$(echo "$STAGED" | grep -E "$BEHAVIOR_RE" || true)
HAS_BEHAVIOR="0"
if [ -n "$BEHAVIOR_HITS" ]; then
    HAS_BEHAVIOR="1"
fi

# Fast path: no behavior code AND under threshold → no trailer needed.
if [ "$HAS_BEHAVIOR" = "0" ] && [ "$NUM_FILES" -lt "$THRESHOLD" ]; then
    exit 0
fi

MSG=$(cat "$MSG_FILE")

# Read the trailer value (strip 'Code-reviewed:' prefix, trim whitespace).
# `|| true` is load-bearing, not defensive noise. Under `set -euo pipefail`
# (line 25) a grep that legitimately matches nothing fails the whole command
# substitution and kills the script — silently, exit 1, no message.
#
# The absent trailer is the NORMAL case for at least one of these two on
# every commit, so this hook rejected every message that did not carry BOTH
# a Code-reviewed and a Code-skip-reason trailer. It died at line 49 before
# it could read the valid Code-reviewed trailer sitting at line 48.
#
# Found 2026-09-04, the first time this hook was wired into a project. It
# emitted no diagnostic, which is why it read as "the trailer did not
# resolve" rather than "the hook cannot run".
TRAILER=$(echo "$MSG" | grep -E '^Code-reviewed:' | head -1 | sed -E 's/^Code-reviewed:[[:space:]]*//' | tr -d '\r' | sed -E 's/[[:space:]]+$//' || true)
SKIP=$(echo "$MSG" | grep -E '^Code-skip-reason:' | head -1 | sed -E 's/^Code-skip-reason:[[:space:]]*//' | tr -d '\r' || true)

if [ -n "$SKIP" ]; then
    exit 0
fi

if [ -z "$TRAILER" ]; then
    cat >&2 <<EOF
✗ code-review-trailer: commit needs a Code-reviewed trailer.

Reason: $([ "$HAS_BEHAVIOR" = "1" ] && echo "touches behavior code ($BEHAVIOR_HITS | tr '\n' ',')" || echo "touches $NUM_FILES files (≥$THRESHOLD)")

Add ONE of these:

  Code-reviewed: <envelope-sha>       # sha of PASS/WARN record in .claude/gates/
  Code-reviewed: code-reviewer        # legacy self-attest (non-behavior only)
  Code-skip-reason: <short reason>    # explicit skip

Recommended: run the code-reviewer agent, then:
  pe gate parse --record .claude/gates/last-gate.json \\
                --diff-sha \$(git diff --cached | git hash-object --stdin) \\
                <transcript>
  sha=\$(shasum -a 256 .claude/gates/last-gate.json | cut -c1-12)
  # then in the commit message: Code-reviewed: \$sha

To bypass for a hotfix: git commit --no-verify
EOF
    exit 1
fi

# Verify evidence-backed trailer. Two accepted forms:
#   1) TRAILER == "code-reviewer" — legacy self-attest; ONLY allowed when
#      HAS_BEHAVIOR=0. On behavior paths we insist on evidence.
#   2) TRAILER == <sha> (>=8 hex chars) — must resolve.
if [ "$TRAILER" = "code-reviewer" ]; then
    if [ "$HAS_BEHAVIOR" = "1" ]; then
        cat >&2 <<EOF
✗ code-review-trailer: 'Code-reviewed: code-reviewer' is self-attestation.
  This commit touches behavior code (paths matching $BEHAVIOR_RE) — evidence required.

Replace with an envelope sha:
  pe gate parse --record .claude/gates/last-gate.json \\
                --diff-sha \$(git diff --cached | git hash-object --stdin) \\
                <transcript>
  sha=\$(shasum -a 256 .claude/gates/last-gate.json | cut -c1-12)
  # Code-reviewed: \$sha
EOF
        exit 1
    fi
    # Non-behavior + self-attest allowed.
    exit 0
fi

# v0.36.0: envelope resolution + verdict parsing moved to
# hooks/_trailer-contract.sh. Code's named record is last-gate.json
# (session-wide); nothing project-scoped precedes it.
_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$_HOOK_DIR/_trailer-contract.sh"

if ! pe_trailer_is_sha "$TRAILER"; then
    echo "✗ code-review-trailer: 'Code-reviewed: $TRAILER' is not an envelope sha" >&2
    echo "  Expected hex sha (8-64 chars). Run 'shasum -a 256 .claude/gates/last-gate.json | cut -c1-12' for one." >&2
    exit 1
fi

RECORD=$(pe_trailer_resolve_record "$TRAILER" ".claude/gates/last-gate.json")

if [ -z "$RECORD" ]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    cat >&2 <<EOF
✗ code-review-trailer: Code-reviewed sha '$TRAILER' does not resolve.
  Looked for:
    $REPO_ROOT/.claude/gates/last-gate.json (sha256 prefix)
    $REPO_ROOT/.claude/gates/$TRAILER.json
  Regenerate the record with 'pe gate parse --record ...' after running the code-reviewer.
EOF
    exit 1
fi

VERDICT=$(pe_trailer_verdict "$RECORD")

case "$VERDICT" in
    PASS|WARN)
        exit 0 ;;
    *)
        echo "✗ code-review-trailer: envelope at $RECORD has verdict '$VERDICT' — not PASS/WARN" >&2
        exit 1 ;;
esac
