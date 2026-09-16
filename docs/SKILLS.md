# Engine skills contract (v0.16.0 / P7.4; sources + discovery v0.56.0)

> The engine's opinion on which Claude Code skills belong in the
> operator's `~/.claude/skills/`, where each one comes from, and how to
> tell when it has gone stale. Pair with `pe skills-audit`.

## Why this exists

The 2026-07-02 workflow audit found **67 skills** in `~/.claude/skills/`
and duplicated project/user-global copies of `data-audit`, `health`,
`kickstart`, `onboard`. That's noise: every skill loads context every
time Claude Code resolves a slash-command. The engine's target is a
**curated core set of about twenty** — one clear reason each.

The 2026-09-16 check found the opposite failure. The core set was
present, and **every external skill in it was stale**: sixteen of
sixteen copies differed from their source, and the `frontend-design`
plugin was the December 2025 text, rewritten upstream twice since. Its
old wording pushed toward the glow-and-gradient look `design-critic`
fails. Nothing recorded where a skill came from, so nothing could check.
Hence the Source column.

## The core set

| # | Skill | Why | Source |
|---|---|---|---|
| 1 | `start-session` | Session orientation | `sanishsk/8colors-process-engine` skills/start-session (shipped by `pe install`) |
| 2 | `end-session` | Session close-out | `sanishsk/8colors-process-engine` skills/end-session (shipped by `pe install`) |
| 3 | `coding-standards` | Universal PEP-8-adjacent hygiene across languages | `affaan-m/everything-claude-code` skills/coding-standards |
| 4 | `tdd-workflow` | RED → GREEN → REFACTOR discipline (the engine's TDD agent references this) | `affaan-m/everything-claude-code` skills/tdd-workflow |
| 5 | `verification-loop` | Comprehensive verification framework | `affaan-m/everything-claude-code` skills/verification-loop |
| 6 | `search-first` | Research-before-coding — check package registries + GitHub before hand-rolling | `affaan-m/everything-claude-code` skills/search-first |
| 7 | `security-review` | Auth / user-input / secrets / API-endpoint checklist | `affaan-m/everything-claude-code` skills/security-review |
| 8 | `security-scan` | Scan `.claude/` config for injection risks / misconfig | `affaan-m/everything-claude-code` skills/security-scan |
| 9 | `strategic-compact` | Manual context compaction at phase boundaries (V3 §2) | `affaan-m/everything-claude-code` skills/strategic-compact |
| 10 | `python-patterns` | Pythonic idioms + PEP-8 | `affaan-m/everything-claude-code` skills/python-patterns |
| 11 | `python-testing` | pytest patterns + fixtures + coverage | `affaan-m/everything-claude-code` skills/python-testing |
| 12 | `backend-patterns` | Backend architecture (Node/Express/Next API-routes) | `affaan-m/everything-claude-code` skills/backend-patterns |
| 13 | `frontend-patterns` | React + Next + state management + perf | `affaan-m/everything-claude-code` skills/frontend-patterns |
| 14 | `api-design` | REST resource design + pagination + errors + versioning | `affaan-m/everything-claude-code` skills/api-design |
| 15 | `database-migrations` | Zero-downtime migration patterns | `affaan-m/everything-claude-code` skills/database-migrations |
| 16 | `deployment-patterns` | CI/CD + Docker + health checks + rollback | `affaan-m/everything-claude-code` skills/deployment-patterns |
| 17 | `docker-patterns` | Local dev + container security + multi-service | `affaan-m/everything-claude-code` skills/docker-patterns |
| 18 | `e2e-testing` | Playwright / POM / CI integration / flake handling | `affaan-m/everything-claude-code` skills/e2e-testing |
| 19 | `frontend-design` | The generator for UI work: 2026 AI-design clusters, token-plan pass before code. `design-critic` is the gate that checks what it produced | `anthropics/skills` skills/frontend-design |
| 20 | `grilling` | Dependency-ordered decision rounds, each question with a recommended answer; facts looked up, never asked. Wired into `/brainstorm` and `planner` | `mattpocock/skills` skills/productivity/grilling |
| 21 | *(reserved)* | Pick ONE language-specific skill you actively use (`django-patterns`, `springboot-patterns`, `golang-patterns`, etc.) | its upstream repo |

That's 20 named plus one reserved. Everything not shipped by the
engine is external; the engine's agents assume it is present.

`scripts/skills_audit.py` holds the same list as `CORE_SKILLS`;
`tests/test_skill_discovery_reachable.sh` fails if the two drift.

## Discovery — check before you build

Before writing a new agent, command or skill, look for one that exists.
The order is in `docs/OSS_SEARCH_ORDER.md`; for agent behaviour (a
review, a workflow, a discipline) it starts at [skills.sh](https://skills.sh)
and `npx skills find <topic>`. Install counts are a signal, not a
verdict: a popular skill still goes through the value bar in
`CONTRIBUTING.md`, and one that overlaps an engine agent is not adopted
(Matt Pocock's `tdd`, `code-review` and `implement` overlap `tdd-guide`,
`code-reviewer` and the slot pipeline, so they stay out).

**Adopt, extend or wrap** follows `docs/PROMOTION_BOUNDARY.md`. A wrapper
around an external skill is the same smell as a wrapper around an engine
hook: say what is missing upstream, or configure it, rather than fork it.

**Install channel: the skills CLI.** It is the only channel that writes a
lockfile (`~/.agents/.skill-lock.json`: source, path, hash), which is what
makes `npx skills update` possible. Plugin-marketplace copies could not be
refreshed in practice (`claude plugin update` reported success and changed
nothing), and hand copies carry no source at all.

```bash
npx skills add anthropics/skills --skill frontend-design -g -a claude-code
npx skills add mattpocock/skills --skill grilling -g -a claude-code
npx skills update -g
```

## Freshness — staleness is found by a ritual, not by accident

Monthly, per `docs/RHYTHM.md`: run `npx skills update -g`, then
`pe skills-audit`. The Source column above is the map a freshness check
reads; the upstream comparison itself (`pe skills-audit --upstream`,
local git blob hash against the source's) is the next release.

## What's candidate for stocktake

Anything OUTSIDE the core set that isn't tied to a real, current
project should go. Run `pe skills-audit` to see the actual list on
this machine.

**Common categories to prune:**

- **Language patterns you don't use.** If you're not writing Java,
  delete `java-coding-standards`, `springboot-*`, `jpa-patterns`.
  Same for `cpp-*`, `golang-*` if not applicable, `swift-*` if you
  don't do iOS.
- **Experiments left behind.** `continuous-learning-v2` alongside
  `continuous-learning` — pick one. Same for stale agent-harness /
  RFC-pipeline explorations.
- **One-shot / occasional utilities.** `visa-doc-translate`,
  `investor-materials`, `investor-outreach`, `article-writing` —
  keep as needed, but they don't need to live in `~/.claude/skills/`;
  invoke them from a project when required.
- **Skill/command name collisions.** If `data-audit` exists as BOTH
  a skill and a command, pick one. Skill for reusable knowledge;
  command for a one-line invocation.

## The `pe skills-audit` contract

Zero mutation. The tool never deletes or moves files on the
operator's machine. It surfaces the sprawl; the operator prunes.

```bash
pe skills-audit                            # inventory + classification
pe skills-audit --project /path/to/8CStudio  # + flag project-local duplicates
pe skills-audit --home /some/other/home     # audit a different profile
```

Exit code:
- `0` — no consolidations needed
- `1` — at least one name collision OR at least one engine-command
  shadowed by a same-named skill

## Rationale — why we're opinionated

Each skill adds cognitive load at slash-command resolution time. A
20-item list is scannable in one glance; a 67-item list is not. The
engine's `retrospective-agent` explicitly flags "agents/skills that
were invoked 0 times this week" as candidates for deletion — the
same principle applies to the operator's global set. `pe
skills-audit` makes that suggestion actionable without touching your
machine.

## Not covered by this doc

- **Agents** (`~/.claude/agents/`) — handled by P2.10 in v0.11.1;
  all 14 user-global agents now symlink into the engine.
- **Commands** (`~/.claude/commands/`) — reported by `pe
  skills-audit` but not curated here; commands are typically
  one-line invocations with much lower context cost than skills.
- **Plugins** — not curated here. Where a skill exists both as a plugin
  and through the skills CLI, prefer the CLI copy and disable the plugin,
  so one version loads and it is the one that can update.
