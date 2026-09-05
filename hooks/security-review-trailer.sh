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

# ─── Path exemption — fail-closed, shared with the review gate ──────────
# The regex above is a substring match on paths, and that is deliberate: a
# word-boundary version would stop catching authenticate.py and
# authorization.py, which are the files this gate exists for. The cost is
# false positives on words that mean something else in a given codebase —
# "session" is a workout in a fitness app, "token" is a design token in a
# CSS file — and on the engine's OWN files: every *-security.test.py.template
# `pe install` copies into an adopter trips this regex by name, so the engine
# ships files that trigger its own gate on the next commit that touches them.
#
# Two layers, both exempt-lists (anything unlisted is still gated):
#   DEFAULT  — names the ENGINE chose. Templates are never executed; the
#              session docs, session skills and design-token files are
#              engine conventions. This is the engine not tripping over
#              itself, not a narrowing of intent.
#   ADOPTER  — ENGINE_SECURITY_EXEMPT_PATHS → security_gate.exempt_paths in
#              .process-engine.yaml. ADDED to the default, never replacing
#              it, or declaring one exemption would re-expose every template.
#
# Per-commit, not per-file: one exempt path plus one auth path is gated.
# An invalid adopter regex exempts nothing (hooks/_exempt-paths.sh).
_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_exempt-paths.sh
. "$_HOOK_DIR/_exempt-paths.sh"
DEFAULT_EXEMPT_RE='(\.template$|(^|/)docs/(process-engine/)?sessions/|design-tokens?\.|(^|/)templates/design/tokens\.json|(^|/)skills/(start|end)-session/|session-cost-warn\.sh$)'
ADOPTER_EXEMPT_RE=$(pe_exempt_regex ENGINE_SECURITY_EXEMPT_PATHS security_gate.exempt_paths)
EXEMPT_RE="$DEFAULT_EXEMPT_RE"
[ -n "$ADOPTER_EXEMPT_RE" ] && EXEMPT_RE="($DEFAULT_EXEMPT_RE|$ADOPTER_EXEMPT_RE)"
STAGED=$(pe_unexempt_paths "$EXEMPT_RE" <<<"$STAGED")

HITS=$( { echo "$STAGED" | grep -iE "$SECURITY_RE"; } 2>/dev/null || true)
if [ -z "$HITS" ]; then
    exit 0
fi

MSG=$(cat "$MSG_FILE")
TRAILER=$( { echo "$MSG" | grep -E '^Security-reviewed:' || true; } | head -1 | sed -E 's/^Security-reviewed:[[:space:]]*//' | tr -d '\r' | sed -E 's/[[:space:]]+$//')
SKIP=$( { echo "$MSG" | grep -E '^Security-skip-reason:' || true; } | head -1)

# ─── S3 test-evidence gate ──────────────────────────────────────────
# Money-mutating paths (payment / webhook / billing) require BOTH the
# Security-reviewed trailer AND co-staged test evidence. Templates
# live at templates/tests/{payment,webhook}-security.test.py.template
# for adopters to copy in.
#
# Override the narrow regex via ENGINE_SECURITY_TEST_PATHS.
# Explicit escape: Security-tests-skip-reason: <reason>.
DEFAULT_TEST_RE='(payment|billing|webhook)'
TEST_RE="${ENGINE_SECURITY_TEST_PATHS:-$DEFAULT_TEST_RE}"
MONEY_HITS=$( { echo "$STAGED" | grep -iE "$TEST_RE" || true; } | { grep -vE '(^|/)tests?/' || true; })
TESTS_STAGED=$(echo "$STAGED" | grep -E '(^|/)tests?/' || true)
TESTS_SKIP=$( { echo "$MSG" | grep -E '^Security-tests-skip-reason:' || true; } | head -1)

if [ -n "$SKIP" ]; then
    exit 0
fi

if [ -n "$MONEY_HITS" ] && [ -z "$TESTS_STAGED" ] && [ -z "$TESTS_SKIP" ]; then
    cat >&2 <<EOF
✗ security-review-trailer: this commit touches money-mutating paths:

$(echo "$MONEY_HITS" | sed 's/^/    /')

…but NO test files are staged alongside them. Money paths require
test evidence in the SAME commit as the code change.

Copy the pytest template for your surface:

  cp \$ENGINE_DIR/templates/tests/payment-security.test.py.template \\
     tests/test_payment_security.py
  cp \$ENGINE_DIR/templates/tests/webhook-security.test.py.template \\
     tests/test_webhook_security.py

Wire the adopter stubs (marked \`raise NotImplementedError\` /
\`pytest.skip\`) to your app + rerun.

To skip explicitly (docs-only patch, revert, etc.):

  Security-tests-skip-reason: <short reason>

Override the money-path regex via ENGINE_SECURITY_TEST_PATHS.
EOF
    exit 1
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
If a matched word means something else in this codebase (a workout
"session", a design "token"), declare it — this narrows the gate to
the paths you name and nothing else:

  security_gate:
    exempt_paths: '^ios/.*Session[A-Za-z]*\\.swift$'   # .process-engine.yaml

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

# v0.36.0: envelope resolution + verdict parsing moved to
# hooks/_trailer-contract.sh. Named-record precedence: security.json
# first (project-scoped), then last-gate.json (session-wide fallback).
_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$_HOOK_DIR/_trailer-contract.sh"

if ! pe_trailer_is_sha "$TRAILER"; then
    echo "✗ security-review-trailer: '$TRAILER' is not an envelope sha" >&2
    exit 1
fi

RECORD=$(pe_trailer_resolve_record "$TRAILER" \
    ".claude/gates/security.json" \
    ".claude/gates/last-gate.json")

if [ -z "$RECORD" ]; then
    echo "✗ security-review-trailer: sha '$TRAILER' does not resolve to any .claude/gates/*.json" >&2
    exit 1
fi

VERDICT=$(pe_trailer_verdict "$RECORD")

case "$VERDICT" in
    PASS|WARN) exit 0 ;;
    *)
        echo "✗ security-review-trailer: envelope at $RECORD has verdict '$VERDICT'" >&2
        exit 1 ;;
esac
