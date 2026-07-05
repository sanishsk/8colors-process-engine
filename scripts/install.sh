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
# nullglob so `*.md` expands to nothing when the directory is empty —
# without this, an empty `.claude/agents/` would iterate the literal
# glob string as a filename (P2.8).
shopt -s nullglob 2>/dev/null || true
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Source preset rosters + yaml subset reader (shared with pe sync).
# shellcheck source=./_subset.sh
. "$ENGINE_DIR/scripts/_subset.sh"

# Source shared YAML reader (P2.6).
# shellcheck source=./_yaml.sh
. "$ENGINE_DIR/scripts/_yaml.sh"

# Source hook-install helpers (P1.4).
# shellcheck source=./_hooks.sh
. "$ENGINE_DIR/scripts/_hooks.sh"

# ─── Arg parsing hook flags (P1.4) ────────────────────────────────────────
# --no-claude-hooks — skip the .claude/settings.json merge
# --no-git-hooks    — skip .pre-commit-config.yaml + pre-commit install
# --no-ponytail     — skip Ponytail decision-ladder skill install (A5:
#                     Ponytail is default-on as of v0.23.0 — the ~54%
#                     LOC-reduction / 100%-safety-hold evals make it a
#                     universal prerequisite for code-writing work,
#                     not a flag. --with-ponytail is retained as a
#                     no-op for backward compatibility with older
#                     install scripts).
NO_CLAUDE_HOOKS=0
NO_GIT_HOOKS=0
WITH_PONYTAIL=1

# ─── Arg parsing ───────────────────────────────────────────────────────────
# Usage: ./install.sh [--subset gate-only|core|full] /path/to/target-project
SUBSET=""
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --subset)       SUBSET="${2:-}"; shift 2 ;;
    --subset=*)     SUBSET="${1#--subset=}"; shift ;;
    --no-claude-hooks) NO_CLAUDE_HOOKS=1; shift ;;
    --no-git-hooks)    NO_GIT_HOOKS=1; shift ;;
    --no-ponytail)     WITH_PONYTAIL=0; shift ;;
    --with-ponytail)   WITH_PONYTAIL=1; shift ;;  # back-compat no-op — default is now on
    -h|--help)
      echo "Usage: ./install.sh [--subset gate-only|core|full] [--no-claude-hooks] [--no-git-hooks] [--no-ponytail] /path/to/target-project"
      exit 0 ;;
    --*)
      echo "Unknown flag: $1" >&2
      echo "Usage: ./install.sh [--subset ...] [--no-claude-hooks] [--no-git-hooks] [--no-ponytail] /path/to/target-project" >&2
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

# Re-validate AFTER resolution — a typo or quoted value in the yaml
# (e.g. subset: ful, subset: "core") would otherwise make agent_in_subset
# reject every agent and install ZERO agents while reporting "skipped".
case "$SUBSET" in
  gate-only|core|full) ;;
  *)
    echo "ERROR: install.subset in $TARGET/.process-engine.yaml is invalid" >&2
    echo "  (got: '$SUBSET' — must be one of: gate-only, core, full, unquoted)" >&2
    exit 2 ;;
esac

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
declare -a PRESERVED_FORKS=()

# install_link ENGINE_SRC DST LABEL — symlink DST at ENGINE_SRC, but NEVER
# clobber a regular file that differs from the engine (an operator fork).
# ln -sf used to replace forks unconditionally — unrecoverable data loss,
# and it contradicted pe sync's diff-before-clobber contract for the same
# situation. Forks are preserved; `pe sync` reviews them interactively.
install_link() {
  local engine_src="$1" dst="$2" label="$3"
  if [ -e "$dst" ] && [ ! -L "$dst" ] && ! cmp -s "$engine_src" "$dst"; then
    PRESERVED_FORKS+=("$label")
    return 0
  fi
  ln -sf "$engine_src" "$dst"
}
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
  # Skip _-prefixed files — these are spec documents (e.g.
  # _gate-contract.md), not runnable agents.
  case "$agent_stem" in _*) continue ;; esac
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
  install_link "$f" "$TARGET/.claude/agents/$agent_name" "agents/$agent_name"
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
  install_link "$f" "$TARGET/.claude/commands/$(basename "$f")" "commands/$(basename "$f")"
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
  install_link "$skill_dir/SKILL.md" "$HOME/.claude/skills/$skill_name/SKILL.md" "skills/$skill_name/SKILL.md"
done

# Symlink engine-owned scripts (currently just research_index.py for v0.3 RAG).
# Symlinked so engine upgrades propagate without project edit. If the
# project needs to fork it, replace the symlink with a real file.
for f in "$ENGINE_DIR"/scripts/research_index.py; do
  if [ -f "$f" ]; then
    install_link "$f" "$TARGET/scripts/$(basename "$f")" "scripts/$(basename "$f")"
  fi
done

# Append .gitignore entries for engine-managed paths. Create the file
# if absent (P2.8 — previously silently skipped, leaving the
# research-index .sqlite committed by default in fresh projects).
if [ ! -f "$TARGET/.gitignore" ]; then
    touch "$TARGET/.gitignore"
fi
for pattern in "*.research-index.sqlite" ".process-engine.local.yaml" ".claude/gates/"; do
    if ! grep -qF -- "$pattern" "$TARGET/.gitignore" 2>/dev/null; then
        echo "$pattern" >> "$TARGET/.gitignore"
    fi
done

# Copy templates (project may edit freely — no symlink)
for f in "$ENGINE_DIR"/templates/*.md; do
  if [ ! -f "$TARGET/docs/templates/$(basename "$f")" ]; then
    cp "$f" "$TARGET/docs/templates/$(basename "$f")"
  fi
done

# Copy complexity/duplication/size config templates (v0.13.0 — P6.2/P5.4/P6.3).
# Dropped into docs/templates/complexity/ as read-only-ish references;
# operator promotes selectively into the project root (README in that dir
# explains the ladder). Copy is idempotent — never overwrites operator edits.
if [ -d "$ENGINE_DIR/templates/complexity" ]; then
    mkdir -p "$TARGET/docs/templates/complexity"
    for f in "$ENGINE_DIR"/templates/complexity/*; do
        [ -f "$f" ] || continue
        dst="$TARGET/docs/templates/complexity/$(basename "$f")"
        if [ ! -f "$dst" ]; then
            cp "$f" "$dst"
        fi
    done
fi

# Copy product-quality templates (v0.14.0 — P5.3, P5.5, P5.6, P5.8).
# Design lint config + E2E smoke spec + confusion-budget test + auth
# robustness test template all land in docs/templates/. Adopter promotes
# each as needed.
for f in "$ENGINE_DIR/templates/design-lint.config.template"; do
    [ -f "$f" ] || continue
    dst="$TARGET/docs/templates/$(basename "$f")"
    [ -f "$dst" ] || cp "$f" "$dst"
done
if [ -d "$ENGINE_DIR/templates/e2e" ]; then
    mkdir -p "$TARGET/docs/templates/e2e"
    for f in "$ENGINE_DIR"/templates/e2e/*; do
        [ -f "$f" ] || continue
        dst="$TARGET/docs/templates/e2e/$(basename "$f")"
        [ -f "$dst" ] || cp "$f" "$dst"
    done
fi
if [ -d "$ENGINE_DIR/templates/tests" ]; then
    mkdir -p "$TARGET/docs/templates/tests"
    for f in "$ENGINE_DIR"/templates/tests/*; do
        [ -f "$f" ] || continue
        dst="$TARGET/docs/templates/tests/$(basename "$f")"
        [ -f "$dst" ] || cp "$f" "$dst"
    done
fi

# Copy design templates (v0.40.0 — D7 Style Dictionary + tokens seed;
# v0.41.0 — D8 SIGNATURE.md template; v0.45.0 — D3 reference-lock
# README template). These land in docs/templates/design/ as `.template`
# files; adopter renames (drops the .template suffix) and moves into
# the correct project path when ready to opt in. SIGNATURE.md remains
# .template so the D8 gate is inert until the adopter explicitly
# authors + moves the file to docs/design/SIGNATURE.md. Same for the
# D3 reference-README — the adopter promotes it to
# docs/design/reference/README.md to activate the visual-baseline-guard.
if [ -d "$ENGINE_DIR/templates/design" ]; then
    mkdir -p "$TARGET/docs/templates/design"
    for f in "$ENGINE_DIR"/templates/design/*; do
        [ -f "$f" ] || continue
        dst="$TARGET/docs/templates/design/$(basename "$f")"
        [ -f "$dst" ] || cp "$f" "$dst"
    done
fi

# Copy security templates (v0.17.0 — S1). semgrep allowlist starter +
# README explaining the SAST tool ladder.
if [ -d "$ENGINE_DIR/templates/security" ]; then
    mkdir -p "$TARGET/docs/templates/security"
    for f in "$ENGINE_DIR"/templates/security/*; do
        [ -f "$f" ] || continue
        dst="$TARGET/docs/templates/security/$(basename "$f")"
        [ -f "$dst" ] || cp "$f" "$dst"
    done
    # Dotfile allowlist template also lands (mkdir -p handled above)
    for f in "$ENGINE_DIR"/templates/security/.*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in .|..) continue ;; esac
        dst="$TARGET/docs/templates/security/$(basename "$f")"
        [ -f "$dst" ] || cp "$f" "$dst"
    done
fi

# Copy MCP registration templates (A9.1 — ai-testing-agent + future MCPs).
# The engine cataloges MCP servers gate agents consume; adopters
# merge the .mcp.json snippets into their project .mcp.json.
if [ -d "$ENGINE_DIR/templates/mcp" ]; then
    mkdir -p "$TARGET/docs/templates/mcp"
    for f in "$ENGINE_DIR"/templates/mcp/*; do
        [ -f "$f" ] || continue
        dst="$TARGET/docs/templates/mcp/$(basename "$f")"
        [ -f "$dst" ] || cp "$f" "$dst"
    done
fi

# Copy design + perf template dirs (v0.18.0 — D1/D2/PF3).
# axe-core config, Lighthouse budgets, backend p95 assertion template.
for d in design perf; do
    if [ -d "$ENGINE_DIR/templates/$d" ]; then
        mkdir -p "$TARGET/docs/templates/$d"
        for f in "$ENGINE_DIR"/templates/$d/*; do
            [ -f "$f" ] || continue
            dst="$TARGET/docs/templates/$d/$(basename "$f")"
            [ -f "$dst" ] || cp "$f" "$dst"
        done
    fi
done

# Copy Lighthouse CI workflow into ci/ template dir (shared with existing engine-gate/quality).
if [ -f "$ENGINE_DIR/templates/ci/lighthouse-ci.yml.template" ]; then
    mkdir -p "$TARGET/docs/templates/ci"
    dst="$TARGET/docs/templates/ci/lighthouse-ci.yml.template"
    [ -f "$dst" ] || cp "$ENGINE_DIR/templates/ci/lighthouse-ci.yml.template" "$dst"
fi

# ─── --with-ponytail (P6.1) ─────────────────────────────────────────
# Clone/refresh Ponytail decision-ladder skill into user-global skills
# directory. Idempotent: git pull if already present. Silently skips if
# git is missing (unlikely but graceful).
if [ "$WITH_PONYTAIL" -eq 1 ]; then
    PONY_DIR="$HOME/.claude/skills/ponytail"
    if ! command -v git >/dev/null 2>&1; then
        echo "  ⚠ Ponytail: git not on PATH — skipping (install git and re-run --with-ponytail)"
    else
        mkdir -p "$HOME/.claude/skills"
        if [ -d "$PONY_DIR/.git" ]; then
            if git -C "$PONY_DIR" pull --ff-only --quiet 2>/dev/null; then
                echo "  ✓ Ponytail: refreshed $PONY_DIR"
            else
                echo "  ⚠ Ponytail: could not fast-forward $PONY_DIR (local changes?) — left untouched"
            fi
        elif [ -e "$PONY_DIR" ]; then
            echo "  ⚠ Ponytail: $PONY_DIR exists but isn't a git checkout — left untouched"
        else
            if git clone --quiet --depth 1 \
                https://github.com/DietrichGebert/ponytail "$PONY_DIR" 2>/dev/null; then
                echo "  ✓ Ponytail: cloned to $PONY_DIR"
            else
                echo "  ⚠ Ponytail: clone failed (no network / repo moved?) — skipping"
            fi
        fi
    fi
fi

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

# Copy docs (project may edit — these are reference). Allowlist only —
# the previous `cp -r docs/*` shipped HANDOFF.md, BACKLOG.md, session
# notes, and IMPROVEMENT_PLAN.md into every adopter, which then got
# stomped on the next install (P2.8 fix).
DOC_ALLOWLIST=(
    "RHYTHM.md"
    "OSS_SEARCH_ORDER.md"
    "AGENT_INVOCATION_RULES.md"
    "CAPABILITY_CATALOG.md"
    "RAG.md"
    "TROUBLESHOOTING.md"
    "E1_GATE_ENVELOPE.md"
    "COUPLING_MAP.md"
    "PHASE_3_ESCALATION_ROUTER.md"
    "SKILLS.md"
    "EXECUTION_PATTERNS.md"
)
for doc in "${DOC_ALLOWLIST[@]}"; do
    src="$ENGINE_DIR/docs/$doc"
    dst="$TARGET/docs/process-engine/$doc"
    if [ -f "$src" ] && [ ! -f "$dst" ]; then
        cp "$src" "$dst"
    fi
done

# ─── Hook wiring (P1.4) ────────────────────────────────────────────────
# Only fire if the yaml opts in AND the flag doesn't override off.
# yaml_bool_get defaults to false when the yaml is absent — first-run
# projects still get hooks because the template ships with them set to
# true; existing installs whose yaml pre-dates v0.10.0 must add the block
# to opt in, which is the correct migration behavior.
YAML_FILE="$TARGET/.process-engine.yaml"
WANT_CLAUDE_HOOKS=$(yaml_bool_get hooks.claude_hooks_enabled "$YAML_FILE")
WANT_GIT_HOOKS=$(yaml_bool_get hooks.pre_commit_enabled "$YAML_FILE")

# Fresh installs (yaml just copied from template above) → both true.
# Legacy yamls (silently upgrading through re-install) stay off unless
# the operator flips them explicitly. Log both paths.
if [ "${CREATED_CONFIG:-0}" = "1" ]; then
    WANT_CLAUDE_HOOKS="true"
    WANT_GIT_HOOKS="true"
fi

if [ "$NO_CLAUDE_HOOKS" = "0" ] && [ "$WANT_CLAUDE_HOOKS" = "true" ]; then
    install_claude_hooks "$ENGINE_DIR" "$TARGET"
elif [ "$NO_CLAUDE_HOOKS" = "1" ]; then
    echo "  ⚠ Claude hooks: --no-claude-hooks — skipped"
fi

if [ "$NO_GIT_HOOKS" = "0" ] && [ "$WANT_GIT_HOOKS" = "true" ]; then
    install_git_hooks "$ENGINE_DIR" "$TARGET"
elif [ "$NO_GIT_HOOKS" = "1" ]; then
    echo "  ⚠ Git hooks: --no-git-hooks — skipped"
fi

# A8 pin file. Records the engine version + SHA the adopter was
# installed against, so `pe pin show|verify` can report drift on
# subsequent `pe upgrade` runs. Non-fatal: if the pin can't be
# written (permissions, missing python), the install still succeeds.
#
# The pin file is intentionally COMMITTED to the adopter's git repo —
# every teammate + CI run should see the same engine version the
# project was installed against. Do NOT add it to `.gitignore`.
ENGINE_VERSION=$(cat "$ENGINE_DIR/VERSION")
ENGINE_SHA=$(git -C "$ENGINE_DIR" rev-parse HEAD 2>/dev/null || echo "")
PIN_TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")
PIN_FILE="$TARGET/.claude/.engine-pin.json"
mkdir -p "$(dirname "$PIN_FILE")"
cat > "$PIN_FILE.tmp" <<EOF
{
  "engine_path": "$ENGINE_DIR",
  "engine_sha": "$ENGINE_SHA",
  "engine_version": "$ENGINE_VERSION",
  "install_mode": "symlink",
  "installed_at": "$PIN_TS"
}
EOF
mv "$PIN_FILE.tmp" "$PIN_FILE"

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
if [ "${#PRESERVED_FORKS[@]}" -gt 0 ]; then
  echo "  Preserved: ${#PRESERVED_FORKS[@]} customized file(s) NOT overwritten (${PRESERVED_FORKS[*]})"
  echo "             Run 'pe sync $TARGET' to review them against the engine versions."
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
