#!/usr/bin/env bash
# tests/test_complexity_gate_eslint.sh — the eslint path of complexity-gate
# must run, or skip loudly. It must never block without saying why.
#
# This path had never executed. The engine repo contained zero JavaScript
# until 2026-09-04, so `STAGED_JS` was always empty and run_eslint returned
# on its first line. The first .js file ever staged found it broken:
#
#   `eslint --no-eslintrc ...` — `--no-eslintrc` is an eslint 8 flag. eslint 9
#   rejects it outright ("Invalid option '--eslintrc'"), and that message went
#   to 2>/dev/null. The hook printed "FAIL — one or more checks blocked the
#   commit" with no reason attached. A missing flag was indistinguishable from
#   a real complexity violation.
#
#   This is not specific to this repo. ANY project that wires complexity-gate
#   and has eslint 9 installed gets an unexplained block on every JS commit.
#
# Two more, found in the same pass:
#   - `npx --yes --no-install` is self-contradictory. --no-install says do not
#     download; --yes says auto-confirm the download. npm cancels.
#   - Claude Code workflow scripts are not standalone JS — a top-level
#     `return` is the contract — so a module-mode parser cannot read them.
#     They are excluded, and the exclusion is announced.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ROOT/hooks/complexity-gate.sh"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_complexity_gate_eslint"

# ─── static: the invocation itself ──────────────────────────────────
# Executable lines only — the hook's comments quote the broken form on
# purpose, to explain what was wrong with it.
HOOK_CODE=$(grep -vE '^\s*#' "$HOOK")
grep -q -- '--yes --no-install' <<<"$HOOK_CODE" \
    && bad "the self-contradictory 'npx --yes --no-install' is back" \
    || ok "no live 'npx --yes --no-install' — the contradiction is gone"

grep -q -- '--no-config-lookup' "$HOOK" && grep -q -- '--no-eslintrc' "$HOOK" \
    && ok "the config flag is selected by eslint major version (8 vs 9)" \
    || bad "only one eslint config flag present — one of the two majors will break"

# The eslint invocation must not discard stderr. Find the line that runs the
# rules and check it does not end in a stderr redirect.
# Herestring, not a pipe: a match here means FAILURE, so a SIGPIPE'd writer
# under pipefail would report "clean" on a hook that still discards stderr.
INVOCATION=$(grep -A6 'no_config \\' "$HOOK")
if grep -q '2>/dev/null' <<<"$INVOCATION"; then
    bad "the eslint invocation still discards stderr — failures stay unexplained"
else
    ok "the eslint invocation lets stderr through"
fi

# ─── behavioural ────────────────────────────────────────────────────
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO/src" "$REPO/workflows"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/seed"
git -C "$REPO" add -A && git -C "$REPO" commit -qm seed --no-verify

# A workflow-shaped script: top-level return, which is legal there and a
# parse error anywhere else.
cat > "$REPO/workflows/thing.js" <<'JS'
export const meta = { name: 'thing', description: 'x' }
const r = await agent('do a thing')
if (!r) { return { ok: false } }
return { ok: true }
JS
git -C "$REPO" add -A

out=$( (cd "$REPO" && bash "$HOOK" 2>&1) ); rc=$?

grep -q 'not linting workflow script' <<<"$out" \
    && ok "a staged workflow script is excluded, and the exclusion is announced" \
    || bad "the workflow exclusion is silent or absent"

[ "$rc" -eq 0 ] \
    && ok "a workflow script alone does not block the commit" \
    || bad "a workflow script blocked the commit (exit $rc): $(printf '%s' "$out" | tail -3)"

# A normal JS file must still be linted — the exclusion must not leak.
if command -v eslint >/dev/null 2>&1; then
    printf 'export const ok = 1\n' > "$REPO/src/fine.js"
    git -C "$REPO" add -A
    out=$( (cd "$REPO" && bash "$HOOK" 2>&1) ); rc=$?
    [ "$rc" -eq 0 ] \
        && ok "a clean non-workflow .js passes" \
        || bad "a clean .js was blocked (exit $rc): $(printf '%s' "$out" | tail -3)"

    # 5 nested ifs — over max-depth 4. eslint must catch it, and the hook
    # must block WITH the reason visible.
    {
      printf 'export function deep(a, b, c, d, e) {\n'
      printf '  if (a) {\n    if (b) {\n      if (c) {\n        if (d) {\n          if (e) {\n'
      printf '            return 1\n'
      printf '          }\n        }\n      }\n    }\n  }\n  return 0\n}\n'
    } > "$REPO/src/deep.js"
    git -C "$REPO" add -A
    out=$( (cd "$REPO" && bash "$HOOK" 2>&1) ); rc=$?
    [ "$rc" -ne 0 ] \
        && ok "a real max-depth violation blocks the commit" \
        || bad "the gate passed a 5-deep nesting — eslint is not actually running"
    grep -qiE 'max-depth|Blocks are nested' <<<"$out" \
        && ok "the refusal names the rule that fired" \
        || bad "the gate blocked without naming a rule — the silent-fail shape"
else
    echo "  ⚠ eslint not installed — the behavioural half of this test did not run"
fi

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
