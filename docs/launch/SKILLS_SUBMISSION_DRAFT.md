# Anthropic Skills directory submission draft

> Draft submission for the two session skills to the Anthropic Skills
> directory (when / if available). The skills are user-global and
> project-agnostic, which makes them clean fits for the directory
> format.

---

## Skill 1: `start-session`

**Name:** start-session

**Tagline:** Orient at the start of a Claude Code session — read
your project context, surface the active focus, flag stale plans,
and recommend the first task. Never starts work without your
go-ahead.

**Description (long):**

Most Claude Code sessions start with re-explaining context Claude
could read on its own. This skill picks up CLAUDE.md, MEMORY,
weekly plans, quality calendars, and recent git activity — then
surfaces what matters in a single orientation report:

- ⚠ banners that need verbatim attention (obligations, deadlines)
- The current active focus (per the weekly plan)
- Plan items that already shipped (cross-referenced against
  recent commits)
- Overdue recurring tasks (from the quality calendar, if you have
  one)
- Open blockers from the prior session's RESUME HERE pointer
- A recommended first task, with size estimate and the strongest
  single reason to do it

Then it stops and waits for you to decide. It never starts work
autonomously.

The skill is project-agnostic: it discovers files via a graceful
fallback chain (CLAUDE.md → README.md → git log) and degrades
cleanly when optional context is absent. Per-project customization
via `.claude/session.yaml` (add custom report sections, override
operating mode, skip sections that don't apply).

Token budget: under 8k input tokens on a typical project.

**When to use:**

- At the start of any coding session, especially when returning to
  a project after >1 day
- When picking up a multi-slot feature wave mid-stream
- When operating across multiple projects and you need fast
  re-orientation

**When NOT to use:**

- The user has already stated a precise task in the same turn
- The session is a single-file edit or hotfix with clear scope

**Use cases / example outputs:**

(Include 2-3 screenshots of real orientation reports from real
projects.)

**Author:** Sanish ([8Colors](https://8cs.io))

**License:** MIT

**Repo:** https://github.com/sanishsk/8colors-process-engine

**Standalone install:** Copy `skills/start-session/SKILL.md` to
`~/.claude/skills/start-session/SKILL.md`. Restart Claude Code.

---

## Skill 2: `end-session`

**Name:** end-session

**Tagline:** Close out a coding session — surface uncommitted work,
sync status, memory banner updates, deliverables ledger, and
next-session pickup pointer. Never auto-commits.

**Description (long):**

The end of a session is where context gets lost: uncommitted
changes drift, MEMORY pointers go stale, the next-session "where
was I" becomes a 10-minute reconstruction.

This skill runs a structured close-out:

1. **Working-tree status** — `git status` + diff stats. Asks you
   what to do with uncommitted changes; never auto-commits.
2. **Local-vs-origin sync** — N commits ahead / N behind. Surfaces
   anything you'd want to push or carry forward.
3. **Pending MEMORY banner check** — scans the auto-memory file for
   ⚠ banners, resolves which ones this session advanced, proposes
   edits (diffs only — never writes without approval).
4. **Session deliverables ledger** — commits with hashes, BACKLOG
   entries added / modified, memory files touched, unresolved items.
5. **Next-session pickup hints** — proposes the literal RESUME HERE
   block to drop into MEMORY.md so next session re-orients in 3
   tool calls.
6. **Final state confirmation** — `git log -5` + `git status` +
   "session can close" / "session can close with WIP carry-forward".

The skill produces a single message. It NEVER auto-commits, NEVER
auto-edits MEMORY, NEVER pushes to origin. Every change is
surfaced for explicit approval first.

Token budget: under 3k input tokens.

**When to use:**

- About to close the terminal or switch projects
- Reached a natural slot boundary (just merged / just promoted)
- Approaching context-window pressure and want a clean handoff

**When NOT to use:**

- Mid-edit on a single file with a 5-minute return
- The user has explicitly asked for a different close-out flow

**Use cases / example outputs:**

(Include 2-3 screenshots of real close-out reports.)

**Author:** Sanish ([8Colors](https://8cs.io))

**License:** MIT

**Repo:** https://github.com/sanishsk/8colors-process-engine

**Standalone install:** Copy `skills/end-session/SKILL.md` to
`~/.claude/skills/end-session/SKILL.md`. Restart Claude Code.

---

## Submission notes

- Both skills are part of a larger plugin (8colors-process-engine)
  but work standalone with no other dependencies.
- The plugin's other agents and hooks complement the skills but
  aren't required.
- I'm a single developer; the engine has been validated on one
  production codebase (8CStudio). Beta cohort feedback comes
  before any v0.8 release.
- Happy to iterate on the skill descriptions or formatting based
  on directory guidelines.
