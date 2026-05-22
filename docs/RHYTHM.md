# Weekly Rhythm — process-engine standard

Generic cadence. Project-specific bits (Role.ALL_MODULES, sidebar wiring,
double-margin gate, etc.) stay in the target project's docs.

## Monday — Brainstorm + Plan
- 08:00 — dev-log auto-runs (project's existing tooling)
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
