#!/usr/bin/env bash
# Shell wrapper for test_agent_runner.py — participates in the standard
# test suite (all shell scripts under tests/). Zero external deps.

set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not on PATH (agent-runner tests require Python 3.11+)" >&2
    exit 0
fi

python3 "$ENGINE_DIR/tests/test_agent_runner.py"
