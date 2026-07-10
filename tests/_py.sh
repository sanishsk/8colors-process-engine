# _py.sh — resolve a Python >=3.11 for tests (stock macOS python3 is 3.9).
# Mirrors scripts/pe::pe_python. Source this, then use "$PY" not python3.
# ponytail: 2 tests use it today; others adopt on next touch.
PY="${PE_PYTHON:-}"
if [ -z "$PY" ]; then
    for _c in python3 python3.13 python3.12 python3.11; do
        if command -v "$_c" >/dev/null 2>&1 \
           && "$_c" -c 'import sys; raise SystemExit(0 if sys.version_info>=(3,11) else 1)' 2>/dev/null; then
            PY="$_c"; break
        fi
    done
fi
[ -n "$PY" ] || { echo "SKIP: no Python >=3.11 on PATH" >&2; exit 0; }
