# 8colors-process-engine — beta tester brief

> Hand-out for the beta cohort. Copy / paste / link as needed.
>
> **v0.55.1 — every count, model tier, command name and threshold below is
> verified against the repository by CI.**

---

## TL;DR

I built **`8colors-process-engine`** — a portable Claude Code plugin
that drops **21 specialist agents**, semantic search over your research
docs, a weekly retro cron job, 10 slash commands, 2 session skills,
30 governance hooks (git-side and Claude Code-side), and a
**verdict-blind gate escalation router** into any project in **one
install command**. Defaults need
**zero API keys**. MIT-licensed. I want your hands on it for 2–4
weeks of real work, then I want to know what broke, what was
confusing, and what you expected that wasn't there.

Repo: <https://github.com/sanishsk/8colors-process-engine>
Current version: **v0.55.1**

### Want to try just one piece?

**You do not have to install the engine to use it.** If you only want a
security review, or a code review, or a performance pass — one agent,
against your own code — read
**[`docs/RUNNING_AGENTS.md`](../RUNNING_AGENTS.md)** first. It is a
five-minute path with no symlinks and no commitment:

```bash
git diff --cached | pe agent run security-reviewer --brief - --dry-run
```

`--dry-run` shows exactly what would be sent and costs nothing. Swap
`security-reviewer` for any of the 21 agents.

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
- **Gate agents disagree and you don't know when to actually halt.**
  code-reviewer says HIGH; security-reviewer says MEDIUM; is it
  really a stop? Answered by v0.7.

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
- **Verdict-blind halt on HIGH/CRITICAL** — the escalation router
  reads gate envelopes, halts on any HIGH/CRITICAL regardless of
  PASS/FAIL verdict, and escalates worker_quality failures up the
  Haiku → Sonnet → Opus ladder (Phase 3, graduated 2026-06-28)

If that doctrine isn't what you want, fork it. I won't water it
down for adoption.

---

## What's in the box (inventory)

### 21 specialist agents

Each has a single job, a model tier matched to that job, and explicit
when-to-invoke rules.

**The 7 gate agents** end their output with a machine-parseable **gate
envelope**. That JSON is what the escalation router reads, and what
`pe gate parse` validates. These are the ones worth wiring into
enforcement:

| Agent | Model | Job |
|---|---|---|
| `code-reviewer` | Sonnet | MANDATORY before commit; CRITICAL findings block |
| `security-reviewer` | Sonnet | OWASP Top 10, secrets, auth, input handling, SSRF, unsafe crypto |
| `database-reviewer` | Sonnet | PostgreSQL schema / migration / RLS / tenant isolation |
| `performance-reviewer` | Sonnet | N+1 queries, unbounded list endpoints, blocking work in a request path |
| `tdd-guide` | Sonnet | Write-tests-first; RED phase is a hard refusal point |
| `e2e-runner` | Sonnet | Generates + runs E2E tests; manages journeys + artifacts |
| `design-critic` | Sonnet | Two-mode UI gate: the floor everywhere, the ceiling where it matters |

**The other 14:**

| Agent | Model | Job |
|---|---|---|
| `brief-writer` | Sonnet | 1-page brief with alternatives + market check; required before non-trivial work |
| `architect` | Opus | System design, scalability, integration patterns |
| `planner` | Opus | Multi-slot implementation plans with dependency analysis |
| `researcher` | Sonnet | OSS / MCP scout; searches before you write |
| `build-error-resolver` | Sonnet | Minimal-diff build / type-error fixes; no architectural edits |
| `data-model-auditor` | Sonnet | Finds hardcoded business values; recommends moving them to the data model |
| `tenant-isolation-auditor` | Haiku | New SQL that crosses a tenant boundary without RLS context |
| `doc-updater` | Haiku | Codemaps, READMEs, schema docs |
| `project-kickstarter` | Opus | Scaffolds a new project. Once, at the start |
| `project-onboarder` | Opus | Gaps in an existing project against the doctrine. Once, on adoption |
| `retrospective-agent` | Opus | Daily / weekly / monthly retros from dev-log digests |
| `ceo` | Opus | Friday weekly retro + next-week plan (auto-fires) |
| `memory-consolidator` | Sonnet | Quarterly memory hygiene; archives historical resume blocks |
| `incident-synthesizer` | Opus | Should this incident become an engine-wide gate? Proposes only, never writes |

Gates run at Sonnet or above regardless of the worker tier — see the
"gate-agent paradox" note in `docs/AGENT_INVOCATION_RULES.md`.

`pe install` symlinks all 21 by default. For a leaner install,
`--subset gate-only` gives you the 7 gate agents; `--subset core` gives
you those plus `planner`, `brief-writer` and `architect` (10 total).

**To run just one agent — a security review, a code review, anything —
see [`docs/RUNNING_AGENTS.md`](../RUNNING_AGENTS.md).** You do not have to
install the engine to use one piece of it.

The `brief-writer` and `architect` agents query the semantic index in their
Step 0 — that's where the Workbox-miss class gets structurally closed.

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

### 10 slash commands

- **`/brainstorm [topic]`** — capture brainstorm → produce a 1-page
  brief via `brief-writer`
- **`/new-feature`** — the full chain: brainstorm → brief → architect →
  plan → tdd, with the checkpoints where you decide
- **`/pre-commit`** — run the gates that match the staged paths, validate
  the envelopes via `pe gate parse`
- **`/simplify`** — post-GREEN cleanup: reuse, dead code, altitude. Tests
  must stay green
- **`/research-search [query]`** — semantic search over your
  `docs/research/*.md`
- **`/retro`** — retrospective over the last day / week / month; invokes
  `retrospective-agent`
- **`/weekly-retro`** — Friday retro + next-week plan; invokes `ceo` (also
  auto-fires via launchd / systemd / Task Scheduler)
- **`/memory-consolidate`** — quarterly memory hygiene; invokes
  `memory-consolidator`
- **`/lock-backlog [phase]`** — lock a phase backlog (read-only audit
  trail; `ceo` reads it but cannot modify it)
- **`/design-scan`** — quarterly refresh of the curated visual references

### 29 hooks

Two layers. **Claude Code hooks** fire from inside a session
(PreToolUse / PostToolUse / Stop) and are merged into
`<project>/.claude/settings.json` by `pe install`. **git-side hooks** run
through the `pre-commit` framework and catch work done outside Claude
Code. The full catalogue, with every tuning variable, is in
[`hooks/README.md`](../../hooks/README.md); the ones you will meet first:

**Trailer gates** (commit-msg) — each blocks a commit on its own paths
unless the message carries the trailer, or an explicit skip-reason:

- **`code-review-trailer`** — commits over the file threshold, or touching
  behaviour paths, need `Code-reviewed:` / `Code-skip-reason:`
- **`security-review-trailer`** — auth / payment / webhook / jwt / session
  paths need `Security-reviewed:`; money paths also need co-staged tests
- **`design-review-trailer`** — template / JS / CSS changes need
  `Design-reviewed:`
- **`perf-gate`** — ORM / query / serializer / migration paths need
  `Perf-tested:`
- **`docs-updated-trailer`** — CLAUDE.md / README / schema changes need
  `Docs-updated:`

**Deterministic gates** (pre-commit) — no agent, no API, no tokens:

- **`secrets-scan`** — gitleaks / detect-secrets over staged files
- **`sast-scan`** — semgrep / bandit / gosec / eslint-security; blocks on
  HIGH+ when a tool ran
- **`complexity-gate`** — ruff C901/PLR, xenon, vulture
- **`size-budget`** — file (default 800 lines) and function (50) budgets
- **`duplication-gate`** — jscpd ratchet; a commit must not raise the baseline
- **`claude-md-size`** — warns above 12,000 bytes, **blocks** above 20,000
- **`design-lint`**, **`motion-lint`**, **`signature-lint`**,
  **`copy-lint`**, **`migration-lint`**, **`api-contract-check`**,
  **`deps-audit`**, **`test-run`**, **`research-index-rebuild`**
- **`stacking-rule-check`** (pre-push) — blocks pushes bundling ≥2 slot IDs
  with foundational changes

**In-session hooks** — `pre-commit-envelope-check` blocks `git commit`
unless a validated gate envelope matches the staged diff;
`transcript-guard` scans tool output for prompt-injection markers and
secret-shaped strings; `ponytail-preflight`, `post-edit-lint`,
`cache-hygiene-warn`, `stop-uncommitted-reminder` are advisory.

All hooks read tuning env vars. None require Anthropic intervention to
run. `pe doctor <project>` reports how many of the 29 your project is
actually wired for — and whether they can run at all.

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
pe install [--subset gate-only|core|full] <project>
                          # symlink agents/commands/skills into a project;
                          # --subset controls which agents (default: full)
pe sync <project>         # re-point project symlinks at current engine
                          # (diff-before-clobber: differing files NEVER
                          #  overwritten without explicit confirmation)
pe launchd <project>      # wire macOS launchd weekly retro
pe upgrade                # git pull; symlinks auto-propagate
pe status                 # engine version + last commit + inventory
pe doctor [<project>]     # diagnose install (broken symlinks, missing deps,
                          #  per-agent staleness against user-global agents)
pe eject <project>        # remove engine-managed symlinks
pe version                # print engine version
```

Day-to-day beyond install:

```
pe agent run <name>       # invoke ONE agent headlessly via `claude -p`
                          #   --brief <file>|-   what to work on
                          #   --dry-run          show what would be sent, spend nothing
                          # See docs/RUNNING_AGENTS.md
pe gate parse <file>      # extract + validate a gate envelope
                          #   0 PASS · 1 FAIL/worker_quality · 2 FAIL/non-escalatable
                          #   3 WARN · 4 did not parse or validate
pe audit                  # run the gates across the WHOLE repo, not just staged
pe verify                 # are the engine's own files unmodified?
pe recall <query>         # search past decisions + reconciliations
pe memory ls|show|rm|verify|stale     # auto-memory governance
pe collect                # git-derived dev-log digest (zero tokens)
pe telemetry collect|summary          # transcripts → usage records + cost
```

Advanced, mostly for engine developers: `pe new <name>` (project
scaffold), `pe module add <name>` (reusable domain modules),
`pe pin show|verify|bump` (per-project engine version pin),
`pe incident propose` (synthesize a gate proposal from an incident —
proposes, never applies), `pe baseline capture`, `pe shadow decide` /
`shadow reconcile`.

`pe help <subcommand>` prints the detail for any of them.

---

## What's enforced — the Phase 3 escalation router (graduated 2026-06-28)

New in v0.7-v0.8, and the piece I'd most like beta feedback on.

The 7 gate agents (`code-reviewer`, `security-reviewer`,
`database-reviewer`, `performance-reviewer`, `tdd-guide`, `e2e-runner`,
`design-critic`) each emit a **gate envelope** — a machine-parseable JSON
block with:

- `verdict`: PASS / FAIL / WARN
- `failure_class`: `worker_quality` / `task_underspecified` /
  `blocked` / `out_of_scope`
- `findings[]`: severity ∈ CRITICAL / HIGH / MEDIUM / LOW
- `confidence`, `model_used`

The router reads envelopes and decides:

- **Any finding with severity HIGH or CRITICAL → HALT**, regardless
  of the verdict. This is the "verdict-blind severity floor" — the
  answer to "gates disagree, when do I actually stop?"
- **verdict=FAIL + failure_class=worker_quality → escalate** to the
  next tier (Haiku → Sonnet → Opus). Cap of 6 iterations per slot,
  then human halt.
- **failure_class ∈ {task_underspecified, blocked, out_of_scope} →
  human halt** (no amount of retry will fix an underspecified task)
- **verdict=WARN → proceed, surface to human** for the next session

Cohort-validated on 12 real slots in 8CStudio before flipping from
shadow to enforce mode. See `docs/PHASE_3_ESCALATION_ROUTER.md` +
`docs/E1_GATE_ENVELOPE.md` for the full contract.

**Beta ask on this:** if a gate agent fires in your project, does
its envelope look right? Are its findings severity levels
calibrated to what YOUR domain considers HIGH? If not, that's the
kind of tuning I need to know about.

---

## What's opinionated (you should know upfront)

- **Brief before code is required**, not optional. The `brief-writer`
  agent is in the engine's invocation rules; agents that skip it get
  flagged.
- **Code review at every commit** is enforced by a commit-msg hook that
  blocks commits over the file threshold, or touching behaviour paths,
  without a trailer. Threshold and paths are tunable
  (`ENGINE_REVIEW_THRESHOLD`, `ENGINE_REVIEW_BEHAVIOR_PATHS`).
- **`CLAUDE.md` has a hard ceiling.** `claude-md-size` warns above 12,000
  bytes and **blocks above 20,000**. It is re-read into every session turn,
  so it is the most expensive file in your repository. Raise it with
  `ENGINE_CLAUDE_MD_FAIL` if you must, but the number is deliberate.
- **`pre-commit install` needs both hook types.** Bare `pre-commit install`
  writes only `.git/hooks/pre-commit`, so every trailer gate is configured
  and never runs — silently. Use
  `pre-commit install --hook-type pre-commit --hook-type commit-msg`, and
  confirm with `pe doctor`.
- **Tests-first** is the documented stance for new features. If your
  project's culture is "tests after," you'll fight the engine.
- **`docs/research/`** is treated as a first-class data store. If
  your project doesn't have research docs today, the RAG sits
  unused.
- **The `8colors-process-engine` name** is the project name, not a
  white-label. Yes, it's a little weird. Yes, I'll consider renaming
  if there's a strong reason. The `pe` CLI is generic enough.
- **HIGH/CRITICAL findings halt.** No override flag today. If a
  gate agent flags something HIGH that you disagree with, the fix
  is to tune the agent's rubric (fork or PR), not to override at
  run time.

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
mkdir -p ~/.local/bin
ln -s ~/.local/share/8colors-process-engine/scripts/pe ~/.local/bin/pe

# 2a. Verify ~/.local/bin is on $PATH (stock macOS zsh does not include it)
case ":$PATH:" in
  *":$HOME/.local/bin:"*) echo "OK — ~/.local/bin is on PATH" ;;
  *) echo "MISSING — add this to ~/.zshrc, then open a new shell:"
     echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac

# 3. Install into a target project
pe install /path/to/your/project
# or, for a leaner install:
#   pe install --subset gate-only /path/to/your/project   # 7 gate agents only
#   pe install --subset core /path/to/your/project        # 10 agents

# 4. Restart Claude Code in the target project.

# 5. Verify
#    In Claude Code: type "/start-session" and see the orientation
#    On the CLI: pe status, pe doctor /path/to/your/project
```

### After an engine upgrade — `pe sync`

When you `git pull` the engine and want a project to pick up the
changes without a full re-install:

```bash
pe sync /path/to/your/project
# or preview first:
pe sync --dry-run /path/to/your/project
```

`pe sync` re-points project symlinks at the current engine with a
**diff-before-clobber** safety contract:

- Symlinks already pointing at the current engine → silent skip
- Symlinks pointing at a stale/other engine → prompts to re-point
- Regular files identical to the engine version → silently
  upgraded to symlinks
- **Regular files that DIFFER from the engine → shows unified
  diff, prompts y/N, never overwrites without explicit
  confirmation** (this is the safety contract)
- Missing in-subset files → silently re-added
- Orphan symlinks from a wider previous subset → prompted for
  removal

Ships with a smoke test (`tests/test_pe_sync.sh`) that gates the
destructive path — the failure mode of untested = clobbered
customized agent.

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

## Daily rituals — how you actually use it

Two skills ship with the engine — `/start-session` and `/end-session` —
that are THE rituals. Learn these and everything else falls into place.

### First time on a project (onboarding)

Do this once per project, then you're in the daily flow below.

```bash
# 1. Install (see Install section above)
pe install /path/to/your/project

# 2. Edit the auto-created config with real values
#    (do NOT commit the template placeholders: acme / Acme Corp / /Users/you/…)
$EDITOR /path/to/your/project/.process-engine.yaml
# Set: project.org_tag, project.display_name, project.root

# 3. (Optional, macOS) Wire the Friday weekly retro
pe launchd /path/to/your/project

# 4. Verify install is healthy
pe doctor /path/to/your/project
```

Create/grow `CLAUDE.md` and `MEMORY.md` in your project root as work
happens. The session skills read them.

### Every day (start → work → end)

**Start of session:**

1. Open Claude Code in the project directory.
2. Type `/start-session`. The skill reads CLAUDE.md, MEMORY, weekly plan,
   git state; surfaces active focus + stale plans + first-task
   recommendation and **stops waiting for you.** It never starts work
   autonomously.
3. If you recently `git pull`-ed the engine, run
   `pe sync --dry-run /path/to/project` first to preview any updates the
   engine wants to propagate. Then `pe sync` (no `--dry-run`) if you want
   them applied — **diff-before-clobber protects any customizations you
   made.**
4. Decide the task. Work.

**End of session:**

1. Type `/end-session`. The skill runs the close-out: git status, sync
   check (ahead/behind origin), MEMORY banner updates (surfaces diffs —
   **never auto-writes**), deliverables ledger (commits + hashes),
   unresolved items, next-session pickup pointer.
2. Review its output. Apply MEMORY updates it surfaces if you agree
   (you commit them manually).
3. Commit + push if you have work to ship. The skill never pushes for
   you.

Both skills are project-agnostic — they discover files via fallback
chains. Tune per-project via `.claude/session.yaml`.

### Rule of thumb

| Situation | What to run |
|---|---|
| First time on a project | `pe install` + edit yaml + `/start-session` |
| Daily start | `/start-session` |
| After engine has new upstream commits | `pe sync --dry-run` → `pe sync` |
| Daily end | `/end-session`, then commit + push if applicable |
| Something's off (broken symlinks, wrong version) | `pe doctor /path/to/project` |

### Why this works

- `/start-session` does the "where was I?" work so you don't waste 10
  minutes re-orienting.
- `/end-session` prevents "wait, what did I actually do today?" via the
  ledger + surfacing what to remember.
- `pe sync --dry-run` is the safe default — see what would change before
  anything changes.
- **Neither skill auto-commits, auto-pushes, or auto-edits MEMORY.** You
  stay in control of what lands. Every write is human-approved.

---

## What to try first (30 minutes)

A sample first session that touches the most pieces:

1. **`/start-session`** — see if it picks up your project's CLAUDE.md
   / README / git state cleanly. Note what it gets right, what it
   misses.
2. **`pe sync --dry-run`** — see what the engine's diff-before-clobber
   check reports for your project. Should be clean on a fresh install.
3. **Invoke `code-reviewer`** before your next commit. See if its
   findings match your own review priorities. Note the gate envelope
   JSON at the bottom of its output — that's what the router reads.
4. **Invoke `brief-writer`** for a feature you're considering.
   Compare its 1-page brief to what you'd write yourself.
5. **Run `python3 scripts/research_index.py rebuild`** if you have
   research docs. Try a query for a topic you know well — does the
   right doc come up?
6. **`/end-session`** when you're done. See if the close-out report
   surfaces things you'd otherwise lose.

If you want the full experience, also:

- Set up a `.pre-commit-config.yaml` with the engine hooks
  (`cp <engine>/hooks/.pre-commit-config.yaml.template .pre-commit-config.yaml`,
  then `pre-commit install --hook-type pre-commit --hook-type commit-msg`)
  and try committing without trailers — see what blocks. Run
  `pe doctor .` afterwards: it tells you how many of the engine's 29 hooks
  your project is actually wired for, and whether they can run at all.
- **Run a single agent without installing anything** —
  `git diff --cached | pe agent run security-reviewer --brief - --dry-run`
  shows exactly what would be sent, for free. Drop `--dry-run` to do it.
  Any agent works this way; see `docs/RUNNING_AGENTS.md`.
- Run `pe launchd` and `--force` the weekly retro to see what the
  CEO agent produces for your project.
- Trigger a gate to fail on purpose (e.g. commit something with a
  hardcoded API key) and see the escalation router escalate or halt.

---

## What I want you to tell me

Specific questions are more useful than "any thoughts?":

1. **Did `pe install` work first try?** If not, what broke?
2. **Did `pe sync --dry-run` report anything you weren't expecting?**
3. **Did `/start-session` make sense for your project?** What did
   it miss?
4. **Did `code-reviewer`'s findings match your priorities?** Was
   it too strict, too lax, weird in some specific way?
5. **Did any gate agent's severity calibration feel wrong** for
   your domain? (This is the piece most likely to need tuning.)
6. **Did the semantic search surface useful prior work?** If you
   don't have `docs/research/`, was that a blocker?
7. **What pieces did you end up actually using vs ignoring?** This
   is the most valuable feedback — pieces nobody uses should die.
8. **What was the friction point that almost made you stop?**
9. **What did you expect the engine to do that it didn't?**
10. **If you ran `pe launchd`, did the weekly retro fire?** What did
    the output look like?

Open issues at <https://github.com/sanishsk/8colors-process-engine/issues>
(I've added bug + feature templates), or DM me directly — both work.

---

## Reference docs (in-repo, worth skimming)

- **`docs/RUNNING_AGENTS.md`** — how to run one agent, or only some,
  without adopting the whole engine. Start here if you want to try a
  single reviewer against your code.
- `docs/ADOPTION_AUDIT.md` — which of the engine's hooks and agents is
  wired where, and what is not yet covered.
- `docs/CAPABILITY_CATALOG.md` — single reference of every tool +
  agent evaluated, with adopt/reject/defer rationale
- `docs/COUPLING_MAP.md` — module coupling analysis across the two
  current adopter projects; useful if you're wondering "how should
  I split sessions across coupled modules?"
- `docs/PHASE_3_ESCALATION_ROUTER.md` — the router contract
- `docs/E1_GATE_ENVELOPE.md` + `schemas/gate-envelope.schema.json` —
  gate envelope JSON schema
- `docs/RHYTHM.md` — the operating cadence doctrine
- `docs/AGENT_INVOCATION_RULES.md` — the agent-chain matrix
- `docs/OSS_SEARCH_ORDER.md` — the canonical search order for
  `researcher`
- `docs/RAG.md` — embedding-provider decisions
- `CHANGELOG.md` — what's changed release-by-release

---

## Honest disclaimers

- **Single developer.** Bus factor of 1. You're helping that.
- **Validated on two projects now.** Doctrine's primary distillation
  is [8CStudio](https://8cs.io) (Flask + Postgres + Alpine +
  Tailwind, ~75 tables, 19 modules, a year of shipped slots). Cross-
  environment reusability proof came from Origyn (Flask + SQLite
  fitness coaching platform) — the engine ran cleanly against a
  second, differently-shaped codebase 2026-06-29. Some patterns may
  still not transfer to your stack. PRs welcome.
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
- **The engine will never auto-modify itself.** Since v0.51.0 an agent
  *can* propose a change — `pe incident propose` synthesizes a gate
  proposal from a real incident and materializes it under
  `.pe/incident-proposals/` **in your project**, never in the engine repo.
  There is no `--auto-apply` mode and there will not be one. Every engine
  change is human-reviewed on a PR, versioned, and pulled by adopters via
  `pe sync`.

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

## Where the engine is now (v0.55.1, 2026-09-05)

`pe sync`, the install presets and `pe doctor` are all still there. What
has been added since, grouped by what it changes for you:

**Enforcement got deterministic.** SAST, secrets, complexity, duplication
and size budgets became hooks that run without an agent, an API key or a
token. `sast-scan` blocks on HIGH+ when a scanner actually ran and skips
*loudly* when none is installed.

**More gates.** `design-critic` (UI floor and ceiling), `performance-reviewer`
(N+1, unbounded endpoints, blocking work in a request path),
`tenant-isolation-auditor`, `data-model-auditor`, `incident-synthesizer`. The
gate set went from 5 to 7.

**One agent at a time became a real thing.** `pe agent run <name>` invokes
any agent headlessly through `claude -p`, with `--dry-run` to see the cost
before you pay it. See `docs/RUNNING_AGENTS.md`.

**Supply chain and prompt-injection.** `pe verify` checks the engine's own
files against a manifest; `transcript-guard` scans tool output for
injection markers and secret-shaped strings before an agent consumes them.

**Reusable domain modules.** `pe module add auth|tenancy|api-credentials|billing`
materializes a working, tested module into your project.

**CI you can point at your own repo.** The engine runs its own test suite,
executes every one of the 29 hooks against a fixture, and runs its own gates
on its own commits, on every push. `pe doctor <project>` reports how many of
the 29 your project is wired for, and whether they can run at all.

---

## What's next

- **`/gate-review` as a Claude Code dynamic workflow** — the parallel gate
  pattern is currently prose that Claude follows turn by turn. Making it a
  script guarantees all gates run every time, validates envelopes at the
  call site, and gives a bounded fix → re-review loop with a circuit breaker.
- **Eval corpora for the remaining agents.** Five gates have seeded fixtures;
  the other sixteen agents have none, so a prompt regression in them is
  invisible. This is the largest known hole.
- **Wiring `boot-smoke`.** A "fresh clone boots" gate that ships and is
  called by nothing. Audit finding, still open.
- **Anthropic Skills directory + plugin marketplace submission** — once the
  above settles.

Explicitly **not** on the runway:

- **Dependency-aware DAG scheduler.** The coupling map for both current
  adopters shows clean clusters, not pervasive tangle, so session-per-cluster
  is the answer. Re-evaluation triggers in `docs/COUPLING_MAP.md §7`.
- **Engine self-improvement that writes.** An agent may *propose*
  (`pe incident propose`, materialized in your project, never in the engine).
  There is no auto-apply mode and there will not be one — one bad auto-commit
  would propagate to every adopter through `pe sync`.

---

## Why I'm asking you specifically

You've shipped real software with AI assistance. You've felt the
same friction I have. You're honest enough to tell me when
something doesn't work. That's exactly the cohort I need before
this goes wider.

Thanks for taking the time.

— Sanish ([8Colors](https://8cs.io))
