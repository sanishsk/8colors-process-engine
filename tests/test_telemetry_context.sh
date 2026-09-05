#!/usr/bin/env bash
# tests/test_telemetry_context.sh — the token-cost reporting contract (T1).
#
# `pe telemetry` exists so token spend can be measured instead of guessed.
# Measured against a real 2,231-turn ledger, it was reporting the wrong
# things in two ways that both pointed effort at the wrong lever:
#
#   1. The per-model table printed input, output and cost, and computed but
#      never printed cache-read — which was 356,681 tokens per turn against
#      968 generated. The tool built to show where the money goes was hiding
#      97% of it.
#
#   2. An unpriced model got UNKNOWN_MODEL_PRICES, whose comment claimed the
#      zero "surfaces the miss". Nothing surfaced: `$0.00` printed beside
#      1,390 turns of the most expensive model in the ledger, and the grand
#      total silently understated the bill.
#
# And the new `context` subcommand must not overcorrect. The CLAUDE.md chain
# is ~2% of what gets replayed; the rest is conversation history, which no
# file edit touches. A command that lists files and implies trimming them
# fixes a context bill would be worse than no command.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
PE="$ROOT/scripts/pe"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "test_telemetry_context"

PROJ="$TMP/proj"
mkdir -p "$PROJ/.pe" "$PROJ/.claude/agents"
git -C "$PROJ" init -q 2>/dev/null

# A ledger with two models: one the price table knows, one it does not.
# The unpriced one carries the larger spend, which is the case that matters.
cat > "$PROJ/.pe/telemetry.jsonl" <<'EOF'
{"turn_uuid":"a","session_id":"s1","model":"claude-haiku-4-5","input_tokens":100,"output_tokens":200,"cache_read_tokens":1000,"cache_creation_tokens":50,"cost_cents":1.0,"timestamp":"2026-09-05T10:00:00Z"}
{"turn_uuid":"b","session_id":"s1","model":"totally-unpriced-model","input_tokens":10,"output_tokens":5000,"cache_read_tokens":900000,"cache_creation_tokens":2000,"cost_cents":0.0,"timestamp":"2026-09-05T10:01:00Z"}
{"turn_uuid":"c","session_id":"s1","model":"totally-unpriced-model","input_tokens":10,"output_tokens":5000,"cache_read_tokens":900000,"cache_creation_tokens":2000,"cost_cents":0.0,"timestamp":"2026-09-05T10:02:00Z"}
EOF

printf '# Project\n%s\n' "$(head -c 3000 /dev/zero | tr '\0' 'x')" > "$PROJ/CLAUDE.md"
printf 'agent body\n' > "$PROJ/.claude/agents/code-reviewer.md"

# ─── summary: the dominant term must be visible ─────────────────────
out=$("$PE" telemetry summary --project "$PROJ" 2>&1)

printf '%s' "$out" | grep -q 'cache-read' \
    && ok "the per-model table names cache-read" \
    || bad "cache-read is computed and still not printed — the dominant term is invisible"

printf '%s' "$out" | grep -q '900,000\|1,800,000' \
    && ok "cache-read token counts reach the table" \
    || bad "cache-read column carries no numbers"

# ─── summary: an unpriced model must not read as free ───────────────
if printf '%s' "$out" | grep -qi 'UNPRICED' \
   && printf '%s' "$out" | grep -q 'totally-unpriced-model'; then
    ok "an unpriced model is named, not reported as \$0"
else
    bad "a model missing from the price table printed \$0.00 with no warning"
fi

printf '%s' "$out" | grep -qi 'UNDERSTATE' \
    && ok "the summary says the totals are understated, not merely that a price is missing" \
    || bad "the reader is not told the grand total is wrong"

# A priced model must NOT be flagged — otherwise the warning is noise.
flagged=$(printf '%s' "$out" | grep -c 'claude-haiku-4-5.*\*' || true)
[ "${flagged:-0}" -eq 0 ] \
    && ok "a model the table prices is not flagged" \
    || bad "the unpriced warning fires on a priced model"

# ─── summary: the lever must be ranked, not just listed ─────────────
if printf '%s' "$out" | grep -qi 'Where the tokens go'; then
    ok "the summary ranks context replay against generation"
else
    bad "nothing tells the reader which of these numbers is worth acting on"
fi

# ─── context: per-turn vs on-demand is the whole point ──────────────
ctx=$("$PE" telemetry context --project "$PROJ" --claude-home "$TMP/nohome" 2>&1)
rc=$?

[ "$rc" -eq 0 ] \
    && ok "pe telemetry context runs" \
    || bad "pe telemetry context exited $rc"

printf '%s' "$ctx" | grep -q 'PER TURN' && printf '%s' "$ctx" | grep -q 'ON DEMAND' \
    && ok "context separates what is re-read every turn from what loads on use" \
    || bad "context does not distinguish per-turn cost from on-demand cost"

printf '%s' "$ctx" | grep -q 'CLAUDE.md' \
    && ok "the project's CLAUDE.md is inventoried" \
    || bad "CLAUDE.md is missing from the per-turn inventory"

printf '%s' "$ctx" | grep -q 'agents' \
    && ok "installed agents are counted as on-demand, not per-turn" \
    || bad "agents were not reported"

# The honesty requirement: the files are a small share of real replay, and
# the command has to say so rather than implying a trim fixes the bill.
if printf '%s' "$ctx" | grep -qi 'conversation history'; then
    ok "context reconciles the file inventory against MEASURED replay"
else
    bad "context lists files without saying they are a fraction of what is replayed"
fi

# The ledger above holds 1,000 + 900,000 + 900,000 = 1,801,000 cache-read
# tokens over 3 turns, so the mean is 600,333. Asserted exactly, because a
# rounded-looking number here would not prove the ledger was read rather
# than a constant printed.
printf '%s' "$ctx" | grep -q '600,333 tok/turn replayed' \
    && ok "the measured per-turn replay is computed from the ledger" \
    || bad "context did not read the ledger it was pointed at"

# ─── the subcommand has to be reachable through \`pe\` ──────────────
# `pe shadow reset` shipped in argparse and went eleven releases unrouted by
# the dispatcher. Derive the roster rather than trusting a list.
subs=$("${PE_PYTHON:-python3}" - "$ROOT/scripts/telemetry.py" <<'PYEOF'
import ast, sys
names = set()
for node in ast.walk(ast.parse(open(sys.argv[1]).read())):
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "add_parser" and node.args
            and isinstance(node.args[0], ast.Constant)):
        names.add(node.args[0].value)
print(" ".join(sorted(names)))
PYEOF
)
unreachable=""
for sub in $subs; do
    grep -qE "^[[:space:]]*([a-z]+\|)*$sub(\|[a-z]+)*\)" "$ROOT/scripts/_cmd_ops.sh" \
        || unreachable="$unreachable $sub"
done
[ -z "$unreachable" ] \
    && ok "every telemetry subcommand ($subs) is routed by cmd_telemetry" \
    || bad "telemetry.py defines subcommand(s) \`pe telemetry\` cannot reach:$unreachable"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
