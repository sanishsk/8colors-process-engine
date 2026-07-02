#!/usr/bin/env bash
# security-review-trailer — commit-msg hook that requires a
# Security-reviewed trailer on any commit touching auth / session /
# payment / webhook paths (P1.5).
#
# The regex default catches the common cases across Flask/Django/Express
# codebases. Override via ENGINE_SECURITY_PATHS.
#
# Accepted trailers:
#   Security-reviewed: <envelope-sha>       ← evidence, preferred
#   Security-reviewed: security-reviewer    ← legacy self-attest
#   Security-skip-reason: <short reason>    ← explicit skip
#
# Bypass: git commit --no-verify.

set -euo pipefail

MSG_FILE="${1:?Usage: $0 <commit-msg-file>}"
DEFAULT_RE='(auth|login|oauth|session|passwd|password|payment|billing|webhook|jwt|token)'
SECURITY_RE="${ENGINE_SECURITY_PATHS:-$DEFAULT_RE}"

STAGED=$(git diff --cached --name-only)
HITS=$(echo "$STAGED" | grep -iE "$SECURITY_RE" || true)
if [ -z "$HITS" ]; then
    exit 0
fi

MSG=$(cat "$MSG_FILE")
TRAILER=$(echo "$MSG" | grep -E '^Security-reviewed:' | head -1 | sed -E 's/^Security-reviewed:[[:space:]]*//' | tr -d '\r' | sed -E 's/[[:space:]]+$//')
SKIP=$(echo "$MSG" | grep -E '^Security-skip-reason:' | head -1)

if [ -n "$SKIP" ]; then
    exit 0
fi

if [ -z "$TRAILER" ]; then
    cat >&2 <<EOF
✗ security-review-trailer: this commit touches security-sensitive paths:

$(echo "$HITS" | sed 's/^/    /')

…but the commit message lacks a Security-reviewed trailer.

Add ONE of:

  Security-reviewed: <envelope-sha>       # PASS/WARN record from security-reviewer
  Security-reviewed: security-reviewer    # legacy self-attest
  Security-skip-reason: <short reason>    # explicit skip

Recommended: run the security-reviewer agent, then:
  pe gate parse --record .claude/gates/security.json \\
                --diff-sha \$(git diff --cached | git hash-object --stdin) \\
                <transcript>

Override the path regex via ENGINE_SECURITY_PATHS.
To bypass for a hotfix: git commit --no-verify
EOF
    exit 1
fi

# Legacy self-attest allowed (matches code-review-trailer's shape). Evidence
# resolution follows the same fallback chain: last-gate sha prefix or named
# record file.
if [ "$TRAILER" = "security-reviewer" ]; then
    exit 0
fi

if ! echo "$TRAILER" | grep -qE '^[0-9a-fA-F]{8,64}$'; then
    echo "✗ security-review-trailer: '$TRAILER' is not an envelope sha" >&2
    exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
RECORD=""
for candidate in "$REPO_ROOT/.claude/gates/security.json" "$REPO_ROOT/.claude/gates/last-gate.json"; do
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
    echo "✗ security-review-trailer: sha '$TRAILER' does not resolve to any .claude/gates/*.json" >&2
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
    *)
        echo "✗ security-review-trailer: envelope at $RECORD has verdict '$VERDICT'" >&2
        exit 1 ;;
esac
