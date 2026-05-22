# Installing 8colors-process-engine

## Prerequisites

- Claude Code 1.x or later installed
- Target project has a `docs/` directory
- Target project has a `.claude/` directory (or one will be created)

## Steps

1. Clone the engine:
   ```bash
   cd /Users/sanishsasikumar/Documents/8Colors/
   git clone https://github.com/sanishsk/8colors-process-engine.git
   ```

2. Install into target project:
   ```bash
   cd 8colors-process-engine
   ./scripts/install.sh /Users/sanishsasikumar/Documents/8Colors/8CStudio
   ```

3. Restart Claude Code in the target project.

4. Verify agents loaded:
   ```
   > what agents do you have available?
   ```
   You should see `brief-writer`, `researcher`, `ceo` in the list.

5. Verify commands loaded:
   ```
   > /brainstorm test
   ```
   Command should respond.

## Updating

```bash
cd 8colors-process-engine
git pull origin master
# Symlinks auto-pick up new agent definitions on next Claude Code session
```

## Uninstalling (manual for v0.1; auto-script in v0.3)

```bash
rm /path/to/project/.claude/agents/brief-writer.md
rm /path/to/project/.claude/agents/researcher.md
rm /path/to/project/.claude/agents/ceo.md
rm /path/to/project/.claude/commands/brainstorm.md
rm /path/to/project/.claude/commands/lock-backlog.md
rm /path/to/project/.claude/commands/weekly-retro.md
rm -rf /path/to/project/docs/process-engine
# Templates in docs/templates/ may be kept or deleted at your discretion
```
