# Engine skills contract (v0.16.0 / P7.4)

> The engine's opinion on which Claude Code skills belong in the
> operator's `~/.claude/skills/` — and why the rest is candidate for
> stocktake. Pair with `pe skills-audit`.

## Why this exists

The 2026-07-02 workflow audit found **67 skills** in `~/.claude/skills/`
and duplicated project/user-global copies of `data-audit`, `health`,
`kickstart`, `onboard`. That's noise: every skill loads context every
time Claude Code resolves a slash-command. The engine's target is
**≤20 curated** — one clear reason each.

## The core-20

| # | Skill | Why | Where it comes from |
|---|---|---|---|
| 1 | `start-session` | Session orientation | **Engine-shipped** (`pe install`) |
| 2 | `end-session` | Session close-out | **Engine-shipped** (`pe install`) |
| 3 | `coding-standards` | Universal PEP-8-adjacent hygiene across languages | External / ECC |
| 4 | `tdd-workflow` | RED → GREEN → REFACTOR discipline (the engine's TDD agent references this) | External / ECC |
| 5 | `verification-loop` | Comprehensive verification framework | External / ECC |
| 6 | `search-first` | Research-before-coding — check package registries + GitHub before hand-rolling | External / ECC |
| 7 | `security-review` | Auth / user-input / secrets / API-endpoint checklist | External / ECC |
| 8 | `security-scan` | Scan `.claude/` config for injection risks / misconfig | External / ECC |
| 9 | `strategic-compact` | Manual context compaction at phase boundaries (V3 §2) | External / ECC |
| 10 | `python-patterns` | Pythonic idioms + PEP-8 | External / ECC |
| 11 | `python-testing` | pytest patterns + fixtures + coverage | External / ECC |
| 12 | `backend-patterns` | Backend architecture (Node/Express/Next API-routes) | External / ECC |
| 13 | `frontend-patterns` | React + Next + state management + perf | External / ECC |
| 14 | `api-design` | REST resource design + pagination + errors + versioning | External / ECC |
| 15 | `database-migrations` | Zero-downtime migration patterns | External / ECC |
| 16 | `deployment-patterns` | CI/CD + Docker + health checks + rollback | External / ECC |
| 17 | `docker-patterns` | Local dev + container security + multi-service | External / ECC |
| 18 | `e2e-testing` | Playwright / POM / CI integration / flake handling | External / ECC |
| 19 | `frontend-design` | High-quality frontend generation without generic AI aesthetic | External / ECC |
| 20 | *(reserved)* | Pick ONE language-specific skill you actively use (`django-patterns`, `springboot-patterns`, `golang-patterns`, etc.) | External / ECC |

That's 20. Rows 3–19 are external (mostly Everything Claude Code /
ECC) — the engine doesn't ship them, but the engine's agents assume
they're available.

## What's candidate for stocktake

Anything OUTSIDE the core-20 that isn't tied to a real, current
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
- **Plugins** — future P3.3 work; not in scope.
