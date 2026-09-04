#!/usr/bin/env bash
# tests/test_engine_self_gating.sh — every engine hook is either wired on the
# engine's own commits, or has a written reason why not.
#
# The engine's .pre-commit-config.yaml ran 5 of its own 29 hooks and omitted
# the rest with one vague sentence. The cost was concrete:
# code-review-trailer.sh rejected every commit it ever saw, for two months,
# because the engine's own config omitted it and no project had wired it yet
# — so the code path had never executed anywhere.
#
# The absence of a gate is a decision. This test makes it a written one: a
# hook must appear in the config, or by name in the config's decision table.
# Adding hooks/new-thing.sh without deciding either way fails here.
#
# It deliberately does NOT assert WHICH hooks are wired. That is a judgement
# call that will change; what must not change is that somebody made it.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
CFG="$ROOT/.pre-commit-config.yaml"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_engine_self_gating"

[ -f "$CFG" ] || { echo "  ✗ .pre-commit-config.yaml missing"; exit 1; }

# Hooks the config actually runs (an `entry:` line naming hooks/<name>.sh).
wired=$(grep -oE '^\s*entry: hooks/[a-z0-9-]+\.sh' "$CFG" \
        | sed -E 's|.*hooks/([a-z0-9-]+)\.sh|\1|' | sort -u)
n_wired=$(printf '%s\n' "$wired" | grep -c . || true)
[ "$n_wired" -gt 0 ] && ok "the engine wires $n_wired of its own hooks" \
                     || bad "the engine wires none of its own hooks"

# Only the comment block above `repos:` counts as the decision table — a hook
# named solely in an entry: line has not been reasoned about, it has been used.
table=$(sed -n '1,/^repos:/p' "$CFG")

undecided=""
for h in "$ROOT"/hooks/*.sh; do
    b=$(basename "$h" .sh)
    case "$b" in _*) continue ;; esac
    case " $wired " in *" $b "*) continue ;; esac
    printf '%s' "$table" | grep -qF "$b" || undecided="$undecided $b"
done

if [ -z "$undecided" ]; then
    ok "every unwired hook is named in the config's decision table"
else
    bad "no decision recorded for:$undecided — wire it, or say why not"
fi

# The table must not name a hook that no longer exists, or it is describing
# a repository that has moved on.
# The name column is exactly five spaces after the `#`; continuation lines
# are indented further, and prose is indented further still. Matching on the
# column, not on "looks like a hook name", keeps ordinary hyphenated English
# ("skip-reason", "pre-merge", "stdlib-only") out of the comparison.
ghosts=""
for b in $(printf '%s\n' "$table" | grep -oE '^#     [a-z][a-z0-9-]*' \
           | sed 's/^#     //' | sort -u); do
    [ -f "$ROOT/hooks/$b.sh" ] || ghosts="$ghosts $b"
done
[ -z "$ghosts" ] && ok "the decision table names no hook that has been deleted" \
                 || bad "table names hooks that no longer exist:$ghosts"

# The commit-msg stage needs its own installed hook; `pre-commit install`
# alone only writes .git/hooks/pre-commit, so a commit-msg entry in the
# config is inert until --hook-type commit-msg is passed. That is the same
# shape as the defect that started all this: configured, never running.
if grep -q 'stages: \[commit-msg\]' "$CFG"; then
    if grep -q 'commit-msg' "$ROOT/CONTRIBUTING.md"; then
        ok "CONTRIBUTING tells contributors to install the commit-msg hook"
    else
        bad "config has a commit-msg hook but CONTRIBUTING does not say to install it"
    fi
fi

# A commit-msg hook is HANDED the message file as $1, and every trailer hook
# opens with `${1:?Usage: ...}`. `pass_filenames: false` on such an entry
# makes it fail on EVERY commit with a usage error. The first wiring of
# docs-updated-trailer did exactly that, copied from the pre-commit entries
# sitting above it in the same file. It failed loudly and was fixed in
# minutes — which is the difference between this and the defects that
# started the audit.
bad_shape=$(awk '
    /^ *- id: /        { id = $3; stage = 0; nofiles = 0 }
    /stages: \[commit-msg\]/ { stage = 1 }
    /pass_filenames: false/  { nofiles = 1 }
    /^ *- id: |^repos:|^$/   { if (id && stage && nofiles) { print id; id = "" } }
    END                { if (id && stage && nofiles) print id }
' "$CFG" | sort -u | tr '\n' ' ' | sed 's/ *$//')

if [ -z "$bad_shape" ]; then
    ok "no commit-msg hook suppresses the message filename"
else
    bad "commit-msg hooks with pass_filenames: false get no \$1: $bad_shape"
fi

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
