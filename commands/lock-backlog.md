---
description: Lock a phase backlog (e.g., shoot backlog) — produces an immutable docs/<PHASE_NAME>_BACKLOG.md that the ceo agent reads but cannot modify.
---

# /lock-backlog [phase-name]

Locks a phase backlog. Workflow:

1. Read all approved briefs in `docs/research/brief-*.md`.
2. Read `docs/BACKLOG.md` for context.
3. Ask user: "What's the phase name and end date?"
4. Ask user: "Which 5–7 features are critical-path?"
5. Produce `docs/<PHASE_NAME>_BACKLOG.md` with: features in priority order, estimated slot sizes, parallelizable lanes marked, success criteria.
6. File is immutable until phase ends — `ceo` agent reads it but cannot modify.

Use case: "lock the shoot backlog" before shoot starts.
