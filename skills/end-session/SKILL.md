---
name: end-session
description: Close out a coding session — surface uncommitted work, sync status, memory banner updates, deliverables ledger, and next-session pickup hints. Project-agnostic; never auto-commits or auto-edits memory without explicit operator approval.
---

# End Session

A portable close-out skill. Reports state, proposes memory updates, lists
deliverables, and writes the next-session pickup pointer — but **never
mutates state autonomously**. Every change is surfaced for operator
approval first.

## When to use

Invoke at the end of a coding session, especially when:
- About to close the terminal or switch projects
- Reached a natural slot boundary (e.g. just merged or promoted)
- Approaching context-window pressure and want a clean handoff

Skip when:
- The session is mid-edit on a single file and you'll resume in <5 min
- The user has explicitly asked for a different close-out flow

## Procedure

Run these steps **in order**. Most are sequential because later steps
depend on earlier output.

### 1. Working-tree status check

Run `git status` (concise) and `git diff --stat`.

If there are uncommitted changes:
- List the changed files (grouped by modified / new / deleted)
- Ask the operator: "Commit before close, leave as WIP, or stash?"
- **Do not auto-commit.** Operator decides.

If clean: state "Working tree clean."

### 2. Local-vs-origin sync check

Determine the upstream branch:

```bash
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null
```

If an upstream exists, run:

```bash
git log @{u}..HEAD --oneline
git log HEAD..@{u} --oneline
```

Report:
- N commits **ahead** of upstream (list them with hashes + subjects)
- N commits **behind** (list, if any)
- If ahead-only: "Want to push or carry forward?" — operator decides
- If behind: flag potential conflict before next session

If no upstream is configured, state that and move on.

### 3. Pending MEMORY banner check

If a MEMORY.md exists (check the discovery order from `start-session`):

- Scan for `⚠️` banners, `RESUME HERE` blocks, "verification pending"
  notes
- For each one, determine from this session's activity whether it has
  been **resolved**, **partially advanced**, or **untouched**
- Propose specific edits:
  - Banners to remove (with the diff: old block → "(remove)")
  - Banners to update (old text → proposed new text)
  - New banners to add (e.g. for an obligation surfaced this session)

**Wait for operator approval before applying.** Surface diffs; don't write.

### 4. Session deliverables ledger

Produce a structured ledger:

**Commits this session** — use:
```bash
git log --oneline --since="<session start time>" --author="$(git config user.email)"
```
Or scope by the SHA range from session-start to HEAD if known.

For each commit: hash, one-line description, optionally the trailer
status (e.g. `Code-reviewed: yes`, `Docs-updated: …`).

**BACKLOG entries added or modified** — grep `docs/BACKLOG.md` (or
project equivalent) against the session's commit diffs for new `#NNN`
entries or status flips.

**Memory files written or appended** — list files under the project's
memory directory touched this session.

**UNRESOLVED items** — anything started but not finished. Be specific:
- A branch left in WIP
- A migration written but not promoted
- A pending Sentry event needing follow-up
- A code-reviewer HIGH finding deferred with `Code-skip-reason:`

If a section is empty, write "None" — don't omit (operator scans for
completeness).

### 5. Next-session pickup hints

Propose:

- **Natural first task next session** — one sentence
- **Explicit "first action" warning** if any — e.g. "Sentry MCP check
  on `release:<sha>` for soak verification"
- **Proposed MEMORY RESUME HERE update** — the literal block to drop
  into MEMORY.md so next session re-orients in 3 tool calls or fewer

Surface as a diff. **Wait for operator approval before writing.**

### 6. Final state confirmation

Run:

```bash
git log --oneline -5
git status
```

Report. If step 1 found changes the operator chose to leave as WIP, state
that explicitly so the operator confirms intentional WIP.

End with: **"Session can close."** or, if uncommitted/unpushed work
remains by operator choice: **"Session can close with WIP carry-forward
(<short summary>)."**

## Output format

Produce a **single message** structured as the six numbered sections
above. Use markdown headings (`### 1. …`). Show command output inline
only when it's compact; otherwise summarize.

Keep each section tight — a complete close-out should be under 500 words
unless the session had many commits or unresolved items.

## Configuration override (optional)

Projects can place `.claude/session.yaml` at repo root to customize:

```yaml
# .claude/session.yaml — all keys optional
end_session:
  extra_checks:
    - title: "Sentry release tag"
      command: "echo Last release: $(git describe --tags --abbrev=0)"
    - title: "Deploy status"
      command: "cat .deploy-state 2>/dev/null || echo none"

  memory_paths:
    # override default memory discovery
    - path: .claude/memory/MEMORY.md

  backlog_path: docs/BACKLOG.md  # or wherever the project tracks issues

  skip_sections:
    - "sync check"  # e.g. solo projects with no remote

  closeout_message: "Don't forget to log timesheet."  # appended to final state
```

Or `.claude/session.md` for free-form prose appended to the close-out.

## Failure modes to avoid

- **Never auto-commit.** Even if the working tree has obvious-looking
  changes (e.g. only formatting). Operator decides.
- **Never auto-edit MEMORY.md or BACKLOG.md.** Propose diffs; wait for
  approval; then apply with `Edit` after explicit go-ahead.
- **Never push to origin.** Even if local commits look ready. Operator
  decides.
- **Don't fabricate session commits.** If `git log --since` returns
  nothing, say "No commits this session" — don't infer from open files.
- **Don't skip the sync check on the grounds of "probably fine."** A
  surprise behind-by-N is exactly the kind of carry-forward the
  operator needs to see.
- **Don't summarize what was discussed.** The operator was there.
  Summarize what *changed in the repo / memory / external state*.

## When the project has *none* of these files

Degrade gracefully:
1. `git status` + `git log -5` + sync check are universally applicable
2. Skip MEMORY banner check and BACKLOG ledger silently
3. End with: "Session can close. (No CLAUDE.md / MEMORY detected; want
   me to scaffold the engine?)"

## Token budget

This skill should consume **under 3k input tokens** in total reads. The
close-out happens at the end of a session when context is already full;
keep it lean.
