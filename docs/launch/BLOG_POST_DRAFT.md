# Process discipline for Claude Code, in 30 seconds

> Draft blog post for the v0.7 launch. Edit freely. Suggested
> outlets: personal blog, Hacker News (Show HN), r/ClaudeAI, X/LinkedIn.

---

## TL;DR

I built [`8colors-process-engine`](https://github.com/sanishsk/8colors-process-engine),
a portable Claude Code plugin that drops 13 specialist agents, 5
slash commands, 2 session skills, semantic search over your research
docs, a weekly retro cron job, and 6 pre-commit hooks into any
project in one command. Defaults are zero-API-key. Friend-installable
in 30 seconds. MIT-licensed.

```bash
git clone https://github.com/sanishsk/8colors-process-engine.git ~/.local/share/8c-engine
ln -s ~/.local/share/8c-engine/scripts/pe ~/.local/bin/pe
pe install ~/code/your-project
```

Restart Claude Code. You now have brief-before-code, OSS-first
search, mandatory code review, TDD, semantic memory, and a weekly
retro on Friday 17:00 — for free.

---

## Why I built this

I run a videography invoice + production system called 8CStudio.
75+ database tables, 18 modules, a year of shipped features. AI is
doing the majority of implementation work, and after enough shipped
slots a pattern emerged: **the gap between session N and session N+1
was where bugs slipped in.**

A concrete incident from late May: I picked up a multi-day offline-
sync feature on Monday. Read the latest planner doc, started
implementing. By Wednesday I'd hand-rolled a Service-Worker caching
layer. On Friday during code review, the agent noticed the *brief*
from three weeks earlier had locked in `Workbox 7.4.1` — a battle-
tested OSS library that does the exact thing I'd just rebuilt.

I reverted 600 lines of code.

This wasn't a one-off. The pattern: prior decisions get locked in
briefs and architect docs that subsequent sessions don't re-read.
Patches that work for "what should I do today" don't fix "what did
we decide three weeks ago."

I patched the symptom by mandating "always read researcher → brief
→ architect → planner in that order at slot pickup." That's a
process patch.

I wanted a structural fix.

---

## The pieces, briefly

After a year of accumulating workflow patterns in 8CStudio, I
extracted the generic ones into a plugin any Claude Code project can
install:

### 13 specialist agents

Each with a single job, a model tier matched to that job, and
explicit when-to-invoke rules:

- **brief-writer** — converts a brainstorm into a 1-page brief with
  alternatives + market check. Required before any non-trivial work.
- **architect** — system design, scalability, integration patterns.
- **planner** — multi-slot implementation plans with dependency
  analysis.
- **code-reviewer** — mandatory before commit. CRITICAL blocks.
- **security-reviewer** — OWASP top 10, secrets, auth.
- **tdd-guide** — write tests first, 80%+ coverage.
- **doc-updater** — codemaps, READMEs, schema docs.
- **researcher** — async OSS scout. Runs parallel with implementation.
- **ceo** — Friday weekly retro + next-week plan.
- **build-error-resolver**, **data-model-auditor**, **e2e-runner**,
  **retrospective-agent**, **memory-consolidator** — specialized.

### 2 session skills

The piece I personally wish I'd built first:

- **`/start-session`** reads your CLAUDE.md, MEMORY, weekly plan,
  quality calendar at session start. Surfaces active focus, stale
  plans, overdue tasks, blockers. Recommends the first task. Waits
  for you to decide.
- **`/end-session`** runs the close-out at session end: git status,
  sync check, MEMORY banner updates, deliverables ledger, next-
  session pickup pointer.

Both project-agnostic. Both tunable per-project via
`.claude/session.yaml`. **Never auto-commits, never auto-edits
memory.**

### Semantic search over your research docs

This is the structural fix to the Workbox-miss class.
`scripts/research_index.py` builds a local SQLite index of
`docs/research/*.md` using embeddings. The `brief-writer` and
`architect` agents query it in their Step 0 before drafting
anything new.

Four embedding providers — `fastembed` (default, fully local, no
API key), `voyage`, `gemini`, `openai`. Adopters can be productive
with zero signups; power users switch providers via one line in
config.

Validated on my real 70-doc research corpus: querying "workbox dexie
offline sync OSS contract" surfaces all four relevant docs with
cosine ≥0.70. The Workbox-miss class is structurally closed.

### Weekly retro on launchd / systemd / Task Scheduler

`pe launchd <project>` wires the CEO agent to fire Friday 17:00
automatically. It writes `docs/dev-log/weekly-plan-YYYY-W<NN>.md`
to your project. Forever. A 3-day heartbeat watchdog notifies you
if the cadence breaks.

macOS uses launchd; Linux uses systemd or cron; Windows uses Task
Scheduler. All four templates ship in v0.6+.

### 6 pre-commit + commit-msg hooks

Generalized from 8CStudio's pre-commit config:

- `code-review-trailer` — blocks ≥5-file commits without
  `Code-reviewed:` or `Code-skip-reason:` trailer.
- `docs-updated-trailer` — blocks structural-file commits without
  `Docs-updated:` trailer.
- `design-review-trailer` — blocks UI-file commits without
  `Design-reviewed:` trailer.
- `claude-md-size` — warns when CLAUDE.md > 40 KB.
- `research-index-rebuild` — re-embeds the semantic index when
  `docs/research/` changes.
- `stacking-rule-check` — blocks pushes that bundle ≥2 distinct
  slot IDs with foundational file changes (Process v2 rule).

All hooks read tuning env vars. None of them require Anthropic
intervention to run.

### A GitHub Actions CI gate

For contributors who don't install pre-commit locally. Soft mirror
of the trailer hooks. Catches PRs that slipped through.

---

## What it's not

This engine is opinionated. It assumes:

- You want **brief before code** discipline.
- You want **OSS-first** search before building.
- You want **mandatory code review** at every commit, with explicit
  skip-reasons logged when you skip.
- You want a **weekly retro** that actually happens automatically.
- You want **semantic memory** so prior decisions aren't lost.

If you'd rather have a flexible toolkit and decide-per-feature, this
isn't for you. Fork it. Strip the opinionation. Or use the agents
without the workflow scaffolding.

If you want rails that fail loud when skipped, this is for you.

---

## How to try it

```bash
# Install
git clone https://github.com/sanishsk/8colors-process-engine.git ~/.local/share/8c-engine
ln -s ~/.local/share/8c-engine/scripts/pe ~/.local/bin/pe
pe install ~/code/your-project

# Optional: wire the Friday weekly retro
pe launchd ~/code/your-project
# (macOS only; Linux / Windows templates ship in templates/<platform>/)

# Optional: build the semantic index (no API key needed — fastembed default)
pip install fastembed numpy
python3 ~/code/your-project/scripts/research_index.py rebuild
```

Restart Claude Code. Type `/start-session`. The orientation will
tell you what's there.

---

## What's next

Currently looking for **2–3 beta adopters** to install and run for
2–4 weeks of real work, then share what broke, what was confusing,
and what they expected that wasn't there. If you'd like to be one,
drop me a note or open a GitHub issue. I'll personally help with
install and iterate fast on adopter feedback.

After beta feedback ships into a `v0.8`, I'll submit to the
Anthropic Skills directory and the Claude Code plugin marketplace.

---

## Honest disclaimers

- **MIT license**, free, no telemetry today.
- **Opinionated.** If the doctrine doesn't fit, fork. I won't water
  it down.
- **One developer.** Bus factor of 1. Adopters help that.
- **Single project's distillation.** Patterns work in 8CStudio's
  Flask + Postgres + Alpine + Tailwind stack; some may not transfer
  cleanly to React + Node + Mongo without tuning. PRs welcome.
- **Anthropic doesn't ship embeddings.** Default RAG provider is
  `fastembed` (BAAI/bge-small-en-v1.5), which runs locally. You can
  swap in Voyage (Anthropic-recommended partner), Gemini, or OpenAI
  via config.

---

GitHub: <https://github.com/sanishsk/8colors-process-engine>
Latest release: <https://github.com/sanishsk/8colors-process-engine/releases/tag/v0.7.0>
Author: Sanish ([8Colors](https://8cs.io))
