#!/usr/bin/env bash
# Shell wrapper for test_p2_11_python_hygiene.py so it participates
# in the engine's standard test suite (all shell scripts under tests/).
# The Python unittest module runs with zero external deps — just python3.

set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/_py.sh"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not on PATH (P2.11 tests require Python 3.11+)" >&2
    exit 0
fi

"$PY" "$ENGINE_DIR/tests/test_p2_11_python_hygiene.py"
