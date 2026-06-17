# 8colors-process-engine — beta tester brief

> Hand-out for the 2–3 beta cohort. Copy / paste / link as needed.

---

## TL;DR

I built **`8colors-process-engine`** — a portable Claude Code plugin
that drops 13 specialist agents, semantic search over your research
docs, a weekly retro cron job, 5 slash commands, 2 session skills,
and 6 pre-commit governance hooks into any project in **one install
command**. Defaults need **zero API keys**. MIT-licensed. I want
your hands on it for 2–4 weeks of real work, then I want to know
what broke, what was confusing, and what you expected that wasn't
there.

Repo: <https://github.com/sanishsk/8colors-process-engine>
Current version: **v0.7.0**

---

## What problem it actually solves

Most "AI agent toolkits" give you flexible kits. You decide per
feature what to use. That works for prototypes; it breaks under
sustained shipping pressure.

After about a year of shipping features in my own production
project ([8CStudio](https://8cs.io), a videography invoice +
production system), the same pattern kept costing me time:

- **Decisions in a brief from week 1 get lost by week 3** when I
  pick up a continuation slot and read only the planner doc. (Real
  incident: I hand-rolled an offline-sync layer because the
  planner doc didn't re-surface that the brief had locked in
  `Workbox` three weeks earlier. Reverted 600 lines.)
- **Code review at every commit is mandatory**, but easy to skip
  when you're alone and tired.
- **Memory drifts** as resume-pointer blocks accumulate and the
  auto-loaded `MEMORY.md` grows past 30 KB.
- **Weekly retros never happen** because nothing fires them, and a
  promise to "do it Fridays" is a promise to no one.

The engine is the structural fix. **Doctrine, not a kit.** It
ships opinionated rails that fail loud when skipped:

- **Brief before code** (via the `brief-writer` agent)
- **OSS-first** search before building (via the `researcher` agent)
- **Code review mandatory** (via the `code-reviewer` agent + a
  pre-commit hook that blocks ≥5-file commits without a
  `Code-reviewed:` trailer)
- **TDD when applicable** (via `tdd-guide`)
- **Semantic memory** so prior decisions aren't lost (via local
  RAG over `docs/research/`)
- **Weekly retro auto-fires** Friday 17:00 (via launchd / systemd
  / Task Scheduler)

If that doctrine isn't what you want, fork it. I won't water it
down for adoption.

---

## What's in the box (v0.7.0 inventory)

### 13 specialist agents

Each has a single job, a model tier matched to that job, and
explicit when-to-invoke rules:

| Agent | Model | Job |
|---|---|---|
| `brief-writer` | Sonnet | 1-page brief with alternatives + market check; required before non-trivial work |
| `researcher` | Haiku | OSS / MCP scout; runs async, parallel with implementation |
| `architect` | Opus | System design, scalability, integration patterns |
| `planner` | Opus | Multi-slot implementation plans with dependency analysis |
| `code-reviewer` | Haiku | MANDATORY before commit; CRITICAL findings block |
| `security-reviewer` | Sonnet | OWASP top 10, secrets, auth, input handling |
| `tdd-guide` | Sonnet | Write-tests-first; enforces 80%+ coverage |
| `doc-updater` | Haiku | Codemaps, READMEs, schema docs |
| `build-error-resolver` | Haiku | Minimal-diff build / type-error fixes; no architectural edits |
| `data-model-auditor` | Sonnet | Finds hardcoded business values; recommends moving them to data model |
| `e2e-runner` | Sonnet | Generates + runs E2E tests; manages journeys + artifacts |
| `retrospective-agent` | Sonnet | Daily / weekly / monthly retros from dev-log digests |
| `ceo` | Opus | Friday weekly retro + next-week plan (auto-fires) |
| `memory-consolidator` | Sonnet | Quarterly memory hygiene; archives historical resume blocks |

All are user-global. You invoke them by name in Claude Code. The
`brief-writer` and `architect` agents specifically query the
semantic index in their Step 0 — that's where the Workbox-miss
class gets structurally closed.

### 2 session skills

- **`/start-session`** — at session start, reads CLAUDE.md, MEMORY,
  weekly plan, quality calendar, recent git activity. Surfaces
  active focus, stale plans (>7 days old), overdue recurring
  tasks, open blockers, and recommends the first task. **Then
  stops and waits for you to decide.** Never starts work
  autonomously. Project-agnostic — discovers files via fallback
  chains; tunes via per-project `.claude/session.yaml`.
- **`/end-session`** — at session end, runs the close-out: git
  status, sync check (commits ahead / behind origin), MEMORY
  banner updates (surfaces diffs, never auto-writes), deliverables
  ledger (commits with hashes), unresolved items, next-session
  pickup pointer. **Never auto-commits, never auto-edits memory,
  never pushes to origin.**

Both are project-agnostic. Both work standalone with no other
engine pieces.

### 5 slash commands

- **`/brainstorm [topic]`** — capture brainstorm → produce 1-page
  brief via `brief-writer`
- **`/lock-backlog [phase]`** — lock a phase backlog (read-only
  audit trail; the `ceo` agent reads it but can't modify it)
- **`/research-search [query]`** — semantic search over your
  `docs/research/*.md`
- **`/weekly-retro`** — Friday retro + next-week plan (also
  auto-fires via launchd/systemd/Task Scheduler)
- **`/memory-consolidate`** — quarterly memory hygiene; invokes
  `memory-consolidator`

### 6 pre-commit + commit-msg + pre-push hooks

Drop into `.pre-commit-config.yaml`:

- **`code-review-trailer`** (commit-msg) — blocks ≥5-file commits
  without a `Code-reviewed:` or `Code-skip-reason:` trailer
- **`docs-updated-trailer`** (commit-msg) — blocks commits to
  structural files (CLAUDE.md, README, schema) without a
  `Docs-updated:` trailer
- **`design-review-trailer`** (commit-msg) — blocks commits to UI
  files without a `Design-reviewed:` trailer
- **`claude-md-size`** (pre-commit) — warns when CLAUDE.md > 40 KB
- **`research-index-rebuild`** (pre-commit) — re-embeds the
  semantic index when `docs/research/*.md` is staged
- **`stacking-rule-check`** (pre-push) — blocks pushes that bundle
  ≥2 distinct slot IDs with foundational file changes (Process v2
  rule: foundational changes always per-slot)

All hooks read tuning env vars. None require Anthropic
intervention to run.

### Semantic search over `docs/research/`

`scripts/research_index.py` builds a **local SQLite + embedding**
index of your research markdown files. Four providers:

| Provider | API key | Quality | Best for |
|---|---|---|---|
| **`fastembed`** (default) | None | Good for ≤10k docs | "Just works" path; runs offline |
| `voyage` | `VOYAGE_API_KEY` | Highest recall | Larger corpora; Anthropic-recommended |
| `gemini` | `GEMINI_API_KEY` | Good | Existing Gemini users |
| `openai` | `OPENAI_API_KEY` | Good | Existing OpenAI users |

Adopters get a working RAG with **zero signups** by default. Power
users switch via one line in `.process-engine.yaml`.

**The `brief-writer` and `architect` agents query this index in
their Step 0 before drafting anything new.** Top matches with
cosine ≥ 0.55 get pulled into a `## Related prior work` section in
the new doc. Solves the Workbox-miss class structurally.

### Weekly retro automation

Cross-platform scheduler templates ship for:

- **macOS launchd** — wired automatically via `pe launchd <project>`
- **Linux systemd** — user-level `.service` + `.timer` units
- **Linux cron** — plain crontab for systemd-averse setups
- **Windows Task Scheduler** — PowerShell `Install-Task.ps1`

Friday 17:00 local time, the `ceo` agent runs headless and writes:

- `docs/dev-log/weekly-plan-YYYY-W<NN>.md` — next week's lanes,
  blockers, trigger check
- `docs/dev-log/retro-YYYY-W<NN>.md` — what went well, what broke,
  process adjustments, agent invocation counts

A 3-day heartbeat watchdog notifies you (macOS notification /
notify-send / Windows toast) if the cadence breaks for >8 days.

### CI gate template

`.github/workflows/engine-gate.yml.template` — soft mirror of the
local trailer hooks for contributors who don't install pre-commit
locally. Belt + suspenders.

### Unified `pe` CLI

One entry point for everything:

```
pe install <project>     # symlink agents/commands/skills into a project
pe launchd <project>     # wire macOS launchd weekly retro
pe upgrade               # git pull; symlinks auto-propagate
pe status                # engine version + last commit + inventory
pe doctor [<project>]    # diagnose install (broken symlinks, missing deps)
pe eject <project>       # remove engine-managed symlinks
```

---

## What's opinionated (you should know upfront)

- **Brief before code is required**, not optional. The `brief-writer`
  agent is in the engine's invocation rules; agents that skip it get
  flagged.
- **Code review at every commit** is enforced by a pre-commit hook
  that blocks commits ≥5 files without a trailer.
- **Tests-first** is the documented stance for new features. If your
  project's culture is "tests after," you'll fight the engine.
- **`docs/research/`** is treated as a first-class data store. If
  your project doesn't have research docs today, the RAG sits
  unused.
- **The `8colors-process-engine` name** is the project name, not a
  white-label. Yes, it's a little weird. Yes, I'll consider renaming
  if there's a strong reason. The `pe` CLI is generic enough.

If any of those bullets are dealbreakers for your workflow, please
**still try it for an afternoon** and tell me — that's the most
useful kind of feedback.

---

## Install (5 minutes)

```bash
# 1. Clone the engine to a stable location
git clone https://github.com/sanishsk/8colors-process-engine.git \
    ~/.local/share/8colors-process-engine

# 2. Symlink the pe CLI onto your PATH
ln -s ~/.local/share/8colors-process-engine/scripts/pe ~/.local/bin/pe
# (ensure ~/.local/bin is on $PATH; add to ~/.zshrc / ~/.bashrc if not)

# 3. Install into a target project
pe install /path/to/your/project

# 4. Restart Claude Code in the target project.

# 5. Verify
#    In Claude Code: type "/start-session" and see the orientation
#    On the CLI: pe status, pe doctor /path/to/your/project
```

### Optional: wire the Friday weekly retro (macOS)

```bash
# Edit the auto-created config
$EDITOR /path/to/your/project/.process-engine.yaml
# Set: project.org_tag, project.root

# Render + place the launchd plists
pe launchd /path/to/your/project

# Load them (the installer prints these — operator runs explicitly)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.weekly.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.heartbeat.plist

# Dry-run now (bypasses Friday gate)
~/.local/bin/<org>-ceo/run_weekly.sh --force
```

Linux + Windows: see `templates/systemd/README.md`, `templates/cron/README.md`,
`templates/windows-task-scheduler/README.md` in the engine repo.

### Optional: build the semantic index

```bash
pip install fastembed numpy
python3 /path/to/your/project/scripts/research_index.py rebuild
python3 /path/to/your/project/scripts/research_index.py query "<a topic>"
```

No API key. No signup. The first run downloads a ~33 MB model to
`~/.cache/fastembed/`. After that it's offline.

---

## What to try first (30 minutes)

A sample first session that touches the most pieces:

1. **`/start-session`** — see if it picks up your project's CLAUDE.md
   / README / git state cleanly. Note what it gets right, what it
   misses.
2. **Invoke `code-reviewer`** before your next commit. See if its
   findings match your own review priorities.
3. **Invoke `brief-writer`** for a feature you're considering.
   Compare its 1-page brief to what you'd write yourself.
4. **Run `python3 scripts/research_index.py rebuild`** if you have
   research docs. Try a query for a topic you know well — does the
   right doc come up?
5. **`/end-session`** when you're done. See if the close-out report
   surfaces things you'd otherwise lose.

If you want the full experience, also:

- Set up a `.pre-commit-config.yaml` with the engine hooks
  (`cp <engine>/hooks/.pre-commit-config.yaml.template .pre-commit-config.yaml`)
  and try committing without trailers — see what blocks.
- Run `pe launchd` and `--force` the weekly retro to see what the
  CEO agent produces for your project.

---

## What I want you to tell me

Specific questions are more useful than "any thoughts?":

1. **Did `pe install` work first try?** If not, what broke?
2. **Did `/start-session` make sense for your project?** What did
   it miss?
3. **Did `code-reviewer`'s findings match your priorities?** Was
   it too strict, too lax, weird in some specific way?
4. **Did the semantic search surface useful prior work?** If you
   don't have `docs/research/`, was that a blocker?
5. **What pieces did you end up actually using vs ignoring?** This
   is the most valuable feedback — pieces nobody uses should die.
6. **What was the friction point that almost made you stop?**
7. **What did you expect the engine to do that it didn't?**
8. **If you ran `pe launchd`, did the weekly retro fire?** What did
   the output look like?

Open issues at <https://github.com/sanishsk/8colors-process-engine/issues>
(I've added bug + feature templates), or DM me directly — both work.

---

## Honest disclaimers

- **Single developer.** Bus factor of 1. You're helping that.
- **Single project's distillation.** The doctrine is validated on
  one production codebase (8CStudio: Flask + Postgres + Alpine +
  Tailwind, ~75 tables, 18 modules, a year of shipped slots). Some
  patterns may not transfer cleanly to other stacks. PRs welcome.
- **Alpha quality on cross-platform.** macOS is the most-tested
  path. Linux systemd + Windows Task Scheduler templates are
  written from documentation, not from my own daily use. If
  they're broken, I want to know fast.
- **No telemetry today.** I'm not collecting anything. Feedback is
  manual, from you.
- **Opinionated.** If the doctrine doesn't fit, fork it. I won't
  water it down to chase adoption.
- **Anthropic doesn't ship embedding models.** Default RAG provider
  is `fastembed` (BAAI/bge-small-en-v1.5), which runs locally.
  Voyage / Gemini / OpenAI are optional upgrades.

---

## If you hate it

```bash
pe eject /path/to/your/project
rm -rf ~/.claude/skills/start-session ~/.claude/skills/end-session
# macOS: unload launchd
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.weekly.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.<org>.ceo.heartbeat.plist
rm -f ~/Library/LaunchAgents/com.<org>.ceo.*.plist
rm -rf ~/.local/bin/<org>-ceo ~/Library/Logs/<org>-ceo
```

The eject is reversible — `pe install` restores the symlinks.

---

## What I'm planning for v0.8 (your feedback shapes this)

- **Multi-project portfolio mode** — single dashboard / CEO across
  projects you maintain. Blocked on ≥2 multi-project adopters.
- **Adopter telemetry opt-in** — anonymous, opt-in retro data shared
  back. Blocked on real adopter signal.

After v0.8, I plan to submit to the Anthropic Skills directory and
the Claude Code plugin marketplace.

---

## Why I'm asking you specifically

You've shipped real software with AI assistance. You've felt the
same friction I have. You're honest enough to tell me when
something doesn't work. That's exactly the cohort I need before
this goes wider.

Thanks for taking the time.

— Sanish ([8Colors](https://8cs.io))
