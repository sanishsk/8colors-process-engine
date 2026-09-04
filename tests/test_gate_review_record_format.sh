#!/usr/bin/env bash
# tests/test_gate_review_record_format.sh — the transcript shape the Record
# prompt shows must be one `pe gate parse` actually accepts.
#
# The Record phase is the step without which none of /gate-review's work
# reaches the commit gate, and it is driven entirely by a prompt. Nothing
# checked that the prompt described a format the parser would take.
#
# It did not. The prompt said to write "an 'Envelope key values' block
# listing schema_version, gate_name, verdict, failure_class, model_used and
# timestamp one per line" — which omits the only thing CROSSCHECK_KV_RE in
# scripts/pe_gate.py enforces: the key lines must be indented two spaces or
# a tab. A transcript written to the letter of that sentence is rejected
# with "missing required field" six times, which reads as a broken envelope
# rather than a broken heading. agents/_gate-contract.md avoids this by
# SHOWING the block; the workflow paraphrased it.
#
# So this test does not read the prompt for keywords. It lifts the literal
# block out of the prompt, fills it in, and feeds it to the real parser. If
# the shape the operator's agent is told to write cannot be recorded, this
# goes red.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_gate_review_record_format"

WF="workflows/gate-review.js"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Lift the six cross-check lines out of the Record prompt, replacing the
# `${envelope.x}` interpolations with values from a synthetic envelope.
# Indentation is preserved byte-for-byte — that is the whole point.
"${PE_PYTHON:-python3}" - "$WF" "$TMP" <<'PY'
import json, re, sys

wf, tmp = sys.argv[1], sys.argv[2]
src = open(wf, encoding="utf-8").read()

env = {
    "schema_version": "1.0.0",
    "gate_name": "merge-gate",
    "verdict": "WARN",
    "failure_class": "none",
    "findings": [{"severity": "HIGH", "rule": "example-rule",
                  "message": "a finding, for the shape"}],
    "model_used": "test-model",
    "timestamp": "2026-09-04T12:00:00Z",
}

# Each prompt line looks like:  `  schema_version: ${envelope.schema_version}\n` +
line_re = re.compile(
    r"`(?P<indent>[ \t]*)(?P<key>schema_version|gate_name|verdict|"
    r"failure_class|model_used|timestamp): \$\{envelope\.(?P=key)\}(?:\\n)+`")

found = {}
for m in line_re.finditer(src):
    found[m.group("key")] = m.group("indent")

missing = [k for k in ("schema_version", "gate_name", "verdict",
                       "failure_class", "model_used", "timestamp")
           if k not in found]
if missing:
    print("MISSING|" + ",".join(missing))
    raise SystemExit(0)

lines = ["Envelope key values\n"]
for k in ("schema_version", "gate_name", "verdict",
          "failure_class", "model_used", "timestamp"):
    lines.append(f"{found[k]}{k}: {env[k]}\n")
lines.append("\n```json gate-envelope\n")
lines.append(json.dumps(env, indent=2))
lines.append("\n```\n")

open(f"{tmp}/transcript.md", "w", encoding="utf-8").write("".join(lines))

PY

if [ ! -f "$TMP/transcript.md" ]; then
    bad "could not lift the cross-check block out of the Record prompt — the prompt no longer SHOWS the six key lines, so nothing verifies the shape it asks for"
    echo "  $PASS passed, $FAIL failed"
    exit 1
fi
ok "the Record prompt shows all six cross-check lines literally"

# The decisive check: does the real parser take it?
out=$(./scripts/pe gate parse --record "$TMP/last-gate.json" \
      --diff-sha 0000000000000000000000000000000000000000 \
      "$TMP/transcript.md" 2>&1)
rc=$?

# `pe gate parse` encodes the VERDICT in its exit code — 0 PASS, 1 FAIL
# worker_quality, 2 FAIL non-escalatable, 3 WARN — and reserves 4 for "the
# envelope was invalid, nothing was written". So a recorded WARN exits 3,
# and only 4 means rejected. Asserting exit 0 here would call a correctly
# recorded WARN a failure.
if [ $rc -ne 4 ] && [ -f "$TMP/last-gate.json" ] \
   && printf '%s' "$out" | grep -q 'gate: recorded'; then
    ok "the shape the Record prompt asks for is accepted and recorded (exit $rc = WARN)"
else
    bad "the Record prompt asks for a transcript pe gate parse rejects (exit $rc): $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
fi

# And it must land intact, not merely be accepted.
if [ -f "$TMP/last-gate.json" ]; then
    v=$("${PE_PYTHON:-python3}" -c "
import json,sys
d=json.load(open('$TMP/last-gate.json'))
e=d.get('envelope',{})
print(d.get('verdict'), d.get('gate_name'), len(e.get('findings',[])), d.get('diff_sha','')[:8])
" 2>/dev/null)
    case "$v" in
        "WARN merge-gate 1 00000000")
            ok "the recorded file carries the verdict, gate, findings and diff_sha" ;;
        *)
            bad "recorded file is wrong: got '$v'" ;;
    esac
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
