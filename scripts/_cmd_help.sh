#!/usr/bin/env bash
# _cmd_help.sh — sourced by scripts/pe. Not executable on its own.
#
# scripts/pe was 1506 lines against the engine's OWN size-budget hook, which
# blocks at max_file_lines=800. The gate had therefore been failing on every
# change to the engine's main dispatcher, and each one was made with
# PE_SKIP_SIZE_BUDGET=1. A bypass reached for routinely is a gate that has
# stopped working.
#
# Split by lifecycle stage, not by size: the help surface — usage() and
# help_subcommand(), which is per-subcommand help text and nothing else.
#
# Everything here relies on $ENGINE_DIR, $VERSION and pe_python(), all
# defined in scripts/pe before this file is sourced.

# ─── usage ──────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
pe — 8colors-process-engine CLI v$VERSION

USAGE
    pe <subcommand> [args]

SUBCOMMANDS
    install [--subset gate-only|core|full] <project>
                          Install agents/commands/skills/scripts into a project
                          (--subset controls which agents; default full)
    launchd <project>     Wire macOS launchd weekly CEO retro (macOS only)
    upgrade               git pull the engine; symlinks auto-propagate
    sync <project>        Re-point project symlinks at current engine (diff-before-clobber)
    status                Show engine version, last commit, install paths
    doctor [<project>]    Diagnose install (broken symlinks, missing deps)
    audit [--screens-only] Run gates across the WHOLE repo (not just staged) + agent-sweep cmds
    eject <project>       Remove engine-managed symlinks from a project (asks confirmation)
    baseline capture ...  Record a Phase 0 slot baseline (speed / size / quality)
    collect [<project>] [--window N] [--date YYYY-MM-DD]
                          Portable git-derived dev-log digest for retrospective-agent
                          (P7.3: replaces the ambient collector that went stale)
    skills-audit [--project <path>]
                          Inventory ~/.claude/skills/ + ~/.claude/commands/ sprawl;
                          flag duplicates + classify against engine core-20 (P7.4)
    telemetry <sub>       Parse Claude Code transcripts → structured usage
                          records + OTel spans + cost (A1/L1/L4). Subs:
                          collect, summary.
    agent run <name>      Invoke an engine agent headlessly via \`claude -p\`
                          with the agent's persona + a brief on stdin (A4).
    incident propose      Synthesize a gate proposal from one incident (A3).
                          Proposes only; never modifies the engine repo.
    incident list         List materialized proposals in the current project.
    memory <sub>          L3 auto-memory governance: ls / show / rm / verify /
                          stale. Inspect + prune ~/.claude/projects/<slug>/memory/.
    new <name> [--stack]  A6 scaffold — deterministic template drop + git init +
                          auto pe install. Stacks: python-flask (default), generic.
    module add <name>     A6 domain module — materialize a reusable module
                          (e.g. api-credentials) into <project>/modules/<name>/.
    gate parse <file>     Extract + validate gate-envelope JSON (E1)
    shadow decide ...     Phase 3 routing decision (enforce gated by --enforce; graduated 2026-06-28)
    shadow reconcile ...  Join shadow decisions for a slot to actual outcome
    version               Print engine version
    help [<subcommand>]   Show help

EXAMPLES
    pe install ~/code/myproject
    pe launchd ~/code/myproject
    pe upgrade
    pe status
    pe doctor ~/code/myproject
    pe eject ~/code/myproject

LEARN MORE
    Engine repo: https://github.com/sanishsk/8colors-process-engine
    Doctrine:    $ENGINE_DIR/docs/RHYTHM.md
EOF
}

help_subcommand() {
    case "${1:-}" in
        install)
            cat <<EOF
pe install [--subset gate-only|core|full] <project>

Symlinks engine agents, commands, skills, and scripts into the
target project. Idempotent — re-run after engine upgrades or after
adding new files.

Subset presets (controls which agents get symlinked; commands,
skills, and scripts are always installed):

  gate-only  5 gate agents only:
             code-reviewer, security-reviewer, database-reviewer,
             tdd-guide, e2e-runner.

  core       gate-only + planner + brief-writer + architect (8 agents).
             The smallest install that supports the brief → plan →
             implement → review pipeline.

  full       All engine agents. Default — current behavior, no-surprise.

Resolution order when --subset is omitted:
  1. The install: subset value already in .process-engine.yaml
     (preserves the choice from a prior install).
  2. "full" (default).

The resolved subset is persisted to .process-engine.yaml under
install.subset so pe sync honors the operator's choice on re-points.

What gets installed:
  - Agents        → <project>/.claude/agents/        (symlinked, subset-filtered)
  - Commands     → <project>/.claude/commands/      (symlinked)
  - Skills       → ~/.claude/skills/                 (symlinked, user-global)
  - research_index.py → <project>/scripts/           (symlinked)
  - .process-engine.yaml → <project>/                (copied if absent)
  - Templates    → <project>/docs/templates/         (copied)
  - Engine docs  → <project>/docs/process-engine/    (copied)

The script also appends *.research-index.sqlite +
.process-engine.local.yaml to <project>/.gitignore if not present.

Restart Claude Code in the target project after install.
EOF
            ;;
        sync)
            cat <<EOF
pe sync [--dry-run] [--yes] <project>

Re-points the project's engine-managed symlinks at the current engine.
The contract is DIFF-BEFORE-CLOBBER: a file that differs from the
engine version is NEVER overwritten without explicit confirmation.

Scope (per BACKLOG P1.2 confirmation B):
  - <project>/.claude/agents/<name>.md   (filtered by install.subset)
  - <project>/.claude/commands/<name>.md
  - <project>/scripts/research_index.py

For each engine-managed file, sync classifies the project state:
  current        symlink already points at this engine — silent skip
  stale-symlink  symlink points elsewhere — prompt to re-point
  matches        regular file, byte-identical to engine — silently upgrade to symlink
  differs        regular file, differs from engine — show diff + prompt y/N
  missing        in-subset agent has no file in project — silently re-add
  orphan         project has a symlink for an agent NOT in current subset — prompt to remove

Flags:
  --dry-run   Show what would change, write nothing.
  --yes       Auto-confirm prompts (re-points + orphan removals + diff overrides).
              Use sparingly — bypasses the diff-before-clobber gate for differing
              files. The default (interactive prompt) is the safe path.

Exit codes:
  0  Sync completed (some prompts may have been declined — that's OK)
  1  Project missing or .process-engine.yaml missing
  2  Invalid flag

Originally surfaced by Finding #4 (Origyn cross-environment test) —
the structural fix for stale-user-globals propagation across projects.
EOF
            ;;
        launchd)
            cat <<EOF
pe launchd <project>

Renders launchd template plists from <project>/.process-engine.yaml
and places them in ~/Library/LaunchAgents/ + wrapper scripts in
~/.local/bin/<org>-ceo/. Result: CEO weekly retro auto-fires every
Friday 17:00 local time.

Prerequisites:
  - macOS (launchd is macOS-only)
  - <project>/.process-engine.yaml with project.org_tag + project.root set
  - Python 3.x on PATH (for minimal YAML parsing)
  - 'claude' CLI on PATH (captured at install time)

After this command, you still need to bootstrap the plists into
launchd manually (the installer prints the commands). This is by
design — loading LaunchAgents touches the user's account state.

For Linux: use cron with the rendered run_weekly.sh wrapper.
For Windows: use Task Scheduler with the same wrapper (WSL or
adapted to PowerShell).
EOF
            ;;
        upgrade)
            cat <<EOF
pe upgrade

Runs 'git pull' in the engine directory. Because agents, commands,
skills, and scripts are symlinked from target projects to this repo,
the upgrade propagates to all installed projects automatically.

Cases where you should ALSO re-run 'pe install <project>' after upgrade:
  - New commands or skills were added in the new version
  - New scripts were added (e.g. research_index.py in v0.3)
  - .gitignore patterns changed

'pe upgrade' will tell you when this is needed by reporting any
new files in <engine>/agents/, /commands/, /skills/, /scripts/ since
the last upgrade.
EOF
            ;;
        status)
            cat <<EOF
pe status

Reports:
  - Engine version (from VERSION file)
  - Engine directory + git HEAD
  - Last commit date + author
  - Count of agents, commands, skills, scripts, templates

Use 'pe doctor <project>' to diagnose a specific install.
EOF
            ;;
        eject)
            cat <<EOF
pe eject <project>

Removes engine-managed symlinks from a project. Asks for confirmation
before deleting anything.

What gets removed:
  - <project>/.claude/agents/*.md      (only symlinks pointing at this engine)
  - <project>/.claude/commands/*.md    (same)
  - <project>/scripts/research_index.py

What gets kept:
  - .process-engine.yaml (project-edited config)
  - docs/templates/*     (copies the project may have customized)
  - docs/process-engine/ (reference docs)

What you remove manually (system-level, used by other projects):
  - ~/.claude/skills/{start,end}-session/
  - ~/Library/LaunchAgents/com.*.ceo.*.plist (macOS)
  - ~/.config/systemd/user/*-ceo-weekly.*  (Linux)
  - Windows scheduled tasks

The eject is reversible: 'pe install <project>' restores the symlinks.
EOF
            ;;
        doctor)
            cat <<EOF
pe doctor [<project>]

Without arguments: checks the engine repo itself (no broken refs).
With a project path: checks the symlinks in <project>/.claude/agents/,
<project>/.claude/commands/, <project>/scripts/, and ~/.claude/skills/
all resolve to live files in the engine.

Reports:
  - Broken symlinks (engine repo moved? files deleted?)
  - Missing engine files
  - Outdated symlinks (project has a file that's no longer in engine)
  - Required deps for the RAG (numpy, google-generativeai, GEMINI_API_KEY)
  - launchd job status (macOS only, if project has CEO weekly wired)
  - Hook reachability + coverage: how many of the engine's hooks this
    project is configured to run, and which it is not

FLAGS
  --json [<project>]   Machine-readable reachability + coverage report.
EOF
            ;;
        *)
            usage
            ;;
    esac
}
