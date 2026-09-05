#!/usr/bin/env bash
# tests/test_dev_log_gitignored.sh — the engine's scheduled writer must not
# dirty an adopter's working tree.
#
# `dev-log-collect.sh` writes docs/dev-log/daily/<date>.{json,md} INTO the
# adopter project, and `pe install` schedules it — launchd / systemd / cron.
# So it fires on a timer, at a moment nobody chose.
#
# The engine's own .gitignore has ignored docs/dev-log/{daily,weekly,monthly}/
# since the collector shipped. `install.sh` propagates four ignore patterns to
# adopters and this is not among them — the same mirror-image gap fixed for
# .claude/gates/ in v0.52.0, one directory over and still open.
#
# WHY IT IS NOT COSMETIC. `pre-commit` stashes unstaged tracked changes before
# running hooks and restores them after. A writer that appends to a tracked
# file DURING that window makes the restore conflict, and pre-commit rolls the
# whole commit back. The operator sees a failed commit directly after
# "lint ok / tests ok / secrets ok" — it reads as a gate failure and is not
# one. Diagnosed in a live adopter on 2026-09-05 against a subagent-completion
# log; the engine's own scheduled collector is the same shape, on a timer.
#
# Two independent guarantees, because either alone has a hole:
#   1. `pe install` adds the path to the adopter's root .gitignore
#   2. the collector drops a self-ignoring .gitignore in the directory it
#      writes — so it holds in a project that never ran `pe install`

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "test_dev_log_gitignored"

# ─── 1. install propagates the ignore ───────────────────────────────
# Asserted against the installer's pattern list rather than a full install
# run, which needs a network-free but slow end-to-end setup already covered
# elsewhere. The list is the thing that can silently omit an entry.
PATTERNS=$(grep -n 'for pattern in' "$ROOT/scripts/install.sh" | head -1)
case "$PATTERNS" in
    *"docs/dev-log/"*)
        ok "install.sh propagates docs/dev-log/ to the adopter .gitignore" ;;
    *)
        bad "install.sh ignores .claude/gates/ and .pe/ but not docs/dev-log/ — the scheduled collector writes there" ;;
esac

# ─── 2. the collector ignores its own output, install or no install ──
# A real repo: `git status --porcelain` in a non-git directory is empty and
# would pass this in both the red and green states.
REPO="$TMP/proj"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
echo "seed" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm seed

bash "$ROOT/scripts/dev-log-collect.sh" --project "$REPO" >/dev/null 2>&1

if [ ! -d "$REPO/docs/dev-log" ]; then
    bad "the collector wrote nothing — cannot tell whether its output is ignored"
else
    ok "the collector wrote into docs/dev-log/ as documented"

    # Compute first, assert second. A $(...) inside the assertion string
    # keeps its escaped quotes literal, git then gets a path containing
    # quote characters, fails, prints nothing — and the emptiness test
    # passes. That exact shape produced a green-but-vacuous assertion in
    # this suite before.
    UNTRACKED=$(git -C "$REPO" status --porcelain 2>/dev/null)
    if [ -z "$UNTRACKED" ]; then
        ok "a scheduled collect leaves the working tree clean"
    else
        bad "collect dirtied the tree — a timer firing mid-commit will roll the commit back:
$UNTRACKED"
    fi

    if git -C "$REPO" check-ignore -q docs/dev-log/daily 2>/dev/null; then
        ok "docs/dev-log/daily is ignored without pe install having run"
    else
        bad "the collector's own output is not ignored — it depends on an install step that may never have run"
    fi
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
