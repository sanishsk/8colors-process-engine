---
description: Chain brainstorm → brief → architect → plan → tdd for a new feature, checking each artifact exists before advancing. The strongest brief-before-code enforcement short of file-system hooks.
---

# /new-feature [topic]

Walks the full brief-before-code pipeline for a new feature. Refuses to
skip stages — if an artifact is missing, the command surfaces exactly
which step to run and stops. This is the operator's guarantee that the
engine's flagship anti-rework mechanism actually fires.

## Contract

Each stage produces a REQUIRED artifact at a known path. The next
stage checks for it and STOPS if missing.

| Stage | Runs | Produces | Blocks next stage if missing |
|---|---|---|---|
| 1. Brainstorm | `/brainstorm <topic>` | `docs/research/brainstorm-YYYY-MM-DD-<topic>.md` | ✓ |
| 2. Brief | `brief-writer` agent (auto after brainstorm) | `docs/research/brief-<topic>.md` | ✓ |
| 3. Architect | `architect` agent | `docs/research/architect-<topic>.md` | ✓ |
| 4. Plan | `planner` agent | `docs/research/plan-<topic>.md` (task list + risks) | ✓ |
| 5. TDD | `tdd-guide` agent | RED tests written + failing output pasted verbatim | ✓ |
| 6. Implementation | worker (haiku/sonnet/opus by tier) | Code + passing tests | Gate-blocked |
| 7. Code review | `code-reviewer` agent | Envelope PASS/WARN → `.claude/gates/last-gate.json` | Commit-blocked |

## Procedure

Take the `<topic>` slug from the invocation. Then for each stage in
order:

1. **Check the artifact exists** at the documented path.
2. **If missing:** print a diagnostic — "Stage N (<name>) has not run.
   The next step is: <exact command>." Stop. Do not proceed.
3. **If present but stale** (last-mod predates the previous stage's
   artifact): print a diagnostic asking the operator to re-run the
   stage. Stop.
4. **If fresh:** move to the next stage.

### Stage 1 — Brainstorm

- Check for `docs/research/brainstorm-*-<topic>.md`.
- If none, run `/brainstorm <topic>` interactively. Do not fabricate
  content — the brainstorm captures REAL operator input.

### Stage 2 — Brief

- Check for `docs/research/brief-<topic>.md`.
- If missing, invoke the `brief-writer` agent with the brainstorm as
  input.
- STOP after brief is written. Ask operator to read + approve before
  advancing. **Do not auto-advance without approval** — this is where
  the human alignment lives.

### Stage 3 — Architect

- Check for `docs/research/architect-<topic>.md`.
- If missing, invoke the `architect` agent with the brief as input.
- Architect Step 0 (research_index query) MUST fire — the agent's
  Bash tool is now guaranteed by the P0.11 fix.

### Stage 4 — Plan

- Check for `docs/research/plan-<topic>.md`.
- If missing, invoke the `planner` agent with brief + architect doc.

### Stage 5 — TDD

- Invoke `tdd-guide` agent to write RED tests FIRST.
- Do not write any implementation code until the operator confirms the
  RED tests are captured.

### Stage 6 — Implementation

- Only advance here after Stages 1-5 artifacts exist.
- Implement to make tests pass (GREEN), then refactor.
- Coverage floor: read `ENGINE_COVERAGE_MIN` (default 80).

### Stage 7 — Code review + commit

- Recommend `/pre-commit` — it runs the code-reviewer, records the
  envelope, verifies verdict, constructs the commit with the
  evidence-backed `Code-reviewed:` trailer.
- Do NOT bypass. The Claude Code PreToolUse hook blocks bare
  `git commit` anyway (see hooks/pre-commit-envelope-check.sh).

## What this refuses to do

- **Never fabricate a brief.** If the brainstorm is missing, the
  command halts.
- **Never auto-advance past the brief step** without the operator
  seeing it.
- **Never skip Stage 5.** RED-first is non-negotiable for new features.
- **Never write the commit without envelope evidence.** Delegate to
  `/pre-commit`.
