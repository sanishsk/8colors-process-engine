# E1.c — Propagation Fix (the green check)

**Status:** Shipped 2026-06-24. Operator-approved verification per the
sequencing decision after E1.b's investigation.

**Goal:** make the engine repo's `agents/*.md` the actual source
Claude Code reads for the `code-reviewer` agent in 8CStudio context,
so the E1 + E1.a contract takes effect at runtime.

---

## What was done

```
pe install /Users/sanishsasikumar/Documents/8Colors/8CStudio
```

That single command produced:

```
✓ 8colors-process-engine v0.7.0 installed to ...8CStudio
  Agents:    14 symlinked → ...8CStudio/.claude/agents/
  Commands:  9 symlinked → ...8CStudio/.claude/commands/
  Skills:    2 symlinked → ~/.claude/skills/ (user-global)
  ...
```

Pre-install: 3 project-local agent symlinks (`brief-writer`, `ceo`,
`researcher`) — all stale leftovers from when `pe install` was first
run at engine v0.1.

Post-install: 14 project-local agent symlinks, including the
previously missing `code-reviewer.md` → engine version (which has
`model: sonnet` and the full E1 / E1.a CRITICAL OUTPUT CONTRACT).

The stale user-global `~/.claude/agents/code-reviewer.md` (model:
haiku, mtime 2026-05-22) still exists on disk but is now **shadowed**
by the higher-priority project-local symlink (per the official
docs' precedence table — project = priority 3, user-global =
priority 4).

---

## Empirical verification — in-session, no restart

The 8CStudio MEMORY originally noted this verification would need a
Claude Code restart. **It did not.** The probe ran in the same
session as the install and the symlink took effect immediately.

This is itself a useful finding: Claude Code re-reads subagent
definitions per-invocation, not cached from session start. Documented
here for future operators wondering whether to restart.

### Before → after comparison on the same fixture

The fixture is `schemas/fixtures/e1a-live-test/sample_buggy.py`
(synthetic — SQL injection on line 5, mutable default argument on
line 9). Same fixture was used for the E1.a 3-pass test and for this
E1.c probe.

| Metric | E1.a pass 1 (pre-tighten) | E1.a pass 3 (post-tighten, pre-E1.c) | E1.c probe (post-symlink) |
|---|---|---|---|
| `model_used` self-report | `claude-haiku-4-5-20251001` | `claude-haiku-4-5-20251001` | **`claude-sonnet-4-6`** |
| Fence info-string | `json gate-envelope` (right by accident) | `json gate-envelope` | `json gate-envelope` |
| Envelope shape | wrong `rule` format | schema-compliant | schema-compliant |
| Cross-check section | absent | absent | **printed with literal values** |
| Self-validation Bash calls | 0 | 9 (per direct prompt instruction) | **10 (from the agent's own contract)** |
| `pe gate parse` exit code | 4 (schema error) | 1 (FAIL worker_quality) | **1 (FAIL worker_quality)** |

The leftmost column is the original problem; the rightmost is the
green check.

### Standalone round-trip

The probe's emitted envelope was captured at
`schemas/fixtures/e1a-live-test/transcript-4-post-e1c.md` and run
through `pe gate parse` independently:

```
post-E1.c probe exit code: 1 (expected 1 = FAIL worker_quality)
(no stderr — clean envelope)
```

Zero validation errors. The contract is now self-enforcing AND
tier-correct at runtime.

---

## What this proves

The operator's pre-investigation worry was that **tiered routing
might be a no-op** — that even with the gate-agent paradox
documented, the actual model serving the gate might not switch when
the frontmatter says it should. E1.c is the empirical disproof:

1. **`model:` frontmatter IS honored at runtime.** The same fixture
   that produced Haiku output for 3 invocations under stale config
   produced Sonnet output on the very first invocation after
   `pe install`. The only thing that changed is which file Claude
   Code resolved as the `code-reviewer` definition.
2. **Project-local DOES override user-global.** The stale
   `~/.claude/agents/code-reviewer.md` is still on disk; it's just
   ranked below the project-local symlink in the resolution order.
3. **Per-invocation agent-file re-reads are real.** The symlink
   landed at install time and was honored on the next subagent call
   without any session boundary. The 8CStudio MEMORY hint about
   needing a restart was a worst-case assumption; the docs don't
   say one is required, and empirical observation confirms it isn't.

## What this UN-blocks

The Phase 3 escalation router can now route on tier. Without E1.c,
"escalate Haiku → Sonnet → Opus" was vapor — the runtime would have
silently stayed on whatever model the user-global file declared
regardless of router intent.

## What this does NOT do

- **It does not fix the propagation gap on OTHER projects** (vReview,
  Lipi, any future beta). Each project needs `pe install` to land
  the symlinks; the engine alone can't reach into a project's
  `.claude/agents/`. That's E1.c.1's job — preventive collision
  detection so beta testers can self-diagnose.
- **It does not clean up the 13 stale user-global files.** They are
  shadowed for 8CStudio but still active fallbacks for any project
  that hasn't run `pe install`. Cleanup is a follow-up gated by the
  divergence audit (logged in E1.b §"Open questions") — some may
  contain operator customizations.

## Receipts (file paths)

- 8CStudio project-local agents:
  `/Users/sanishsasikumar/Documents/8Colors/8CStudio/.claude/agents/`
  (14 symlinks, including `code-reviewer.md` → engine).
- Engine source pinned to `feat/e1-b-investigation` branch at
  install time (inherits E1 + E1.a content).
- E1.c probe envelope:
  `schemas/fixtures/e1a-live-test/transcript-4-post-e1c.md`.
- Stale user-global (now shadowed for 8CStudio):
  `~/.claude/agents/code-reviewer.md`.

---

## Next: E1.c.1 (engine-side hardening)

The 8CStudio install is fixed. The class of problem ("user-global
file silently shadows engine update") is not — every beta tester is
one stale install away from the same silent failure.

E1.c.1 (next slot) adds **collision detection** to `pe install` and
`pe doctor`:

- `pe install` warns when a user-global file with the same name
  exists, naming each affected agent and explaining that **other**
  projects (those without project-local symlinks) will still read
  the user-global version.
- `pe doctor <project>` reports the same gap as a diagnosable issue,
  so beta testers can detect the shadow before it bites them.

E1.c.1 is built on the engine, will land as its own draft PR.