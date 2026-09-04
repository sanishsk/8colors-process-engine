#!/usr/bin/env bash
# boot-smoke — "fresh clone boots" gate (P5.1).
#
# Reads .process-engine.yaml -> boot_check.{setup, run, probe_url,
# timeout_seconds, expected_max_status} and:
#   1. Runs `setup` to bring up a throwaway environment (create DB,
#      run migrations, seed a minimal user, etc.).
#   2. Starts `run` in the background.
#   3. Waits until `probe_url` returns HTTP < expected_max_status
#      (or times out).
#   4. Kills the background process.
#   5. Fails if the probe never succeeded OR the startup log contained
#      lines matching "^ERROR" / "^CRITICAL" (level=ERROR).
#
# This is the single check that would have caught 4 of the 8CStudio
# audit's boot failures at once. Ships generic; every adopter declares
# its own commands. If boot_check is absent OR enabled=false: skip.
#
# Invoked by: NOTHING, as of 2026-09-04.
#
# This header used to claim `pe doctor` (opportunistic) and the CI job in
# templates/ci/engine-quality.yml.template. Neither references this file —
# grep the repo. The adoption audit found it wired to no pre-commit config,
# no hooks.json entry, no CI template and no consuming project, with no test
# and no fixture. It is the engine's one fully-orphaned hook.
#
# It is kept rather than deleted because the capability is sound and the
# missing half is the wiring, not the script. Correctly NOT a pre-commit
# hook — boot is slow (10-60s); it belongs at CI or `pe doctor` time, which
# is exactly where it is not yet called from. See docs/ADOPTION_AUDIT.md.
#
# Bypass: PE_SKIP_BOOT_SMOKE=1

set -euo pipefail

if [ "${PE_SKIP_BOOT_SMOKE:-0}" = "1" ]; then
    echo "[boot-smoke] skipped (PE_SKIP_BOOT_SMOKE=1)" >&2
    exit 0
fi

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ENGINE_DIR/scripts/_yaml.sh" ]; then
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/scripts/_yaml.sh"
fi

CONFIG=".process-engine.yaml"
if [ ! -f "$CONFIG" ]; then
    echo "[boot-smoke] no .process-engine.yaml — skipping" >&2
    exit 0
fi

enabled=$(yaml_get "boot_check.enabled" "$CONFIG" 2>/dev/null || true)
[ -z "$enabled" ] && enabled="false"
if [ "$enabled" != "true" ]; then
    echo "[boot-smoke] boot_check.enabled != true — skipping" >&2
    exit 0
fi

SETUP_CMD=$(yaml_get "boot_check.setup" "$CONFIG" 2>/dev/null || true)
RUN_CMD=$(yaml_get "boot_check.run" "$CONFIG" 2>/dev/null || true)
PROBE_URL=$(yaml_get "boot_check.probe_url" "$CONFIG" 2>/dev/null || true)
TIMEOUT=$(yaml_get "boot_check.timeout_seconds" "$CONFIG" 2>/dev/null || true)
MAX_STATUS=$(yaml_get "boot_check.expected_max_status" "$CONFIG" 2>/dev/null || true)

[ -z "$TIMEOUT" ] && TIMEOUT=30
[ -z "$MAX_STATUS" ] && MAX_STATUS=500

if [ -z "$RUN_CMD" ] || [ -z "$PROBE_URL" ]; then
    echo "[boot-smoke] boot_check.run or boot_check.probe_url missing — cannot run" >&2
    echo "  Add to .process-engine.yaml:" >&2
    echo "    boot_check:" >&2
    echo "      enabled: true" >&2
    echo "      setup:     'flask db upgrade'          # or whatever brings up your DB" >&2
    echo "      run:       'flask run --port 5555'    # long-running command" >&2
    echo "      probe_url: 'http://127.0.0.1:5555/login'" >&2
    echo "      timeout_seconds: 30" >&2
    echo "      expected_max_status: 500" >&2
    exit 1
fi

LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

echo "[boot-smoke] step 1/3: setup" >&2
if [ -n "$SETUP_CMD" ]; then
    if ! bash -c "$SETUP_CMD" >"$LOG_FILE" 2>&1; then
        echo "[boot-smoke] FAIL: setup command failed" >&2
        tail -20 "$LOG_FILE" >&2
        exit 1
    fi
fi

echo "[boot-smoke] step 2/3: launch app in background" >&2
# Run in a new session so we can kill the whole process group
bash -c "$RUN_CMD" >>"$LOG_FILE" 2>&1 &
APP_PID=$!
# Ensure we always clean up
cleanup_app() {
    if kill -0 "$APP_PID" 2>/dev/null; then
        # try graceful, then hard
        kill "$APP_PID" 2>/dev/null || true
        sleep 1
        kill -9 "$APP_PID" 2>/dev/null || true
        # kill any child processes launched by the run command
        pkill -P "$APP_PID" 2>/dev/null || true
    fi
}
trap 'cleanup_app; rm -f "$LOG_FILE"' EXIT

echo "[boot-smoke] step 3/3: probe $PROBE_URL (timeout ${TIMEOUT}s, max_status <$MAX_STATUS)" >&2

if ! command -v curl >/dev/null 2>&1; then
    echo "[boot-smoke] FAIL: curl not on PATH — cannot probe" >&2
    exit 1
fi

deadline=$(( $(date +%s) + TIMEOUT ))
probe_status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "[boot-smoke] FAIL: app process exited before probe succeeded" >&2
        tail -30 "$LOG_FILE" >&2
        exit 1
    fi
    probe_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$PROBE_URL" 2>/dev/null || echo "000")
    if [ "$probe_status" != "000" ] && [ "$probe_status" -lt "$MAX_STATUS" ]; then
        echo "[boot-smoke] probe OK — HTTP $probe_status" >&2
        break
    fi
    sleep 1
done

if [ -z "$probe_status" ] || [ "$probe_status" = "000" ] || [ "$probe_status" -ge "$MAX_STATUS" ]; then
    echo "[boot-smoke] FAIL: probe never returned <$MAX_STATUS (last: $probe_status)" >&2
    tail -30 "$LOG_FILE" >&2
    exit 1
fi

# Log-line ERROR check
if grep -qE '^(ERROR|CRITICAL)' "$LOG_FILE"; then
    echo "[boot-smoke] FAIL: ERROR/CRITICAL log lines during startup:" >&2
    grep -E '^(ERROR|CRITICAL)' "$LOG_FILE" | head -10 >&2
    exit 1
fi

echo "[boot-smoke] PASS — app boots, probe returned $probe_status, no ERROR log lines" >&2
exit 0
