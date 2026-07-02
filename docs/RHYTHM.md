# Weekly Rhythm — process-engine standard

Generic cadence. Project-specific bits (Role.ALL_MODULES, sidebar wiring,
double-margin gate, etc.) stay in the target project's docs.

## Monday — Brainstorm + Plan
- 08:00 — `pe collect --window 1` auto-runs (via cron/launchd — see "Wiring the collector" below)
- 08:35 — researcher agent runs weekly market scan (awesome-mcp-servers, Glama)
- 20:00 — voice/text brainstorm with user on top-priority feature (60 min)
- 21:00 — brief-writer produces draft brief overnight (async)

## Tuesday — Review + Architecture
- Morning — user reads brief (5 min). Thumbs up or revise.
- Once approved — architect agent produces tech design (~2h async)
- Researcher runs in parallel if eval needed
- Evening — user reads tech design (10 min). Thumbs up or revise.

## Wednesday–Thursday — Implementation
- Project's existing workflow runs (CLAUDE.md §9)
- tdd-guide writes tests first
- User codes with Claude Code as developer
- code-reviewer, database-reviewer, security-reviewer invoked per AGENT_INVOCATION_RULES
- **Before any slot commit:** invoke `code-reviewer` agent (MANDATORY).
  CRITICAL findings block commit. HIGH findings addressed before commit
  unless an explicit `Code-skip-reason:` trailer is logged on the commit
  message. See `docs/AGENT_INVOCATION_RULES.md` for the full gate spec.

## Friday — Deploy + Retro
- Morning — staging deploy, user validates (20 min)
- Prod promote with auto-rollback monitor
- 20:00 — ceo agent reads week's dev-log + Sentry + Process v2 triggers
- ceo produces weekly retro + next week's plan
- User reads retro (10 min)

## Total user time: ~4 hours/week

---

## Execution patterns (v0.16.0 / P7.5)

For any given piece of work, first classify the **lane** (see
`OPERATOR_WORKFLOW_V3.md` §4 + `docs/EXECUTION_PATTERNS.md`):

| Lane | Pattern |
|---|---|
| Judgment | Interactive session, plan mode, Fable/Opus |
| Standard slot | Interactive OR background; engine chain |
| Mechanical batch | Headless `claude -p` per item OR worktree fleet |

The four concrete recipes live in `docs/EXECUTION_PATTERNS.md`
(Pattern 1 interactive, Pattern 2 worktree, Pattern 3 headless,
Pattern 4 background). Wire the mechanical work through the
deterministic gates (`hooks/*.sh`) — a cheap model plus a strong
verifier beats an expensive model with no verifier.

## Wiring the collector (P7.3)

The retrospective-agent runs `pe collect` in its Step 0, so the
weekly retro will always produce a digest as long as `pe` is on PATH.
For richer trend data, wire a daily run so 7 fresh daily JSONs are
sitting in `docs/dev-log/daily/` when Friday rolls around.

**macOS (launchd):** create
`~/Library/LaunchAgents/com.<org>.devlog-collect.plist` invoking
`~/.local/bin/pe collect /absolute/path/to/project` at 07:55 daily
(RunAtLoad = true).

**Linux (cron):**

```
55 7 * * * cd /path/to/project && $HOME/.local/bin/pe collect
```

**Manual (any platform):** run `pe collect` before the retro.

The collector is pure git — no Claude tokens, no external services,
runs in seconds. Failure is silent (exit 2 on non-git dirs, exit 3
on git errors); the retrospective-agent degrades gracefully.
