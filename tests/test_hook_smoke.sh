#!/usr/bin/env bash
# tests/test_hook_smoke.sh — every hook must RUN, not merely exist.
#
# On 2026-09-04 `code-review-trailer.sh` was found to have rejected every
# commit it ever saw. A grep for an absent optional trailer died under
# `set -euo pipefail`, the script exited 1 before printing anything, and the
# caller read that as "the trailer did not resolve". It had never run
# anywhere: no consuming project wired it and the engine's own config omitted
# it, so nothing had ever executed the code path.
#
# Reading a hook does not find that. Running it does.
#
#   A hook that exits non-zero with no output is the bug signature.
#
# This drives every hooks/*.sh against a throwaway fixture repo that is
# deliberately boring — a small Python module, a template, a stylesheet, a
# migration, a manifest — and asserts, for each:
#
#   * it terminates (no hang, no interpreter error),
#   * if it fails, it says why on stdout or stderr,
#   * it emits no shell diagnostic ("integer expression expected" and
#     friends), which is how a broken counter hides behind a passing exit.
#
# It asserts nothing about VERDICT. Whether a given hook should pass or fail
# on this fixture is that hook's own test's business; this one only insists
# that the hook is capable of running and of speaking when it refuses.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$ROOT/hooks"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fixture"
echo "test_hook_smoke"

# ─── fixture ────────────────────────────────────────────────────────
mkdir -p "$FIX"/{src,docs,templates,static/css,static/js,migrations,tests,.claude/gates}
git -C "$FIX" init -q
git -C "$FIX" config user.email t@t.t
git -C "$FIX" config user.name t
printf '# Project\n\nA fixture.\n'                       > "$FIX/CLAUDE.md"
printf '# readme\n'                                       > "$FIX/README.md"
printf '# arch\n'                                         > "$FIX/docs/architecture.md"
printf 'def add(a, b):\n    return a + b\n'               > "$FIX/src/app.py"
printf 'def test_add():\n    assert 1 + 2 == 3\n'         > "$FIX/tests/test_app.py"
printf '<html><body><h1>Hi</h1></body></html>\n'          > "$FIX/templates/page.html"
printf ':root { --c: #333; }\nbody { color: var(--c); }\n' > "$FIX/static/css/app.css"
printf 'console.log("hi");\n'                             > "$FIX/static/js/app.js"
printf 'def upgrade(conn):\n    pass\n'                   > "$FIX/migrations/migrate_001_init.py"
printf 'requests==2.32.3\n'                               > "$FIX/requirements.txt"
git -C "$FIX" add -A
git -C "$FIX" commit -qm base --no-verify

# A second round, so every hook sees a non-empty staged diff.
printf 'def sub(a, b):\n    return a - b\n' >> "$FIX/src/app.py"
printf '<p>more</p>\n'                      >> "$FIX/templates/page.html"
printf '.x { color: #444; }\n'              >> "$FIX/static/css/app.css"
printf '\n## more\n'                        >> "$FIX/README.md"
git -C "$FIX" add -A
printf 'feat: add sub\n\nBody.\n' > "$FIX/.git/COMMIT_EDITMSG"

# Hooks that pre-commit invokes at the commit-msg stage take the message
# file as $1. Everything else takes no arguments.
COMMITMSG=" code-review-trailer docs-updated-trailer design-review-trailer security-review-trailer perf-gate "

SHELL_NOISE='integer expression expected|unary operator expected|command not found|: \[: |No such file or directory|syntax error'

for h in "$HOOKS"/*.sh; do
    b=$(basename "$h" .sh)
    case "$b" in _*) continue ;; esac        # sourced libraries, not hooks

    # `${msgarg:+"$msgarg"}` rather than an array: bash 3.2 (still the
    # system shell on macOS) treats "${args[@]}" on an empty array as an
    # unbound variable under `set -u`, which would make every no-argument
    # hook look like a silent failure. The first draft of this test did
    # exactly that and reported 24 false positives.
    msgarg=""
    case "$COMMITMSG" in *" $b "*) msgarg="$FIX/.git/COMMIT_EDITMSG" ;; esac

    out=$( (cd "$FIX" && "$h" ${msgarg:+"$msgarg"} 2>&1 </dev/null) ); rc=$?
    bytes=$(printf '%s' "$out" | wc -c | tr -d ' ')

    if [ "$rc" -ge 126 ]; then
        bad "$b: exit $rc — could not execute (interpreter or permissions)"
    elif [ "$rc" -ne 0 ] && [ "$bytes" -eq 0 ]; then
        bad "$b: exit $rc with NO output — the silent-fail signature"
    elif printf '%s' "$out" | grep -qE "$SHELL_NOISE"; then
        bad "$b: shell diagnostic in output — $(printf '%s' "$out" | grep -oE "$SHELL_NOISE" | head -1)"
    else
        ok "$b: exit $rc, $bytes bytes"
    fi
done

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
