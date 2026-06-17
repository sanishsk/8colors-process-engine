#!/usr/bin/env bash
# research-index-rebuild — pre-commit hook that rebuilds the semantic
# index whenever any docs/research/*.md is staged.
#
# Incremental (sha256), so unchanged files skip. Cost on the typical
# 70-doc corpus: <1s with fastembed.
#
# Install:
#   - id: research-index-rebuild
#     entry: hooks/research-index-rebuild.sh
#     language: script
#     stages: [pre-commit]
#     files: ^docs/research/.*\.md$

set -euo pipefail

# Only fire if research_index.py exists
if [ ! -f scripts/research_index.py ]; then
    exit 0
fi

# Pick python3 — prefer project venv if present
if [ -x .venv/bin/python3 ]; then
    PY=.venv/bin/python3
else
    PY=python3
fi

# Detect staged docs/research changes; bail if none
STAGED=$(git diff --cached --name-only | grep -E '^docs/research/.*\.md$' || true)
if [ -z "$STAGED" ]; then
    exit 0
fi

echo "→ research-index-rebuild: incrementally re-embedding changed docs"
"$PY" scripts/research_index.py rebuild || {
    echo "⚠ research-index-rebuild: rebuild failed. Commit proceeds anyway."
    echo "  Re-run manually: $PY scripts/research_index.py rebuild"
    exit 0   # don't block the commit on index failure
}

# Re-stage the updated index? No — it's gitignored on purpose.
exit 0
