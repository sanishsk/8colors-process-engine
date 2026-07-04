# 8colors-process-engine

> **Process discipline for Claude Code, made portable.**
> Opinionated agents, skills, commands, and automation that force
> brief-before-code, async OSS scouting, mandatory code review, TDD,
> semantic search over prior research, and a weekly retro cadence —
> into any project, in one install.

[![version](https://img.shields.io/badge/version-0.42.0-blue)](VERSION)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)](#platform-support)

---

## Why this exists

You start a feature on Monday. By Wednesday Claude has implemented
something solid. By Friday you realize the brief locked in `Workbox`
on Tuesday and Claude hand-rolled an equivalent on Wednesday because
the planner doc never mentioned it.

That's the "Workbox-miss class" — and it's just one of a half-dozen
process gaps that compound when you ship features with AI agents
across multiple sessions.

This engine is **the accumulated workflow patterns of one production
project** (`8CStudio`, a videography invoice + production system with
75+ tables, 18 modules, a year of shipped slots), extracted into a
plugin any Claude Code project can install in 30 seconds.

It's opinionated. It assumes you want:

- **Brief before code.** Every non-trivial feature passes through a
  one-page brief with alternatives + market check.
- **OSS-first.** Search before building. Document the search.
- **Code review at every commit.** Mandatory, not optional. CRITICAL
  blocks, HIGH addressed unless skip-reason logged.
- **TDD when applicable.** Tests first. 80%+ coverage. Verified.
- **Weekly retro.** Friday 17:00, automatic, every week. CEO agent
  reads dev-log, Sentry, backlog. Writes next week's plan.
- **Semantic memory.** Prior briefs, architect docs, and planner
  artifacts are searchable. Slot pickups don't re-derive decisions.

If you'd rather have a flexible toolkit and decide-per-feature, this
isn't for you. If you'd rather have rails that fail loud when
skipped, read on.

---

## Install in 30 seconds

```bash
git clone https://github.com/sanishsk/8colors-process-engine.git ~/.local/share/8colors-process-engine
ln -s ~/.local/share/8colors-process-engine/scripts/pe ~/.local/bin/pe   # ensure ~/.local/bin is on $PATH

pe install /path/to/your/project
```

Restart Claude Code in `your-project`. You now have:

- 19 specialist agents (or a leaner set via `pe install --subset gate-only|core`)
- 9 slash commands
- 2 session skills (`/start-session`, `/end-session`)
- Semantic search over `docs/research/`
- An opinionated set of templates

**Optional one-liner extras:**

```bash
pe launchd /path/to/your/project   # macOS only — Friday 17:00 auto-retro
```

That wires a Friday 17:00 launchd job that runs the CEO agent
headless and writes `docs/dev-log/weekly-plan-YYYY-W<NN>.md` to your
project. Forever. With a 3-day heartbeat watchdog that notifies you
if the cadence breaks.

---

## What you get

### Agents (19)

| Agent | Model | When |
|---|---|---|
| `architect` | Opus | System design, scalability, architectural decisions. Consults `docs/research/` first. |
| `brief-writer` | Sonnet | 1-page briefs with alternatives + market check. Consults `docs/research/` first. |
| `build-error-resolver` | Sonnet | Multi-stack (TS/Py/Go/Rust/Java) build + type-error resolution. Minimal diffs. |
| `ceo` | Opus | Weekly retro + next-week plan. Auto-fires Fridays via launchd. |
| `code-reviewer` | Haiku | MANDATORY review before commit. CRITICAL blocks. Envelope-contract gate. |
| `data-model-auditor` | Haiku | Finds hardcoded business values; recommends moving to data model / config. |
| `database-reviewer` | Sonnet | Generic Postgres + multi-tenant SaaS reviewer (tenant isolation, migrations, query safety). |
| `design-critic` | Sonnet | MANDATORY design review before UI commits. AI-aesthetic tells + hierarchy/density/tabular-nums/empty-state/responsive rubric. Envelope-contract gate. |
| `doc-updater` | Haiku | Documentation + codemap maintenance. Multi-stack feature-detect. |
| `e2e-runner` | Sonnet | End-to-end testing (Playwright / Vercel Agent Browser). Artifact management. |
| `memory-consolidator` | Sonnet | Extracts durable memory from session transcripts. |
| `planner` | Opus | Complex features, refactoring, multi-step implementation plans. |
| `project-kickstarter` | Opus | Scaffolds new projects — structure, tests, lint, CLAUDE.md, rules. |
| `project-onboarder` | Opus | Analyzes existing projects against standard rules; generates + applies improvement plan. |
| `researcher` | Sonnet | OSS/MCP scout. Runs async, parallel with implementation. |
| `retrospective-agent` | Sonnet | Daily/weekly/monthly retro. Degrades gracefully when dev-log absent. |
| `security-reviewer` | Sonnet | Auth, user input, secrets, OWASP top 10. Envelope-contract gate. |
| `tdd-guide` | Sonnet | Executable state machine — Phase 0 stack detect → RED → GREEN → REFACTOR → COVERAGE. |
| `tenant-isolation-auditor` | Haiku | Scans recent git history for SQL crossing tenant boundaries without RLS context. |

### Skills (2, user-global)

- **`/start-session`** — at session start, reads CLAUDE.md, MEMORY,
  weekly plan, quality calendar. Surfaces active focus, stale plans,
  overdue tasks, blockers. Recommends the first task. Waits for your
  decision.
- **`/end-session`** — at session end, surfaces git status, sync
  state, MEMORY banner updates, commits ledger, next-session pickup
  pointer. Never auto-commits or auto-edits MEMORY.

Both project-agnostic; tweak via `.claude/session.yaml` per project.

### Commands (4)

- **`/brainstorm [topic]`** — capture brainstorm → produce 1-page brief
- **`/lock-backlog [phase]`** — lock a phase backlog (read-only audit trail)
- **`/research-search [query]`** — semantic search over `docs/research/`
- **`/weekly-retro`** — Friday retro + next-week plan

### RAG over `docs/research/`

`scripts/research_index.py` — local SQLite index with **4 swappable
embedding providers**. Solves the "Workbox-miss class" by surfacing
relevant prior briefs, architect docs, planner artifacts before
drafting. `brief-writer` + `architect` agents consult it in their
Step 0.

| Provider | API key? | Quality | Cost |
|---|---|---|---|
| **`fastembed`** (default) | None | Good for ≤10k docs | $0, runs offline |
| `voyage` | `VOYAGE_API_KEY` | Best recall (Anthropic-recommended) | Free credit + paid |
| `gemini` | `GEMINI_API_KEY` | Good | Free tier + paid |
| `openai` | `OPENAI_API_KEY` | Good | Cheap paid |

Adopters get a working RAG with **zero signups** by default. Power
users switch via one line in `.process-engine.yaml`. Validated on
8CStudio's Wave 1M.3 corpus — Workbox brief surfaces at cosine 0.73
in ≤10s of CPU, no network calls.

- Zero infra (SQLite).
- Zero API keys (fastembed default).
- Sub-second query on ≤100k chunks.
- Sha256-incremental rebuild.

Full doctrine: [`docs/RAG.md`](docs/RAG.md).

### Launchd templates (macOS)

`templates/launchd/` — plist + wrapper templates for the CEO weekly
retro. TCC-safe wrappers in `~/.local/bin/<org>-ceo/`. Rendered from
`.process-engine.yaml` at install time.

Linux/Windows: use cron / systemd / Task Scheduler with the wrapper
scripts. See [`docs/RHYTHM.md`](docs/RHYTHM.md).

### Doctrine docs

- [`docs/OSS_SEARCH_ORDER.md`](docs/OSS_SEARCH_ORDER.md) — the 5 rules of OSS-first
- [`docs/RHYTHM.md`](docs/RHYTHM.md) — weekly cadence (Mon brainstorm, Fri retro)
- [`docs/AGENT_INVOCATION_RULES.md`](docs/AGENT_INVOCATION_RULES.md) — slot-type → agent-chain matrix
- [`docs/RAG.md`](docs/RAG.md) — semantic search architecture + tradeoffs

---

## Before / after — a concrete example

### Before the engine

> *Sanish picks up Wave 1M.3 on Monday. Reads the planner doc — it
> says "build offline write queue + per-entity appliers". Spends 3
> days hand-rolling a sync solution. On Friday during code review,
> Claude notices the Wave 1M.3 brief from 3 weeks ago had locked in
> `Workbox 7.4.1`. Sanish reverts 600 lines of code. (Real incident,
> 2026-05-28.)*

### After the engine

> *Sanish picks up Wave 1M.3 on Monday. Types `/start-session`. The
> orientation surfaces "next task: Wave 1M.3 — pickup protocol says
> read brief → architect → planner in this order." Sanish opens the
> brief and immediately sees `Workbox 7.4.1`. Or — Sanish invokes
> `brief-writer` for a new wave; its Step 0 runs
> `/research-search "workbox dexie offline"` and finds the prior
> brief automatically. The Workbox-miss class is structurally
> closed.*

---

## CLI reference

```bash
pe install <project>     # Install agents/commands/skills/scripts into project
pe launchd <project>     # Wire macOS launchd weekly retro (macOS only)
pe upgrade               # git pull the engine; symlinks auto-propagate
pe status                # Show engine version, last commit, inventory
pe doctor [<project>]    # Diagnose install (broken symlinks, missing deps)
pe version               # Print engine version
pe help [<subcommand>]   # Show help
```

`pe install` is idempotent — re-run after upgrades or after adding
new files. `pe upgrade` will tell you when re-install is needed.

---

## Configuration

### `.process-engine.yaml` (per-project)

Created by `pe install` if absent. Controls launchd org tag, weekly
retro schedule, Sentry MCP settings, skill install location. Minimal:

```yaml
schema_version: 1
project:
  org_tag: acme              # used in launchd labels: com.acme.ceo.weekly
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

Full schema in [`templates/process-engine.yaml.template`](templates/process-engine.yaml.template).

### `.claude/session.yaml` (per-project, optional)

Customizes the `/start-session` and `/end-session` skills. Useful for
adding project-specific orientation steps (e.g. a Sentry MCP check on
the latest release SHA). Schema documented in the skill SKILL.md files.

---

## Platform support

| Feature | macOS | Linux | Windows |
|---|---|---|---|
| Agents + commands + skills | ✅ | ✅ | ✅ |
| `/research-search` (RAG) | ✅ | ✅ | ✅ |
| `pe install` + `pe upgrade` | ✅ | ✅ | bash needed |
| `pe launchd` (weekly retro) | ✅ launchd | ✅ systemd / cron | ✅ Task Scheduler |
| Session skills | ✅ | ✅ | ✅ |
| Pre-commit hooks (`hooks/`) | ✅ | ✅ | ✅ (Git Bash / WSL) |
| `pe eject` (uninstall) | ✅ | ✅ | ✅ (Git Bash / WSL) |

Cross-platform scheduler templates ship in `templates/systemd/`,
`templates/cron/`, and `templates/windows-task-scheduler/`. macOS
launchd is wired automatically via `pe launchd`; other platforms
follow the README in each template directory.

---

## Adopting incrementally

Don't have to flip everything at once.

| Want only this | Run |
|---|---|
| Just session skills | `pe install <project>` then never invoke other agents |
| Just RAG | `pe install <project>` + `pip install fastembed numpy` + `python3 scripts/research_index.py rebuild` (no API key needed) |
| Just weekly retro | `pe install <project>` + `pe launchd <project>` |
| Just code-reviewer | `pe install <project>` then invoke `code-reviewer` agent before commits |

Each piece works standalone. The full doctrine compounds when you use
them together, but no piece is a hard dep of another.

---

## Updating

```bash
pe upgrade
```

Symlinks auto-propagate engine changes to all installed projects. If
new commands or skills were added, `pe upgrade` tells you and asks
you to re-run `pe install <project>` for each project to pick them up.

---

## Uninstalling

Manual for now (auto `pe eject` lands in v0.4+):

```bash
# Unload launchd (macOS)
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.weekly.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.heartbeat.plist
rm -f ~/Library/LaunchAgents/com.<org>.ceo.*.plist
rm -rf ~/.local/bin/<org>-ceo ~/Library/Logs/<org>-ceo

# Remove project install
rm -f <project>/.claude/agents/{architect,brief-writer,ceo,code-reviewer,doc-updater,planner,researcher,security-reviewer,tdd-guide}.md
rm -f <project>/.claude/commands/{brainstorm,lock-backlog,research-search,weekly-retro}.md
rm -f <project>/scripts/research_index.py
rm -f <project>/.process-engine.yaml
rm -rf <project>/docs/process-engine

# Remove user-global skills
rm -rf ~/.claude/skills/start-session ~/.claude/skills/end-session
```

See [`INSTALL.md`](INSTALL.md) for the full uninstall walkthrough.

---

## Roadmap

- v0.1 — 3 agents (brief-writer, researcher, ceo), 3 commands, templates, docs ✅
- v0.2 — 6 more agents, start-session + end-session skills, launchd templates, `.process-engine.yaml` config ✅
- v0.3 — RAG over `docs/research/*` via SQLite + Gemini embeddings, `/research-search`, brief-writer + architect Step-0 wiring ✅
- v0.4 — `pe` unified CLI, public-launch README, CHANGELOG, CONTRIBUTING ✅
- v0.5 — Multi-provider embeddings (fastembed default + voyage / gemini / openai); zero-API-key adopter path ✅
- v0.6 — `hooks/` directory (5 generalized pre-commit hooks) + `pe eject` + Linux systemd / cron / Windows Task Scheduler templates ✅
- v0.7 — Domain agents (data-model-auditor, build-error-resolver, e2e-runner, retrospective-agent) + memory-consolidator agent + `/memory-consolidate` command + CI gate template + stacking-rule pre-push hook ✅
- v0.8 — Distribution bundle: `pe sync` (diff-before-clobber), `pe install --subset`, version-aware `pe doctor`, PATH check ✅
- **v0.9 (current)** — Reconciling `pe install` (silent broken-symlink cleanup) ✅
- v1.0 — Plugin marketplace publication + Anthropic Skills marketplace listing

---

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Short version:

1. New agent → add `agents/<name>.md` with frontmatter (`name`, `description`, `model`, `tools`). Open a PR with the use case.
2. New command → add `commands/<name>.md`. Same format.
3. New skill → add `skills/<name>/SKILL.md`. Mark `install_user_global` semantics in the description.
4. Doctrine doc → add to `docs/` and link from the README.

Bug reports + adoption feedback welcome via GitHub issues.

---

## License

MIT. Originated at [8Colors](https://8cs.io) by Sanish, extracted
from the `8CStudio` project's accumulated workflow patterns.
