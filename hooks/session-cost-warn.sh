#!/usr/bin/env bash
# session-cost-warn — T1 advisory Stop hook: nudge when the cost of REPLAYING
# this session's own context has grown past a threshold.
#
# The measurement this exists for. Across 2,231 real turns on this engine,
# 73.1% of input-side billed-equivalent tokens were context replayed and 2.0%
# was output. Generation is not the bill; re-reading the conversation is.
#
# And the replay grows *within* a session, because every turn re-reads every
# previous turn. Two measured sessions, per-turn cache-read by decile:
#
#     decile      never-compacted        compacted mid-run
#          1              138,832                  146,911
#          4              346,489                  531,280
#          6              477,988          →       156,951   ← compaction
#         10              674,401                  380,062
#     growth                  4.9x                     2.6x
#
# The 531,280 → 156,951 step is one compaction: a ~70% cut in per-turn cost,
# in a single action. The other session ran 841 turns to 674k/turn and never
# reset, paying ~5x its opening rate by the end.
#
# So the lever is real, it is large, and it is time-sensitive — and nothing
# told the operator when to pull it. `pe telemetry` reports all of this
# accurately and only AFTER the session is over, which is the wrong side of
# the decision. This hook moves the same number to a point where it can still
# change something.
#
# Two triggers, because "how expensive is this now" and "when is it cheapest
# to act" are different questions:
#
#   Stop         — every turn, warn once per threshold band. Catches a
#                  session that grew expensive without a natural break.
#   after commit — a commit is the point at which the preceding context has
#                  DONE ITS JOB. The exploration, the failed attempt, the
#                  test output that led to the fix: all of it is now
#                  represented by the diff and the message, and none of it
#                  needs re-reading for the next piece of work. So the bar is
#                  half the Stop bar here — the same tokens are cheaper to
#                  shed at a boundary than in the middle of something.
#
# What this hook CANNOT do is compact for you. A hook returns a decision or a
# message; there is no action that resets a session's context, and inventing
# one in a comment would be the engine's oldest failure mode. `/compact`, or
# finishing and starting fresh, stays a keystroke the operator makes. This
# tells them when it is worth making.
#
# Advisory ONLY. Exits 0 always, never blocks a turn or a commit. It nudges
# at most once per threshold band per session, because a warning that fires
# every turn is a warning people turn off.
#
# Config (.process-engine.yaml):
#     session_cost:
#       warn_tokens_per_turn: 300000   # default; ~2x a typical opening rate
#       enabled: true
#
# At a commit boundary the effective threshold is half this value.
#
# Bypass: PE_SKIP_SESSION_COST=1

set -uo pipefail

if [ "${PE_SKIP_SESSION_COST:-0}" = "1" ]; then
    exit 0
fi

# No stdin means this was run by hand, not by the hook runner. Reading the
# event is how we find the session; without it there is nothing to measure.
if [ -t 0 ]; then
    exit 0
fi
EVENT=$(cat 2>/dev/null || true)

# Cheap bail-out BEFORE spawning python. This hook is registered on
# PostToolUse for Bash, so it is invoked on every shell command the session
# runs — and only a `git commit` is a boundary worth measuring. Deciding that
# here costs a grep; deciding it in python costs an interpreter start on
# every `ls`. A Stop event has no tool_name and falls through.
if printf '%s' "$EVENT" | grep -q '"tool_name"'; then
    printf '%s' "$EVENT" | grep -q 'git commit' || exit 0
fi

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ENGINE_DIR/scripts/_yaml.sh" ]; then
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/scripts/_yaml.sh"
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
CONFIG="$PROJECT_ROOT/.process-engine.yaml"
enabled="true"
warn_per_turn="${PE_SESSION_COST_WARN:-}"

if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get session_cost.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    if [ -z "$warn_per_turn" ]; then
        v=$(yaml_get session_cost.warn_tokens_per_turn "$CONFIG" 2>/dev/null || true)
        [ -n "$v" ] && warn_per_turn="$v"
    fi
fi
[ "$enabled" != "true" ] && exit 0
warn_per_turn="${warn_per_turn:-300000}"

# Everything below is one python pass: locate the transcript, read only its
# TAIL (a long session's transcript is tens of MB and this runs on every
# turn — reading it whole would make the cost warning a cost), compute the
# recent per-turn replay, and decide whether this band has already been
# reported.
PONYTAIL_EVENT="$EVENT" \
PE_PROJECT_ROOT="$PROJECT_ROOT" \
PE_WARN_PER_TURN="$warn_per_turn" \
"${PE_PYTHON:-python3}" - <<'PY' 2>/dev/null || exit 0
import json, os, sys
from pathlib import Path

WINDOW = 25          # turns averaged for "recent"
TAIL_BYTES = 400_000  # enough for WINDOW assistant records, bounded

project = Path(os.environ.get("PE_PROJECT_ROOT", ".")).resolve()
try:
    warn = int(float(os.environ.get("PE_WARN_PER_TURN", "300000")))
except ValueError:
    sys.exit(0)
if warn <= 0:
    sys.exit(0)

try:
    event = json.loads(os.environ.get("PONYTAIL_EVENT") or "{}")
except Exception:
    event = {}

# Which trigger fired. A PostToolUse event naming a `git commit` is the
# boundary case; anything else is the per-turn Stop case.
command = ((event.get("tool_input") or {}).get("command") or "")
at_commit = (
    event.get("tool_name") == "Bash"
    and "git commit" in command
    and "--dry-run" not in command
)
# The threshold to FIRE at is lower on a commit; the band used for
# deduplication is always measured against the base, so one session cannot be
# nudged twice for the same level of cost just because two triggers scale
# differently.
base_warn = warn
fire_at = max(1, warn // 2) if at_commit else warn

# The event names the transcript; the glob is the fallback for hook runners
# that do not pass it. Guessing "newest file" is only ever a fallback because
# two sessions in one project would make it wrong.
transcript = None
tp = event.get("transcript_path")
if tp and Path(tp).is_file():
    transcript = Path(tp)
else:
    slug = str(project).replace("/", "-")
    d = Path.home() / ".claude" / "projects" / slug
    if d.is_dir():
        files = [p for p in d.glob("*.jsonl") if p.is_file()]
        sid = event.get("session_id")
        named = [p for p in files if sid and p.stem == sid]
        pool = named or files
        if pool:
            transcript = max(pool, key=lambda p: p.stat().st_mtime)
if transcript is None:
    sys.exit(0)

size = transcript.stat().st_size
with transcript.open("rb") as fh:
    if size > TAIL_BYTES:
        fh.seek(size - TAIL_BYTES)
        fh.readline()          # drop the partial line the seek landed in
    tail = fh.read().decode("utf-8", errors="replace")

replays = []
for line in tail.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        continue
    usage = (rec.get("message") or {}).get("usage") or {}
    if not usage:
        continue
    replays.append(
        (usage.get("cache_read_input_tokens") or 0)
        + (usage.get("cache_creation_input_tokens") or 0)
    )

recent = replays[-WINDOW:]
if len(recent) < 5:          # too early to say anything useful
    sys.exit(0)
per_turn = sum(recent) / len(recent)
if per_turn < fire_at:
    sys.exit(0)

# One nudge per band. Band 1 is the threshold, band 2 is twice it, and so on
# — so a session that keeps growing is told again, and a session that merely
# sits above the line is not told every turn.
band = max(1, int(per_turn // base_warn))
state_dir = project / ".pe"
state_file = state_dir / "session-cost.state"
key = transcript.stem
seen = {}
if state_file.exists():
    try:
        seen = json.loads(state_file.read_text())
    except Exception:
        seen = {}
if seen.get(key, 0) >= band:
    sys.exit(0)
seen[key] = band
try:
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps(seen))
except OSError:
    pass                      # advisory; a lost state file only costs a repeat

opening = sum(replays[:WINDOW]) / max(len(replays[:WINDOW]), 1)
growth = f", about {per_turn/opening:.1f}x the earliest turns in view" if opening else ""

lead = (
    "Commit landed — a natural boundary. The"
    if at_commit else
    "Session cost: the"
)
why_now = (
    "The work that context was carrying is now in the diff and the message, "
    "so the next piece of work does not need to re-read it. This is the "
    "cheapest moment to reset."
    if at_commit else
    "Every turn re-reads the whole conversation, so this keeps climbing on "
    "its own."
)
msg = (
    f"{lead} last {len(recent)} turns each replayed about "
    f"{per_turn:,.0f} tokens of context{growth}. {why_now}\n"
    f"Measured on this engine, one compaction cut per-turn replay from 531k "
    f"to 157k — about 70%, in one step. Generation is ~2% of the bill, so "
    f"this is worth more than any amount of terser code.\n"
    f"/compact, or finish here and start fresh. `pe telemetry context` shows "
    f"the split. Silence with session_cost.enabled=false in "
    f".process-engine.yaml."
)
print(json.dumps({"systemMessage": msg}))
PY

exit 0
