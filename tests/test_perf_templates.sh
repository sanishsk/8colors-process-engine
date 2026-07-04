#!/usr/bin/env bash
# tests/test_perf_templates.sh — PF4 soak template + PF5 k6 load
# template + CI wiring shape checks.
#
# We can't actually run k6 or a soak in CI (both need a real target).
# What we CAN assert:
#   - the templates exist at the paths named in the plan
#   - they contain the load-bearing structural markers (thresholds
#     block, RSS/slope check, tracemalloc snapshot, etc.)
#   - the CI job is wired to workflow_dispatch (not push/PR)
#   - the CI job requires load_test_base_url before running k6

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
SOAK="$ENGINE_DIR/templates/tests/soak.test.py.template"
K6="$ENGINE_DIR/templates/perf/load-test.k6.js.template"
CI="$ENGINE_DIR/templates/ci/engine-quality.yml.template"
PY="${PE_PYTHON:-python3}"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_perf_templates.sh — PF4 + PF5 shape checks"
echo ""

# ─── PF4 soak template ──────────────────────────────────────────────

if [ -f "$SOAK" ]; then
    record_pass "PF4 soak template present at templates/tests/soak.test.py.template"
else
    record_fail "PF4 soak template missing"
    exit 1
fi

if grep -q "class TestSoak" "$SOAK" \
   && grep -q "test_rss_does_not_grow_linearly" "$SOAK" \
   && grep -q "test_gc_reclaims_after_soak" "$SOAK"; then
    record_pass "PF4: TestSoak class with rss-slope + gc-reclaim cases"
else
    record_fail "PF4: TestSoak class shape wrong"
fi

if grep -q "tracemalloc.start" "$SOAK" \
   && grep -q "tracemalloc.take_snapshot" "$SOAK"; then
    record_pass "PF4: tracemalloc snapshot fires on failure (source location)"
else
    record_fail "PF4: tracemalloc integration missing"
fi

if grep -q "MAX_RSS_GROWTH_MB" "$SOAK" \
   && grep -q "MAX_SLOPE_MB_PER_100REQ" "$SOAK"; then
    record_pass "PF4: dual-threshold contract (delta + slope) present"
else
    record_fail "PF4: threshold constants missing"
fi

if grep -q "gc.collect" "$SOAK" \
   && grep -q "psutil" "$SOAK"; then
    record_pass "PF4: gc + psutil integration (RSS after collect)"
else
    record_fail "PF4: gc/psutil integration missing"
fi

if grep -q "_boot_app" "$SOAK" \
   && grep -q "_call_hot_endpoint" "$SOAK" \
   && grep -qE "raise NotImplementedError" "$SOAK"; then
    record_pass "PF4: adopter stubs marked NotImplementedError"
else
    record_fail "PF4: adopter stubs missing / not clearly marked"
fi

# ─── PF5 k6 load template ───────────────────────────────────────────

if [ -f "$K6" ]; then
    record_pass "PF5 k6 template present at templates/perf/load-test.k6.js.template"
else
    record_fail "PF5 k6 template missing"
    exit 1
fi

if grep -q "import http from 'k6/http'" "$K6" \
   && grep -q "import { check, sleep } from 'k6'" "$K6"; then
    record_pass "PF5: canonical k6 imports present"
else
    record_fail "PF5: k6 imports missing"
fi

if grep -q "thresholds:" "$K6" \
   && grep -q "'p(95)<" "$K6" \
   && grep -q "'rate<" "$K6"; then
    record_pass "PF5: thresholds block with p95 + error rate gates"
else
    record_fail "PF5: threshold shape wrong"
fi

if grep -qE "list_(errors|latency)" "$K6" \
   && grep -qE "detail_(errors|latency)" "$K6" \
   && grep -qE "write_(errors|latency)" "$K6"; then
    record_pass "PF5: metrics split by endpoint class (list/detail/write)"
else
    record_fail "PF5: metrics not split by endpoint class"
fi

if grep -q "ramping-vus" "$K6" \
   && grep -q "warmup" "$K6"; then
    record_pass "PF5: ramping-vus scenario with warmup stage"
else
    record_fail "PF5: ramp shape missing"
fi

if grep -q "__ENV.BASE_URL" "$K6" \
   && grep -q "__ENV.AUTH_TOKEN" "$K6"; then
    record_pass "PF5: env-driven BASE_URL + AUTH_TOKEN"
else
    record_fail "PF5: env config missing"
fi

# ─── CI wiring — load-test-k6 job ───────────────────────────────────

if [ -f "$CI" ]; then
    record_pass "CI template present"
else
    record_fail "CI template missing"
    exit 1
fi

if grep -qE "^  load-test-k6:" "$CI"; then
    record_pass "CI: load-test-k6 job present"
else
    record_fail "CI: load-test-k6 job missing"
fi

# Job must be manual-dispatch only (NOT triggered by push / PR).
if awk '/^  load-test-k6:/{in_block=1;next} in_block && /^  [a-z][a-zA-Z0-9_-]*:/{exit} in_block' "$CI" \
    | grep -q "workflow_dispatch"; then
    record_pass "CI: load-test-k6 gated on workflow_dispatch only"
else
    record_fail "CI: load-test-k6 not workflow-dispatch-gated"
fi

# Job must validate the base URL input before running k6.
if awk '/^  load-test-k6:/{in_block=1;next} in_block && /^  [a-z][a-zA-Z0-9_-]*:/{exit} in_block' "$CI" \
    | grep -qi "load_test_base_url"; then
    record_pass "CI: load-test-k6 validates load_test_base_url input"
else
    record_fail "CI: load-test-k6 doesn't validate BASE_URL input"
fi

# Job is advisory (continue-on-error).
if awk '/^  load-test-k6:/{in_block=1;next} in_block && /^  [a-z][a-zA-Z0-9_-]*:/{exit} in_block' "$CI" \
    | grep -q "continue-on-error: true"; then
    record_pass "CI: load-test-k6 marked advisory (continue-on-error: true)"
else
    record_fail "CI: load-test-k6 not advisory (would block PRs)"
fi

# Job uploads the k6 summary as an artifact.
if awk '/^  load-test-k6:/{in_block=1;next} in_block && /^  [a-z][a-zA-Z0-9_-]*:/{exit} in_block' "$CI" \
    | grep -q "upload-artifact"; then
    record_pass "CI: load-test-k6 uploads k6-summary.json artifact"
else
    record_fail "CI: no artifact upload"
fi

# workflow_dispatch inputs include the new load_test_base_url control.
if grep -q "load_test_base_url:" "$CI" \
   && grep -q "run_load_test:" "$CI"; then
    record_pass "CI: workflow_dispatch inputs include run_load_test + load_test_base_url"
else
    record_fail "CI: workflow_dispatch inputs missing PF5 controls"
fi

# ─── PF4 reviewer regression: baseline captured BEFORE tracemalloc ──
# The CRITICAL: tracemalloc.start() adds 5-15MB of instrumentation
# overhead. Capturing baseline_rss after starting it would inflate the
# baseline and let real growth hide inside the noise floor. Grep for
# the ordering.
if awk '/def test_rss_does_not_grow_linearly/,/def test_gc_reclaims/' "$SOAK" \
    | grep -B1 "tracemalloc.start()" \
    | grep -q "baseline_rss = _current_rss_mb"; then
    record_pass "PF4: baseline_rss captured BEFORE tracemalloc.start (reviewer CRITICAL)"
else
    record_fail "PF4: baseline captured AFTER tracemalloc.start (inflates baseline)"
fi

# ─── PF4 reviewer regression: warmup checkpoints skipped in slope ───
if grep -q "WARMUP_CHECKPOINTS" "$SOAK" \
   && grep -q "samples\[WARMUP_CHECKPOINTS:\]" "$SOAK"; then
    record_pass "PF4: WARMUP_CHECKPOINTS trims cache-warm samples from slope regression"
else
    record_fail "PF4: no warmup-checkpoint trim — cache-warm slope can mask real leaks"
fi

# ─── PF5 reviewer regression: URL validation rejects localhost ──────
if awk '/^  load-test-k6:/{in_block=1;next} in_block && /^  [a-z][a-zA-Z0-9_-]*:/{exit} in_block' "$CI" \
    | grep -q "localhost" \
    && awk '/^  load-test-k6:/{in_block=1;next} in_block && /^  [a-z][a-zA-Z0-9_-]*:/{exit} in_block' "$CI" \
    | grep -q "127.0.0.1"; then
    record_pass "PF5: URL validation rejects localhost / 127.0.0.1 (reviewer MEDIUM)"
else
    record_fail "PF5: URL validation doesn't guard against localhost load-test"
fi

# ─── PF5 reviewer regression: URL validation requires http(s) scheme ─
if awk '/^  load-test-k6:/{in_block=1;next} in_block && /^  [a-z][a-zA-Z0-9_-]*:/{exit} in_block' "$CI" \
    | grep -qE "https?://"; then
    record_pass "PF5: URL validation enforces http:// or https:// prefix"
else
    record_fail "PF5: URL validation doesn't enforce scheme"
fi

# ─── PF5 reviewer regression: LOAD_TEST_AUTH_TOKEN presence warned ───
if awk '/^  load-test-k6:/{in_block=1;next} in_block && /^  [a-z][a-zA-Z0-9_-]*:/{exit} in_block' "$CI" \
    | grep -q "LOAD_TEST_AUTH_TOKEN secret is not configured"; then
    record_pass "PF5: missing LOAD_TEST_AUTH_TOKEN warns loudly (reviewer HIGH)"
else
    record_fail "PF5: missing AUTH_TOKEN silently causes 401 storm — no warning"
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
