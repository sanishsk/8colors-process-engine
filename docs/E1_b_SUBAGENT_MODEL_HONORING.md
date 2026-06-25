# E1.b — Subagent Model Honoring Investigation

**Status:** Investigation complete, 2026-06-24. ~25 min wall-clock.
**Trigger:** During E1.a live testing the `code-reviewer` agent ran on
Haiku 4.5 despite `model: sonnet` in the engine's agent frontmatter.
The gate-agent paradox depends on the frontmatter being honored.
Operator-required to settle before E1.1 mass-produces the pattern
across 4 more gate agents.

---

## The two questions, decoupled

Per operator framing — they are independent:

1. **Envelope VALIDITY** — already protected. E1.a's self-validation
   step (mandatory `pe gate parse` round-trip before emission) makes
   envelope validity tier-independent. Pass 3 of the E1.a live test
   proved a Haiku agent emits valid envelopes once the contract
   instructs it to call the parser. **Not at risk.**
2. **Gate JUDGMENT QUALITY** — still tier-dependent. A Haiku
   gate emits valid envelopes but makes worse PASS/FAIL calls. **This
   is the silent quality compromise.**

The investigation only addresses #2.

---

## Verdict — both subquestions answered

### Q1: Is `model:` frontmatter honored?

**Yes**, per the official Claude Code subagent docs
(https://code.claude.com/docs/en/sub-agents). Resolution order:

> 1. `CLAUDE_CODE_SUBAGENT_MODEL` environment variable, if set
> 2. Per-invocation `model` parameter (passed by Claude when invoking)
> 3. The frontmatter `model:` field
> 4. Default: `inherit` (uses the same model as the main conversation)

> "The environment variable, per-invocation parameter, and frontmatter
> values are checked against your organization's `availableModels`
> allowlist. A value that resolves to an excluded model is not used
> and the subagent runs on the inherited model instead."

The frontmatter is honored. Live-test observation corroborates: every
E1 / E1.a invocation self-reported `claude-haiku-4-5-20251001`, which
exactly matches the file Claude Code actually read (see Q2).

### Q2: Precedence — project-local vs user-global with the same name?

**Project wins**, per the same docs. Official table:

| Location | Scope | Priority |
|---|---|---|
| Managed settings | Org-wide | 1 (highest) |
| `--agents` CLI flag | Current session | 2 |
| **`.claude/agents/` (project)** | Current project | **3** |
| **`~/.claude/agents/` (user)** | All projects | **4** |
| Plugin's `agents/` | Where plugin enabled | 5 (lowest) |

> "When multiple subagents share the same name, the higher-priority
> location wins."

---

## The actual cause of the observed Haiku behavior

**Not** "frontmatter ignored." The cause is a **propagation gap** in
the 8CStudio install:

```
~/Documents/8Colors/8CStudio/.claude/agents/
├── brief-writer.md      ← symlink → engine repo
├── ceo.md               ← symlink → engine repo
└── researcher.md        ← symlink → engine repo
                            (these 3 only — engine has 14 agents)

~/.claude/agents/         ← 15 regular files, NOT symlinks
├── architect.md         (model: haiku — pre-engine)
├── code-reviewer.md     ← THIS ONE (model: haiku, last touched 2026-05-22)
├── data-model-auditor.md
├── doc-updater.md
├── e2e-runner.md
├── planner.md
├── retrospective-agent.md
├── security-reviewer.md
├── tdd-guide.md
└── ... 6 more
```

`pe install` symlinks **every** engine agent into `<project>/.claude/agents/`
via `ln -sf` (force-overwrite). But it was last run on 8CStudio at an
earlier engine version when only `brief-writer`, `ceo`, and
`researcher` existed in the engine.

The other 13 user-global agents predate the engine — they were
extracted INTO the engine v0.4–v0.7, but the originals remained in
`~/.claude/agents/` as the live source for 8CStudio. Because no
project-local file exists for `code-reviewer`, Claude Code falls
back to the stale user-global copy, which says `model: haiku` and
has none of the E1 / E1.a CRITICAL OUTPUT CONTRACT content.

**This explains every observation:**

| Observation | Cause |
|---|---|
| Agent self-reported `claude-haiku-4-5` | User-global file literally says `model: haiku` |
| Agent didn't emit `gate-envelope` fence on pass 1 | User-global file has no envelope contract section |
| Agent improvised envelope shape on pass 2 | Same — no contract guidance in file Claude Code reads |
| Agent invoked `pe gate parse` on pass 3 | That was a direct-invocation prompt instruction (from me), not the agent file |
| My edits to engine `agents/code-reviewer.md` had no behavioral effect | Engine file was not in Claude Code's resolution path |

---

## Branch decision (operator's framing)

The operator framed two branches:

- **Frontmatter honored → proceed with E1.1.** Frontmatter IS
  honored per docs. ✅
- **Frontmatter NOT honored → STOP, pull orchestrator-choice
  forward.** Not applicable. ❌

So formally: proceed with E1.1.

**But there is a hidden third branch the framing didn't anticipate:**

- **Propagation gap blocks the engine from reaching Claude Code.**
  Until 8CStudio's user-global agent files are aligned with engine
  state, E1.1 can roll out perfectly to the engine repo and have
  zero effect on the running agents. **This must be fixed first.**

Recommendation: **proceed with E1.1, but precede it with a
propagation-fix slot E1.c.**

---

## E1.c — Propagation fix (recommended next slot, ~15 min)

### Goal

Make the engine repo's `agents/*.md` the actual source Claude Code
reads for the `code-reviewer` agent in 8CStudio context, so the
E1 / E1.a contract takes effect.

### Mechanism

```
pe install ~/Documents/8Colors/8CStudio
```

Verify:
- `ls -la ~/Documents/8Colors/8CStudio/.claude/agents/` shows 14
  symlinks (or however many the engine has), including
  `code-reviewer.md → ~/Documents/8Colors/8colors-process-engine/agents/code-reviewer.md`
- Project precedence (rule 3 above) overrides the stale user-global
  files for the duration that the symlinks exist.

### Engine-side follow-up (E1.c.1, separate small slot)

`pe install` currently force-symlinks silently. Two enhancements to
prevent this exact failure mode for beta testers:

1. **Detect collisions.** When installing, check if
   `~/.claude/agents/<name>.md` exists AND differs from the engine
   version. If so, print a warning:

   ```
   ⚠  user-global agent ~/.claude/agents/code-reviewer.md exists.
      It will be SHADOWED by the project-local symlink for this
      project, but other projects without the symlink will still
      read the stale user-global file. Consider:
        - rm ~/.claude/agents/code-reviewer.md  (delete the stale one)
        - or run `pe install` in each project that needs the engine
   ```

2. **Add `pe doctor <project>` check.** Already exists; add a
   collision check that lists every `<name>.md` present in
   `~/.claude/agents/` AND the engine, flagging if the project-local
   symlink is missing.

### Why this stays in scope as an engine-repo concern

The 8CStudio propagation gap is a project-specific instance. But the
class of gap — "user-global agent file from a previous era silently
shadows an engine update" — affects every beta tester. Any beta who
installed agents pre-engine (or used Claude Code's interactive
`/agents` builder) has the same vulnerability. The fix belongs in
the engine, not in 8CStudio.

---

## What NOT to do

- **Don't delete `~/.claude/agents/<name>.md` files unilaterally.**
  Some may be customized; some may be used by other projects without
  the engine. `pe install` per-project is non-destructive and
  reversible.
- **Don't roll out E1.1 first.** Mass-producing the CRITICAL OUTPUT
  CONTRACT pattern onto 4 more engine-repo agents has zero effect on
  the running gates until E1.c is done. We'd be optimizing the
  wrong layer.
- **Don't add a `CLAUDE_CODE_SUBAGENT_MODEL` env-var override yet.**
  It's the highest-priority resolution rule per the docs, but using
  it would mean every gate agent is locked to a single model
  globally, defeating per-agent tier choice. Reserve as an emergency
  escape hatch.

---

## Open questions for follow-up retros

1. **Were the 13 user-global agent files customized by the user
   over the past year?** If yes, a blanket `rm` would lose work; if
   no, deleting them is a clean way to make the engine the only
   source. The `git log` of `~/.claude/agents/` (if it's a git repo)
   would settle this — but it isn't a repo. **Need to diff each
   user-global file against the engine version to see if any
   diverged beyond cosmetics.** Out of scope for E1.b; logged.

2. **Does Claude Code cache subagent definitions across sessions?**
   If yes, even after `pe install` lands the symlinks, the running
   session may keep using the stale Haiku version. The docs don't
   explicitly say. Worth a quick empirical test post-E1.c.

3. **`pe install` updates the engine but other projects (vReview,
   Lipi) may also have stale user-global agents shadowing.** Engine
   doctor should be a `pe doctor --all-projects` once a beta has
   multiple installs.

---

## Receipt

- Investigation duration: ~25 min wall-clock.
- Docs source: https://code.claude.com/docs/en/sub-agents (fetched
  2026-06-24).
- Filesystem evidence:
  - `8CStudio/.claude/agents/`: 3 symlinks (`brief-writer`, `ceo`,
    `researcher`).
  - `~/.claude/agents/`: 15 regular files including the stale
    `code-reviewer.md` (model: haiku, mtime 2026-05-22).
  - Engine repo `feat/e1-gate-envelope` branch's
    `agents/code-reviewer.md`: model: sonnet + CRITICAL OUTPUT
    CONTRACT (the version Claude Code SHOULD be reading).
- Live-test corroboration: 3 invocations, all returned
  `model_used: claude-haiku-4-5-20251001`, which is the precise model
  ID the stale user-global file declares.

The gate-agent paradox is **honored by the runtime**; the engine
just isn't reaching the runtime yet for this project.
