#!/usr/bin/env bash
# tests/test_skills_audit_upstream.sh — `pe skills-audit --upstream` says
# which installed skills have drifted from their source.
#
# On 2026-09-16 every one of the sixteen ECC-sourced skills in the core set
# differed from upstream, and the frontend-design plugin was nine months and
# two rewrites behind. It was found by accident. v0.56.0 recorded a source for
# every core skill; this is the check that reads those sources.
#
# The comparison is a git blob hash: the local SKILL.md hashed the way git
# hashes it, against the sha GitHub reports for the same path. Upstream shas
# are injected through PE_SKILLS_UPSTREAM_SHAS so this test never touches the
# network and cannot pass or fail on someone else's commit.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
AUDIT="$ROOT/scripts/skills_audit.py"
PY="${PE_PYTHON:-python3}"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_skills_audit_upstream"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H="$T/home"; S="$H/.claude/skills"
mkdir -p "$S/grilling" "$S/frontend-design" "$S/api-design" "$S/my-skill" "$H/.claude/commands"
printf 'fresh grilling\n'  > "$S/grilling/SKILL.md"
printf 'old frontend\n'    > "$S/frontend-design/SKILL.md"
printf 'api design\n'      > "$S/api-design/SKILL.md"
printf 'adopter skill\n'   > "$S/my-skill/SKILL.md"
printf '{"my-skill": "acme/skills skills/my-skill"}\n' > "$S/.upstream.json"

g=$(git hash-object "$S/grilling/SKILL.md")
m=$(git hash-object "$S/my-skill/SKILL.md")
# frontend-design gets a different sha (stale); api-design gets none (unreachable);
# coding-standards is in the core set but not installed.
cat > "$T/shas.json" <<JSON
{
  "mattpocock/skills:skills/productivity/grilling/SKILL.md": "$g",
  "anthropics/skills:skills/frontend-design/SKILL.md": "0000000000000000000000000000000000000000",
  "acme/skills:skills/my-skill/SKILL.md": "$m"
}
JSON

run() { PE_SKILLS_UPSTREAM_SHAS="$T/shas.json" "$PY" "$AUDIT" --home "$H" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
# Section [2] also lists skill names, so every status check reads section [5] only.
line() { sed -n '/\[5\] FRESHNESS/,$p' "$T/out" | grep -E "· $1 "; }

# ─── without the flag: unchanged, and no network ────────────────────
run
if ! grep -q 'FRESHNESS' "$T/out"; then
    ok "without --upstream the report has no freshness section"
else
    bad "freshness section appears without --upstream — the plain audit must stay offline"
fi
[ "$(cat "$T/rc")" = "0" ] && ok "without --upstream, drift does not change the exit code" \
                          || bad "plain audit exited $(cat "$T/rc")"

# ─── with the flag ──────────────────────────────────────────────────
run --upstream
grep -q '\[5\] FRESHNESS' "$T/out" && ok "--upstream adds section [5] FRESHNESS" \
                                    || bad "no [5] FRESHNESS section"

line grilling | grep -q 'fresh' \
    && ok "a skill whose hash matches upstream is fresh" \
    || bad "grilling not reported fresh: $(line grilling)"
line frontend-design | grep -q 'STALE' \
    && ok "a skill whose hash differs is STALE" \
    || bad "frontend-design not reported STALE: $(line frontend-design)"
line frontend-design | grep -q 'anthropics/skills' \
    && ok "a stale line names the source to update from" \
    || bad "stale line does not name its source"
line api-design | grep -q 'unknown' \
    && ok "an unreachable upstream is unknown, not fresh and not stale" \
    || bad "api-design not reported unknown: $(line api-design)"
if line coding-standards | grep -q 'not installed'; then
    ok "a core skill missing locally is reported as not installed"
else
    bad "coding-standards not reported as not installed: $(line coding-standards)"
fi
line my-skill | grep -q 'fresh' \
    && ok "an adopter skill from .upstream.json is checked too" \
    || bad "my-skill from .upstream.json not checked: $(line my-skill)"
line start-session >/dev/null \
    && bad "engine-shipped skills are listed — they are symlinks into the engine, pe install keeps them current" \
    || ok "engine-shipped skills are left to pe install"

[ "$(cat "$T/rc")" = "1" ] && ok "a stale skill makes the audit exit 1" \
                          || bad "exit $(cat "$T/rc") with a stale skill, expected 1"

# ─── unknown alone must not fail the run ────────────────────────────
printf 'old frontend\n' > "$T/fd"
fd=$(git hash-object "$T/fd")
"$PY" - "$T/shas.json" "$fd" <<'PYFIX'
import json, sys
p, sha = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d["anthropics/skills:skills/frontend-design/SKILL.md"] = sha
json.dump(d, open(p, "w"))
PYFIX
run --upstream
[ "$(cat "$T/rc")" = "0" ] && ok "unknown and not-installed alone do not fail the audit (a flaky network is not drift)" \
                          || bad "exit $(cat "$T/rc") with nothing stale"

# ─── output that is not a sha is unknown, never STALE ───────────────
# `gh api ... --jq .sha` prints the literal text "null" for a path that is
# now a directory or gone. Treated as a sha, that reads as drift and fails
# the run: the one thing "unknown" promises not to do.
"$PY" - "$T/shas.json" <<'PYFIX'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["anthropics/skills:skills/frontend-design/SKILL.md"] = "null"
json.dump(d, open(p, "w"))
PYFIX
run --upstream
line frontend-design | grep -q 'unknown' \
    && ok "upstream output that is not a 40-hex sha is unknown, not STALE" \
    || bad "non-sha upstream output reported as: $(line frontend-design)"
[ "$(cat "$T/rc")" = "0" ] && ok "and it does not fail the run" \
                          || bad "non-sha upstream output exited $(cat "$T/rc")"

# ─── an unreadable local file degrades that skill only ──────────────
chmod 000 "$S/api-design/SKILL.md"
if [ -r "$S/api-design/SKILL.md" ]; then
    ok "unreadable-file case skipped: running as a user who can read mode-000 files"
else
    run --upstream
    if line api-design | grep -q 'unreadable' && line grilling | grep -q 'fresh'; then
        ok "an unreadable SKILL.md is reported for that skill and the rest still run"
    else
        bad "unreadable SKILL.md: $(tail -1 "$T/out")"
    fi
fi
chmod 644 "$S/api-design/SKILL.md"

# ─── a broken injected-shas file warns and goes nowhere near the network ─
printf '{broken' > "$T/bad.json"
PE_SKILLS_UPSTREAM_SHAS="$T/bad.json" "$PY" "$AUDIT" --home "$H" --upstream > "$T/out" 2>&1; echo $? > "$T/rc"
if ! grep -q 'Traceback' "$T/out" && grep -q 'PE_SKILLS_UPSTREAM_SHAS' "$T/out" \
   && line grilling | grep -q 'unknown'; then
    ok "a malformed PE_SKILLS_UPSTREAM_SHAS is named, and every skill is unknown rather than fetched"
else
    bad "malformed PE_SKILLS_UPSTREAM_SHAS: $(grep -m1 -E 'Traceback|Error' "$T/out")"
fi

# ─── a broken adopter map is reported, not fatal ────────────────────
for broken in '{not json' '{"my-skill": "acme/skills"}' '{"my-skill": 5}' \
              '{"my-skill": "acme/skills ../../user"}' '{"my-skill": "acme skills/x"}'; do
    printf '%s' "$broken" > "$S/.upstream.json"
    run --upstream
    if grep -q '.upstream.json' "$T/out" && grep -q 'api-design' "$T/out"; then
        ok "malformed .upstream.json ($broken) is named and the audit still reports"
    else
        bad "malformed .upstream.json ($broken) crashed the audit or went unmentioned: $(tail -1 "$T/out")"
    fi
done

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
