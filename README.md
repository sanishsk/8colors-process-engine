# 8colors-process-engine

Portable Claude Code process engine. Agents, skills, commands, and
launchd templates that force brief-before-code discipline, async OSS
scouting, mandatory code review, write-tests-first TDD, and weekly retro
cadence into any project.

## What's in the box (v0.3.0)

**Agents (9):**

| Agent | Model | When |
|---|---|---|
| `architect` | Opus | System design, scalability, architectural decisions |
| `brief-writer` | Sonnet | 1-page briefs with alternatives + market check |
| `ceo` | Opus | Weekly retro + next-week plan |
| `code-reviewer` | Haiku | MANDATORY review before commit |
| `doc-updater` | Haiku | Documentation + codemap maintenance |
| `planner` | Opus | Complex features, refactoring, multi-step implementation plans |
| `researcher` | Haiku | OSS/MCP scout — runs async, parallel with impl |
| `security-reviewer` | Sonnet | Auth, user input, secrets, OWASP top 10 |
| `tdd-guide` | Sonnet | Write-tests-first methodology, 80%+ coverage |

**Skills (2):**

- `/start-session` — orient at session start (reads CLAUDE.md, MEMORY, weekly plan, quality calendar); waits for operator decision
- `/end-session` — close-out (git status, sync check, MEMORY banner update, deliverables ledger, next-session pickup)

Both are project-agnostic — they discover files at runtime and degrade
gracefully when optional context is absent. Per-project tweaks via
`.claude/session.yaml`.

**Commands (4):**

- `/brainstorm [topic]` — capture brainstorm → brief
- `/lock-backlog [phase]` — lock a phase backlog (read-only audit trail)
- `/research-search [query]` — semantic search over `docs/research/*` (v0.3)
- `/weekly-retro` — Friday retro + next-week plan

**RAG (v0.3):**

- `scripts/research_index.py` — local SQLite + Gemini-embedding index over
  `docs/research/*`. Solves the "Workbox-miss class" where slot pickup
  misses an OSS contract locked in a prior brief.
- `brief-writer` + `architect` agents call the index in their Step 0 to
  surface relevant prior decisions before drafting.
- Full doctrine: `docs/RAG.md`.

**Launchd templates (macOS):**

- `templates/launchd/com.<org>.ceo.weekly.plist.template` — Friday 17:00 trigger
- `templates/launchd/com.<org>.ceo.heartbeat.plist.template` — staleness watchdog
- `templates/launchd/run_weekly.sh.template` — TCC-safe wrapper for headless `claude -p /weekly-retro --force`
- `templates/launchd/check_heartbeat.sh.template` — writes `docs/dev-log/CEO_STALE.md` if `last_run > 8 days`

**Doctrine:**

- OSS-first search order (`docs/OSS_SEARCH_ORDER.md` — 5 rules, non-negotiable)
- Weekly rhythm (`docs/RHYTHM.md` — Mon brainstorm, Fri retro)
- Agent invocation rules per slot type (`docs/AGENT_INVOCATION_RULES.md`)

## Install

```bash
git clone https://github.com/sanishsk/8colors-process-engine.git
cd 8colors-process-engine
./scripts/install.sh /path/to/your-project
```

What gets installed:
- 9 agents symlinked → `<project>/.claude/agents/`
- 3 commands symlinked → `<project>/.claude/commands/`
- 2 skills symlinked → `~/.claude/skills/` (user-global)
- Templates copied → `<project>/docs/templates/`
- `.process-engine.yaml` template copied to project root (edit before launchd install)
- Engine docs copied → `<project>/docs/process-engine/`

Restart Claude Code in the target project. Agents, skills, and commands
load on next session.

## Optional: wire CEO weekly retro to launchd (macOS)

```bash
# Edit project's .process-engine.yaml — set project.org_tag and project.root
$EDITOR /path/to/project/.process-engine.yaml

# Render + place launchd plists
./scripts/install_launchd.sh /path/to/your-project

# Load the agents (operator runs these — installer does not auto-bootstrap)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.weekly.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.heartbeat.plist

# Dry-run to verify (bypasses Friday gate)
~/.local/bin/<org>-ceo/run_weekly.sh --force
```

Result: every Friday 17:00, the CEO agent writes
`docs/dev-log/weekly-plan-YYYY-W<NN>.md` + `retro-YYYY-W<NN>.md` to
your project — no human required. Heartbeat watchdog flags + notifies
if `last_run > 8 days`.

Linux + Windows adopters: use cron / systemd / Task Scheduler with the
wrapper scripts as-is. See `docs/RHYTHM.md` for cron equivalents.

## Configuration: `.process-engine.yaml`

Project-level config consumed by `install_launchd.sh` and (in future
versions) other engine installers. Schema documented in
`templates/process-engine.yaml.template`. Minimal:

```yaml
schema_version: 1
project:
  org_tag: acme              # ^[a-z][a-z0-9-]*$ — used in launchd labels
  display_name: "Acme Corp"
  root: "/Users/jane/code/acme"
  main_branch: master
ceo_weekly:
  enabled: true
  schedule: { weekday: 5, hour: 17, minute: 0 }
  staleness_days: 8
session_skills:
  install_user_global: true
```

## Update

```bash
cd 8colors-process-engine
git pull origin master
# Symlinks auto-pick up new agent definitions on next Claude Code session.
# Re-run ./scripts/install.sh <target> if new skills or templates were added.
# Re-run ./scripts/install_launchd.sh <target> if launchd templates changed.
```

## Roadmap

- v0.1 — 3 agents (brief-writer, researcher, ceo), 3 commands, templates, docs ✅
- v0.2 — 6 more agents (architect, code-reviewer, doc-updater, planner, security-reviewer, tdd-guide), start-session + end-session skills, launchd templates, `.process-engine.yaml` config schema ✅
- **v0.3 (current)** — RAG over `docs/research/*` via SQLite + Gemini embeddings, `/research-search` command, brief-writer + architect Step-0 wiring, `docs/RAG.md` doctrine ✅
- v0.4 — `hooks/` directory (pre-commit hooks generalized: design-review trailer, code-review trailer, docs-updated trailer, module-permissions block, `docs/research/` rebuild on staged change), `upgrade.sh`, `eject.sh`
- v0.5 — Linux + Windows scheduler templates (systemd + Task Scheduler) for the weekly retro
- v0.6 — Domain-specific agent extraction: data-model-auditor, database-reviewer, tenant-isolation-auditor (parameterized for the project's DB engine)
- v1.0 — Plugin marketplace publication + Anthropic Skills marketplace listing

## Project-level overrides

The engine ships opinions; projects bend them via:

- `.claude/session.yaml` — start/end-session skill customization (extra files to read, custom report sections, operating-mode defaults, skip-sections)
- `.process-engine.yaml` — engine-installer customization (org tag, project paths, Sentry org/project, weekly retro schedule)
- `.claude/agents/<agent>.md` — overwrite the symlink to ship a project-specific variant

## License

MIT. Originated at [8Colors](https://8cs.io) by Sanish, extracted from
the 8CStudio invoice-system project's accumulated workflow patterns.
