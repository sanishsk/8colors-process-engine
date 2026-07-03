#!/usr/bin/env bash
# design-review-trailer — commit-msg hook that requires an evidence-backed
# Design-reviewed trailer on any UI/visual commit (D1, v0.18.0).
#
# Mirrors hooks/code-review-trailer.sh to close the code-vs-design
# asymmetry: code was evidence-verified against .claude/gates/, design
# was self-attested. This hook now requires either:
#
#   Design-reviewed: <envelope-sha>       ← preferred; must resolve to a
#                                            PASS/WARN record in .claude/gates/
#                                            emitted by the design-critic agent
#   Design-reviewed: design-critic        ← legacy self-attestation — allowed
#                                            only on single-file UI diffs
#                                            (bug fix / copy tweak); rejected
#                                            on multi-file UI commits
#   Design-skip-reason: <one-line reason> ← explicit skip (logged in commit body)
#
# When `<envelope-sha>` is given, it must name a file at
# `.claude/gates/<sha>.json` OR match `.claude/gates/last-design-review.json`'s
# sha (`shasum -a 256 last-design-review.json | cut -c1-12`).
#
# UI files default: templates/**.html, static/js/**.js, static/css/**.css,
# app/**/*.tsx, app/**/*.jsx, and any docs/design*. Override via
# ENGINE_UI_FILES (regex).
#
# Threshold for "multi-file" (self-attest blocked): ENGINE_UI_THRESHOLD
# (default 2). Below the threshold, `Design-reviewed: design-critic`
# self-attest is accepted (bug fix / single-line copy tweak).

set -euo pipefail

MSG_FILE="${1:?Usage: $0 <commit-msg-file>}"
DEFAULT_RE='^(templates/.*\.(html|jinja|jinja2)|static/(js|css)/.*\.(js|css)|app/.*\.(tsx|jsx|vue|svelte)|docs/design.*\.md)$'
UI_RE="${ENGINE_UI_FILES:-$DEFAULT_RE}"
UI_FILES_COUNT_THRESHOLD="${ENGINE_UI_THRESHOLD:-2}"

if [ "${PE_SKIP_DESIGN_TRAILER:-0}" = "1" ]; then
    echo "[design-review-trailer] skipped (PE_SKIP_DESIGN_TRAILER=1)" >&2
    exit 0
fi

UI_HITS=$(git diff --cached --name-only | grep -E "$UI_RE" || true)
if [ -z "$UI_HITS" ]; then
    exit 0
fi

UI_COUNT=$(printf '%s\n' "$UI_HITS" | grep -c . || echo 0)

MSG=$(cat "$MSG_FILE")

# Explicit skip trailer — accepted, must have a non-empty reason
if echo "$MSG" | grep -qE '^Design-skip-reason:[[:space:]]*[^[:space:]]'; then
    exit 0
fi

# Trailer must be present
TRAILER=$(printf '%s\n' "$MSG" | awk '/^Design-reviewed:/{print $2; exit}')
if [ -z "$TRAILER" ]; then
    cat >&2 <<EOF
✗ design-review-trailer: this commit changes $UI_COUNT UI file(s):

$(echo "$UI_HITS" | sed 's/^/    /' | head -10)

…but the commit message lacks a Design-reviewed trailer.

Add ONE of these as a trailer:

  Design-reviewed: <envelope-sha>       # preferred — sha of PASS/WARN record
                                        # in .claude/gates/, emitted by the
                                        # design-critic agent
  Design-reviewed: design-critic        # legacy self-attest (single-file UI
                                        # diffs only; blocked on multi-file)
  Design-skip-reason: <short reason>    # e.g. "bug fix, no visual change"

To produce an envelope sha:
  # invoke design-critic on the diff → captures envelope to .claude/gates/last-design-review.json
  pe gate parse --record .claude/gates/last-design-review.json \\
                --diff-sha "\$(git diff --cached | shasum -a 256 | cut -c1-12)" \\
                <transcript-file>
  sha=\$(shasum -a 256 .claude/gates/last-design-review.json | cut -c1-12)
  # Add 'Design-reviewed: \$sha' as a trailer in your commit message.

To bypass this ONE commit (audit trail preserved):
  PE_SKIP_DESIGN_TRAILER=1 git commit ...

Rationale: v0.18.0 D1 closes the code-vs-design asymmetry. Code
review has been evidence-verified since v0.10.0; design was still
honor-system — this hook makes design evidence-verified too.
EOF
    exit 1
fi

# Legacy self-attest — allowed only on single-file UI diffs
if [ "$TRAILER" = "design-critic" ] || [ "$TRAILER" = "self" ] || [ "$TRAILER" = "ui-ux-design-agent" ]; then
    if [ "$UI_COUNT" -ge "$UI_FILES_COUNT_THRESHOLD" ]; then
        cat >&2 <<EOF
✗ design-review-trailer: 'Design-reviewed: $TRAILER' is self-attestation.

Multi-file UI commit ($UI_COUNT files) — envelope-sha trailer required
(evidence-verified). Self-attest allowed only on single-file diffs
(bug fix, copy tweak, no visual composition change).

Options:
  1. Invoke the design-critic agent, record its envelope, use the
     sha as the trailer. (Instructions above under "To produce an
     envelope sha".)
  2. If the diff is genuinely non-visual (e.g. an unrelated Python
     file that happens to match the UI regex): use
     'Design-skip-reason: <reason>' instead.
EOF
        exit 1
    fi
    # single-file self-attest — accept
    exit 0
fi

# Envelope sha path — must be hex, 8..64 chars
if ! echo "$TRAILER" | grep -qE '^[a-fA-F0-9]{8,64}$'; then
    echo "✗ design-review-trailer: 'Design-reviewed: $TRAILER' is not an envelope sha" >&2
    echo "  Expected hex sha (8-64 chars). Run 'shasum -a 256 .claude/gates/last-design-review.json | cut -c1-12' for one." >&2
    exit 1
fi

# Validate against .claude/gates/
GATES_DIR=".claude/gates"
LAST_DR="$GATES_DIR/last-design-review.json"

# Path 1: sha names a file directly
if [ -f "$GATES_DIR/$TRAILER.json" ]; then
    exit 0
fi

# Path 2: sha matches shasum of last-design-review.json (first N chars)
if [ -f "$LAST_DR" ]; then
    ACTUAL_SHA=$(shasum -a 256 "$LAST_DR" 2>/dev/null | cut -c1-64)
    if printf '%s' "$ACTUAL_SHA" | grep -q "^${TRAILER}"; then
        # Additional check — envelope's verdict is PASS or WARN, not FAIL
        VERDICT=$(python3 -c "
import json, sys
try:
    d=json.load(open('$LAST_DR'))
    print((d.get('envelope',{}).get('verdict') or d.get('verdict') or '').upper())
except Exception:
    print('')
" 2>/dev/null || echo "")
        case "$VERDICT" in
            PASS|WARN)
                exit 0
                ;;
            FAIL)
                echo "✗ design-review-trailer: envelope $TRAILER has verdict=FAIL — commit blocked." >&2
                echo "  Address the design-critic findings before committing." >&2
                exit 1
                ;;
            *)
                echo "✗ design-review-trailer: envelope $TRAILER has unrecognized verdict '$VERDICT'" >&2
                exit 1
                ;;
        esac
    fi
fi

cat >&2 <<EOF
✗ design-review-trailer: envelope sha '$TRAILER' does not resolve to a record.

Looked for:
  $GATES_DIR/$TRAILER.json                (not found)
  $LAST_DR                                ($([ -f "$LAST_DR" ] && echo "exists but sha does not match" || echo "does not exist"))

Produce a fresh envelope:
  # invoke design-critic → captures envelope to .claude/gates/last-design-review.json
  pe gate parse --record .claude/gates/last-design-review.json \\
                --diff-sha "\$(git diff --cached | shasum -a 256 | cut -c1-12)" \\
                <transcript-file>
  sha=\$(shasum -a 256 .claude/gates/last-design-review.json | cut -c1-12)
  # Replace 'Design-reviewed: <old-sha>' with the new sha in your commit message.
EOF
exit 1
