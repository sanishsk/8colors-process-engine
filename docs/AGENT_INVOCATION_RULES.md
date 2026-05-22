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
| Weekly retro | ceo |
| Phase boundary | /lock-backlog → ceo |

Parallel review pattern for high-risk slots (RLS changes, payment, auth):
Launch 3 agents in parallel:
1. security-reviewer — data isolation focus
2. database-reviewer — transaction safety + RLS
3. code-reviewer — general quality

Aggregate findings; fix CRITICAL + HIGH before merge.
