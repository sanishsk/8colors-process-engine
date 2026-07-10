#!/usr/bin/env bash
# test_gate_efficacy.sh — A2 gate-efficacy corpus runner.
#
# TWO MODES:
#
# ── shape mode (default; CI-safe, zero API cost) ────────────────
# For every fixture under evals/fixtures/<gate>/<verdict>-<slug>/:
#   1. Assert input.md exists and starts with '# <slug>'.
#   2. Call `pe gate parse --bare expected-envelope.json`.
#   3. Assert the exit code class matches the directory-prefix contract:
#        pass-*         → exit 0
#        fail-escalate-* → exit 1
#        fail-halt-*    → exit 2
#        warn-*         → exit 3
#        adversarial-*  → exit 0 (safe lookalike must not FP)
# Catches: schema drift, mislabeled fixtures, missing input.md scaffolding.
#
# ── live mode (--live; A4, needs claude CLI + API key) ──────────
# For every fixture:
#   1. Invoke `pe agent run <gate> --brief input.md` (uses --append-
#      system-prompt so gates output an envelope per their contract).
#   2. Extract the emitted envelope via `pe gate parse` in transcript mode.
#   3. Compare the EMITTED envelope's verdict + failure_class against the
#      EXPECTED envelope. Records precision/recall per gate + adversarial
#      false-positive rate.
# Runs weekly / pre-release, not on every push. Burns real tokens.
#
# ── flags ───────────────────────────────────────────────────────
#   --live               enable live-mode invocation
#   --gate <name>        limit to one gate (default: all)
#   --fixture <name>     limit to one fixture within the gate
#   --model <alias>      override the gate agent's default model
#   --timeout <s>        per-invocation timeout (default 300)

set -uo pipefail

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENGINE_DIR=$(cd -P "$SCRIPT_DIR/.." && pwd)
# Load $PY resolver (I2 v0.50.0: primary-rule assertions need Python ≥3.11).
. "$SCRIPT_DIR/_py.sh"
PE="$ENGINE_DIR/scripts/pe"
CORPUS="$ENGINE_DIR/evals/fixtures"

# ─── argparse ───────────────────────────────────────────────────
LIVE=0
GATE_FILTER=""
FIXTURE_FILTER=""
MODEL_OVERRIDE=""
TIMEOUT_S=300
METRICS_PATH=""
HOLDOUT_ONLY=0
INCLUDE_HOLDOUT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --live)         LIVE=1; shift ;;
        --gate)         GATE_FILTER="$2"; shift 2 ;;
        --fixture)      FIXTURE_FILTER="$2"; shift 2 ;;
        --model)        MODEL_OVERRIDE="$2"; shift 2 ;;
        --timeout)      TIMEOUT_S="$2"; shift 2 ;;
        --metrics)      METRICS_PATH="$2"; shift 2 ;;
        --holdout-only) HOLDOUT_ONLY=1; shift ;;
        --no-holdout)   INCLUDE_HOLDOUT=0; shift ;;
        -h|--help)
            sed -n '/^# test_gate_efficacy.sh/,/^set -uo pipefail/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
    esac
done

# Initialize metrics file if requested (JSONL — one line per fixture).
if [ -n "$METRICS_PATH" ]; then
    : > "$METRICS_PATH"
fi

# ─── shared state ───────────────────────────────────────────────
pass=0
fail=0
declare -a failures=()

record_fail() {
    fail=$((fail+1))
    failures+=("$1")
    echo "  ✗ $1"
}

record_pass() {
    pass=$((pass+1))
    echo "  ✓ $1"
}

expected_exit_for() {
    local dir_name="$1"
    case "$dir_name" in
        pass-*)           echo 0 ;;
        fail-escalate-*)  echo 1 ;;
        fail-halt-*)      echo 2 ;;
        warn-*)           echo 3 ;;
        adversarial-*)    echo 0 ;;
        *)                echo "?" ;;
    esac
}

if [ ! -d "$CORPUS" ]; then
    echo "ERROR: eval corpus missing: $CORPUS" >&2
    exit 2
fi

# ─── live-mode preflight ────────────────────────────────────────
if [ $LIVE -eq 1 ]; then
    if ! command -v claude >/dev/null 2>&1; then
        echo "SKIP: --live requires the \`claude\` CLI on PATH" >&2
        exit 0
    fi
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo "SKIP: --live requires ANTHROPIC_API_KEY in the environment" >&2
        exit 0
    fi
    echo "gate-efficacy LIVE mode — $CORPUS"
    echo "  (invoking each gate via \`pe agent run\`, will burn real tokens)"
else
    echo "gate-efficacy shape check — $CORPUS"
fi
echo ""

# _emit_metric — append one JSONL line to the metrics file. Reads
# trajectory data from `.pe/runs/<slug>/run.json` (populated by
# `pe agent run` for --live invocations; empty for shape mode). L2
# extension: step count / retries / wall-clock / cost per fixture.
_emit_metric() {
    local gate="$1" fixture="$2" expected="$3" actual="$4" \
          corpus_kind="$5" cost_cents="$6" duration_ms="$7" \
          num_turns="$8" tool_calls="$9"
    [ -z "$METRICS_PATH" ] && return 0
    printf '{"gate":"%s","fixture":"%s","corpus":"%s","expected_exit":%s,"actual_exit":%s,"cost_cents":%s,"duration_ms":%s,"num_turns":%s,"tool_calls":%s}\n' \
        "$gate" "$fixture" "$corpus_kind" \
        "$expected" "$actual" \
        "${cost_cents:-null}" "${duration_ms:-null}" \
        "${num_turns:-null}" "${tool_calls:-null}" \
        >> "$METRICS_PATH"
}

# _extract_run_metrics — parse metadata from the most recent
# .pe/runs/<slug>/run.json. Prints "cost_cents duration_ms num_turns
# tool_calls" (nulls if any field missing). Silent if no runs dir.
_extract_run_metrics() {
    local runs_dir=".pe/runs"
    [ -d "$runs_dir" ] || { echo "null null null null"; return; }
    local latest
    latest=$(ls -t "$runs_dir" 2>/dev/null | head -1)
    [ -z "$latest" ] && { echo "null null null null"; return; }
    local run_json="$runs_dir/$latest/run.json"
    [ -f "$run_json" ] || { echo "null null null null"; return; }
    python3 - "$run_json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
raw = d.get("raw_json", {}) or {}
content = ((raw.get("result") or "") if isinstance(raw.get("result"), str) else "")
# tool_calls best-effort: count from usage.iterations if present.
usage = raw.get("usage", {}) or {}
iters = usage.get("iterations") or []
tool_calls = sum(1 for it in iters if isinstance(it, dict))  # each iteration ~= one API call
cost = d.get("cost_cents")
dur = raw.get("duration_ms") or d.get("duration_ms")
turns = raw.get("num_turns")
def _fmt(v):
    return "null" if v is None else str(v)
print(f"{_fmt(cost)} {_fmt(dur)} {_fmt(turns)} {tool_calls}")
PY
}

# ─── main loop ──────────────────────────────────────────────────
for gate_dir in "$CORPUS"/*/; do
    [ -d "$gate_dir" ] || continue
    gate_name=$(basename "$gate_dir")
    if [ -n "$GATE_FILTER" ] && [ "$gate_name" != "$GATE_FILTER" ]; then
        continue
    fi
    echo "gate: $gate_name"

    # Collect fixture dirs from both the main corpus AND the holdout
    # subdir (L2 completion). Holdout fixtures live under
    # <gate>/holdout/<verdict-slug>/ so the runner can measure the
    # "unseen during development" precision/recall separately.
    fixture_dirs=()
    if [ $HOLDOUT_ONLY -eq 0 ]; then
        for f in "$gate_dir"*/; do
            [ -d "$f" ] || continue
            [ "$(basename "$f")" = "holdout" ] && continue
            fixture_dirs+=("$f:main")
        done
    fi
    if [ $INCLUDE_HOLDOUT -eq 1 ] || [ $HOLDOUT_ONLY -eq 1 ]; then
        if [ -d "$gate_dir/holdout" ]; then
            for f in "$gate_dir/holdout"/*/; do
                [ -d "$f" ] || continue
                fixture_dirs+=("$f:holdout")
            done
        fi
    fi

    for entry in "${fixture_dirs[@]:-}"; do
        [ -z "$entry" ] && continue
        fixture_dir="${entry%:*}"
        corpus_kind="${entry##*:}"
        fixture_name=$(basename "$fixture_dir")
        if [ -n "$FIXTURE_FILTER" ] && [ "$fixture_name" != "$FIXTURE_FILTER" ]; then
            continue
        fi
        expected=$(expected_exit_for "$fixture_name")

        if [ "$expected" = "?" ]; then
            record_fail "$gate_name/$fixture_name — unknown directory prefix (expected pass-/fail-escalate-/fail-halt-/warn-/adversarial-)"
            continue
        fi

        # 1. input.md present + first line matches slug
        input_md="$fixture_dir/input.md"
        if [ ! -f "$input_md" ]; then
            record_fail "$gate_name/$fixture_name — missing input.md"
            continue
        fi
        first_line=$(head -1 "$input_md")
        if [ "$first_line" != "# $fixture_name" ]; then
            record_fail "$gate_name/$fixture_name — input.md first line is '$first_line', expected '# $fixture_name'"
            continue
        fi

        # 2. expected-envelope.json present
        envelope="$fixture_dir/expected-envelope.json"
        if [ ! -f "$envelope" ]; then
            record_fail "$gate_name/$fixture_name — missing expected-envelope.json"
            continue
        fi

        if [ $LIVE -eq 0 ]; then
            # SHAPE MODE — validate the expected envelope's exit-code class.
            set +e
            "$PE" gate parse --bare "$envelope" > /dev/null 2>&1
            actual=$?
            set -e

            if [ "$actual" != "$expected" ]; then
                record_fail "$gate_name/$fixture_name [$corpus_kind] — pe gate parse exit=$actual, expected=$expected"
            else
                record_pass "$gate_name/$fixture_name [$corpus_kind] (exit=$actual)"
            fi

            # I2 (v0.50.0) — primary-rule correctness. For any fixture with
            # findings[], assert findings[0].rule is non-empty AND matches the
            # schema pattern `^[a-z0-9][a-z0-9-]*$`. Catches the dotted-name
            # class the v0.46.0/v0.47.0 reviewers hit BEFORE it lands in the
            # live corpus. Absence of findings[] (e.g. clean pass fixtures) is
            # silent.
            primary_rule=$("$PY" -c "
import json, sys
try:
    d = json.load(open('$envelope'))
    findings = d.get('findings') or []
    if findings:
        r = findings[0].get('rule', '')
        sys.stdout.write(r)
except Exception:
    pass
" 2>/dev/null)
            if [ -n "$primary_rule" ]; then
                if echo "$primary_rule" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
                    :  # good — pattern conforms
                else
                    record_fail "$gate_name/$fixture_name [$corpus_kind] — primary rule '$primary_rule' fails schema pattern ^[a-z0-9][a-z0-9-]*$"
                fi
            fi

            _emit_metric "$gate_name" "$fixture_name" "$expected" "$actual" "$corpus_kind" null null null null
        else
            # LIVE MODE — actually invoke the gate agent, compare emitted envelope.
            local_out=$(mktemp)
            if [ -n "$MODEL_OVERRIDE" ]; then
                set -- --model "$MODEL_OVERRIDE"
            else
                set --
            fi
            set +e
            "$PE" agent run "$gate_name" \
                --brief "$input_md" \
                --out "$local_out" \
                --timeout "$TIMEOUT_S" \
                "$@" \
                2> /dev/null
            run_rc=$?
            set -e

            if [ $run_rc -eq 3 ]; then
                record_fail "$gate_name/$fixture_name — pe agent run SKIPPED (claude not available)"
                rm -f "$local_out"
                continue
            fi
            if [ $run_rc -ne 0 ]; then
                record_fail "$gate_name/$fixture_name — pe agent run failed (rc=$run_rc)"
                rm -f "$local_out"
                continue
            fi

            # Parse the transcript-shape output for a fenced envelope.
            set +e
            "$PE" gate parse "$local_out" > /dev/null 2>&1
            emitted_exit=$?
            set -e

            if [ "$emitted_exit" != "$expected" ]; then
                record_fail "$gate_name/$fixture_name [$corpus_kind] — emitted envelope exit=$emitted_exit, expected=$expected (verdict mismatch)"
            else
                record_pass "$gate_name/$fixture_name [$corpus_kind] (live emitted=$emitted_exit)"
            fi

            # I2 (v0.50.0) — primary-rule precision. Compare emitted
            # findings[0].rule against expected findings[0].rule. Records
            # the match/miss as an advisory metric (does NOT fail the test)
            # — a gate can legitimately pick a different primary from a
            # ranked findings list. WARN-level surfacing keeps the signal
            # visible for weekly precision review.
            expected_rule=$("$PY" -c "
import json, sys
try:
    d = json.load(open('$envelope'))
    findings = d.get('findings') or []
    if findings:
        sys.stdout.write(findings[0].get('rule', ''))
except Exception:
    pass
" 2>/dev/null)
            emitted_rule=$("$PY" "$ENGINE_DIR/scripts/pe_gate.py" "$local_out" 2>/dev/null \
                | "$PY" -c "
import json, sys
try:
    d = json.load(sys.stdin)
    findings = d.get('findings') or []
    if findings:
        sys.stdout.write(findings[0].get('rule', ''))
except Exception:
    pass
" 2>/dev/null)
            if [ -n "$expected_rule" ] && [ -n "$emitted_rule" ]; then
                if [ "$expected_rule" != "$emitted_rule" ]; then
                    echo "  ⚠ $gate_name/$fixture_name — primary rule drift: expected='$expected_rule' emitted='$emitted_rule' (advisory)" >&2
                fi
            fi
            # L2 completion: capture trajectory metrics per fixture.
            read -r cost_cents duration_ms num_turns tool_calls <<< "$(_extract_run_metrics)"
            _emit_metric "$gate_name" "$fixture_name" "$expected" "$emitted_exit" \
                         "$corpus_kind" "$cost_cents" "$duration_ms" \
                         "$num_turns" "$tool_calls"
            rm -f "$local_out"
        fi
    done
    echo ""
done

echo "───────────────────────────────────────────────────"
if [ $LIVE -eq 1 ]; then
    echo "gate-efficacy LIVE: $pass passed, $fail failed"
else
    echo "gate-efficacy shape: $pass passed, $fail failed"
fi
if [ $fail -gt 0 ]; then
    echo ""
    echo "Failures:"
    for f in "${failures[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
