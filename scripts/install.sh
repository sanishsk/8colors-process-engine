#!/usr/bin/env bash
# Install 8colors-process-engine into a target project
# Usage: ./install.sh /path/to/target-project
#
# v0.2.0 changes:
# - 6 new agents (architect, code-reviewer, doc-updater, planner, security-reviewer, tdd-guide)
# - 2 new skills (start-session, end-session) — installed user-global to ~/.claude/skills
# - launchd template bundle (run ./install_launchd.sh separately to wire CEO weekly)
# - .process-engine.yaml template copied to project root if absent

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
mkdir -p "$HOME/.claude/skills"

# Symlink agents (so engine upgrades propagate)
for f in "$ENGINE_DIR"/agents/*.md; do
  ln -sf "$f" "$TARGET/.claude/agents/$(basename "$f")"
done

# Symlink commands
for f in "$ENGINE_DIR"/commands/*.md; do
  ln -sf "$f" "$TARGET/.claude/commands/$(basename "$f")"
done

# Symlink skills (user-global — start-session / end-session apply across all
# projects and discover the current project's CLAUDE.md / MEMORY / quality
# calendar at runtime).
for skill_dir in "$ENGINE_DIR"/skills/*/; do
  skill_name="$(basename "$skill_dir")"
  mkdir -p "$HOME/.claude/skills/$skill_name"
  ln -sf "$skill_dir/SKILL.md" "$HOME/.claude/skills/$skill_name/SKILL.md"
done

# Copy templates (project may edit freely — no symlink)
for f in "$ENGINE_DIR"/templates/*.md; do
  if [ ! -f "$TARGET/docs/templates/$(basename "$f")" ]; then
    cp "$f" "$TARGET/docs/templates/$(basename "$f")"
  fi
done

# Copy .process-engine.yaml template if the project doesn't already have one
if [ ! -f "$TARGET/.process-engine.yaml" ]; then
  cp "$ENGINE_DIR/templates/process-engine.yaml.template" "$TARGET/.process-engine.yaml"
  CREATED_CONFIG=1
fi

# Copy docs (project may edit — these are reference)
cp -r "$ENGINE_DIR"/docs/* "$TARGET/docs/process-engine/"

echo "✓ 8colors-process-engine v$(cat "$ENGINE_DIR/VERSION") installed to $TARGET"
echo "  Agents:    $(ls "$TARGET/.claude/agents" | wc -l | tr -d ' ') symlinked → $TARGET/.claude/agents/"
echo "  Commands:  $(ls "$TARGET/.claude/commands" | wc -l | tr -d ' ') symlinked → $TARGET/.claude/commands/"
SKILL_COUNT=$(ls "$HOME/.claude/skills" 2>/dev/null | grep -cE '^(start|end)-session$' || true)
echo "  Skills:    ${SKILL_COUNT} symlinked → ~/.claude/skills/ (user-global)"
echo "  Templates: copied → $TARGET/docs/templates/"
if [ "${CREATED_CONFIG:-0}" = "1" ]; then
  echo "  Config:    created $TARGET/.process-engine.yaml — EDIT project.org_tag + project.root before next steps"
fi
echo ""

# Verify all symlinks resolve (fail loudly if engine repo missing files)
echo "Verifying symlinks resolve..."
BROKEN=0
for link in "$TARGET"/.claude/agents/*.md "$TARGET"/.claude/commands/*.md \
            "$HOME"/.claude/skills/start-session/SKILL.md \
            "$HOME"/.claude/skills/end-session/SKILL.md; do
  if [ ! -e "$link" ]; then
    echo "  ✗ BROKEN: $link"
    BROKEN=$((BROKEN+1))
  fi
done

if [ $BROKEN -gt 0 ]; then
  echo ""
  echo "ERROR: $BROKEN symlink(s) broken. Engine repo may be missing files."
  echo "Check $ENGINE_DIR/agents/, $ENGINE_DIR/commands/, $ENGINE_DIR/skills/"
  exit 2
fi

echo "  ✓ All symlinks resolve"
echo ""
echo "Next steps:"
echo "  1. Restart Claude Code in $TARGET to load new agents + skills."
echo "  2. (Optional) Edit $TARGET/.process-engine.yaml — set project.org_tag and project.root."
echo "  3. (Optional, macOS) Run: $ENGINE_DIR/scripts/install_launchd.sh $TARGET"
echo "     to wire the CEO weekly retro auto-fire (Fridays 17:00)."
