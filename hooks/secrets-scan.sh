#!/usr/bin/env bash
# secrets-scan — pre-commit hook that scans staged files for secrets (P1.3).
#
# Tool detection (first available wins):
#   1. gitleaks (recommended)
#   2. detect-secrets
#   3. trufflehog
#
# If NONE is installed, prints an install hint and exits 0 (soft warn) — a
# missing scanner is not a commit-blocker; we don't want to break every
# adopter's first commit. Install one via:
#
#   brew install gitleaks
#   pipx install detect-secrets
#   brew install trufflehog
#
# Bypass: ENGINE_SKIP_SECRETS=1.

set -uo pipefail

if [ "${ENGINE_SKIP_SECRETS:-0}" = "1" ]; then
    echo "secrets-scan: ENGINE_SKIP_SECRETS=1 — skipping" >&2
    exit 0
fi

STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
if [ -z "$STAGED" ]; then
    exit 0
fi

if command -v gitleaks >/dev/null 2>&1; then
    # gitleaks protect scans the pre-commit index only.
    gitleaks protect --staged --redact --no-banner
    exit $?
fi

if command -v detect-secrets >/dev/null 2>&1; then
    # detect-secrets treats each staged file independently.
    # shellcheck disable=SC2086
    echo "$STAGED" | xargs detect-secrets scan --baseline .secrets.baseline 2>/dev/null || {
        # No baseline yet — do a plain scan and non-zero on any finding.
        echo "$STAGED" | xargs detect-secrets scan | grep -q '"results"' && {
            echo "secrets-scan: findings detected. Review + add to baseline: detect-secrets scan --update .secrets.baseline" >&2
            exit 1
        }
    }
    exit 0
fi

if command -v trufflehog >/dev/null 2>&1; then
    trufflehog git file://. --since-commit HEAD --only-verified --fail 2>/dev/null
    exit $?
fi

cat >&2 <<EOF
secrets-scan: no scanner installed — skipping (this is a soft warn).
  Install ONE of these to enforce:
    brew install gitleaks         # recommended, single binary
    pipx install detect-secrets   # baseline-oriented
    brew install trufflehog       # verified-only scanning
  The engine ships this hook to make the promise real. Skipping is
  documented in hooks/README.md.
EOF
exit 0
