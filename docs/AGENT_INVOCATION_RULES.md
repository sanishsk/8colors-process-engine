# Agent Invocation Rules

| Slot type | Agents in order |
|---|---|
| New feature idea | /brainstorm → brief-writer → architect → tdd-guide → code-reviewer |
| OSS/library decision | researcher → architect → code-reviewer |
| Schema migration | brief-writer → database-reviewer → code-reviewer → security-reviewer |
| Auth/multi-tenancy | brief-writer → security-reviewer (mandatory) + database-reviewer + code-reviewer in parallel |
| Bug fix | tdd-guide (regression test first) → code-reviewer |
| Build error | build-error-resolver |
| UI change | brief-writer → design-critic (mandatory) → code-reviewer |
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

### Parallel review for high-risk slots — run `/gate-review`

For RLS changes, payment paths and auth/multi-tenancy, do not launch the
three gate agents by hand. Run the workflow:

```
/gate-review                      # in the engine repo
/8colors-process-engine:gate-review   # when installed as a plugin
```

It runs `security-reviewer`, `database-reviewer` and `code-reviewer` in
parallel against the staged diff, validates each envelope at the call site,
merges the findings into one `merge-gate` envelope ranked by severity, and
records it to `.claude/gates/last-gate.json` so
`hooks/pre-commit-envelope-check.sh` can see it.

**Why a workflow and not this paragraph.** Until v0.51.15 these six lines
*were* the mechanism: an instruction to launch three agents and aggregate
their findings, which the model either followed or did not, with nothing
observing which. That is the drift class this engine exists to prevent, and
it was sitting in the engine's own doctrine. A script either runs the three
gates or visibly fails.

**A gate that does not answer can never produce PASS.** If any of the three
is skipped or dies, the workflow adds a `gate-did-not-run` HIGH finding and
caps the verdict at WARN. Two clean envelopes out of three is not a pass.

`/gate-review` needs Claude Code ≥ 2.1.154 and a paid plan. Everything else
in the engine works without it; where it is unavailable, invoke the three
agents by hand and treat a missing one the same way.

Contract and rationale: `docs/E1_GATE_ENVELOPE.md §9.1`,
`docs/research/architect-gate-review-workflow.md`.

## Gate envelope (E1, 2026-06-24)

As of E1, the `code-reviewer` agent emits a machine-parseable
**gate envelope** as the final fenced ` ```json gate-envelope ` block in
its output. The envelope carries `verdict`, `failure_class`,
`findings[]`, `confidence`, `model_used`, and is validated against
`schemas/gate-envelope.schema.json`. Run `pe gate parse <transcript>`
to extract + validate it.

**Status of consumers** (corrected 2026-09-04 — every line here was
out of date, some by two months):

- **Seven agents emit the envelope**, not one: `code-reviewer`,
  `security-reviewer`, `database-reviewer`, `tdd-guide`, `e2e-runner`,
  `design-critic` and `performance-reviewer`. Six of them have eval
  fixtures under `evals/fixtures/`. Slot E1.1 shipped.
- The orchestrator that routes on the envelope **graduated on
  2026-06-28**. `pe shadow decide` makes the routing decision;
  enforcement is gated behind `--enforce`. This section said "Phase 3 —
  not wired yet" until 2026-09-04, while `pe help` had said "graduated"
  since June.
- The envelope is no longer only observational. `hooks/pre-commit-envelope-check.sh`
  blocks `git commit` unless `.claude/gates/last-gate.json` is PASS or WARN
  **and** its recorded `diff_sha` matches the staged diff.

**Gate-agent paradox:** the `code-reviewer` model is now `sonnet`,
not `haiku`. Gates run at Sonnet+ regardless of the worker tier
because the engine's quality bar cannot exceed the gate's quality
bar. Per-iteration cost implications: see
`docs/E1_GATE_ENVELOPE.md §4`.

Full rationale, exit-code contract, schema versioning policy, and
the three orchestrator options (named, deferred to Phase 4) in
`docs/E1_GATE_ENVELOPE.md`.
