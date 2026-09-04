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
# Also covers the one-slot history: --record writes a single fixed filename,
# so every review overwrote the previous one, while the engine's own
# scripts/dev-log-collect.sh globs .claude/gates/*.json to count verdicts
# into the digest the retro agent reads — and reported "0 gate verdicts" for
# a day with three reviews.

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

# ─── 4. the record the blocking hook reads survives repeat writes ───
# A timestamped history sibling was tried here and removed: the engine
# cannot start creating untracked files in an adopter's working tree, or
# the tree never comes clean and stop-uncommitted-reminder — shipped by
# this same engine — nags every turn forever. tests/test_hooks.sh caught
# it. See write_record()'s docstring and docs/ADOPTION_AUDIT.md.
rm -rf "$TMP/gates"; mkdir -p "$TMP/gates"
for _ in 1 2 3; do
    "$PY" "$GATE" --record "$REC" --diff-sha abc123 "$TMP/pass.md" >/dev/null 2>&1
done
n=$(find "$TMP/gates" -name '*.json' | wc -l | tr -d ' ')
[ "$n" -eq 1 ] \
    && ok "--record writes exactly one file, and no untracked siblings" \
    || bad "--record left $n files in the gates dir — it must write only what it was asked to"
[ -f "$REC" ] && ok "the fixed name the blocking hook reads still exists" \
              || bad "last-gate.json is gone — the pre-commit hook has nothing to read"

# ─── 5. no DeprecationWarning on the happy path ─────────────────────
warn=$("$PY" -W error::DeprecationWarning "$GATE" --record "$REC" \
       --diff-sha abc123 "$TMP/pass.md" 2>&1 >/dev/null)
printf '%s' "$warn" | grep -q "DeprecationWarning" \
    && bad "happy path emits a DeprecationWarning into the channel the record lines use" \
    || ok "happy path stderr carries the record line and nothing else"

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
