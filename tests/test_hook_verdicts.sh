#!/usr/bin/env bash
# tests/test_hook_verdicts.sh — the eight hooks that ran but never judged.
#
# tests/test_hook_smoke.sh drives every hook against a boring fixture and
# asserts only that it terminates and speaks when it refuses. It says so
# itself: "It asserts nothing about VERDICT. Whether a given hook should pass
# or fail on this fixture is that hook's own test's business."
#
# For eight hooks there was no such business. boot-smoke, cache-hygiene-warn,
# copy-lint, deps-audit, migration-lint, research-index-rebuild,
# stacking-rule-check and test-run were executed by the smoke loop and judged
# by nothing. A hook that runs cleanly and blocks the wrong thing — or blocks
# nothing at all — passes that loop perfectly.
#
# So each hook here gets a pair: an input it MUST accept and an input it MUST
# refuse. A hook that always exits 0 fails the refuse case; one that always
# exits 1 fails the accept case. Neither can be satisfied by a script that
# merely runs.
#
# Every case builds its own repo under mktemp -d — nothing here touches the
# engine tree, so this is safe under tests/run-all.sh's parallel runner.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
HOOKS="$ROOT/hooks"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "test_hook_verdicts"

# A fresh git repo per case, so one case's staged files cannot leak into the
# next — every one of these hooks reads `git diff --cached`.
new_repo() {
    local d="$TMP/$1"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email t@t.t
    git -C "$d" config user.name t
    printf 'seed\n' > "$d/seed.txt"
    git -C "$d" add -A
    git -C "$d" commit -qm base --no-verify
    echo "$d"
}

# Run a hook inside a repo, capturing output to a file and RETURNING the
# hook's exit code as this function's own.
#
# The obvious shape — assign inside the function to a global RC, call it as
# `out=$(run_hook ...)` — does not work, and fails in the direction that
# hides it: command substitution runs the function in a subshell, so RC
# never reaches the caller and every assertion reads a STALE value from some
# earlier case. Half of these checks passed that way while proving nothing.
# The exit code has to come back through $?, which is the one channel a
# subshell cannot swallow.
HOOK_OUT="$TMP/.hook-out"
run_hook() {
    local repo="$1" hook="$2"; shift 2
    ( cd "$repo" && env "$@" bash "$HOOKS/$hook.sh" ) >"$HOOK_OUT" 2>&1
}
# Same contract for the hooks driven by stdin (PostToolUse events, the
# pre-push ref list). One mechanism for all eight: the first version of this
# file had two, and the section using the other one is exactly where the
# stale-RC bug lived.
#
# The trailing newline is not cosmetic. stacking-rule-check reads its refs
# with `while read -r ...`, and read returns non-zero at an unterminated
# final line — so a payload built with $(...), which strips it, makes the
# loop body never execute and the hook exit 0 having inspected nothing.
# Three assertions here passed that way, green and vacuous, before the
# fourth (the one that expects a BLOCK) exposed it.
run_hook_stdin() {
    local repo="$1" hook="$2" input="$3"
    printf '%s\n' "$input" | ( cd "$repo" && bash "$HOOKS/$hook.sh" ) >"$HOOK_OUT" 2>&1
}
hook_said() { grep -q "$1" "$HOOK_OUT" 2>/dev/null; }
hook_silent() { [ ! -s "$HOOK_OUT" ]; }
hook_out() { cat "$HOOK_OUT" 2>/dev/null; }

# ─── 1. migration-lint — the clearest pair ──────────────────────────────
# sys.exit() in a migration killed the 8CStudio runner and hid 107 unapplied
# migrations for months. That is the whole reason this hook exists.
echo "migration-lint"
R=$(new_repo mig)
mkdir -p "$R/migrations"
printf 'def upgrade(conn):\n    pass\n' > "$R/migrations/migrate_001_ok.py"
git -C "$R" add -A
run_hook "$R" migration-lint; RC=$?
[ "$RC" -eq 0 ] \
    && ok "a clean migration is accepted" \
    || bad "clean migration rejected (rc=$RC): $(hook_out)"

printf 'import sys\ndef upgrade(conn):\n    sys.exit(0)\n' > "$R/migrations/migrate_002_bad.py"
git -C "$R" add -A
run_hook "$R" migration-lint; RC=$?
if [ "$RC" -ne 0 ] && hook_said 'migrate_002_bad.py'; then
    ok "sys.exit() in a migration is BLOCKED, and the file is named"
else
    bad "the defect this hook exists for was let through (rc=$RC): $(hook_out)"
fi

run_hook "$R" migration-lint PE_SKIP_MIGRATION_LINT=1; RC=$?
[ "$RC" -eq 0 ] \
    && ok "PE_SKIP_MIGRATION_LINT=1 bypasses" \
    || bad "documented bypass did not work (rc=$RC)"

# A non-migration file with the same forbidden call must NOT be blocked —
# otherwise the hook is a repo-wide ban on sys.exit wearing a narrow name.
R2=$(new_repo mig2)
mkdir -p "$R2/src"
printf 'import sys\nsys.exit(1)\n' > "$R2/src/cli.py"
git -C "$R2" add -A
run_hook "$R2" migration-lint; RC=$?
[ "$RC" -eq 0 ] \
    && ok "sys.exit() OUTSIDE migrations/ is none of this hook's business" \
    || bad "migration-lint blocked a non-migration file (rc=$RC): $(hook_out)"

# ─── 2. stacking-rule-check — a pre-push gate with real branching ───────
# Blocks only on the CONJUNCTION: a slot-stack AND a foundational change.
# Either alone must pass, or the rule is not the rule that was written.
echo "stacking-rule-check"
R=$(new_repo stack)
mkdir -p "$R/core"
base=$(git -C "$R" rev-parse HEAD)

# The pre-push contract: stdin lines of
# "<local_ref> <local_sha> <remote_ref> <remote_sha>".
stack_push() {   # $1=repo
    run_hook_stdin "$1" stacking-rule-check \
        "$(printf 'refs/heads/x %s refs/heads/x %s\n' "$(git -C "$1" rev-parse HEAD)" "$base")"
}

printf 'x = 1\n' > "$R/core/database.py"
git -C "$R" add -A; git -C "$R" commit -qm "3.1 touch core database" --no-verify
stack_push "$R"; RC=$?
[ "$RC" -eq 0 ] \
    && ok "one slot ID + a foundational change is allowed" \
    || bad "single-slot foundational push was blocked (rc=$RC): $(hook_out)"

printf 'y = 2\n' > "$R/core/database.py"
git -C "$R" add -A; git -C "$R" commit -qm "4.2 second slot, same foundation" --no-verify
stack_push "$R"; RC=$?
if [ "$RC" -ne 0 ] && hook_said 'core/database.py'; then
    ok "two slot IDs + a foundational change is BLOCKED, and the file is named"
else
    bad "a foundational slot-stack was let through (rc=$RC): $(hook_out)"
fi

R=$(new_repo stack2)
base=$(git -C "$R" rev-parse HEAD)
mkdir -p "$R/src"
printf 'a\n' > "$R/src/a.py"; git -C "$R" add -A
git -C "$R" commit -qm "3.1 ordinary work" --no-verify
printf 'b\n' > "$R/src/b.py"; git -C "$R" add -A
git -C "$R" commit -qm "4.2 more ordinary work" --no-verify
stack_push "$R"; RC=$?
[ "$RC" -eq 0 ] \
    && ok "two slot IDs with NO foundational change is allowed" \
    || bad "an ordinary slot-stack was blocked (rc=$RC): $(hook_out)"

ZERO_SHA=0000000000000000000000000000000000000000
run_hook_stdin "$R" stacking-rule-check \
    "refs/heads/x $ZERO_SHA refs/heads/x $base"; RC=$?
[ "$RC" -eq 0 ] \
    && ok "a branch deletion is not a push to inspect" \
    || bad "branch deletion was treated as a push (rc=$RC): $(hook_out)"

# ─── 3. copy-lint — advisory by default, blocking on request ────────────
echo "copy-lint"
R=$(new_repo copy)
mkdir -p "$R/templates"
printf '<html><body><h1>Invoices</h1><button>Add invoice</button></body></html>\n' \
    > "$R/templates/clean.html"
git -C "$R" add -A
run_hook "$R" copy-lint; RC=$?
if [ "$RC" -eq 0 ] && ! hook_said 'WARN'; then
    ok "plain sentence-case copy passes silently"
else
    bad "clean template was flagged (rc=$RC): $(hook_out)"
fi

printf '<html><body><h1>Unleash Your Workflow</h1><p>Seamless invoicing.</p></body></html>\n' \
    > "$R/templates/manifesto.html"
git -C "$R" add -A
run_hook "$R" copy-lint; RC=$?
if [ "$RC" -eq 0 ] && hook_said 'WARN.*Unleash'; then
    ok "manifesto copy WARNs but does not block (advisory default)"
else
    bad "advisory default is wrong (rc=$RC): $(hook_out)"
fi

printf 'copy_lint:\n  strict: true\n' > "$R/.process-engine.yaml"
git -C "$R" add -A
run_hook "$R" copy-lint; RC=$?
if [ "$RC" -ne 0 ] && hook_said 'FAIL'; then
    ok "copy_lint.strict=true turns the same copy into a block"
else
    bad "strict mode did not enforce (rc=$RC): $(hook_out)"
fi

run_hook "$R" copy-lint PE_SKIP_COPY_LINT=1; RC=$?
[ "$RC" -eq 0 ] \
    && ok "PE_SKIP_COPY_LINT=1 bypasses even in strict mode" \
    || bad "documented bypass did not work in strict mode (rc=$RC)"

# ─── 4. test-run — the hook that decides whether tests ran ──────────────
echo "test-run"
R=$(new_repo testrun)
printf 'x\n' > "$R/thing.py"; git -C "$R" add -A
run_hook "$R" test-run ENGINE_TEST_CMD=true; RC=$?
[ "$RC" -eq 0 ] \
    && ok "a passing test command lets the commit through" \
    || bad "passing tests blocked the commit (rc=$RC): $(hook_out)"

run_hook "$R" test-run ENGINE_TEST_CMD="exit 3"; RC=$?
[ "$RC" -eq 3 ] \
    && ok "a failing test command blocks, preserving its exit code" \
    || bad "test failure did not propagate (rc=$RC, wanted 3): $(hook_out)"

run_hook "$R" test-run ENGINE_TEST_CMD="exit 3" ENGINE_SKIP_TESTS=1; RC=$?
[ "$RC" -eq 0 ] \
    && ok "ENGINE_SKIP_TESTS=1 bypasses a failing suite" \
    || bad "documented bypass did not work (rc=$RC)"

R=$(new_repo testrun2)
run_hook "$R" test-run ENGINE_TEST_CMD="exit 3"; RC=$?
[ "$RC" -eq 0 ] \
    && ok "nothing staged → no test run, no block" \
    || bad "ran tests with an empty stage (rc=$RC): $(hook_out)"

# ─── 5. deps-audit — fires on manifests, silent otherwise ───────────────
echo "deps-audit"
R=$(new_repo deps)
printf 'x\n' > "$R/thing.py"; git -C "$R" add -A
run_hook "$R" deps-audit; RC=$?
if [ "$RC" -eq 0 ] && hook_silent; then
    ok "a commit with no dependency manifest is silent"
else
    bad "deps-audit spoke about a commit with no manifest (rc=$RC): $(hook_out)"
fi

printf 'requests==2.32.3\n' > "$R/requirements.txt"; git -C "$R" add -A
run_hook "$R" deps-audit; RC=$?
if hook_said 'python'; then
    ok "staging requirements.txt selects the python auditor"
else
    bad "a staged manifest did not reach an auditor (rc=$RC): $(hook_out)"
fi

run_hook "$R" deps-audit ENGINE_SKIP_DEPS_AUDIT=1; RC=$?
if [ "$RC" -eq 0 ] && hook_said 'skipping'; then
    ok "ENGINE_SKIP_DEPS_AUDIT=1 bypasses, and says it did"
else
    bad "documented bypass was silent or ineffective (rc=$RC): $(hook_out)"
fi

# ─── 6. research-index-rebuild — must never block a commit ──────────────
echo "research-index-rebuild"
R=$(new_repo research)
mkdir -p "$R/docs/research" "$R/scripts"
printf 'x\n' > "$R/src.py"; git -C "$R" add -A
run_hook "$R" research-index-rebuild; RC=$?
if [ "$RC" -eq 0 ] && hook_silent; then
    ok "no staged research doc → silent"
else
    bad "rebuilt the index for an unrelated commit (rc=$RC): $(hook_out)"
fi

# The contract this hook states in its own body: an index failure must not
# block the commit. A rebuild that exits 1 is the case that matters.
printf '# note\n' > "$R/docs/research/note.md"
printf 'import sys\nsys.exit(1)\n' > "$R/scripts/research_index.py"
git -C "$R" add -A
run_hook "$R" research-index-rebuild; RC=$?
if [ "$RC" -eq 0 ] && hook_said 'Commit proceeds anyway'; then
    ok "a failing rebuild does NOT block the commit, and says so"
else
    bad "index failure blocked a commit (rc=$RC): $(hook_out)"
fi

# ─── 7. cache-hygiene-warn — advisory, deduped, and quiet off-target ────
echo "cache-hygiene-warn"
R=$(new_repo cache)
event() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"; }

run_hook_stdin "$R" cache-hygiene-warn "$(event Write "$R/CLAUDE.md")"; RC=$?
if [ "$RC" -eq 0 ] && hook_said 'cache-hygiene'; then
    ok "editing CLAUDE.md warns about the broken prompt cache"
else
    bad "a prefix edit produced no warning (rc=$RC): $(hook_out)"
fi

run_hook_stdin "$R" cache-hygiene-warn "$(event Write "$R/CLAUDE.md")"; RC=$?
if [ "$RC" -eq 0 ] && hook_silent; then
    ok "the same file a second time is silent — one nudge per session"
else
    bad "the hook is chatty; it repeated itself: $(hook_out)"
fi

run_hook_stdin "$R" cache-hygiene-warn "$(event Write "$R/src/app.py")"; RC=$?
if [ "$RC" -eq 0 ] && hook_silent; then
    ok "editing ordinary source says nothing"
else
    bad "warned about a non-prefix file: $(hook_out)"
fi

run_hook_stdin "$R" cache-hygiene-warn "$(event Read "$R/CLAUDE.md")"; RC=$?
if [ "$RC" -eq 0 ] && hook_silent; then
    ok "reading a prefix file is not editing it"
else
    bad "warned on a Read event: $(hook_out)"
fi

# ─── 8. boot-smoke — the engine's one fully-orphaned hook ───────────────
# Nothing invokes it (see its header and docs/ADOPTION_AUDIT.md), so nothing
# has ever established that it judges correctly. Its failure paths need no
# server; the success path gets a real one.
echo "boot-smoke"
R=$(new_repo boot)
run_hook "$R" boot-smoke; RC=$?
if [ "$RC" -eq 0 ] && hook_said 'no .process-engine.yaml'; then
    ok "no config → skip, not failure"
else
    bad "absent config was not treated as a skip (rc=$RC): $(hook_out)"
fi

printf 'boot_check:\n  enabled: false\n' > "$R/.process-engine.yaml"
run_hook "$R" boot-smoke; RC=$?
[ "$RC" -eq 0 ] \
    && ok "boot_check.enabled=false → skip" \
    || bad "disabled boot_check still ran (rc=$RC): $(hook_out)"

printf 'boot_check:\n  enabled: true\n' > "$R/.process-engine.yaml"
run_hook "$R" boot-smoke; RC=$?
if [ "$RC" -ne 0 ] && hook_said 'probe_url'; then
    ok "enabled but unconfigured → FAIL with the config it needs"
else
    bad "an unusable config did not fail loudly (rc=$RC): $(hook_out)"
fi

printf 'boot_check:\n  enabled: true\n  setup: "exit 7"\n  run: "sleep 5"\n  probe_url: "http://127.0.0.1:59999/"\n' \
    > "$R/.process-engine.yaml"
run_hook "$R" boot-smoke; RC=$?
if [ "$RC" -ne 0 ] && hook_said 'setup command failed'; then
    ok "a failing setup command fails the gate before any app starts"
else
    bad "setup failure was not caught (rc=$RC): $(hook_out)"
fi

# The green path. A real process, a real probe — this is the assertion that
# would go red if the probe loop stopped working, which no skip-path can show.
if command -v curl >/dev/null 2>&1; then
    printf 'boot_check:\n  enabled: true\n  run: "%s -m http.server 45871 --bind 127.0.0.1"\n  probe_url: "http://127.0.0.1:45871/"\n  timeout_seconds: 15\n' \
        "${PE_PYTHON:-python3}" > "$R/.process-engine.yaml"
    run_hook "$R" boot-smoke; RC=$?
    [ "$RC" -eq 0 ] \
        && ok "an app that really boots and answers the probe PASSES" \
        || bad "a healthy app failed the boot gate (rc=$RC): $(hook_out)"
else
    echo "  ⚠ curl absent — the boot-smoke green path is UNTESTED in this run"
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
