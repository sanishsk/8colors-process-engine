---
name: start-session
description: Orient at the beginning of a coding session — read project context, surface the active focus, flag stale plans, list overdue recurring tasks, and recommend the first task. Project-agnostic; gracefully degrades when optional files are absent.
---

# Start Session

A portable orientation skill. Reads whatever context the project provides,
surfaces what matters, recommends the first task, and **waits for the
operator's decision before any code work begins**.

## When to use

Invoke at the start of any coding session, especially when:
- Returning to a project after >1 day away
- Picking up a multi-slot feature wave mid-stream
- Operating across multiple repos and need a fast re-orientation

Skip when:
- The user has already stated a precise task in the same turn
- The session is a single-file edit or hotfix with clear scope

## Procedure

Run these steps in order. **Use parallel tool calls wherever the reads are
independent** (most of them are).

### 1. Discovery — what does this project have?

Check for each of the following. Skip any that are absent; don't fail the
skill on missing files.

| Item | Where to look (in order) | What it gives you |
|---|---|---|
| **Project rules** | `CLAUDE.md` (root) → `.claude/CLAUDE.md` → `README.md` | Permanent constraints, coding rules, architecture pointers |
| **Auto-memory** | `~/.claude/projects/<project-key>/memory/MEMORY.md` (Claude Code auto-loads) → `.claude/MEMORY.md` → `MEMORY.md` | Cross-session memory, banners, "RESUME HERE" pointers |
| **Recurring tasks** | `docs/QUALITY_CALENDAR.md` → `.claude/QUALITY_CALENDAR.md` → `QUALITY_CALENDAR.md` | What recurring work is overdue |
| **Active plan** | `docs/dev-log/weekly-plan-*.md` → `.claude/plans/weekly-plan-*.md` → `docs/PLAN.md` → `PLAN.md` → `ROADMAP.md` | This week's focus (pick highest-numbered or most recent) |
| **Recent activity** | `docs/dev-log/` → `.claude/dev-log/` → `git log -20` | Velocity, recent commits, recent decisions |
| **Session config (optional override)** | `.claude/session.yaml` → `.claude/session.md` | Project-specific tweaks to this skill (e.g. extra files to check, custom report sections) |

If `.claude/session.yaml` (or `.md`) exists, honor any overrides it
specifies — extra files to load, custom report sections, operating-mode
defaults. Treat unknown keys as no-ops; never error on schema drift.

### 2. Read in parallel, then synthesize

Issue all the file reads in a **single tool-call batch**. After they
return, fold into the report.

The **most important content** to lift verbatim into the report:
- Any `⚠️` banner or `RESUME HERE` block at the top of MEMORY (surface
  banner content **verbatim** — don't paraphrase obligations or
  deadlines)
- The "active focus" / "this week" section of the latest plan
- Status indicators (🔴 red, 🟡 yellow, 🟢 green) from the quality calendar

### 3. Cross-reference plan vs reality

For each plan item that claims to be in-flight or planned:
- Grep recent commits (`git log --oneline -30` or per-item by keyword)
- If commit titles, BACKLOG entries, or memory notes indicate the item
  has shipped, **flag the plan as stale**
- Distinguish "shipped" vs "in progress" vs "not started"

If the plan's authoring date (in frontmatter or filename week number) is
**more than 7 days old**, flag the plan as stale regardless of content
drift.

### 4. Quality calendar audit

List items that are:
- 🔴 RED (broken / never run / overdue past freshness window)
- 🟡 YELLOW with `next_due` already past
- Items whose `last_run` is older than the documented freshness window

Don't list green items; the operator already knows they're fine.

### 5. Operating-mode markers

If the operator's invoking prompt or `.claude/session.yaml` sets an
operating mode (e.g. "Tier 2 audit", "advisor principle", "no per-step
STOPs"), acknowledge it in one sentence so the operator knows you
received it.

If no mode is set, default to: ask before committing, surface tradeoffs
on genuinely ambiguous decisions, don't ask A/B/C menus for resolved
ones.

## Output format

Produce a single message structured as:

1. **⚠️ Banner content (verbatim)** — if any banners exist in MEMORY,
   reproduce them at the top before anything else. Skip this section
   silently if there are none.

2. **Weekly plan status** — green / yellow (stale soon) / red (stale).
   If red, name the latest plan file and its age in days.

3. **Plan items already shipped** — cross-reference list. If the plan
   appears done, recommend a fresh plan generation as part of the first
   task.

4. **Actual recent focus** (if different from plan) — what the commit
   log and MEMORY suggest is actually in flight.

5. **Overdue recurring tasks** — bulleted, with last-run dates where
   known. Skip the section entirely if nothing is overdue.

6. **Open blockers** — from MEMORY banners, last session's RESUME HERE,
   or unresolved items in the latest dev-log. One line each.

7. **Recommended first task** — a specific, scoped suggestion. Include:
   - What
   - Why (the strongest single reason)
   - Rough size estimate (S / M / L)
   - First concrete action (e.g. "Sentry MCP check on `release:<sha>`")

8. **End with**: "Awaiting decision." Do not start any work.

Aim for ≤400 words total. Skip empty sections rather than padding.

## Configuration override (optional)

Projects can place `.claude/session.yaml` at repo root to customize:

```yaml
# .claude/session.yaml — all keys optional
extra_files:
  # additional files to read during discovery
  - path: docs/DEPLOY_REFERENCE.md
    label: "Deploy procedures"
  - path: docs/architecture.md
    label: "System architecture"

custom_sections:
  # extra report sections to surface
  - title: "Production health"
    source: docs/incidents/open.md
  - title: "Customer support inbox"
    command: "gh issue list --label support --limit 5"

operating_mode:
  default: "Tier 2 audit, advisor principle, code-reviewer at each commit"
  # override on invocation by passing args to the skill

skip_sections:
  # report sections to silently omit (e.g. for solo projects with no plan)
  - "weekly plan status"
```

Or `.claude/session.md` for a free-form override (project-specific
prose appended to the report).

## Failure modes to avoid

- **Don't fabricate plan items, banner content, or `last_run` dates.**
  If a section can't be filled because the source file is missing, omit
  the section. Never invent.
- **Don't paraphrase obligation banners.** They often carry exact
  amounts, dates, or rubric numbers. Verbatim or not at all.
- **Don't start coding.** This skill ends with "Awaiting decision." even
  if the recommended first task looks obviously right. The operator
  chooses.
- **Don't run destructive commands during discovery.** Read-only file
  reads + `git log` + optional `gh` queries declared in `.claude/session.yaml`
  only.
- **Don't load the entire dev-log directory.** Just the latest entry
  (highest week number or most recent mtime).

## When the project has *none* of these files

Still useful — degrade gracefully:
1. Read `README.md` if present
2. Run `git log --oneline -20` for recent activity
3. Run `git status` for working tree state
4. Surface: "No CLAUDE.md / MEMORY / plan / calendar detected. Operating
   from git context only. Want me to scaffold the engine?
   (`/onboard` / `/kickstart` are options.)"
5. Recommend the first task based on `git status` + last commit subject
6. Awaiting decision.

## Token budget

This skill should consume **under 8k input tokens** in total file reads
on a typical project. If the project has CLAUDE.md > 40 KB or
MEMORY.md > 20 KB, flag the size in the report so the operator knows to
trim — large context files slow every future session.
