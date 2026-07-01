#!/usr/bin/env bash
# Install 8colors-process-engine into a target project
# Usage: ./install.sh /path/to/target-project
#
# v0.2.0 changes:
# - 6 new agents (architect, code-reviewer, doc-updater, planner, security-reviewer, tdd-guide)
# - 2 new skills (start-session, end-session) — installed user-global to ~/.claude/skills
# - launchd template bundle (run ./install_launchd.sh separately to wire CEO weekly)
# - .process-engine.yaml template copied to project root if absent
#
# v0.3.0 changes:
# - research_index.py (RAG over docs/research/) symlinked into project scripts/
# - /research-search slash command
# - brief-writer + architect agents now consult the index in their Step 0

set -euo pipefail
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Source preset rosters + yaml subset reader (shared with pe sync).
# shellcheck source=./_subset.sh
. "$ENGINE_DIR/scripts/_subset.sh"

# ─── Arg parsing ───────────────────────────────────────────────────────────
# Usage: ./install.sh [--subset gate-only|core|full] /path/to/target-project
SUBSET=""
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --subset)       SUBSET="${2:-}"; shift 2 ;;
    --subset=*)     SUBSET="${1#--subset=}"; shift ;;
    -h|--help)
      echo "Usage: ./install.sh [--subset gate-only|core|full] /path/to/target-project"
      exit 0 ;;
    --*)
      echo "Unknown flag: $1" >&2
      echo "Usage: ./install.sh [--subset gate-only|core|full] /path/to/target-project" >&2
      exit 2 ;;
    *)
      if [ -z "$TARGET" ]; then TARGET="$1"; else
        echo "Unexpected positional arg: $1" >&2; exit 2
      fi
      shift ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "Usage: ./install.sh [--subset gate-only|core|full] /path/to/target-project" >&2
  exit 1
fi

if [ ! -d "$TARGET" ]; then
  echo "Target $TARGET does not exist"; exit 1
fi

# Validate subset value if provided
case "$SUBSET" in
  ""|gate-only|core|full) ;;
  *)
    echo "ERROR: --subset must be one of: gate-only, core, full (got: $SUBSET)" >&2
    exit 2 ;;
esac

# Resolve subset:
#   1. Explicit --subset wins.
#   2. Else inherit from existing .process-engine.yaml install.subset (re-install case).
#   3. Else default to "full" (no-surprise default — current behavior).
if [ -z "$SUBSET" ]; then
  EXISTING=$(read_subset_from_yaml "$TARGET/.process-engine.yaml")
  if [ -n "$EXISTING" ]; then
    SUBSET="$EXISTING"
  fi
fi
SUBSET="${SUBSET:-full}"

mkdir -p "$TARGET/.claude/agents"
mkdir -p "$TARGET/.claude/commands"
mkdir -p "$TARGET/docs/templates"
mkdir -p "$TARGET/docs/process-engine"
mkdir -p "$TARGET/scripts"
mkdir -p "$HOME/.claude/skills"

# Symlink agents (so engine upgrades propagate).
#
# Collision detection (E1.c.1, 2026-06-24): for each engine agent we
# install, check whether ~/.claude/agents/<name>.md exists as a regular
# file (not a symlink). If so, it will be silently SHADOWED in this
# project by the project-local symlink we are about to create, but
# OTHER projects without their own `pe install` will still resolve to
# the stale user-global file. The user needs to know.
#
# Real-world reproduction this guards against: the 8CStudio install
# ran at engine v0.1 (3 agents), so the other 11 agents shipped over
# v0.2-v0.7 lived only in ~/.claude/agents/ as pre-engine regular
# files. They silently shadowed all downstream engine evolution
# (including the E1 / E1.a gate-envelope contract) until E1.c re-ran
# `pe install` against 8CStudio. See docs/E1_b_SUBAGENT_MODEL_HONORING.md.
declare -a USER_GLOBAL_COLLISIONS=()
declare -a INSTALLED_AGENTS=()
declare -a SKIPPED_AGENTS=()
declare -a REMOVED_BROKEN=()
# Reconciliation split (E1.c.2):
#   - install.sh silently removes BROKEN symlinks (target vanished from engine —
#     e.g. operator switched engine branch and an agent was removed upstream).
#     Real files (operator customizations) are never touched.
#   - Subset-downgrade orphans (fine symlink to an agent no longer in the
#     current subset) stay a `pe sync` concern: interactive, prompted, per-file.
#     Not silent, because widening a subset back is common and clobbering
#     without confirmation would surprise the operator.
for f in "$ENGINE_DIR"/agents/*.md; do
  agent_name="$(basename "$f")"
  agent_stem="${agent_name%.md}"
  if ! agent_in_subset "$agent_stem" "$SUBSET"; then
    SKIPPED_AGENTS+=("$agent_stem")
    continue
  fi
  user_global_path="$HOME/.claude/agents/$agent_name"
  if [ -e "$user_global_path" ] && [ ! -L "$user_global_path" ]; then
    # Regular file at ~/.claude/agents/<name>.md. Compare to the engine
    # version; only flag if they actually differ (no false positives
    # when the user-global file IS already engine content).
    if ! cmp -s "$f" "$user_global_path"; then
      USER_GLOBAL_COLLISIONS+=("$agent_name")
    fi
  fi
  ln -sf "$f" "$TARGET/.claude/agents/$agent_name"
  INSTALLED_AGENTS+=("$agent_stem")
done

# Reconcile broken agent symlinks (E1.c.2): remove project-local symlinks
# whose engine target no longer exists. Skip real files (customizations)
# and valid symlinks. Runs after the install loop so we only remove what
# THIS install didn't create.
for link in "$TARGET/.claude/agents"/*.md; do
  [ -L "$link" ] || continue      # skip real files (customizations)
  [ -e "$link" ] && continue      # skip valid symlinks
  rm "$link"
  REMOVED_BROKEN+=("agents/$(basename "$link")")
done

# Symlink commands
for f in "$ENGINE_DIR"/commands/*.md; do
  ln -sf "$f" "$TARGET/.claude/commands/$(basename "$f")"
done

# Reconcile broken command symlinks (E1.c.2): same shape as agents.
for link in "$TARGET/.claude/commands"/*.md; do
  [ -L "$link" ] || continue
  [ -e "$link" ] && continue
  rm "$link"
  REMOVED_BROKEN+=("commands/$(basename "$link")")
done

# Symlink skills (user-global — start-session / end-session apply across all
# projects and discover the current project's CLAUDE.md / MEMORY / quality
# calendar at runtime).
for skill_dir in "$ENGINE_DIR"/skills/*/; do
  skill_name="$(basename "$skill_dir")"
  mkdir -p "$HOME/.claude/skills/$skill_name"
  ln -sf "$skill_dir/SKILL.md" "$HOME/.claude/skills/$skill_name/SKILL.md"
done

# Symlink engine-owned scripts (currently just research_index.py for v0.3 RAG).
# Symlinked so engine upgrades propagate without project edit. If the
# project needs to fork it, replace the symlink with a real file.
for f in "$ENGINE_DIR"/scripts/research_index.py; do
  if [ -f "$f" ]; then
    ln -sf "$f" "$TARGET/scripts/$(basename "$f")"
  fi
done

# Append .gitignore entries for engine-managed paths if .gitignore exists
# and doesn't already contain them.
if [ -f "$TARGET/.gitignore" ]; then
  for pattern in "*.research-index.sqlite" ".process-engine.local.yaml"; do
    if ! grep -qF -- "$pattern" "$TARGET/.gitignore" 2>/dev/null; then
      echo "$pattern" >> "$TARGET/.gitignore"
    fi
  done
fi

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

# Persist the resolved subset to .process-engine.yaml so `pe sync` (and future
# `pe install` re-runs without --subset) honor the operator's choice. Update
# the existing value in place; append a new block if not present.
YAML="$TARGET/.process-engine.yaml"
if grep -qE '^install:' "$YAML" 2>/dev/null && \
   awk '/^install:/{f=1;next} f && /^  subset:/{found=1; exit} f && /^[^ ]/{exit} END{exit !found}' "$YAML"; then
  # BSD/GNU sed compatible in-place update
  sed -i.bak -E "s/^([[:space:]]+)subset:.*/\\1subset: $SUBSET/" "$YAML"
  rm -f "$YAML.bak"
else
  cat >> "$YAML" <<EOF

# Engine install metadata (written by pe install — read by pe sync)
install:
  subset: $SUBSET
EOF
fi

# Copy docs (project may edit — these are reference)
cp -r "$ENGINE_DIR"/docs/* "$TARGET/docs/process-engine/"

echo "✓ 8colors-process-engine v$(cat "$ENGINE_DIR/VERSION") installed to $TARGET"
echo "  Subset:    $SUBSET (${#INSTALLED_AGENTS[@]} agents installed, ${#SKIPPED_AGENTS[@]} skipped)"
if [ "${#SKIPPED_AGENTS[@]}" -gt 0 ]; then
  echo "             Skipped: ${SKIPPED_AGENTS[*]}"
  echo "             Re-run with --subset full to install everything."
fi
echo "  Agents:    $(ls "$TARGET/.claude/agents" | wc -l | tr -d ' ') symlinked → $TARGET/.claude/agents/"
echo "  Commands:  $(ls "$TARGET/.claude/commands" | wc -l | tr -d ' ') symlinked → $TARGET/.claude/commands/"
if [ "${#REMOVED_BROKEN[@]}" -gt 0 ]; then
  echo "  Reconciled: ${#REMOVED_BROKEN[@]} broken symlink(s) removed (${REMOVED_BROKEN[*]})"
fi
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

# Report user-global agent collisions (E1.c.1).
#
# These are agents where ~/.claude/agents/<name>.md exists as a
# regular file that differs from the engine version. The project
# we just installed into is FINE (its project-local symlink wins),
# but every OTHER project that hasn't run `pe install` is still
# resolving the stale user-global copy. That's a silent shadow we
# don't want beta testers to discover the hard way.
if [ "${#USER_GLOBAL_COLLISIONS[@]}" -gt 0 ]; then
  echo ""
  echo "⚠  USER-GLOBAL AGENT COLLISIONS DETECTED (${#USER_GLOBAL_COLLISIONS[@]} files)"
  echo ""
  echo "  These regular files in ~/.claude/agents/ DIFFER from the engine"
  echo "  versions of the same agents. For THIS project they are now"
  echo "  shadowed by the project-local symlinks we just created. But for"
  echo "  any OTHER project without project-local symlinks, Claude Code"
  echo "  will still resolve to the stale user-global copies — silently."
  echo ""
  echo "  Affected agents:"
  for name in "${USER_GLOBAL_COLLISIONS[@]}"; do
    echo "    - ~/.claude/agents/$name"
  done
  echo ""
  echo "  Recommended actions (pick one per agent or apply all):"
  echo "    1. Run 'pe install' in every other project that should use the"
  echo "       engine versions of these agents."
  echo "    2. Diff each user-global file against the engine equivalent."
  echo "       If it has no operator customizations beyond the engine:"
  echo "         diff ~/.claude/agents/<name>.md \\"
  echo "              \"$ENGINE_DIR/agents/<name>.md\""
  echo "         rm ~/.claude/agents/<name>.md   # falls through to engine"
  echo "    3. Run 'pe doctor' in any project to enumerate this for that"
  echo "       project's perspective."
  echo ""
  echo "  Why this matters: this is the propagation gap that hid the E1"
  echo "  gate-envelope contract from Claude Code at runtime for several"
  echo "  hours of debugging. See docs/E1_b_SUBAGENT_MODEL_HONORING.md."
fi

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
echo "  4. (Optional) Set up RAG over docs/research/:"
echo "       export GEMINI_API_KEY=AIza...   # free key at aistudio.google.com/apikey"
echo "       pip install numpy google-generativeai"
echo "       python3 $TARGET/scripts/research_index.py rebuild"
echo "     brief-writer + architect agents will consult the index in their Step 0."
