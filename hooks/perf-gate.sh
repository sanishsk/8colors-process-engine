#!/usr/bin/env bash
# perf-gate — commit-msg hook that requires a Perf-tested trailer on
# any commit touching model / ORM / query / serializer / migration
# paths (PF1). Pairs with `templates/tests/query-count.test.py.template`:
# static review misses INDIRECT N+1 (a template touching `.related`
# per row, a serializer lazy-loading each item, an ORM helper hidden
# behind a repository interface) — only in-process query counting
# catches it, so we require the runtime evidence on commits that
# could introduce it.
#
# Accepted trailers:
#   Perf-tested: <envelope-sha>       ← evidence, preferred
#   Perf-tested: query-count          ← legacy self-attest
#   Perf-skip-reason: <short reason>  ← explicit skip
#
# Path regex is overridable via ENGINE_PERF_PATHS.
# Bypass: git commit --no-verify.

set -euo pipefail

MSG_FILE="${1:?Usage: $0 <commit-msg-file>}"
# Path regex — deliberately tighter than the prose "schema" would suggest.
# We ONLY match names that are conventionally the data-layer schema in
# Python / SQL projects, NOT unrelated JSON / protobuf / OpenAPI schema
# files. Reviewer caught the false-positive class (openapi.json,
# json-schema-validator.js, user.proto). Adjust via ENGINE_PERF_PATHS
# for stacks that use different conventions.
DEFAULT_RE='(models?\.py|/models?/|/db/|/orm/|/repositor|serializer|query_?count|migrations?/|_schema\.py|/schema\.py|schema\.sql)'
PERF_RE="${ENGINE_PERF_PATHS:-$DEFAULT_RE}"

STAGED=$(git diff --cached --name-only)
HITS=$( { echo "$STAGED" | grep -iE "$PERF_RE" || true; } | { grep -vE '(^|/)tests?/' || true; })
if [ -z "$HITS" ]; then
    exit 0
fi

MSG=$(cat "$MSG_FILE")
TRAILER=$( { echo "$MSG" | grep -E '^Perf-tested:' || true; } | head -1 | sed -E 's/^Perf-tested:[[:space:]]*//' | tr -d '\r' | sed -E 's/[[:space:]]+$//')
SKIP=$( { echo "$MSG" | grep -E '^Perf-skip-reason:' || true; } | head -1)

if [ -n "$SKIP" ]; then
    exit 0
fi

if [ -z "$TRAILER" ]; then
    cat >&2 <<EOF
✗ perf-gate: this commit touches ORM / query / migration paths:

$(echo "$HITS" | sed 's/^/    /')

…but the commit message lacks a Perf-tested trailer.

Static review misses indirect N+1 — the only reliable detector is a
runtime query-count assertion. Copy the pytest template:

  cp \$ENGINE_DIR/templates/tests/query-count.test.py.template \\
     tests/test_query_count.py

Wire the adopter stubs (\`_seed_rows\`, \`_call_list_endpoint\`) to
your app + run \`pytest -k query_count\` before commit.

Add ONE trailer:

  Perf-tested: <envelope-sha>       # PASS/WARN record from the run
  Perf-tested: query-count          # legacy self-attest
  Perf-skip-reason: <short reason>  # explicit skip

Override the path regex via ENGINE_PERF_PATHS.
Bypass for a hotfix: git commit --no-verify
EOF
    exit 1
fi

# Legacy self-attest allowed. Evidence resolution mirrors
# code-review-trailer: sha prefix or named record file.
if [ "$TRAILER" = "query-count" ]; then
    exit 0
fi

if ! echo "$TRAILER" | grep -qE '^[0-9a-fA-F]{8,64}$'; then
    echo "✗ perf-gate: '$TRAILER' is not an envelope sha" >&2
    exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
RECORD=""
for candidate in "$REPO_ROOT/.claude/gates/perf.json" "$REPO_ROOT/.claude/gates/last-gate.json"; do
    if [ -f "$candidate" ]; then
        SHA=$(shasum -a 256 "$candidate" 2>/dev/null | awk '{print $1}')
        if [ "${SHA:0:${#TRAILER}}" = "$TRAILER" ]; then
            RECORD="$candidate"
            break
        fi
    fi
done
if [ -z "$RECORD" ] && [ -f "$REPO_ROOT/.claude/gates/$TRAILER.json" ]; then
    RECORD="$REPO_ROOT/.claude/gates/$TRAILER.json"
fi

if [ -z "$RECORD" ]; then
    echo "✗ perf-gate: sha '$TRAILER' does not resolve to any .claude/gates/*.json" >&2
    exit 1
fi

VERDICT=$("${PE_PYTHON:-python3}" -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("verdict",""))
except Exception:
    print("PARSE_ERROR")
' "$RECORD")

case "$VERDICT" in
    PASS|WARN) exit 0 ;;
    "")
        echo "✗ perf-gate: envelope at $RECORD is missing or has an empty 'verdict' field — regenerate with the current gate parser." >&2
        exit 1 ;;
    *)
        echo "✗ perf-gate: envelope at $RECORD has verdict '$VERDICT'" >&2
        exit 1 ;;
esac
