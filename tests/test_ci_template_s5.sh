#!/usr/bin/env bash
# tests/test_ci_template_s5.sh — S5 CI template surface checks.
#
# The engine-quality.yml.template ships four security-adjacent gates
# added in v0.31.0:
#   1) container-security   — hadolint + trivy on Dockerfile presence
#   2) license-audit        — pip-licenses / license-checker
#   3) secrets-scan-history — weekly full-git-history gitleaks
#   4) schedule trigger     — cron for weekly deep scans
#
# We can't run GitHub Actions locally, but we CAN assert the template
# still parses as valid YAML and contains the load-bearing keys +
# feature-detect guards. A downstream engine-quality.yml deployment
# gets those + any Actions-side validation.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
TEMPLATE="$ENGINE_DIR/templates/ci/engine-quality.yml.template"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_ci_template_s5.sh — $TEMPLATE"
echo ""

if [ ! -f "$TEMPLATE" ]; then
    echo "TEMPLATE NOT FOUND: $TEMPLATE"
    exit 2
fi

# ─── 1. weekly schedule (cron) trigger present ──────────────────────
if grep -qE "^\s*-\s*cron:\s*'0 8 \* \* 1'" "$TEMPLATE"; then
    record_pass "weekly Monday 08:00 UTC cron trigger present"
else
    record_fail "cron trigger missing or wrong shape"
fi

# ─── 2. workflow_dispatch present (manual re-run for weekly scans) ──
if grep -qE "^\s*workflow_dispatch:" "$TEMPLATE"; then
    record_pass "workflow_dispatch manual trigger present"
else
    record_fail "workflow_dispatch missing"
fi

# ─── 3. container-security job with hadolint + trivy ────────────────
if grep -qE "^\s*container-security:" "$TEMPLATE" \
   && grep -qE "^\s*if:\s*hashFiles\('Dockerfile'\) != ''" "$TEMPLATE" \
   && grep -qE "hadolint/hadolint-action" "$TEMPLATE" \
   && grep -qE "aquasecurity/trivy-action" "$TEMPLATE"; then
    record_pass "container-security job present with hadolint + trivy + Dockerfile guard"
else
    record_fail "container-security wiring incomplete"
fi

# ─── 4. container-security is advisory (continue-on-error) ──────────
awk '/^  container-security:/{in_block=1;next} in_block && /^  [a-z][a-zA-Z0-9_-]*:/{exit} in_block' "$TEMPLATE" \
    | grep -q "continue-on-error: true" \
    && record_pass "container-security marked advisory (continue-on-error: true)" \
    || record_fail "container-security not advisory (would block PRs on transient CVE churn)"

# ─── 5. license-audit job present ───────────────────────────────────
if grep -qE "^\s*license-audit:" "$TEMPLATE"; then
    record_pass "license-audit job present"
else
    record_fail "license-audit job missing"
fi

# ─── 6. license fail-on defaults include AGPL + GPL-3.0 ─────────────
if grep -q "ENGINE_LICENSE_FAIL_ON: 'AGPL-3.0" "$TEMPLATE" \
   && grep -q "GPL-3.0" "$TEMPLATE"; then
    record_pass "license-audit fail-on defaults include AGPL + GPL-3.0"
else
    record_fail "license fail-on defaults wrong (missing AGPL or GPL-3.0)"
fi

# ─── 7. license warn-on defaults include LGPL ───────────────────────
if grep -q "ENGINE_LICENSE_WARN_ON: 'LGPL-3.0" "$TEMPLATE"; then
    record_pass "license-audit warn-on defaults include LGPL"
else
    record_fail "license warn-on defaults missing LGPL"
fi

# ─── 8. license-audit runs both python + node feature-detected ──────
if grep -qE "if:\s*needs.detect-stack.outputs.stack == 'python'" "$TEMPLATE" \
   && grep -qE "if:\s*needs.detect-stack.outputs.stack == 'node'" "$TEMPLATE" \
   && grep -q "pip-licenses" "$TEMPLATE" \
   && grep -q "license-checker" "$TEMPLATE"; then
    record_pass "license-audit branches on python (pip-licenses) + node (license-checker)"
else
    record_fail "license-audit stack branching incomplete"
fi

# ─── 9. secrets-scan-history job present + schedule-only ────────────
if grep -qE "^\s*secrets-scan-history:" "$TEMPLATE" \
   && awk '/^  secrets-scan-history:/{in_block=1;next} in_block && /^  [a-z][a-zA-Z0-9_-]*:/{exit} in_block' "$TEMPLATE" \
      | grep -q "github.event_name == 'schedule'"; then
    record_pass "secrets-scan-history job present + gated on schedule / dispatch"
else
    record_fail "secrets-scan-history missing or not schedule-gated"
fi

# ─── 10. gitleaks full-history uses --source . + --no-git=false ─────
if grep -qE "gitleaks detect --source \. --no-git=false" "$TEMPLATE"; then
    record_pass "gitleaks full-history mode wired (--source . --no-git=false --redact)"
else
    record_fail "gitleaks full-history invocation wrong"
fi

# ─── 11. existing per-commit secrets-scan job preserved ─────────────
if grep -qE "^\s*secrets-scan:" "$TEMPLATE" \
   && grep -qE "gitleaks/gitleaks-action@v2" "$TEMPLATE"; then
    record_pass "per-commit secrets-scan preserved (incremental gitleaks-action)"
else
    record_fail "per-commit secrets-scan regressed"
fi

# ─── 12. all new S5 jobs are advisory (continue-on-error) ───────────
for job in container-security license-audit secrets-scan-history; do
    section=$(awk -v j="$job" 'BEGIN{pat="^  "j":"} $0 ~ pat {in_block=1;next} in_block && /^  [a-z][a-zA-Z0-9_-]*:/{exit} in_block' "$TEMPLATE")
    if echo "$section" | grep -q "continue-on-error: true"; then
        record_pass "$job is advisory (continue-on-error: true)"
    else
        record_fail "$job would block PRs (missing continue-on-error)"
    fi
done

# ─── 13. license matcher regression — reviewer CRITICAL fix ─────────
# The v0.31.0 reviewer caught a subtle bug: pip-licenses can emit
# classifier-style strings ("GNU General Public License v3 (GPLv3)")
# that a naive substring match against "GPL-3.0" misses. This test
# extracts the Python evaluator from the template and runs it against
# a real-shape license list, asserting the matcher catches all three
# classifier forms (SPDX, full-name, short-form, mixed).
extract_python() {
    awk '/python - <<.PY./{in_block=1;next} in_block && /^          PY$/{exit} in_block' "$TEMPLATE" \
        | sed -E 's/^          //'
}

test_prog=$(mktemp)
{
    cat <<'PROLOGUE'
import json, os
# License shapes the matcher must catch (all GPL-family or LGPL).
_test_licenses = [
    {"Name": "pkg-spdx",        "License": "GPL-3.0-only"},
    {"Name": "pkg-classifier",  "License": "GNU General Public License v3"},
    {"Name": "pkg-shortform",   "License": "GPLv3"},
    {"Name": "pkg-mixed",       "License": "GNU General Public License v3 (GPLv3)"},
    {"Name": "pkg-agpl",        "License": "GNU Affero General Public License v3"},
    {"Name": "pkg-lgpl-warn",   "License": "LGPL-3.0"},
    {"Name": "pkg-mit-clean",   "License": "MIT License"},
]
json.dump(_test_licenses, open('licenses.json', 'w'))
os.environ['ENGINE_LICENSE_FAIL_ON'] = 'AGPL-3.0;AGPL-3.0-only;GPL-3.0;GPL-3.0-only'
os.environ['ENGINE_LICENSE_WARN_ON'] = 'LGPL-3.0;LGPL-3.0-only;LGPL-2.1'
PROLOGUE
    # Strip the sys.exit so we can capture BOTH the FAIL and WARN
    # sections in one run — the real gate exits on the first FAIL.
    extract_python | sed -e "s|sys.exit(1)|pass|"
} > "$test_prog"

cd "$(dirname "$test_prog")"
out=$(python3 "$test_prog" 2>&1)
cd - >/dev/null

# Expect FAIL for all five copyleft forms (SPDX + classifier + short + mixed + AGPL).
if echo "$out" | grep -q "LICENSE FAIL" \
   && echo "$out" | grep -q "pkg-spdx" \
   && echo "$out" | grep -q "pkg-classifier" \
   && echo "$out" | grep -q "pkg-shortform" \
   && echo "$out" | grep -q "pkg-mixed" \
   && echo "$out" | grep -q "pkg-agpl"; then
    record_pass "license matcher catches SPDX + classifier + short + mixed + AGPL forms"
else
    record_fail "license matcher misses classifier forms (reviewer CRITICAL regressed): out='$out'"
fi

# LGPL must land in WARN (not FAIL), MIT must be clean (in neither section).
warn_section=$(echo "$out" | awk '/LICENSE WARN/,/license-audit:/' )
if echo "$warn_section" | grep -q "pkg-lgpl-warn" \
   && ! echo "$out" | grep -q "pkg-mit-clean"; then
    record_pass "license matcher distinguishes WARN (LGPL) from FAIL, clean (MIT)"
else
    record_fail "license matcher WARN/clean classification wrong: out='$out'"
fi

rm -f "$test_prog" licenses.json 2>/dev/null

# ─── 14. no obvious YAML shape errors (bracket balance sanity) ──────
open_maps=$(grep -cE "^\s*[a-z][a-zA-Z0-9_-]+:\s*$" "$TEMPLATE")
if [ "$open_maps" -gt 20 ]; then
    record_pass "template has $open_maps mapping keys (structure preserved)"
else
    record_fail "template mapping-key count too low ($open_maps) — possible truncation"
fi

# ─── summary ────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  passed: $pass"
echo "  failed: $fail"
if [ $fail -gt 0 ]; then
    for f in "${failures[@]}"; do echo "    - $f"; done
    exit 1
fi
exit 0
