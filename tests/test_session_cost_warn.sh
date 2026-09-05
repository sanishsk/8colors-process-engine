#!/usr/bin/env bash
# tests/test_session_cost_warn.sh — the compaction advisory's verdict contract.
#
# The hook exists because context replay is 73% of the bill and grows within a
# session — measured, 138k tokens/turn at the start of a session against 674k
# by the end of one that never compacted. One compaction cut another session
# from 531k to 157k per turn. `pe telemetry` reports all of that AFTER the
# session ends, which is the wrong side of the decision.
#
# An advisory that fires when it should not is worse than none, because it is
# the kind of thing people switch off and then never hear from again. So the
# pairs here are about restraint as much as detection:
#
#   * a cheap session must produce SILENCE
#   * an expensive one must speak, once
#   * the same cost must not speak twice
#   * a commit boundary must lower the bar, not remove it
#   * nothing it does may block a turn or a commit
#
# Every case builds its own transcript and project under mktemp -d.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ROOT/hooks/session-cost-warn.sh"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "test_session_cost_warn"

# Build a transcript of N assistant turns, each replaying $2 tokens.
make_transcript() {   # $1=path  $2=tokens/turn  $3=turns
    "${PE_PYTHON:-python3}" - "$1" "$2" "$3" <<'PY'
import json, sys
path, per_turn, turns = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "summary", "sessionId": "s"}) + "\n")
    for i in range(turns):
        fh.write(json.dumps({
            "type": "assistant",
            "uuid": f"u{i}",
            "message": {"model": "m", "usage": {
                "input_tokens": 10, "output_tokens": 100,
                "cache_read_input_tokens": per_turn,
                "cache_creation_input_tokens": 0,
            }},
        }) + "\n")
PY
}

# Drive the hook with a synthetic event. RC comes back through $?, and output
# to a file — the two things a subshell cannot swallow.
OUT="$TMP/.out"
run_hook() {   # $1=project  $2=event-json  [env...]
    local proj="$1" event="$2"; shift 2
    printf '%s' "$event" \
      | ( cd "$proj" && env CLAUDE_PROJECT_DIR="$proj" "$@" bash "$HOOK" ) \
        >"$OUT" 2>&1
}
said() { grep -q "$1" "$OUT" 2>/dev/null; }
silent() { [ ! -s "$OUT" ]; }

stop_event() { printf '{"transcript_path":"%s"}' "$1"; }
commit_event() {
    printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"transcript_path":"%s"}' "$1"
}

PROJ="$TMP/proj"; mkdir -p "$PROJ/.pe"
T="$TMP/session.jsonl"

# ─── 1. a cheap session says nothing ────────────────────────────────
make_transcript "$T" 50000 30
run_hook "$PROJ" "$(stop_event "$T")" PE_SESSION_COST_WARN=300000; rc=$?
if [ "$rc" -eq 0 ] && silent; then
    ok "50k/turn is under the bar — silence"
else
    bad "warned about a cheap session (rc=$rc): $(cat "$OUT")"
fi

# ─── 2. an expensive session speaks, with the number in it ──────────
rm -f "$PROJ/.pe/session-cost.state"
make_transcript "$T" 600000 30
run_hook "$PROJ" "$(stop_event "$T")" PE_SESSION_COST_WARN=300000; rc=$?
if [ "$rc" -eq 0 ] && said '600,000'; then
    ok "600k/turn crosses the bar and the measured figure is reported"
else
    bad "no advisory on an expensive session (rc=$rc): $(cat "$OUT")"
fi

said 'compact\|/compact' \
    && ok "the advisory names the action, not just the problem" \
    || bad "the operator is told the cost and not what to do about it"

# ─── 3. it does not repeat at the same cost ─────────────────────────
run_hook "$PROJ" "$(stop_event "$T")" PE_SESSION_COST_WARN=300000
if silent; then
    ok "the same band does not nudge twice — this is not a per-turn nag"
else
    bad "the advisory repeated at unchanged cost: $(cat "$OUT")"
fi

# ─── 4. it speaks again when the cost genuinely climbs ──────────────
make_transcript "$T" 1200000 30
run_hook "$PROJ" "$(stop_event "$T")" PE_SESSION_COST_WARN=300000
said '1,200,000' \
    && ok "a session that keeps growing is told again, at the next band" \
    || bad "silence after cost doubled — the dedupe is too aggressive"

# ─── 5. a commit ALWAYS speaks ──────────────────────────────────────
# The Stop trigger is thresholded and deduped because it fires every turn.
# The commit trigger is neither: compacting is a practice, and a practice
# mentioned only once the session is already expensive is one nobody forms —
# by then the tokens the habit existed to save are spent. Commits are rare
# where turns are not, so this is affordable and the omission is not.
#
# 200k/turn is under the 300k Stop bar. The same session must be silent on
# Stop and speak after a commit — that difference IS the feature.
PROJ2="$TMP/proj2"; mkdir -p "$PROJ2/.pe"
make_transcript "$T" 200000 30
run_hook "$PROJ2" "$(stop_event "$T")" PE_SESSION_COST_WARN=300000
silent \
    && ok "200k/turn is below the Stop bar — silence mid-work" \
    || bad "Stop fired under its own threshold: $(cat "$OUT")"

run_hook "$PROJ2" "$(commit_event "$T")" PE_SESSION_COST_WARN=300000
if said 'Commit landed'; then
    ok "the same cost DOES speak at a commit — the cheapest moment to reset"
else
    bad "the commit boundary did not speak: $(cat "$OUT")"
fi

said 'does not need to re-read' \
    && ok "the commit message says why a boundary is the moment" \
    || bad "the commit advisory reads the same as the mid-work one"

# The decisive case for "a practice never missed": a session far below every
# threshold must STILL be reminded at its commit. This is the assertion that
# separates a habit from an alarm, and it is red against a thresholded hook.
PROJ2B="$TMP/proj2b"; mkdir -p "$PROJ2B/.pe"
make_transcript "$T" 40000 30
run_hook "$PROJ2B" "$(commit_event "$T")" PE_SESSION_COST_WARN=300000
said 'Commit landed' \
    && ok "even a cheap session is reminded at its commit — never missed" \
    || bad "a commit under the bar said nothing — the practice IS missable"

# ...but it must not spend a paragraph doing it. The evidence for compacting
# is argued once, when the number warrants the room; repeated at every commit
# it becomes the noise that gets the whole hook muted.
#
# Both halves, deliberately: "the evidence is absent" is also true of a hook
# that said nothing, which is the failure the assertion above is about. Only
# the pair distinguishes a short reminder from silence.
if said 'Commit landed' && ! said '531k'; then
    ok "under the bar the reminder is a line, not the case for it"
else
    bad "under the bar the commit reminder is silent or a full paragraph"
fi

# A flat session is not a growing one. "about 1.0x the earliest turns" is a
# clause that reads like a measurement and carries nothing; the growth figure
# earns its place only when there is growth.
said '1.0x' \
    && bad "reported 1.0x growth on a flat session — noise dressed as a metric" \
    || ok "the growth clause is omitted when the cost is not growing"

run_hook "$PROJ2B" "$(commit_event "$T")" PE_SESSION_COST_WARN=300000
said 'Commit landed' \
    && ok "the second commit is reminded too — no dedupe on this trigger" \
    || bad "the commit reminder deduped itself away — one commit, one nudge"

# A commit must not consume a Stop band. They are separate triggers answering
# separate questions; if the commit path wrote the dedupe state, one commit
# would silence the per-turn warning for the rest of the session.
PROJ2C="$TMP/proj2c"; mkdir -p "$PROJ2C/.pe"
make_transcript "$T" 600000 30
run_hook "$PROJ2C" "$(commit_event "$T")" PE_SESSION_COST_WARN=300000
said 'Commit landed' || bad "expensive commit said nothing: $(cat "$OUT")"
said '531k' \
    && ok "over the bar, the commit reminder makes the case as well" \
    || bad "an expensive commit gave the bare reminder with no evidence"

run_hook "$PROJ2C" "$(stop_event "$T")" PE_SESSION_COST_WARN=300000
said 'Session cost' \
    && ok "a commit does not silence the Stop trigger — separate budgets" \
    || bad "the commit consumed the Stop band: $(cat "$OUT")"

# ─── 6. restraint and safety ────────────────────────────────────────
PROJ3="$TMP/proj3"; mkdir -p "$PROJ3/.pe"
make_transcript "$T" 600000 3
run_hook "$PROJ3" "$(stop_event "$T")" PE_SESSION_COST_WARN=300000
silent \
    && ok "a 3-turn session is too early to judge — silence" \
    || bad "advised on a session with almost no history: $(cat "$OUT")"

# The single exception to "every commit". Not a threshold in disguise: with
# three turns there is no average to report, and this advisory's only claim
# on attention is that its number is real. Asserted so the exception stays
# deliberate and visible rather than becoming a quiet second threshold.
run_hook "$PROJ3" "$(commit_event "$T")" PE_SESSION_COST_WARN=300000
silent \
    && ok "a commit with too little history to average is the one exception" \
    || bad "reported a per-turn figure computed from 3 turns: $(cat "$OUT")"

PROJ4="$TMP/proj4"; mkdir -p "$PROJ4/.pe"
make_transcript "$T" 600000 30
run_hook "$PROJ4" "$(stop_event "$T")" PE_SESSION_COST_WARN=300000 PE_SKIP_SESSION_COST=1; rc=$?
if [ "$rc" -eq 0 ] && silent; then
    ok "PE_SKIP_SESSION_COST=1 bypasses"
else
    bad "documented bypass did not work (rc=$rc)"
fi

PROJ5="$TMP/proj5"; mkdir -p "$PROJ5/.pe"
printf 'session_cost:\n  enabled: false\n' > "$PROJ5/.process-engine.yaml"
run_hook "$PROJ5" "$(stop_event "$T")" PE_SESSION_COST_WARN=300000
silent \
    && ok "session_cost.enabled=false silences it, as the message promises" \
    || bad "the config switch the advisory advertises does not work"

# A missing transcript, a corrupt one, and a garbage event must all be
# survivable: this runs on EVERY Bash call and every turn end.
PROJ6="$TMP/proj6"; mkdir -p "$PROJ6/.pe"
for bad_event in '{"transcript_path":"/nonexistent/x.jsonl"}' 'not json at all' '{}'; do
    run_hook "$PROJ6" "$bad_event" PE_SESSION_COST_WARN=300000; rc=$?
    [ "$rc" -eq 0 ] || bad "hook exited $rc on event: $bad_event"
done
ok "a missing transcript, malformed JSON and an empty event all exit 0"

printf 'garbage\n{"nope":1}\n' > "$TMP/corrupt.jsonl"
run_hook "$PROJ6" "$(stop_event "$TMP/corrupt.jsonl")" PE_SESSION_COST_WARN=300000; rc=$?
[ "$rc" -eq 0 ] \
    && ok "a corrupt transcript cannot break a turn" \
    || bad "corrupt transcript exited $rc — this runs on every Bash call"

# ─── 7. registered where it can actually fire ───────────────────────
# The engine's recurring defect is capability nothing invokes. Assert the
# wiring, not just the script.
for event in PostToolUse Stop; do
    "${PE_PYTHON:-python3}" - "$ROOT/hooks/hooks.json" "$event" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
entries = data.get(sys.argv[2], [])
cmds = [h.get("command", "") for e in entries for h in e.get("hooks", [])]
sys.exit(0 if any("session-cost-warn.sh" in c for c in cmds) else 1)
PYEOF
    [ $? -eq 0 ] \
        && ok "session-cost-warn is wired on $event" \
        || bad "session-cost-warn is not registered on $event — it cannot fire"
done

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
