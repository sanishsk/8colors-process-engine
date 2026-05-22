# Agent Invocation Rules

| Slot type | Agents in order |
|---|---|
| New feature idea | /brainstorm → brief-writer → architect → tdd-guide → code-reviewer |
| OSS/library decision | researcher → architect → code-reviewer |
| Schema migration | brief-writer → database-reviewer → code-reviewer → security-reviewer |
| Auth/multi-tenancy | brief-writer → security-reviewer (mandatory) + database-reviewer + code-reviewer in parallel |
| Bug fix | tdd-guide (regression test first) → code-reviewer |
| Build error | build-error-resolver |
| UI change | brief-writer → ui-ux-design-agent (max 1 v0 prompt/module) → code-reviewer |
| **Before any commit on a slot** | **code-reviewer (mandatory) — reads staged files, blocks on CRITICAL findings, HIGH addressed before commit unless explicit skip-reason logged** |
| Weekly retro | ceo |
| Phase boundary | /lock-backlog → ceo |

## Mandatory pre-commit gate — `code-reviewer`

Every slot commit on a feature branch MUST be preceded by a `code-reviewer`
invocation in the same Claude Code session. The agent reads staged files
and outputs findings at CRITICAL / HIGH / MEDIUM / LOW severity.

- **CRITICAL** → blocks commit. Must be addressed.
- **HIGH** → addressed before commit, OR an explicit
  `Code-skip-reason: <reason>` trailer added to the commit message.
- **MEDIUM / LOW** → noted, addressed in same slot or backlogged.

This is a behavioural + documentary gate. The existing
`code-review-trailer` pre-commit hook (≥5-file threshold) stays as
belt-and-suspenders backup but does NOT replace the workflow-stage
invocation. Rationale and tradeoffs: see the target project's
`docs/research/brief-code-reviewer-workflow-stage.md`.

Parallel review pattern for high-risk slots (RLS changes, payment, auth):
Launch 3 agents in parallel:
1. security-reviewer — data isolation focus
2. database-reviewer — transaction safety + RLS
3. code-reviewer — general quality

Aggregate findings; fix CRITICAL + HIGH before merge.
