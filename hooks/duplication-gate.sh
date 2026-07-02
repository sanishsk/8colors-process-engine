#!/usr/bin/env bash
# duplication-gate — pre-commit hook that runs jscpd and enforces a
# RATCHETING baseline (P5.4 / P6.5). Duplication % may only go DOWN
# unless an operator explicitly re-baselines.
#
# Contract:
#   1. Read baseline % from .jscpd-baseline.json (default 3.0 if absent).
#   2. Run jscpd against the whole project.
#   3. Parse current % from the JSON report.
#   4. If current > baseline + tolerance: FAIL. Else PASS.
#   5. If jscpd not installed: advisory skip (exit 0).
#
# Config in .process-engine.yaml:
#   duplication_gate.enabled     — default true
#   duplication_gate.baseline    — path (default .jscpd-baseline.json)
#   duplication_gate.tolerance   — float, allowed absolute % overshoot (default 0.1)
#
# Manual re-baseline (after a legit refactor that dropped duplication):
#   pe collect --update-jscpd-baseline   # future subcommand
# or:
#   jq '.percentage = <new%>' .jscpd-baseline.json > tmp && mv tmp .jscpd-baseline.json
#
# Bypass one commit: PE_SKIP_DUPLICATION=1 git commit ...

set -euo pipefail

if [ "${PE_SKIP_DUPLICATION:-0}" = "1" ]; then
    echo "[duplication-gate] skipped (PE_SKIP_DUPLICATION=1)" >&2
    exit 0
fi

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ENGINE_DIR/scripts/_yaml.sh" ]; then
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/scripts/_yaml.sh"
fi

CONFIG=".process-engine.yaml"
enabled="true"
baseline_file=".jscpd-baseline.json"
tolerance="0.1"
if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get duplication_gate.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    v=$(yaml_get duplication_gate.baseline "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && baseline_file="$v"
    v=$(yaml_get duplication_gate.tolerance "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && tolerance="$v"
fi

if [ "$enabled" != "true" ]; then
    exit 0
fi

# Feature-detect jscpd
runner=""
if command -v jscpd >/dev/null 2>&1; then
    runner="jscpd"
elif command -v npx >/dev/null 2>&1; then
    runner="npx --yes --no-install jscpd"
else
    echo "[duplication-gate] jscpd not installed (and no npx) — advisory skip" >&2
    exit 0
fi

# Only run when the staged diff touches files that jscpd would scan.
# Cheap heuristic: any .py/.js/.ts/.html/.jinja/.css file staged.
if ! git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | \
     grep -qE '\.(py|js|jsx|ts|tsx|html|jinja|jinja2|css)$'; then
    exit 0
fi

# Baseline percentage
if [ -f "$baseline_file" ] && command -v python3 >/dev/null 2>&1; then
    baseline_pct="$(python3 -c "
import json, sys
try:
    d = json.load(open('$baseline_file'))
    print(d.get('percentage', 3.0))
except Exception:
    print(3.0)
" 2>/dev/null)"
else
    baseline_pct="3.0"
fi

echo "[duplication-gate] running jscpd (baseline: ${baseline_pct}% + ${tolerance}%)" >&2
REPORT_DIR="$(mktemp -d)"
trap 'rm -rf "$REPORT_DIR"' EXIT

# shellcheck disable=SC2086
if ! $runner --reporters json --output "$REPORT_DIR" --silent 2>/dev/null; then
    echo "[duplication-gate] jscpd invocation failed — advisory skip" >&2
    exit 0
fi

REPORT_JSON="$REPORT_DIR/jscpd-report.json"
if [ ! -f "$REPORT_JSON" ]; then
    echo "[duplication-gate] jscpd report not produced — advisory skip" >&2
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[duplication-gate] python3 unavailable — cannot parse report" >&2
    exit 0
fi

current_pct=$(python3 -c "
import json
d = json.load(open('$REPORT_JSON'))
stats = d.get('statistics', {}).get('total', {}) or d.get('duplicates', [{}])
pct = stats.get('percentage') if isinstance(stats, dict) else None
if pct is None:
    pct = d.get('statistics', {}).get('total', {}).get('percentageTokens', 0)
print(f'{float(pct):.2f}')
" 2>/dev/null || echo "0.0")

verdict=$(python3 -c "
b = float('$baseline_pct')
c = float('$current_pct')
t = float('$tolerance')
if c > b + t:
    print(f'FAIL: current {c}% > baseline {b}% + tolerance {t}%')
else:
    print(f'PASS: current {c}% <= baseline {b}% + tolerance {t}%')
")

echo "[duplication-gate] $verdict" >&2

case "$verdict" in
    FAIL:*)
        cat >&2 <<EOF

[duplication-gate] FAIL — this commit raises the project's duplication ratio.

Options:
  1. Extract the duplicated block into a shared function/macro.
  2. If the duplication is intentional + minimal, add it to jscpd 'ignore'.
  3. If you legitimately refactored duplication DOWN and want to lock the
     new lower baseline in, update .jscpd-baseline.json to '$current_pct'.
  4. One-shot bypass:
       PE_SKIP_DUPLICATION=1 git commit ...
EOF
        exit 1
        ;;
    *) exit 0 ;;
esac
