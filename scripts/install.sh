#!/usr/bin/env bash
# Install 8colors-process-engine into a target project
# Usage: ./install.sh /path/to/target-project

set -euo pipefail
TARGET="${1:?Usage: ./install.sh /path/to/target-project}"
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$TARGET" ]; then
  echo "Target $TARGET does not exist"; exit 1
fi

mkdir -p "$TARGET/.claude/agents"
mkdir -p "$TARGET/.claude/commands"
mkdir -p "$TARGET/docs/templates"
mkdir -p "$TARGET/docs/process-engine"

# Symlink agents (so engine upgrades propagate)
for f in "$ENGINE_DIR"/agents/*.md; do
  ln -sf "$f" "$TARGET/.claude/agents/$(basename "$f")"
done

# Symlink commands
for f in "$ENGINE_DIR"/commands/*.md; do
  ln -sf "$f" "$TARGET/.claude/commands/$(basename "$f")"
done

# Copy templates (project may edit freely — no symlink)
for f in "$ENGINE_DIR"/templates/*.md; do
  if [ ! -f "$TARGET/docs/templates/$(basename "$f")" ]; then
    cp "$f" "$TARGET/docs/templates/$(basename "$f")"
  fi
done

# Copy docs (project may edit — these are reference)
cp -r "$ENGINE_DIR"/docs/* "$TARGET/docs/process-engine/"

echo "✓ 8colors-process-engine installed to $TARGET"
echo "  Agents: $(ls "$TARGET/.claude/agents" | wc -l | tr -d ' ') symlinked"
echo "  Commands: $(ls "$TARGET/.claude/commands" | wc -l | tr -d ' ') symlinked"
echo "  Templates: copied to docs/templates/"
echo ""

# Verify all symlinks resolve (fail loudly if engine repo missing files)
# Pattern borrowed from netresearch/agent-harness-skill — fail loud, never silent.
echo "Verifying symlinks resolve..."
BROKEN=0
for link in "$TARGET"/.claude/agents/*.md "$TARGET"/.claude/commands/*.md; do
  if [ ! -e "$link" ]; then
    echo "  ✗ BROKEN: $link"
    BROKEN=$((BROKEN+1))
  fi
done

if [ $BROKEN -gt 0 ]; then
  echo ""
  echo "ERROR: $BROKEN symlink(s) broken. Engine repo may be missing files."
  echo "Check $ENGINE_DIR/agents/ and $ENGINE_DIR/commands/"
  exit 2
fi

echo "  ✓ All symlinks resolve"
echo ""
echo "Next: restart Claude Code in target project to load new agents."
