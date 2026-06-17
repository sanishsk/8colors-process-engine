# Installing 8colors-process-engine

## Prerequisites

- macOS, Linux, or Windows with bash (macOS launchd templates are
  macOS-only; the agents/skills/commands work on any platform)
- Claude Code 2.x or later (`claude --version` to check)
- Target project has a `docs/` directory and a `.claude/` directory (or
  one will be created)
- Python 3.x (used by `install_launchd.sh` for minimal YAML parsing)

## v0.2.0 Quick install

```bash
# 1. Clone the engine
cd ~/Documents
git clone https://github.com/sanishsk/8colors-process-engine.git

# 2. Install core (agents + skills + commands + templates)
cd 8colors-process-engine
./scripts/install.sh /path/to/your-project

# 3. Restart Claude Code in the target project.

# 4. Verify agents loaded
#    In Claude Code: > what agents are available?
#    Expected: architect, brief-writer, ceo, code-reviewer, doc-updater,
#              planner, researcher, security-reviewer, tdd-guide

# 5. Verify skills loaded
#    In Claude Code: > /start-session
#    Should produce an orientation report.
```

## v0.2.0 Optional: wire CEO weekly retro (macOS only)

```bash
# 1. Edit project config
$EDITOR /path/to/your-project/.process-engine.yaml
# Set:
#   project.org_tag: your-org    # lowercase, alphanumeric + dash
#   project.root: /absolute/path/to/project
#   ceo_weekly.enabled: true     # default

# 2. Render + place launchd plists
./scripts/install_launchd.sh /path/to/your-project

# 3. Load the LaunchAgents (operator runs explicitly — installer prints these)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.weekly.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.heartbeat.plist

# 4. Verify
launchctl list | grep ceo
~/.local/bin/<org>-ceo/run_weekly.sh --force   # dry-run, bypasses Friday gate

# 5. Production cadence: Friday 17:00, every week, auto.
# Heartbeat watchdog fires every 3 days; if last_run > 8 days, you get
# a macOS notification + docs/dev-log/CEO_STALE.md is written.
```

## What gets installed where

| Artifact | Source in engine | Destination | Mechanism |
|---|---|---|---|
| Agents | `agents/*.md` | `<project>/.claude/agents/` | Symlink (upgrades propagate) |
| Commands | `commands/*.md` | `<project>/.claude/commands/` | Symlink |
| Skills | `skills/*/SKILL.md` | `~/.claude/skills/<name>/` | Symlink (user-global) |
| Templates (docs) | `templates/*.md` | `<project>/docs/templates/` | Copy (project may edit) |
| Engine config | `templates/process-engine.yaml.template` | `<project>/.process-engine.yaml` | Copy (only if absent) |
| Engine docs | `docs/*` | `<project>/docs/process-engine/` | Copy |
| launchd plists | `templates/launchd/*.plist.template` | `~/Library/LaunchAgents/` | Rendered |
| launchd wrappers | `templates/launchd/*.sh.template` | `~/.local/bin/<org>-ceo/` | Rendered |

## Updating

```bash
cd 8colors-process-engine
git pull origin master

# Agents + commands + skills auto-update via symlinks (next Claude Code
# session picks up changes).

# Re-run if:
#  - new skills or commands were added since last install
#  - templates schema changed (copy is idempotent and skips files that exist)
./scripts/install.sh /path/to/your-project

# Re-run if launchd templates changed (e.g. changed model, changed schedule)
./scripts/install_launchd.sh /path/to/your-project
```

## Uninstalling (manual for v0.2; auto-script in v0.3)

```bash
# Unload launchd agents (macOS)
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.weekly.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.heartbeat.plist

# Remove rendered files (macOS)
rm -f ~/Library/LaunchAgents/com.<org>.ceo.weekly.plist
rm -f ~/Library/LaunchAgents/com.<org>.ceo.heartbeat.plist
rm -rf ~/.local/bin/<org>-ceo
rm -rf ~/Library/Logs/<org>-ceo

# Remove symlinks (project-level)
rm -f /path/to/project/.claude/agents/{architect,brief-writer,ceo,code-reviewer,doc-updater,planner,researcher,security-reviewer,tdd-guide}.md
rm -f /path/to/project/.claude/commands/{brainstorm,lock-backlog,weekly-retro}.md

# Remove user-global skill symlinks
rm -rf ~/.claude/skills/start-session
rm -rf ~/.claude/skills/end-session

# Remove docs + config
rm -rf /path/to/project/docs/process-engine
rm -f  /path/to/project/.process-engine.yaml
# Templates in docs/templates/ may be kept or deleted at your discretion.
```

## Troubleshooting

**Agents not appearing in Claude Code's agent list after install:**
- Restart Claude Code (full quit + reopen, not just window close)
- Verify symlinks resolve: `ls -la <project>/.claude/agents/` — broken
  symlinks show as red on `ls -la` output
- Check `~/.claude/agents/` for shadowing user-level agents with the same name

**Skills not appearing:**
- Restart Claude Code
- Check `~/.claude/skills/start-session/SKILL.md` and
  `~/.claude/skills/end-session/SKILL.md` resolve to the engine repo
- User-global skills appear in every project — no per-project config needed

**CEO weekly retro not firing on Friday:**
- `launchctl list | grep ceo` — must show both `com.<org>.ceo.weekly`
  and `com.<org>.ceo.heartbeat` with exit code 0
- `tail ~/Library/Logs/<org>-ceo/launchd.error.log` for launchd-level errors
- `tail ~/Library/Logs/<org>-ceo/run-*.log` for the most recent run output
- Manually fire: `~/.local/bin/<org>-ceo/run_weekly.sh --force`
- macOS TCC: if the wrapper exits with code 126, the wrapper script
  itself was moved into a TCC-protected directory (`~/Documents`,
  `~/Desktop`, `~/Downloads`). Move it back to `~/.local/bin/<org>-ceo/`.

**`install_launchd.sh` says "claude CLI not found on PATH":**
- The launchd job runs without your shell PATH. The installer captures
  the absolute path to `claude` at install time. If you reinstall
  Claude Code in a new location, re-run `install_launchd.sh`.
