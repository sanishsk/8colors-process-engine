# 8colors-process-engine — beta tester brief

> Hand-out for the 2–3 beta cohort. Copy / paste / link as needed.
> **Last updated 2026-06-30 for v0.8.0** (Phase 3 escalation router
> graduated 2026-06-28; distribution bundle shipped 2026-06-30).

---

## TL;DR

I built **`8colors-process-engine`** — a portable Claude Code plugin
that drops **15 specialist agents**, semantic search over your research
docs, a weekly retro cron job, 5 slash commands, 2 session skills,
6 pre-commit governance hooks, and a **verdict-blind gate escalation
router** into any project in **one install command**. Defaults need
**zero API keys**. MIT-licensed. I want your hands on it for 2–4
weeks of real work, then I want to know what broke, what was
confusing, and what you expected that wasn't there.

Repo: <https://github.com/sanishsk/8colors-process-engine>
Current version: **v0.8.0**

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

## What's in the box (v0.8.0 inventory)

### 15 specialist agents

Each has a single job, a model tier matched to that job, and
explicit when-to-invoke rules:

| Agent | Model | Job |
|---|---|---|
| `brief-writer` | Sonnet | 1-page brief with alternatives + market check; required before non-trivial work |
| `researcher` | Haiku | OSS / MCP scout; runs async, parallel with implementation |
| `architect` | Opus | System design, scalability, integration patterns |
| `planner` | Opus | Multi-slot implementation plans with dependency analysis |
| `code-reviewer` | Haiku | MANDATORY before commit; emits gate envelope; CRITICAL findings block |
| `security-reviewer` | Sonnet | OWASP top 10, secrets, auth, input handling; emits gate envelope |
| `database-reviewer` | Sonnet | PostgreSQL schema / migration / RLS / tenant isolation; emits gate envelope |
| `tdd-guide` | Sonnet | Write-tests-first; enforces 80%+ coverage; emits gate envelope |
| `e2e-runner` | Sonnet | Generates + runs E2E tests; manages journeys + artifacts; emits gate envelope |
| `doc-updater` | Haiku | Codemaps, READMEs, schema docs |
| `build-error-resolver` | Haiku | Minimal-diff build / type-error fixes; no architectural edits |
| `data-model-auditor` | Sonnet | Finds hardcoded business values; recommends moving them to data model |
| `retrospective-agent` | Sonnet | Daily / weekly / monthly retros from dev-log digests |
| `ceo` | Opus | Friday weekly retro + next-week plan (auto-fires) |
| `memory-consolidator` | Sonnet | Quarterly memory hygiene; archives historical resume blocks |

The 5 agents marked "emits gate envelope" are the **gate agents** —
their JSON output drives the escalation router. See **What's
enforced** below.

`pe install` symlinks all 15 by default. If you want a leaner
install, `pe install --subset gate-only` gives you just the 5 gate
agents; `--subset core` gives you gates + planner + brief-writer +
architect (8 total). Default is `full`.

The `brief-writer` and `architect` agents specifically query the
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

Advanced (mostly for engine developers, not adopters):
`pe baseline capture …` (slot baselines), `pe gate parse <file>`
(validate gate envelope JSON), `pe shadow decide` / `shadow reconcile`
(Phase 3 escalation-router tooling — enforce gated by `--enforce`;
graduated 2026-06-28).

---

## What's enforced — the Phase 3 escalation router (graduated 2026-06-28)

New in v0.7-v0.8, and the piece I'd most like beta feedback on.

Gate agents (code-reviewer, security-reviewer, database-reviewer,
tdd-guide, e2e-runner) each emit a **gate envelope** — a
machine-parseable JSON block with:

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
#   pe install --subset gate-only /path/to/your/project   # 5 gate agents only
#   pe install --subset core /path/to/your/project        # 8 agents

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
  (`cp <engine>/hooks/.pre-commit-config.yaml.template .pre-commit-config.yaml`)
  and try committing without trailers — see what blocks.
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
- **The engine will never auto-modify itself.** No self-detected,
  self-committed "improvements." Every engine change is human-
  reviewed, versioned, and pulled by adopters. `pe sync` is the
  pull mechanism.

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

## What shipped in v0.8.0 (2026-06-30)

The distribution bundle: making "everyone gets engine improvements"
real without the engine ever self-modifying.

- **`pe sync <project>`** — diff-before-clobber re-pointer (details
  above). Ships with a safety-contract smoke test.
- **`pe install --subset {gate-only|core|full}`** — install presets.
  Choice persisted to `.process-engine.yaml` so re-runs honor it.
- **INSTALL.md PATH check** — quick-install now probes `$PATH` and
  prints the exact export line for `~/.zshrc` if `~/.local/bin`
  isn't on PATH (stock macOS zsh doesn't include it).
- **`pe doctor` improvements** — reports engine version at the top
  of self-check + project-check; adds an always-on per-agent
  freshness summary (`N/M up to date`) so the check is visible
  even on a clean install.
- **CHANGELOG discipline** — every code change lands with a
  changelog entry.

## What's next (v0.9+ candidates, shaped by beta feedback)

- **`docs/COUPLING_MAP.md` for your project** — the doctrine of
  "split sessions by coupling cluster, not by module name" (§5 of
  the map). If it clicks for you, tell me; if it's too abstract,
  also tell me.
- **Auto-update suggestion surfacer** — engine LOGS improvement
  candidates (based on retro trends) without APPLYING them; you
  review and apply via normal flow. Blocked on real adopter
  signal for what "recurring pattern" looks like in the wild.
- **Multi-project portfolio mode** — single dashboard / CEO across
  projects you maintain. Blocked on ≥2 multi-project adopters.
- **Anthropic Skills directory + Claude Code plugin marketplace
  submission** — planned once v0.9 stabilizes.

Explicitly NOT on the runway:
- **Dependency-aware DAG scheduler (Phase 4).** The Stage A
  coupling map for both current adopters shows clean clusters, not
  pervasive tangle — so session-per-cluster is the answer and no
  scheduler build is justified today. Re-evaluation triggers in
  `docs/COUPLING_MAP.md §7`.
- **Engine self-improvement / auto-commit.** Never. One bad
  auto-commit would propagate to every adopter via `pe sync`.

---

## Why I'm asking you specifically

You've shipped real software with AI assistance. You've felt the
same friction I have. You're honest enough to tell me when
something doesn't work. That's exactly the cohort I need before
this goes wider.

Thanks for taking the time.

— Sanish ([8Colors](https://8cs.io))
