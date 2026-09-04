# Brief — `/gate-review` as a Claude Code dynamic workflow

> Slot: Phase 4 pilot. Status: **brief + architect pass only — no code yet.**
> Written 2026-09-04 against engine v0.51.12, Claude Code 2.1.197.
> Supersedes the hand-off brief in `~/Downloads/gate-review-workflow-brief.md`,
> which was written without repo access. Where they differ, this one has
> the evidence.

## Step 0 — what was checked before writing this

The hand-off brief made Step 0 mandatory. It was done, and it changed the
plan five times. Recorded here so the next reader does not repeat it.

| Check | Result |
|---|---|
| `claude --version` ≥ 2.1.154 | **2.1.197** ✓ |
| Dynamic workflows disabled? | `disableWorkflows` unset, `CLAUDE_CODE_DISABLE_WORKFLOWS` unset → default-on |
| `.claude/workflows/` anywhere on this machine | none — nothing built yet |
| E1's deferred orchestrator options | exactly **three**, `E1_GATE_ENVELOPE.md:227-229` |
| JavaScript anywhere in this repo | **zero files** |

## 1. Problem

`docs/AGENT_INVOCATION_RULES.md:33-38` is the whole of the engine's
parallel-review mechanism:

```
Parallel review pattern for high-risk slots (RLS changes, payment, auth):
Launch 3 agents in parallel:
1. security-reviewer — data isolation focus
2. database-reviewer — transaction safety + RLS
3. code-reviewer — general quality

Aggregate findings; fix CRITICAL + HIGH before merge.
```

Six lines of prose. No mechanism. Whether three agents actually run, whether
their findings are actually aggregated, and whether CRITICAL findings are
actually fixed before merge are all things the model may or may not do — the
precise class of drift the engine exists to prevent, sitting inside the
engine's own doctrine.

The `Auth/multi-tenancy` row of the slot matrix (`:8`) makes the same promise
in a table cell: *"security-reviewer (mandatory) + database-reviewer +
code-reviewer in parallel"*.

## 2. Goal

Replace those six lines with a saved dynamic workflow that guarantees, by
construction rather than by instruction:

- all gate agents run, every invocation, in parallel;
- every envelope is schema-valid **at the call site**, not after the fact;
- findings are deduplicated and ranked by one aggregator;
- CRITICAL/HIGH findings drive a **bounded** fix → re-review loop that stops
  at a round cap or on no progress;
- the aggregated verdict is **persisted where the commit gate can read it**.

That last one is not in the hand-off brief and is the reason this is not a
half-day job. See §5.1.

## 3. Non-goals

Carried from the hand-off brief, all still correct:

- `brief-writer → architect → planner` stays out of a workflow. Workflows
  cannot pause for input; those stages are where the operator decides.
- No session-wide `ultracode`. Cost multiplier, no doctrine benefit.
- Hooks are untouched. Workflows add a runtime, not enforcement.
- `pe gate parse` is not replaced. It stays the CI/transcript validator —
  and, per §5.1, becomes the workflow's own persistence mechanism.

Added after the repo pass:

- **No `pe install` wiring in this slot.** See §6.

## 4. Why a dynamic workflow — Option D

`docs/E1_GATE_ENVELOPE.md §9` names three deferred orchestrator options and
says the choice "does not need to be made until Phase 4". Verbatim, at
`:227-229`:

| Option | Mechanism |
|---|---|
| **A. Subagent burst** | Spawn multiple `Agent(...)` invocations in one Claude Code message |
| **B. Headless `claude -p`** | Run background `claude -p` sessions, each emits an envelope to a file |
| **C. External Python orchestrator** | A driver script that schedules workers, parses envelopes via `pe gate parse`, drives escalation |

A dynamic workflow is a fourth, and it dominates C on the axis the engine
cares about most — who owns the runtime:

| Concern | C (own the driver) | D (dynamic workflow) |
|---|---|---|
| Runtime maintenance | us, bus factor 1 | Anthropic |
| Parallel fan-out | our scheduler | `parallel()` primitive |
| Envelope validation | post-hoc parse | `agent(…, {schema})` at the call site |
| Resume after failure | none | built in |
| Per-agent token visibility | absent (known gap) | `/workflows` view |
| Circuit breaker | model-dependent | plain JS `while`/`for` |

It also dominates A: subagents in one message share the parent's context
budget (`:227`), which is exactly what fan-out is meant to avoid.

Accepted trade-off: workflows are Claude Code-only and need a paid plan.
The engine is already Claude Code-native, so this adds no new lock-in — but
it **is** a new adopter requirement, and the pilot must therefore be
strictly optional (§6).

## 5. What the repo pass changed

### 5.1 The workflow's return value cannot reach the commit gate — LOAD-BEARING

`hooks/pre-commit-envelope-check.sh` blocks `git commit` unless
`.claude/gates/last-gate.json` holds a PASS/WARN envelope **whose recorded
`diff_sha` matches the currently-staged diff**.

A workflow script has no filesystem access. The hand-off brief's sketch ends
with `return { verdict, envelope, rounds }` — which lands in the session
transcript, where no hook can see it. As written, `/gate-review` would
produce a verdict the enforcement layer is blind to, and the commit-trailer
wiring in its §7 would not work.

**Resolution:** the workflow's final step is an `agent()` — agents have
`Bash`, scripts do not — that writes the aggregated envelope through the
engine's existing recorder:

```
pe gate parse --record .claude/gates/last-gate.json \
              --diff-sha "$(git diff --cached | git hash-object --stdin)" <transcript>
```

This is a feature, not a workaround: the verdict is persisted by the same
validated path every other gate uses, so `pe gate parse`'s schema check runs
a second time, independently of the runtime's.

### 5.2 `gate_name` is a closed enum — and it already has the right value

`schemas/gate-envelope.schema.json:42-51` restricts `gate_name` to eight
values, `additionalProperties` is `false` (`:16`), and the aggregator needs
one of them. It does not need a schema change: **`merge-gate`** is already in
the enum and is exactly what an aggregator over several gates is.

### 5.3 `timestamp` is required, and the script cannot produce one

`required` is seven fields (`:7-15`), `timestamp` among them. `Date.now()`,
`new Date()` and `Math.random()` all throw inside a workflow script — they
would break resume. So the aggregating **agent** stamps the envelope, not the
script. This also disposes of the hand-off brief's `args.runId`, which its
own sketch declares and never uses.

### 5.4 Passing `args` to a slash-invoked saved workflow is undocumented

The docs describe `args` as structured data Claude passes when it invokes a
workflow, parsed from natural language. There is **no documented CLI form**
for `/gate-review --args '{...}'`. Building a required argument into the
contract would be building on sand. `maxRounds` therefore defaults in-script
and everything else is derived from `git` by agents.

### 5.5 The engine contains no JavaScript

`find` for `*.js|*.mjs|*.cjs|*.ts` returns **zero files**. This is a bash +
Python engine (`requirements`: `python>=3.10`, `bash>=3.2`). Two consequences:

- There is no JS linter, formatter or test runner in the repo or in CI, so
  `workflows/gate-review.js` is **unlintable by existing tooling**. Its
  correctness has to come from a shell test that inspects it as text, plus
  the eval fixtures.
- It is **not** a new adopter runtime dependency. The script is executed by
  Claude Code's own runtime, never by node on the adopter's machine. The
  manifest's `requirements` block must not grow a `node` entry, and saying so
  explicitly is part of this brief because it is the obvious wrong inference.

## 6. Scope — what this pilot deliberately does not do

The hand-off brief's deliverable 5 was "`pe install` symlinks `workflows/`
into `<project>/.claude/workflows/`". The repo pass found what that actually
costs. The engine's install path list is **hardcoded in six places with no
shared constant**:

| Site | What it does |
|---|---|
| `scripts/install.sh:199-202` | the install loop |
| `scripts/install.sh:204-210` | broken-symlink reconcile |
| `scripts/install.sh:516-518` | post-install verification |
| `scripts/_cmd_lifecycle.sh:233-237` | `pe sync` |
| `scripts/_cmd_lifecycle.sh:370-374` | `pe doctor` |
| `scripts/_cmd_lifecycle.sh:541-543` | `pe eject` |

Wiring fewer than all six produces a half-managed surface — installed but
never verified, or installed but surviving `pe eject`. And it is not a
copy-paste of the `commands/` block: every one of those globs is `*.md`, and
workflows are `.js`. On top of that:

- `scripts/pe_verify.py:49-61` `SURFACE_GLOBS` would need a new entry, or
  `workflows/` becomes the only installed engine surface with no checksum.
- Whether `workflows/` is subset-filtered (`agents/` is, `commands/` is not)
  is an unmade decision that pulls in `_subset.sh` and
  `tests/test_subset_rosters.sh`.
- Claude Code **2.1.216+ refuses to write through a symlink** in
  `.claude/workflows/`. An adopter on a newer build who edits the workflow
  hits this. Symlink-vs-copy is a real decision, not a detail.

**Decision: none of that is in this slot.** The pilot ships the workflow in
the engine's own `workflows/` directory, where it is available two ways that
need no install wiring at all:

1. **As a plugin.** Claude Code's default plugin workflow directory is
   `workflows/` at the plugin root, namespaced `/8colors-process-engine:gate-review`.
   No manifest key is needed — the `workflows` key exists only to point at a
   *non-default* path, and it *replaces* rather than adds.
2. **In the engine repo itself**, as the dogfood case.

If the pilot proves out, install wiring becomes its own slot with all six
sites named. If it does not, we have not spent a day wiring a surface nobody
runs — which is the failure mode `docs/ADOPTION_AUDIT.md` was written about.

## 7. Deliverables

| # | Deliverable | Status |
|---|---|---|
| 1 | `docs/research/brief-gate-review-workflow.md` | this file |
| 2 | `docs/research/architect-gate-review-workflow.md` | next |
| 3 | `workflows/gate-review.js` | pending |
| 4 | `tests/test_gate_review_schema_sync.sh` | pending |
| 5 | `docs/E1_GATE_ENVELOPE.md` — add Option D; fix `:222`, `:223`, `:232-233` | pending |
| 6 | `docs/AGENT_INVOCATION_RULES.md` — replace `:33-38` prose | pending |
| 7 | `evals/gate-review/` — three fixtures | pending |
| 8 | `CHANGELOG.md` + `VERSION` | pending |

Dropped from the hand-off brief:

- **Its D4** (register `workflows/` in the plugin manifest) — inert. Neither
  `plugin.json` nor `.claude-plugin/plugin.json` is read for its directory
  keys; `install.sh` hardcodes paths. A manifest key installs nothing. The
  default `workflows/` directory needs no key at all.
- **Its D5** (install wiring) — deferred, §6.
- **Its D8** (refresh the beta brief) — **already done**, v0.51.9-0.51.12.
  The `AGENT_INVOCATION_RULES` "Phase 3 — not wired yet" staleness it cites
  was also already fixed.

## 8. Value bar

**V4** — a gap a review found and could not act on. `docs/ADOPTION_AUDIT.md`
records that the engine's orchestration layer is prose the model may or may
not follow, and that nothing detects when it does not. This is the smallest
change that replaces one such promise with a mechanism.

Not V1: no incident has yet been traced to the parallel pattern silently not
running. That is precisely because nothing observes it — which is an argument
for the change, not evidence for it, and this brief does not claim otherwise.

## 9. Open questions for the architect pass

1. How does the schema-sync test compare a JSON object embedded in a `.js`
   file against `schemas/gate-envelope.schema.json`, given no JS tooling?
2. Which agents does the workflow fan out to — the three the prose names, or
   all seven envelope-emitters, or a set chosen from the staged paths?
3. What does the fixer agent do about a workflow's inability to pause? A fix
   agent that edits files with no human in the loop is a bigger step than the
   review fan-out, and may belong in a later slot.
4. `pe doctor` has **two** implementations — `scripts/_cmd_lifecycle.sh` and
   `scripts/pe_doctor.py`. If a version check is added at all, both need it,
   and workflow-enablement is undetectable (§5 of the architect pass).
