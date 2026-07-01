# Troubleshooting

Failure modes the engine has seen in real use, with diagnosis steps
and fixes. Beta-tester-facing.

If you hit something not in this doc, please open an issue with the
diagnosis chain (symptoms → what you suspected → what you ruled out
→ what actually fixed it) so the next person doesn't have to repeat
the work.

---

## 1. "I edited an agent in the engine repo and Claude Code still behaves the old way."

### Symptoms

You bumped `agents/<name>.md` in the engine repo — model frontmatter,
system prompt, output contract, anything. Restarted Claude Code. The
agent's behavior is unchanged. The new content has zero runtime
effect.

### Wrong diagnosis we wasted half a day on

> "The `model:` frontmatter must not be honored by Claude Code's
> subagent runtime."

The official Claude Code subagent docs are explicit that it **is**
honored:

```
Resolution order:
  1. CLAUDE_CODE_SUBAGENT_MODEL env var
  2. per-invocation parameter
  3. frontmatter model: field
  4. inherit (parent session model)
```

The frontmatter works. The runtime just isn't reading your file.

### Real root cause — the stale-shadow propagation gap

Claude Code resolves subagent definitions by name across these
locations, in priority order (highest wins on name collision):

| Priority | Location | Scope |
|---|---|---|
| 1 | Managed settings | Org-wide |
| 2 | `--agents` CLI flag | This session |
| 3 | `<project>/.claude/agents/` | Project |
| 4 | `~/.claude/agents/` | User-global |
| 5 | Plugin `agents/` | Plugin-scoped |

`pe install <project>` symlinks every current engine agent into the
**project-local** `.claude/agents/` (priority 3). The symlink follows
the engine repo, so engine upgrades propagate.

**The trap:** `pe install` only adds project-local symlinks for
agents the engine has **at install time**. Agents added in later
engine versions, OR `~/.claude/agents/<name>.md` regular files that
predate the engine, are NOT touched by a stale install.

When you later edit `agents/<name>.md` in the engine repo, the
symlink in your project still points at the engine file — but for
projects where `pe install` was never re-run, there is no
project-local symlink for `<name>` at all. Claude Code falls through
to user-global (priority 4), which is the old regular file. Your
engine edit is silently shadowed.

### How to confirm in 60 seconds

```bash
# 1. What does Claude Code actually resolve for this agent?
ls -lH <project>/.claude/agents/<name>.md 2>/dev/null
ls -lH ~/.claude/agents/<name>.md 2>/dev/null

# 2. If project-local doesn't exist OR isn't a symlink to the engine,
#    you're hitting the shadow.
```

If project-local is missing, Claude Code reads the user-global file
(or nothing). If project-local is a non-symlink file (someone manually
copied), it's whatever's in that file, frozen in time.

### Fix

```bash
pe install <project>
```

This is non-destructive — it `ln -sf`'s engine agents into project-local.
The stale user-global file remains on disk but is now shadowed by the
higher-priority project-local symlink for THIS project.

No Claude Code restart is required. The next subagent invocation reads
the new file. (Empirically verified during E1.c, 2026-06-24.)

### Verify the fix works

Invoke the subagent on something representative. Check what model the
agent self-reports (most agents will include this in their output, or
you can ask). If the model id matches the engine frontmatter, you're
clean.

### Prevent recurrence

`pe install` since v0.7.x (E1.c.1) warns about user-global collisions
at install time:

```
⚠  USER-GLOBAL AGENT COLLISIONS DETECTED (3 files)
   These regular files in ~/.claude/agents/ DIFFER from the engine
   versions of the same agents. ...
   Affected agents:
     - ~/.claude/agents/architect.md
     - ~/.claude/agents/code-reviewer.md
     - ~/.claude/agents/security-reviewer.md
```

Read the warning. Don't dismiss it. Other projects you haven't
re-installed are still resolving the stale copies.

`pe doctor <project>` adds two diagnostic categories that surface
the same gap from a project's perspective:

```
✗ SHADOWED by stale user-global files (3):
    ~/.claude/agents/architect.md  (regular file, differs from engine)
    ~/.claude/agents/code-reviewer.md  (regular file, differs from engine)
    ~/.claude/agents/security-reviewer.md  (regular file, differs from engine)
  Fix: re-run 'pe install <project>' to add project-local symlinks.

⚠ Engine agents not installed in this project (4):
    brief-writer.md
    ceo.md
    memory-consolidator.md
    researcher.md
  Fix: 'pe install <project>' to symlink them.
```

`SHADOWED` is treated as a broken-symlink-equivalent and contributes
to the doctor's exit code, so CI / pre-push gates can fail on it.

### Cleanup decision tree (for user-global files)

After running `pe install` everywhere that matters, you can optionally
clean up the user-global regular files entirely. **Do this carefully.**

```
For each user-global file ~/.claude/agents/<name>.md that pe install
warned about:

  diff ~/.claude/agents/<name>.md <engine-repo>/agents/<name>.md

  → No differences (identical content)
       rm ~/.claude/agents/<name>.md           # safe, falls through
                                              # to engine projects-locally

  → Trivial differences (whitespace, header lines)
       rm ~/.claude/agents/<name>.md           # safe

  → Substantive differences in prompt body or behavior
       The user-global file has operator customizations from before
       engine integration. DO NOT delete blindly.
       Options:
         (a) Port the customization into engine/agents/<name>.md.
             Commit on a branch. PR review. Then rm user-global.
         (b) Keep the user-global as-is for projects that intentionally
             use that variant. They will continue to resolve it.
         (c) Promote the customization to project-local for ONLY the
             projects that want it; let other projects use the engine
             version.
```

Detection of "trivial vs substantive" is a per-file judgment — there
is no automation. The engine warns; the operator decides.

---

## 2. "The gate emitted what looked like a valid envelope but `pe gate parse` rejected it."

### Symptoms

A gate agent (e.g. `code-reviewer`) emitted a JSON-shaped block in its
output. You ran `pe gate parse <transcript>` and got exit code 4 with
schema errors.

### Common causes (in decreasing frequency)

1. **Wrong fence info-string.** The parser only locates blocks fenced
   with literally ` ```json gate-envelope ` (two tokens). A plain
   ` ```json ` block is intentionally ignored so review prose can
   contain other JSON examples without false positives.

   **Fix:** the agent prompt's CRITICAL OUTPUT CONTRACT section
   defines this. If a fresh agent isn't honoring it, it's almost
   certainly reading a stale shadow file (see §1).

2. **`rule` field has spaces, capitals, or punctuation.** The schema
   enforces `^[a-z0-9][a-z0-9-]*$` — kebab-case-only. Human-readable
   descriptions belong in `message`, not `rule`.

   **Wrong:** `"SQL Injection — f-string concatenation"`
   **Right:** `"sql-injection"`

3. **Made-up field names** like `category`, `title`, `detail`,
   `code_snippet`, `recommendation`, `cwe`, `total_findings`. The
   schema's `additionalProperties: false` rejects unknown fields.

   **Fix:** put the extra info in `message` or `summary`. The agent
   prompt lists the banned set explicitly.

4. **Verdict not in {PASS, WARN, FAIL}.** Free-text verdicts like
   `"BLOCK — CRITICAL issue"` fail validation.

5. **Missing required fields.** All seven are required:
   `schema_version`, `gate_name`, `verdict`, `failure_class`,
   `model_used`, `timestamp`, `findings` (may be empty array).

### Diagnose by reading the stderr

`pe gate parse` prints each schema error with a JSON-path pointer:

```
ENVELOPE INVALID:
  - $.findings[0].rule: string 'SQL Injection — f-string' does not match pattern '^[a-z0-9][a-z0-9-]*$'
  - $.verdict: value 'BLOCK' not in enum ['PASS', 'WARN', 'FAIL']
```

Each line names exactly what's wrong. Hand-fix or re-prompt.

### Why the agents are supposed to self-validate

The CRITICAL OUTPUT CONTRACT (E1.a) requires gate agents to call
`pe gate parse` against their **own draft envelope** before emitting.
If the draft fails validation, the agent reads stderr, fixes, retries
(max 3 iterations).

If your gate skipped the self-validation step entirely, it's reading
a stale shadow file that doesn't have the contract. See §1.

---

## 3. "`pe install` says 'install completed' but my project still resolves the old agents."

Almost always §1 — you have a stale `~/.claude/agents/<name>.md`
that's now shadowed for THIS project but you had a stale Claude Code
session reading the old resolution.

The fix is per-invocation, not per-session: just re-invoke the agent.
Empirically verified during E1.c.

If that doesn't work:

```bash
pe doctor <project>
```

Look for `✗ SHADOWED` or `⚠ Engine agents not installed`. If neither
appears, the project install is clean and the issue is elsewhere
(perhaps an actual Claude Code bug — file an issue).

---

## 4. "`pe install` succeeded but `pe doctor` reports broken symlinks."

The most common cause: you've moved or renamed the engine repo since
the project was installed. The project-local symlinks are now dangling.

```bash
pe install <project>     # re-symlinks with the new engine path
```

If the engine path is correct but agents are still missing, an engine
update may have deleted an agent file (e.g. an agent was renamed).
As of **v0.9.0** (E1.c.2), `pe install` reconciles this automatically:
broken symlinks in `.claude/agents/` and `.claude/commands/` are
silently removed on re-install. Real files (operator customizations)
are never touched — only dangling symlinks.

Subset-downgrade orphans (fine symlinks to agents that are no longer in
the current subset, e.g. after `pe install --subset gate-only` following
a `full` install) are NOT removed by install. They are removed
interactively by `pe sync <project>` — see the `orphan` state in
`pe help sync`.

## 4b. "Why does my project have a broken symlink I didn't create?"

Almost always: you re-installed the engine while switched to a
different branch that had a superset of agents, then went back to a
branch where one agent was removed or renamed. The project-local
symlink was created against the wider branch's `agents/` set.

As of v0.9.0, this heals on the next `pe install <project>` (E1.c.2).
Before v0.9.0, the manual fix was `find <project>/.claude/agents -xtype l -delete`.

---

## 5. "A pre-commit or commit-msg hook is blocking and I think it's wrong."

Hooks installed by `pe install` are in `templates/.pre-commit-config.yaml.template`
and `hooks/` in the engine repo. Each hook has a documented bypass
mechanism (trailers like `Code-skip-reason: <reason>`, env-var
overrides like `ENGINE_REVIEW_THRESHOLD`).

**Do not use `--no-verify` to skip hooks.** It bypasses every gate
at once, including the ones that exist for a reason. If a specific
hook is blocking incorrectly, override it specifically (per `hooks/README.md`)
or document the override reason in the commit trailer.

If the hook itself is buggy (false positives), open an engine issue
with a reproduction case.

---

## How to add to this doc

When you hit a new failure mode and trace it to a real root cause:

1. Open a PR with a new top-level section.
2. Use the same shape: **Symptoms → Wrong diagnosis (if you went
   down a dead end) → Real root cause → Confirm in 60 seconds →
   Fix → Prevent recurrence.**
3. Cite the engine version where the failure was observed and any
   linked PR/issue.

The "Wrong diagnosis" section is the most valuable part for the next
reader — it documents the failure of intuition that the fix is
correcting for. Skip it only if there was no plausible wrong path.
