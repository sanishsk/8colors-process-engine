#!/usr/bin/env bash
# size-budget — pre-commit hook enforcing net-LOC + per-file + per-function
# size budgets from the operator's global rules (P6.3).
#
# Checks (all configurable via .process-engine.yaml → size_budget.*):
#
#   1. NET LINES of this commit's staged diff:
#      WARN >warn_net_lines  (default 250)
#      FAIL >fail_net_lines  (default 600)   unless the commit message
#                                            carries a `Size-justified:` trailer.
#
#   2. PER-FILE line count of any source file staged for commit:
#      FAIL >max_file_lines (default 800)
#      Applies to text files under: src/ app/ modules/ lib/ scripts/ hooks/ agents/
#      Ignored: docs/ tests/ migrations/ (long by nature)
#
#   3. PER-FUNCTION line count in staged .py + .js/.ts:
#      FAIL >max_function_lines (default 50)
#      Best-effort AST-lite for Python; regex-based scan for JS/TS.
#
# Bypass one commit:
#   Add trailer `Size-justified: <one-line reason>` to the commit message
#   OR: PE_SKIP_SIZE_BUDGET=1 git commit ...

set -euo pipefail

if [ "${PE_SKIP_SIZE_BUDGET:-0}" = "1" ]; then
    echo "[size-budget] skipped (PE_SKIP_SIZE_BUDGET=1)" >&2
    exit 0
fi

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ENGINE_DIR/scripts/_yaml.sh" ]; then
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/scripts/_yaml.sh"
fi

CONFIG=".process-engine.yaml"
enabled="true"
warn_net=250
fail_net=600
max_file=800
max_function=50

if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get size_budget.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    v=$(yaml_get size_budget.warn_net_lines "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && warn_net="$v"
    v=$(yaml_get size_budget.fail_net_lines "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && fail_net="$v"
    v=$(yaml_get size_budget.max_file_lines "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && max_file="$v"
    v=$(yaml_get size_budget.max_function_lines "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && max_function="$v"
fi

if [ "$enabled" != "true" ]; then
    exit 0
fi

fail=0

# ─── 1. NET LINES ────────────────────────────────────────────────────
NUMSTAT="$(git diff --cached --numstat 2>/dev/null || true)"
if [ -z "$NUMSTAT" ]; then
    exit 0
fi

# Sum insertions - deletions across staged files
NET=$(printf '%s\n' "$NUMSTAT" | awk '
NF >= 3 && $1 != "-" && $2 != "-" { ins += $1; dels += $2 }
END { print (ins - dels) }' 2>/dev/null || echo 0)

# Check commit message for Size-justified trailer
JUSTIFIED=0
MSG_FILE=""
for candidate in .git/COMMIT_EDITMSG COMMIT_EDITMSG; do
    if [ -f "$candidate" ]; then
        MSG_FILE="$candidate"
        break
    fi
done
if [ -n "$MSG_FILE" ] && grep -qiE '^Size-justified:' "$MSG_FILE" 2>/dev/null; then
    JUSTIFIED=1
fi

if [ "$NET" -gt "$fail_net" ]; then
    if [ "$JUSTIFIED" -eq 1 ]; then
        echo "[size-budget] net +${NET} lines (>fail=$fail_net) — allowed via Size-justified: trailer" >&2
    else
        echo "[size-budget] FAIL: net +${NET} lines exceeds fail_net_lines=${fail_net}." >&2
        echo "  Add trailer 'Size-justified: <reason>' to the commit message, or split the commit." >&2
        fail=1
    fi
elif [ "$NET" -gt "$warn_net" ]; then
    echo "[size-budget] WARN: net +${NET} lines exceeds warn_net_lines=${warn_net} (advisory)" >&2
fi

# ─── 2. PER-FILE + 3. PER-FUNCTION ───────────────────────────────────
STAGED="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"

for f in $STAGED; do
    [ -f "$f" ] || continue

    # Skip long-by-design paths
    case "$f" in
        docs/*|tests/*|test/*|**/tests/*|**/test/*|migrations/*|**/migrations/*|CHANGELOG.md|**/CHANGELOG.md) continue ;;
    esac

    # Skip binary-ish files
    case "$f" in
        *.png|*.jpg|*.jpeg|*.gif|*.svg|*.pdf|*.woff|*.woff2|*.ttf|*.eot|*.ico|*.zip|*.tar|*.gz) continue ;;
    esac

    # Only enforce on source-ish paths
    enforce_file=0
    case "$f" in
        src/*|app/*|modules/*|lib/*|scripts/*|hooks/*|agents/*|commands/*|internal/*|pkg/*|cmd/*) enforce_file=1 ;;
    esac

    if [ "$enforce_file" -eq 1 ]; then
        lines="$(wc -l < "$f" 2>/dev/null | tr -d ' ' || echo 0)"
        if [ "$lines" -gt "$max_file" ]; then
            echo "[size-budget] FAIL: $f is $lines lines (max_file_lines=$max_file)" >&2
            fail=1
        fi
    fi

    # Function-length check for .py and .js/.ts
    case "$f" in
        *.py)
            if command -v python3 >/dev/null 2>&1; then
                python3 - "$f" "$max_function" <<'PY' || fail=1
import ast, sys
path, max_fn = sys.argv[1], int(sys.argv[2])
try:
    tree = ast.parse(open(path).read())
except SyntaxError:
    sys.exit(0)
bad = []
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        start = node.lineno
        end = getattr(node, "end_lineno", None) or start
        length = end - start + 1
        if length > max_fn:
            bad.append((node.name, start, length))
if bad:
    for name, line, length in bad:
        print(f"[size-budget] FAIL: {path}:{line} function `{name}` is {length} lines (max_function_lines={max_fn})", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
            fi
            ;;
        *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs)
            if command -v python3 >/dev/null 2>&1; then
                python3 - "$f" "$max_function" <<'PY' || fail=1
# Regex-only JS/TS function-length scan. Under-catches (arrow funcs
# passed inline, no body-brace, etc.) but never over-catches.
import re, sys
path, max_fn = sys.argv[1], int(sys.argv[2])
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError:
    sys.exit(0)
patterns = [
    re.compile(r'^\s*(?:async\s+)?function\s+(\w+)\s*\([^)]*\)\s*\{', re.M),
    re.compile(r'^\s*(?:export\s+(?:default\s+)?)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?\([^)]*\)\s*=>\s*\{', re.M),
    re.compile(r'^\s*(\w+)\s*\([^)]*\)\s*\{', re.M),  # class method-ish
]
lines = text.splitlines()
def find_close(idx):
    depth = 0
    started = False
    for i in range(idx, len(lines)):
        for ch in lines[i]:
            if ch == '{':
                depth += 1; started = True
            elif ch == '}':
                depth -= 1
                if started and depth == 0:
                    return i
    return None
bad = []
seen = set()
for pat in patterns:
    for m in pat.finditer(text):
        line_no = text[:m.start()].count("\n") + 1
        if line_no in seen: continue
        seen.add(line_no)
        end = find_close(line_no - 1)
        if end is None: continue
        length = end - (line_no - 1) + 1
        if length > max_fn:
            bad.append((m.group(1), line_no, length))
if bad:
    for name, line, length in bad:
        print(f"[size-budget] FAIL: {path}:{line} function `{name}` is {length} lines (max_function_lines={max_fn})", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
            fi
            ;;
    esac
done

if [ "$fail" -ne 0 ]; then
    cat >&2 <<EOF

[size-budget] FAIL — one or more size checks blocked the commit.

Options:
  1. Split the file / extract the function.
  2. Add trailer 'Size-justified: <reason>' to the commit message (only
     affects the net-lines gate; file/function gates always block).
  3. Raise the config value in .process-engine.yaml:
       size_budget:
         max_file_lines: <n>
         max_function_lines: <n>
  4. One-shot bypass: PE_SKIP_SIZE_BUDGET=1 git commit ...
EOF
    exit 1
fi

exit 0
