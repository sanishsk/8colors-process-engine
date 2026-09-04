#!/usr/bin/env bash
# tests/test_gate_record.sh — `pe gate parse --record` must say what it did.
#
# Reported 2026-09-04: "it printed the parsed envelope, exited 4, and left
# the target file holding the previous envelope." All three were true, and
# the first is why the other two were a surprise — the envelope went to
# stdout BEFORE validation ran, so an invalid envelope produced a
# well-formed, PASS-looking document on stdout and put the reason on stderr.
# Reading stdout, it looked like it had worked. The operator hand-wrote the
# record JSON from Python twice rather than debug it.
#
# Exit 4 does mean "did not write". The defect was that nothing said so.
#
# Also covers the history. --record writes a single fixed filename, which is
# right for the pre-commit hook (whose only question is "what is the verdict
# for the diff being committed RIGHT NOW") and useless for every other
# question: every review overwrote the previous one, while the engine's own
# scripts/dev-log-collect.sh globs .claude/gates/*.json to count verdicts
# into the digest the retro agent reads — and reported "0 gate verdicts" for
# a day with three reviews. v0.52.0 adds an append-only history.jsonl beside
# the sidecar; both live under .claude/gates/, which is gitignored in adopter
# projects and (since v0.52.0) in the engine's own repo too.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
PY="${PE_PYTHON:-python3}"
GATE="$ROOT/scripts/pe_gate.py"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "test_gate_record"

envelope() {   # $1 = verdict, $2 = failure_class
cat <<EOF
Envelope key values
  schema_version: 1.0.0
  gate_name: code-reviewer
  verdict: $1
  failure_class: $2
  model_used: test-model
  timestamp: 2026-07-02T12:00:00Z

\`\`\`json gate-envelope
{
  "schema_version": "1.0.0",
  "gate_name": "code-reviewer",
  "verdict": "$1",
  "failure_class": "$2",
  "model_used": "test-model",
  "timestamp": "2026-07-02T12:00:00Z",
  "findings": []
}
\`\`\`
EOF
}

envelope PASS none > "$TMP/pass.md"
envelope FAIL worker_quality > "$TMP/fail.md"
# Same envelope, cross-check block stripped — valid JSON, invalid transcript.
sed '/^Envelope key values$/,/^$/d' "$TMP/pass.md" > "$TMP/nocross.md"

REC="$TMP/gates/last-gate.json"
mkdir -p "$TMP/gates"

# ─── 1. PASS writes, and says it wrote ──────────────────────────────
printf '{"prev":"OLD"}\n' > "$REC"
out=$("$PY" "$GATE" --record "$REC" --diff-sha abc123 "$TMP/pass.md" 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "PASS envelope exits 0" || bad "PASS envelope exited $rc"
grep -q OLD "$REC" && bad "PASS did not overwrite the record" \
                   || ok "PASS overwrote the record"
printf '%s' "$out" | grep -q "recorded" \
    && ok "PASS says it recorded, and where" \
    || bad "PASS wrote silently: [$out]"

# ─── 2. an INVALID envelope must not look like a success ────────────
printf '{"prev":"OLD"}\n' > "$REC"
stdout=$("$PY" "$GATE" --record "$REC" --diff-sha abc123 "$TMP/nocross.md" 2>/dev/null); rc=$?
stderr=$("$PY" "$GATE" --record "$REC" --diff-sha abc123 "$TMP/nocross.md" 2>&1 >/dev/null)

[ "$rc" -eq 4 ] && ok "invalid envelope exits 4" || bad "invalid envelope exited $rc"
[ -z "$stdout" ] \
    && ok "invalid envelope prints NOTHING to stdout" \
    || bad "invalid envelope still prints a PASS-looking document to stdout"
grep -q OLD "$REC" && ok "invalid envelope leaves the record untouched" \
                   || bad "invalid envelope overwrote the record"
printf '%s' "$stderr" | grep -q "nothing was written" \
    && ok "invalid envelope says nothing was written" \
    || bad "invalid envelope does not say the record was skipped"
printf '%s' "$stderr" | grep -q "left unchanged" \
    && ok "invalid envelope names the record it did not write" \
    || bad "invalid envelope does not name the untouched record"

# ─── 3. a FAIL verdict is a legitimate not-written — but not a silent one
printf '{"prev":"OLD"}\n' > "$REC"
stderr=$("$PY" "$GATE" --record "$REC" --diff-sha abc123 "$TMP/fail.md" 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 1 ] && ok "FAIL envelope exits 1" || bad "FAIL envelope exited $rc"
grep -q OLD "$REC" && ok "FAIL leaves the record untouched" \
                   || bad "FAIL wrote a record — a failed envelope is not proof of review"
printf '%s' "$stderr" | grep -q "NOT recorded" \
    && ok "FAIL says the record was not written, and why" \
    || bad "FAIL did not write and said nothing: [$stderr]"

# ─── 4. one sidecar, and a history that accumulates ─────────────────
# The sidecar must stay exactly one file: a timestamped-per-review sibling
# was tried once and removed, because an adopter's tree then never comes
# clean and stop-uncommitted-reminder — shipped by this same engine — nags
# every turn. The history is ONE extra file, appended to, and gitignored
# in every tree the engine touches (tests/test_pe_install_reconcile.sh and
# the engine's own .gitignore both assert that).
rm -rf "$TMP/gates"; mkdir -p "$TMP/gates"
for _ in 1 2 3; do
    "$PY" "$GATE" --record "$REC" --diff-sha abc123 "$TMP/pass.md" >/dev/null 2>&1
done
n=$(find "$TMP/gates" -name '*.json' | wc -l | tr -d ' ')
[ "$n" -eq 1 ] \
    && ok "--record still writes exactly ONE .json sidecar, however often it runs" \
    || bad "--record left $n .json files in the gates dir — one per review is the bug that was removed"
[ -f "$REC" ] && ok "the fixed name the blocking hook reads still exists" \
              || bad "last-gate.json is gone — the pre-commit hook has nothing to read"

HIST="$TMP/gates/history.jsonl"
lines=$( [ -f "$HIST" ] && wc -l < "$HIST" | tr -d ' ' || echo 0 )
[ "$lines" -eq 3 ] \
    && ok "three reviews leave three history lines — the day's verdicts survive" \
    || bad "history.jsonl has $lines line(s) after 3 reviews (expected 3)"

# A history line has to answer the audit questions on its own: when, which
# gate, what verdict, on which diff, how bad, by which model.
if [ -f "$HIST" ]; then
    missing=$("${PE_PYTHON:-python3}" - "$HIST" <<'PYEOF'
import json, sys
required = {"recorded_at", "gate_name", "verdict", "diff_sha",
            "findings", "severities", "model_used", "failure_class"}
with open(sys.argv[1]) as fh:
    rows = [json.loads(line) for line in fh if line.strip()]
missing = set()
for row in rows:
    missing |= required - set(row)
print(",".join(sorted(missing)))
PYEOF
)
    [ -z "$missing" ] \
        && ok "each history line carries when/which-gate/verdict/diff/severity/model" \
        || bad "history lines are missing fields the audit needs: $missing"
fi

# An unwritable history must never fail a verdict the commit gate depends on.
rm -rf "$TMP/gates"; mkdir -p "$TMP/gates"
"$PY" "$GATE" --record "$REC" --diff-sha abc123 "$TMP/pass.md" >/dev/null 2>&1
chmod 0444 "$HIST" 2>/dev/null
stderr=$("$PY" "$GATE" --record "$REC" --diff-sha def456 "$TMP/pass.md" 2>&1 >/dev/null); rc=$?
chmod 0644 "$HIST" 2>/dev/null
if [ "$rc" -ne 4 ] && printf '%s' "$stderr" | grep -q 'gate: recorded'; then
    ok "a read-only history does not stop the verdict being recorded"
else
    bad "an unwritable history broke the record path (rc=$rc): $stderr"
fi

# ─── 4b. recording never dirties a git working tree ─────────────────
# The history is why this needs asserting. Before it existed, .claude/gates/
# frequently ended up EMPTY (the FAIL path deletes the sidecar) and git
# cannot see an empty directory — so an unignored gates dir never showed up,
# and that looked like proof it was harmless. tests/test_hooks.sh went red
# the moment a history file made the directory non-empty, because
# stop-uncommitted-reminder — shipped by this same engine — then nags every
# turn about a file the engine itself wrote.
#
# `pe install` gitignores .claude/gates/, but the hooks work without it, so
# the directory ignores its own contents instead. That must hold in a repo
# nobody ran `pe install` on.
GREPO="$TMP/gitrepo"
mkdir -p "$GREPO"
git -C "$GREPO" init -q
git -C "$GREPO" config user.email t@t.t
git -C "$GREPO" config user.name t
printf 'x\n' > "$GREPO/file.txt"
git -C "$GREPO" add file.txt
git -C "$GREPO" commit -qm base --no-verify
for _ in 1 2; do
    "$PY" "$GATE" --record "$GREPO/.claude/gates/last-gate.json" \
        --diff-sha abc123 "$TMP/pass.md" >/dev/null 2>&1
done
[ -f "$GREPO/.claude/gates/history.jsonl" ] \
    && ok "the history lands in a plain repo with no pe install" \
    || bad "no history was written in an uninstalled repo"
dirty=$(git -C "$GREPO" status --porcelain)
[ -z "$dirty" ] \
    && ok "recording leaves the working tree clean — the gates dir ignores itself" \
    || bad "recording dirtied the tree ($dirty) — stop-uncommitted-reminder will nag forever"

# ─── 5. no DeprecationWarning on the happy path ─────────────────────
warn=$("$PY" -W error::DeprecationWarning "$GATE" --record "$REC" \
       --diff-sha abc123 "$TMP/pass.md" 2>&1 >/dev/null)
printf '%s' "$warn" | grep -q "DeprecationWarning" \
    && bad "happy path emits a DeprecationWarning into the channel the record lines use" \
    || ok "happy path stderr carries the record line and nothing else"

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
