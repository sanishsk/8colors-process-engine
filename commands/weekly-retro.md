---
description: Invokes the ceo agent for Friday weekly retro + next week's plan. No-op if it's not Friday unless --force flag is used.
---

# /weekly-retro [--force]

Invokes the `ceo` agent for Friday weekly retro + next week's plan. No-op if
it's not Friday (unless `--force` flag used).

CEO produces two files:

- `docs/dev-log/weekly-plan-YYYY-WW.md` — next week's lanes + blockers + trigger check
- `docs/dev-log/retro-YYYY-WW.md` — what went well / broke + agent invocation counts
