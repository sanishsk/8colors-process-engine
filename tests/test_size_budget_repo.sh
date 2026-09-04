#!/usr/bin/env bash
# tests/test_size_budget_repo.sh — the file-size budget, applied to the repo.
#
# Two separate problems, one test.
#
# 1. `scripts/pe` was 1506 lines against the engine's own
#    `max_file_lines=800`. The gate had been failing on every change to the
#    main dispatcher, and each change was made with PE_SKIP_SIZE_BUDGET=1 —
#    three times in one afternoon, each honestly noted in the commit message.
#    A bypass reached for routinely is a gate that has stopped working.
#
# 2. `hooks/size-budget.sh` reads the STAGED diff, so a file already over the
#    limit is invisible until someone next edits it. `pre-commit run
#    --all-files` does not help: the engine's hooks are `pass_filenames:
#    false` and read the index themselves, so with nothing staged that
#    command checks nothing. The CI job added in 0.51.6 was close to a no-op
#    for exactly this reason.
#
# This walks the tracked files instead, so the budget applies to what is in
# the repository rather than to what happens to be staged.
#
# KNOWN_OVER is an explicit, dated list — not a wildcard. A gate with a
# silent exemption list is the thing this suite exists to catch, so each
# entry names its size and stays visible until it is split.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_size_budget_repo"

MAX=$(grep -oE '^max_file=[0-9]+' hooks/size-budget.sh | head -1 | cut -d= -f2)
if [ -z "$MAX" ]; then
    echo "  ✗ could not read max_file from hooks/size-budget.sh"
    exit 1
fi
ok "budget read from the hook itself (max_file_lines=$MAX)"

# Pre-existing, over the limit as of 2026-09-04, each tracked separately.
# Splitting them is its own change with its own tests; leaving them silent
# is not an option.
KNOWN_OVER=" scripts/pe_orchestrator.py scripts/research_index.py "

over=""
stale=""
for f in $(git ls-files 'scripts/*' 'hooks/*' 'agents/*' 'commands/*' 'tests/*'); do
    [ -f "$f" ] || continue
    n=$(wc -l < "$f" | tr -d ' ')
    case "$KNOWN_OVER" in
        *" $f "*)
            [ "$n" -le "$MAX" ] && stale="$stale $f"
            continue ;;
    esac
    [ "$n" -gt "$MAX" ] && over="$over $f($n)"
done

if [ -z "$over" ]; then
    ok "no tracked engine file exceeds $MAX lines, outside the known list"
else
    bad "over budget and not on the known list:$over"
fi

if [ -z "$stale" ]; then
    ok "every KNOWN_OVER entry is still genuinely over budget"
else
    bad "KNOWN_OVER is stale — these are now under $MAX and should be removed:$stale"
fi

# The dispatcher specifically. This is the file the bypass was for.
pe_lines=$(wc -l < scripts/pe | tr -d ' ')
if [ "$pe_lines" -le "$MAX" ]; then
    ok "scripts/pe is $pe_lines lines — under budget, no bypass needed"
else
    bad "scripts/pe is back to $pe_lines lines (max $MAX) — the split regressed"
fi

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
