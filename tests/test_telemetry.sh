#!/usr/bin/env bash
# Shell wrapper for test_telemetry.py so it participates in the engine's
# standard test suite (all shell scripts under tests/). Zero external
# deps — just python3.

set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not on PATH (telemetry parser tests require Python 3.11+)" >&2
    exit 0
fi

python3 "$ENGINE_DIR/tests/test_telemetry.py"
