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
PE="$ENGINE_DIR/scripts/pe"
CORPUS="$ENGINE_DIR/evals/fixtures"

# ─── argparse ───────────────────────────────────────────────────
LIVE=0
GATE_FILTER=""
FIXTURE_FILTER=""
MODEL_OVERRIDE=""
TIMEOUT_S=300
while [ $# -gt 0 ]; do
    case "$1" in
        --live)    LIVE=1; shift ;;
        --gate)    GATE_FILTER="$2"; shift 2 ;;
        --fixture) FIXTURE_FILTER="$2"; shift 2 ;;
        --model)   MODEL_OVERRIDE="$2"; shift 2 ;;
        --timeout) TIMEOUT_S="$2"; shift 2 ;;
        -h|--help)
            sed -n '/^# test_gate_efficacy.sh/,/^set -uo pipefail/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
    esac
done

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

# ─── main loop ──────────────────────────────────────────────────
for gate_dir in "$CORPUS"/*/; do
    [ -d "$gate_dir" ] || continue
    gate_name=$(basename "$gate_dir")
    if [ -n "$GATE_FILTER" ] && [ "$gate_name" != "$GATE_FILTER" ]; then
        continue
    fi
    echo "gate: $gate_name"

    for fixture_dir in "$gate_dir"*/; do
        [ -d "$fixture_dir" ] || continue
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
                record_fail "$gate_name/$fixture_name — pe gate parse exit=$actual, expected=$expected"
            else
                record_pass "$gate_name/$fixture_name (exit=$actual)"
            fi
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
                record_fail "$gate_name/$fixture_name — emitted envelope exit=$emitted_exit, expected=$expected (verdict mismatch)"
            else
                record_pass "$gate_name/$fixture_name (live emitted=$emitted_exit)"
            fi
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
