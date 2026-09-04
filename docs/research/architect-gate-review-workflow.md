# Architect pass — `/gate-review` dynamic workflow

> Companion to `brief-gate-review-workflow.md`. Answers its §9 open
> questions and fixes the shape before any code is written.
> 2026-09-04, engine v0.51.12, Claude Code 2.1.197.

## Decisions, up front

| # | Decision | Consequence |
|---|---|---|
| D1 | The inline schema is a **structural subset**, not a copy | the sync test asserts *consistency*, not equality (§1) |
| D2 | Fan out to the **three agents the prose names**, not all seven | faithful replacement, no scope creep (§2) |
| D3 | **No fixer agent in the pilot.** Review, aggregate, persist, report | drops the hand-off brief's fix loop (§3) |
| D4 | **No `pe doctor` change** | the check it asked for cannot be performed (§4) |
| D5 | A missing gate can never produce PASS | the safety property (§5) |

## 1. The inline schema, and how a shell test checks it

### Why not a copy

The obvious design — paste `schemas/gate-envelope.schema.json` into the
script and assert byte-equality — does not survive contact with the runtime.

The canonical schema uses draft-07 conditionals: an `allOf` / `if` / `then` /
`else` block (`:17-31`) that makes `failure_class` depend on `verdict`, plus
`additionalProperties: false` (`:16`). The workflow runtime's schema option
feeds a StructuredOutput tool, and the authoring contract says only that
schemas need `{type: 'object', properties}` at root with `required ⊆
properties`, and that **unsatisfiable schemas throw at `agent()`**. Whether
it honours `allOf`/`if`/`then` is not documented, and a schema that is
silently ignored is worse than one that is absent — it would look validated
and not be.

So the inline object is a deliberate **subset**: the seven required fields,
each enum stated flat, no conditionals.

```
schema_version  gate_name  verdict  failure_class
findings[]{severity, rule, message}  model_used  timestamp
```

The conditional rule (`FAIL ⇒ failure_class ≠ none`, otherwise `= none`) is
**not** expressed inline. It does not need to be: `pe gate parse` enforces it
when the envelope is persisted (§6), and `scripts/pe_gate.py` re-checks it in
code independently of the JSON Schema. Two validators, one of them full.

### The sync test

Equality is the wrong assertion, so the test asserts what actually matters —
that the subset cannot drift *out of agreement* with the canonical file:

1. every field in the inline `required` array is also required canonically;
2. every enum the inline schema states is **exactly** the canonical enum for
   that field — same values, same order-independent set;
3. the inline schema names no field the canonical schema forbids
   (`additionalProperties: false` makes this checkable);
4. `gate_name`'s inline enum contains the value the aggregator emits.

Mechanically: the schema is delimited in the `.js` by literal markers, the
shell test slices between them, and `python3` — already a hard dependency —
parses both sides and compares. No JS parser, no node, no new tooling.

```
// >>> GATE-ENVELOPE-SCHEMA-BEGIN  (subset of schemas/gate-envelope.schema.json)
const ENVELOPE_SCHEMA = { … }
// >>> GATE-ENVELOPE-SCHEMA-END
```

This is a stronger test than equality would have been. Equality would fail on
every cosmetic change to the canonical file; consistency fails only when the
two actually disagree about what an envelope is.

## 2. Which agents fan out

**The three the prose names**: `security-reviewer`, `database-reviewer`,
`code-reviewer`. `AGENT_INVOCATION_RULES.md:33-38` names exactly these for
RLS / payment / auth slots, and this slot's job is to make *that* promise
real — not to make a larger one.

`design-critic` and `performance-reviewer` also emit envelopes and are
obvious later additions. They are not in the pilot because a UI gate on an
RLS change is noise, and choosing gates from staged paths is a second
mechanism to get right. Follow-up slot.

Concurrency is a non-issue: three concurrent agents against a cap of
`min(16, cpus-2)`. Nothing queues.

## 3. No fixer agent in the pilot

The hand-off brief's §6 sketch dispatches a fix agent on CRITICAL/HIGH
findings, then re-reviews, bounded by `maxRounds` and a no-progress check.

**Deferred, deliberately.** The circuit breaker in that design protects
against a *runaway* loop. It does not protect against a *wrong* fix. A
workflow cannot pause for a human, so an agent that edits files, re-reviews
its own edits and reports PASS has removed the operator from the one place
the engine's doctrine insists they stay — the brief's own §3 says as much
about `brief-writer → architect → planner`, and the argument is the same
here, only sharper, because this one writes code.

The pilot therefore **reviews and reports**. If the aggregated verdict
carries blockers, the operator sees them and decides. Once the fan-out half
has run for real on real diffs, an opt-in fix loop is a well-scoped follow-up
with evidence behind it.

This removes `maxRounds`, the no-progress counter and the round labelling
from the script, which is most of its branching. What is left is a fan-out,
an aggregation and a write.

## 4. No `pe doctor` change

The hand-off brief asked `pe doctor` to check Claude Code ≥ 2.1.154 and warn
if workflows are disabled. Two problems:

1. **Enablement is not detectable.** There is no documented API, command or
   file a shell script can read to learn whether dynamic workflows are on.
   The only readable signals are *negative*: `disableWorkflows` in a settings
   file, and `CLAUDE_CODE_DISABLE_WORKFLOWS=1`. Absence of both means "not
   disabled", which is not the same as "available" — plan tier is invisible
   from the shell.
2. **`pe doctor` has two implementations.** `scripts/_cmd_lifecycle.sh`
   (`cmd_doctor`) and `scripts/pe_doctor.py`, the latter `exec`'d for
   `--json`. A check added to one is missing from the other — the same
   half-wired shape this engine keeps finding in itself.

A green tick that means "we could not find a reason to think it is off" is
the kind of check this engine spent v0.51.4–0.51.12 removing. The workflow is
optional; an operator whose plan does not include it will not see
`/gate-review` in autocomplete, which is a clearer signal than a doctor line
that cannot tell.

**If** a check is added later, it belongs in both implementations and must
report `not disabled` rather than `enabled`.

## 5. The safety property: a missing gate can never yield PASS

`agent()` returns `null` when the user skips it mid-run or the subagent dies
on a terminal API error after retries. The idiom is `.filter(Boolean)` — and
applied naively here it is a **fail-open bug**: if `security-reviewer` dies,
`parallel()` returns `[null, dbEnv, codeEnv]`, the filter drops it, the
aggregator sees two clean envelopes and returns PASS. The commit gate then
lets a payment-path change through having never been security-reviewed, and
nothing in the transcript says so.

That is the same failure shape as `size-budget`'s stale-trailer read fixed in
v0.51.12, and it is worse here because it is silent.

**Invariant, enforced in the script before the aggregator runs:**

- count the non-null envelopes;
- if any gate is missing, the aggregated verdict is **at best `WARN`**, and a
  finding of severity `HIGH` with rule `gate-did-not-run` naming the missing
  gate is added to the aggregate;
- `PASS` is reachable **only** when all three gates returned an envelope.

The aggregating agent is not trusted to apply this — the script does it,
because the script is the part that cannot be talked out of it.

## 6. Persisting the verdict — the load-bearing step

Restating from the brief §5.1 because the script's shape depends on it: a
workflow's `return` value reaches the session, not the disk, and
`hooks/pre-commit-envelope-check.sh` reads `.claude/gates/last-gate.json`.

Final stage is an `agent()` — agents hold `Bash`, scripts hold nothing —
which:

1. writes the aggregated envelope to a transcript file;
2. computes `git diff --cached | git hash-object --stdin`;
3. runs `pe gate parse --record .claude/gates/last-gate.json --diff-sha <sha>`;
4. returns the recorder's exit code and stderr line verbatim.

Step 4 matters. As of v0.51.7, `pe gate parse` says on stderr exactly what it
did — `gate: recorded <path> …` or `gate: NOT recorded — <path> left
unchanged …`. Returning that verbatim means the workflow cannot claim to have
recorded a verdict it did not record. If step 3 fails, the workflow's return
value says so and the verdict is reported as unpersisted.

`gate_name` on the aggregate is **`merge-gate`** — already in the canonical
enum (`schemas/gate-envelope.schema.json:42-51`), and precisely what an
aggregate over several gates is. No schema change is needed anywhere.

`timestamp` is stamped by this agent, not the script: it is a required field
and `new Date()` throws inside a workflow.

## 7. Shape of the script

```
meta { name: 'gate-review', description, phases: [Collect, Review, Aggregate, Record] }

phase Collect   1 agent   → staged file list, or early return PASS/"nothing staged"
phase Review    3 agents  → parallel(), schema-bound, one per gate        [barrier: correct]
                            script applies the §5 invariant here
phase Aggregate 1 agent   → dedupe + rank + merge-gate envelope, schema-bound
phase Record    1 agent   → pe gate parse --record; returns its stderr verbatim

return { verdict, envelope, gates_ran, gates_missing, recorded }
```

Five agents per run, well inside the `medium` size guideline the hand-off
brief specifies. `parallel()` in Review is a genuine barrier — the aggregator
needs every envelope at once — so it is the correct primitive there rather
than `pipeline()`.

## 8. What still has to be proven by the evals

Three fixtures, per the hand-off brief §8, adjusted for D3:

| Fixture | Asserts |
|---|---|
| clean staged diff | verdict PASS, three envelopes, record written, `diff_sha` matches |
| one HIGH finding | verdict WARN/FAIL with the finding surfaced and ranked; record written |
| one gate killed mid-run | **verdict is not PASS**, `gate-did-not-run` present — §5's invariant, the one that must not regress |

The third is the one worth writing first. It is the assertion that
distinguishes this design from the naive `.filter(Boolean)` version, and it is
the one a future refactor is most likely to break.

## 9. Residual risks, stated

- **The script is unlintable by existing tooling.** No JS anywhere in the
  repo, none in CI. Its correctness rests on the shell sync test, the evals,
  and review. `hooks/size-budget.sh`'s per-file rule does not cover a new
  top-level `workflows/` directory either, though its per-function JS regex
  scan does — an asymmetry worth knowing before someone is surprised by it.
- **`pe verify` does not cover `workflows/`.** `SURFACE_GLOBS`
  (`scripts/pe_verify.py:49-61`) would need an entry for the file to be
  checksummed. Adding one is a one-line change but `MANIFEST.sha256` is a
  release-time artifact, so it belongs to a release, not to this slot.
- **The runtime's schema support is partly undocumented.** §1's subset is the
  hedge; if the runtime turns out to reject even that, the fallback is an
  unschema'd `agent()` plus `pe gate parse` as the sole validator — weaker,
  and it should be recorded as such rather than papered over.
