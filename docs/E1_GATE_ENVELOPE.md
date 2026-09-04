# E1 — Gate Envelope Contract

**Status:** Shipped 2026-06-24 (engine branch `feat/e1-gate-envelope`).
**Phase:** Re-ordered roadmap §1 (was originally folded into Phase 3 in
the v2 design doc; promoted to first concrete slot because it is the
prerequisite for everything downstream — escalation ladder, circuit
breaker, parallel merge gate, third-party gate integrations).

---

## 1. Why this exists

The v2 design proposed an escalation ladder (Haiku → Sonnet → Opus →
human) and a circuit breaker (iteration cap + token budget) that both
depend on knowing whether a gate **passed or failed** programmatically.
Today gates emit prose in chat. An orchestrator cannot route on prose.

E1 defines the **machine-parseable verdict envelope** every L3 gate
emits. Without it:

- "Same gate for all tiers" (principle §2.2) is unenforceable.
- The escalation ladder (§5.2) has no failure signal to act on.
- The circuit breaker (§6) cannot account for per-gate cost.
- Third-party gates (CodeRabbit, scoped pentest workers — Phase 3) have
  nowhere to plug in.

The envelope is the single load-bearing abstraction. The choice of
*who* runs the gate (Claude Code agent today, CodeRabbit tomorrow,
something else next quarter) is swappable behind the same contract.

---

## 2. What this slot ships

| Artifact | Path | Purpose |
|---|---|---|
| JSON Schema (draft-07) | `schemas/gate-envelope.schema.json` | The contract |
| Parser + validator (stdlib only) | `scripts/pe_gate.py` | Routes verdict → exit code |
| CLI surface | `pe gate parse <file>` | Orchestrator entry point |
| Fixtures | `schemas/fixtures/*.json|md` | Smoke-test corpus |
| Updated agent | `agents/code-reviewer.md` | First gate to emit envelopes; bumped Haiku→Sonnet |
| This doc | `docs/E1_GATE_ENVELOPE.md` | Rationale + open issues |

**Out of scope for E1** (deferred, named so they're not forgotten):

- The orchestrator that consumes the envelope and routes escalations
  (Phase 3 — escalation ladder + circuit breaker).
- Wiring `security-reviewer`, `tdd-guide`, `e2e-runner`,
  `database-reviewer`, and a future `merge-gate` to emit envelopes.
  E1 ships the contract and one reference emitter; the rest of the
  gates adopt over the next 1–2 slots.
- Third-party gate integrations (CodeRabbit review gate, scoped pentest
  worker). They sit at Phase 3, behind this envelope.

---

## 3. The keystone field — `failure_class`

`verdict + severity` is necessary but not sufficient. A naive escalation
ladder that escalates on **any** FAIL burns three tiers of budget on
tasks no model can fix — the exact circuit-breaker-burn trap the YAGNI
clause warns against.

`failure_class` partitions FAIL into four mutually exclusive cases:

| Class | Cause | Orchestrator action |
|---|---|---|
| `worker_quality` | Gate proved the worker's output wrong (bug, security hole, missing test). | **Escalate** Haiku → Sonnet → Opus → human. Same task, smarter worker. |
| `task_underspecified` | Gate cannot judge pass/fail because the goal is ambiguous. | **Halt** to human. Smarter worker just makes a smarter guess. |
| `blocked` | External dependency missing or broken (migration, secret, fixture, network). | **Halt** to human. Resolve the blocker; rerun. |
| `out_of_scope` | Worker reached outside the slot's allowlist (foundational files, unrelated modules). | **Halt** to human. Do not let a higher-tier worker silently rewrite scope. |

Only `worker_quality` is escalation fuel. The others terminate the
ladder immediately, which is what keeps the circuit-breaker token
budget bounded. This single field is what wires the escalation ladder
(v2 §5.2) and the circuit breaker (v2 §6) together cleanly instead of
leaving them as separate concerns.

**Bias toward `task_underspecified`** when uncertain — burning three
tiers on an ambiguous task is exactly the failure mode this field
exists to prevent.

---

## 4. The gate-agent paradox — and its per-iteration cost

> If the reviewer is Haiku, the quality bar is Haiku, no matter how
> nicely we wrote "quality is enforced by gates."

The fix is mandatory: **every gate agent runs at Sonnet or above**.
E1 bumps `code-reviewer.md` from `model: haiku` to `model: sonnet`.

The cost note that matters:

> Gate cost is **per-iteration**, not fixed overhead.

A 5-iteration loop pays the Sonnet reviewer **5 times**. The circuit
breaker's token budget formula has to model gates as a per-iteration
line item:

```
loop_budget ≈ (worker_tokens × N_iterations)
            + (Σ gate_tokens × N_iterations)
            + (orchestrator_tokens × N_iterations)
```

Phase 3's circuit breaker MUST surface the cumulative gate cost
separately from worker cost in any dashboard — otherwise budget
overruns will be misdiagnosed as "worker was expensive" when the
actual driver is "five iterations × Sonnet reviewer."

Mitigation levers (rank by easy → hard):

1. **Prompt cache the gate's system prompt** — stable across runs, huge
   hit rate. ~80% gate-input-token reduction.
2. **Scope-limit the gate** — only review the staged diff, not the
   whole file tree.
3. **De-escalate the gate on confidence** — if the gate's last 3 runs
   all came back PASS with confidence ≥ 0.95, run the next one at
   Haiku as a fast first pass; escalate to Sonnet only on FAIL. (Phase
   3.5; not in E1.)

---

## 5. Schema versioning policy

`schema_version` is SemVer. Rules:

- **Patch (1.0.0 → 1.0.1):** clarify a description, tighten a
  regex. No structural change. All parsers accept.
- **Minor (1.0.0 → 1.1.0):** add an optional property, add an enum
  value (with `failure_class`, never silently — see Process below).
  Old parsers tolerate; new parsers exploit.
- **Major (1.x → 2.x):** breaking change. Parser MUST refuse unknown
  major versions. `pe gate parse` emits `EXIT_PARSE_ERROR` and a
  diagnostic; the orchestrator surfaces to a human.

Process for any `failure_class` enum addition:

1. Open an issue on the engine repo with the proposed new class and
   one real example.
2. Wait at least one full retro cycle (Friday → Friday) before merging.
   `failure_class` is the orchestrator's routing fuel — silently
   adding cases destabilizes the ladder.

---

## 6. Emitter contract — multiple paths

The envelope is **not Claude-Code-specific**. Three legitimate
emission paths, all consumed identically by `pe gate parse`:

| Path | Emitter | Format |
|---|---|---|
| **Agent** | A Claude Code gate agent (`code-reviewer`, etc.) inside a session | Final fenced ` ```json gate-envelope ` block in the transcript |
| **Artifact** | A third-party tool (CodeRabbit, a pentest scanner, a future external review service) | Bare `.json` file written to disk |
| **Stdin / inline** | Test fixtures, hand-written envelopes for replay | Bare JSON |

`pe gate parse` tries the fenced path first, then falls back to bare
JSON. This is the load-bearing reason CodeRabbit (Phase 3) can plug in
later without engine changes — it writes its envelope to a file and
the orchestrator does `pe gate parse coderabbit-output.json`.

The fence info-string is intentionally **`json gate-envelope`** (two
words). Generic ` ```json ` code blocks in the agent's prose (e.g.
example snippets) are explicitly ignored by the parser regex. This is
why the smoke fixture `transcript-fenced.md` includes a decoy ` ```json `
block before the real envelope.

---

## 7. Exit-code contract

The `pe gate parse` exit code IS the orchestrator's routing input.

| Code | Meaning | Orchestrator action |
|---|---|---|
| 0 | PASS | Accept the worker's output. Proceed. |
| 1 | FAIL, `failure_class=worker_quality` | Escalate tier; retry. |
| 2 | FAIL, `failure_class ∈ {task_underspecified, blocked, out_of_scope}` | Halt to human. |
| 3 | WARN | Proceed, but surface envelope to human (dashboard, end-of-loop summary). |
| 4 | Schema / parse error | Halt to human. The gate itself is broken; do not route on a malformed envelope. |

Known overlap: the bash wrapper's "no argument" usage error also
exits 2 (POSIX convention). This is harmless in production
(orchestrators always pass a file) but flagged here so future readers
don't conflate the two.

---

## 8. Phase 0 baseline — what to measure (locked, not run yet)

E1 is the prerequisite for Phase 3's escalation ladder. Before Phase 3
ships, Phase 0 must capture a baseline so v2's "faster without quality
loss" claim is verifiable, not believed.

**Per slot type (pick 3 from 8CStudio):**

1. **Speed** — wall-clock from slot-start to first PASS envelope.
2. **Cost** — input + output + cache-read tokens, summed across all
   workers and gates in the slot.
3. **Quality (the constraint that matters)**:
   - **Gate pass-rate** — fraction of slots that hit PASS on the first
     gate invocation.
   - **Rework rate** — number of post-merge fix commits in the first
     72h after a slot ships.
   - **Sentry incidence** — count of new issues tagged with the slot's
     release SHA in the first 7 days.

The escalation ladder is allowed to reduce speed and cost; it is **not
allowed** to reduce quality. If Phase 3 ships and rework-rate goes up,
the ladder rolls back.

Baseline collection is not in E1. Slot ID for that work: **E0**, to
run immediately before Phase 3.

---

## 9. Orchestrator — named, deferred

E1 deliberately did not implement the orchestrator that consumes the
envelope. **Four** viable approaches, all compatible with this contract.
A–C were named in v0.19.0 and deferred to Phase 4; **D was added in
v0.51.15 and is the one being piloted** — see §9.1.

| Option | Mechanism | Best for | Tradeoff |
|---|---|---|---|
| **A. Subagent burst** | Spawn multiple `Agent(...)` invocations in one Claude Code message | Short-lived, shared-context fan-outs | Loses true parallelism on long tasks; subagents share the parent's context budget |
| **B. Headless `claude -p`** | Run background `claude -p` sessions, each emits an envelope to a file | True parallelism, isolation | No shared context between workers; cross-worker conflicts surface only at the merge gate |
| **C. External Python orchestrator** | A driver script that schedules workers, parses envelopes via `pe gate parse`, drives escalation | Maximum control, observability, scheduling logic | More code to own; requires a long-running process |
| **D. Claude Code dynamic workflow** | A saved JS script — `parallel()` of schema-bound `agent()` calls, aggregation, then an agent that records via `pe gate parse --record` | Parallel fan-out with envelope validation at the call site, resume, and per-agent token visibility | Claude Code-only and needs a paid plan; script cannot touch the filesystem, so persistence must go through an agent |

Phases 0–3 are entirely sequential (one worker → one gate → maybe
retry → next worker). The envelope contract is identical for all four.

### 9.1 Option D — the Phase 4 pilot

D dominates C on the axis this engine cares about most: **who owns the
runtime**. C means writing and maintaining a scheduler; D means Anthropic
maintains it and the engine writes ~200 lines of orchestration. It also
dominates A, whose subagents share the parent's context budget — which is
the thing fan-out exists to avoid.

Shipped as `workflows/gate-review.js`. Two properties are worth stating
here because they are contract-level, not implementation detail:

- **The script cannot persist the verdict itself.** Workflow scripts have
  no filesystem access, and `hooks/pre-commit-envelope-check.sh` reads
  `.claude/gates/last-gate.json`. So the final stage is an `agent()` — agents
  hold `Bash` — running `pe gate parse --record`. The envelope therefore
  passes through *this* contract's full validator on its way to disk,
  including the `verdict`/`failure_class` conditional the runtime's schema
  binding does not express.
- **`gate_name` is `merge-gate`.** The aggregate is an envelope over several
  gates, and `merge-gate` was already in the enum — Option D needed no
  change to this schema at all.

Design rationale, scope cuts and the fail-open hazard that shapes the
script: `docs/research/architect-gate-review-workflow.md`.

---

## 10. Third-party gates — explicitly anticipated

| Tool | Slot it fills | E1 dependency | Phase |
|---|---|---|---|
| **Ponytail** (worker-side YAGNI/code-minimization skill) | Worker-layer (L2) | None — sits on the worker, not the gate | Adopt any time |
| **CodeRabbit** | Review gate (L3) | Yes — emits envelope to artifact file | Phase 3 |
| **Anthropic native multi-agent review** | Review gate (L3) | Yes — emits envelope from a Claude Code subagent | Phase 3 |
| **Scoped pentest worker (DAST)** | Security gate (L3) | Yes — emits envelope from a Sonnet+ agent (gate-agent paradox) | Phase 3+ |

The choice between CodeRabbit and Anthropic native review for the
review gate is **deliberately deferred to Phase 3**. The envelope
contract makes them interchangeable; the decision is empirical
(measure both, keep the one that earns its keep) and not blocking
anything before Phase 3.

---

## 11. Open issues / follow-ups

- **E1.1** — adopt the envelope on `security-reviewer`, `tdd-guide`,
  `e2e-runner`, `database-reviewer`. Mechanical: copy the entire
  "CRITICAL OUTPUT CONTRACT" section verbatim from `code-reviewer.md`,
  change `gate_name` + 1-2 agent-specific exemplars, **keep the
  mandatory self-validation step intact** (see §13). ~1h each.
- **E1.2** — add a `pe gate validate-schema` subcommand that asserts
  the schema file itself is valid JSON Schema draft-07.
- **E2** (done) — Phase 0 baseline harness. Records for 1M.5, 1M.3,
  1m.5.1 in `docs/baselines/`. PR #2.
- **E3** — bump remaining Haiku gate agents to Sonnet+ once they
  adopt the envelope. Track per-iteration cost impact.
- **Open — subagent model honoring.** During E1.a live testing the
  `code-reviewer` ran on Haiku 4.5 despite `model: sonnet` in the
  agent frontmatter. May be a Claude Code subagent runtime issue or
  an invocation-time override. Worth investigating before E1.1 —
  the gate-agent paradox depends on the frontmatter being honored.
  Not blocking E1.a: the envelope contract held even on Haiku once
  self-validation was in place.
- **Open** — should `gate_name` allow project-defined values (custom
  gates in adopter projects), or stay closed-enum? Default closed;
  revisit if the first beta tester asks.

---

## 12. Validation receipt

E1 smoke run, 2026-06-24:

```
=== pass.json              ===  exit=0 (PASS)
=== fail-escalate.json     ===  exit=1 (escalate)
=== fail-halt.json         ===  exit=2 (halt)
=== transcript-fenced.md   ===  exit=3 (WARN; fenced extraction skipped decoy)
=== invalid-bad-enum.json  ===  exit=4 (schema error; clear diagnostic)
=== /nope/nada.json        ===  exit=4 (file not found)
```

E1.a live test receipt, 2026-06-24:

```
=== transcript-1.md (pre-tighten, agent improvised rule format)        exit=4
=== transcript-3.md (post-tighten, agent self-validated via pe gate)   exit=1
```

The contract is real and now self-enforcing. The first downstream
consumer (Phase 3's escalation router) can be built against it
without further design work on this layer.

---

## 13. E1.a — Mandatory self-validation (the determinism fix)

Shipped 2026-06-24 as part of PR #1. Reason: pure prompt engineering
proved insufficient to constrain agent output shape.

### What pass 1, 2, and 3 of the live test showed

| Pass | Fence info-string | Envelope shape | rule format | Self-validation | Exit |
|---|---|---|---|---|---|
| 1 | ✓ correct | ✓ correct | ✗ `"SQL Injection — f-string"` | none | **4** |
| 2 | ✗ plain `json` | ✗ improvised banned fields | ✓ kebab-case | none | would be **4** |
| 3 | ✓ correct | ✓ correct | ✓ kebab-case | **yes** | **1** (valid) |

Pass 2 regressed from pass 1 after the prompt was tightened — agents
over-rotate on whichever instruction is emphasized in the invocation
context. Asserting "all 9 checks passed" while emitting invalid
output is a real, observed failure mode. The fix is structural, not
linguistic.

### The structural fix

Each gate agent's prompt now contains a **Mandatory self-validation
step** requiring the agent to:

1. Write its draft envelope JSON to `/tmp/gate-envelope-draft.json`.
2. Run `pe gate parse /tmp/gate-envelope-draft.json`.
3. If exit code is 4 (schema error), read stderr, fix the envelope,
   retry — up to 3 iterations.
4. Only emit the validated envelope inside the
   ` ```json gate-envelope ` fence after the parser returned 0/1/2/3.
5. If 3 iterations cannot produce a valid envelope, emit
   `verdict=FAIL, failure_class=blocked` with a `summary` naming the
   specific validation error. **Halt deterministically rather than
   ship broken.**

Pass 3 of the live test confirmed the agent actually calls Bash and
runs the parser (9 tool calls vs. 1 on the prompt-only passes).
Envelope validity is now a tool-enforced contract, not an
asserted-by-prose claim.

### Why this matters for Phase 3

The Phase 3 escalation router will route on `pe gate parse` exit
codes. If gates could emit malformed envelopes that always exit 4,
the router would either burn retries on schema errors or have to
special-case them out. With self-validation in place, exit 4 is a
true "gate broke" signal, not "agent improvised the shape" noise.

### Template for E1.1 rollout

`agents/code-reviewer.md`'s CRITICAL OUTPUT CONTRACT section is the
canonical template for the remaining 4 gate agents:

- `security-reviewer` — change `gate_name`; rule examples
  (`csrf-missing`, `secret-in-source`, `unsafe-deserialize`).
- `tdd-guide` — `gate_name`; rule examples (`untested-code-path`,
  `flaky-test`, `coverage-low`).
- `e2e-runner` — `gate_name`; rule examples (`selector-stale`,
  `timeout`, `network-error`).
- `database-reviewer` — `gate_name`; rule examples
  (`missing-rls-policy`, `n-plus-one`, `unsafe-cascade`).

The rest of the section — fence rules, decision table, exemplars,
banned-field list, **self-validation step**, key-values cross-check
— stays verbatim. This is what makes E1.1 mechanical.

## 14. E1.d — Cross-check enforced by the parser (the silent-skip fix)

Shipped 2026-06-25. Trigger: E1.1 runtime cross-check on security-reviewer.

### What the runtime test exposed

Three criteria were verified on a fresh `security-reviewer` invocation
against a planted-vuln fixture:

| Criterion | Result |
|---|---|
| `model_used: claude-sonnet-*` | ✓ pass (sonnet-4-6) — tier routing held |
| CRITICAL OUTPUT CONTRACT followed | ⚠ partial — envelope shape correct, but the agent skipped the "Envelope key values" cross-check block |
| Envelope round-trips through `pe gate parse` | ✓ pass (exit 1, FAIL/worker_quality) |

The cross-check section was present in the agent's prompt (line 394 of
the shipped `security-reviewer.md`) and was explicitly required in
prose — "In your reply, **before** the final fenced envelope, print a
short 'Envelope key values' section that literally shows each required
field's value." The agent skipped it anyway, then passed the
schema-only self-validation step (which only checked the JSON).

### Why "instruction" wasn't enough

This is the **same failure class as E1.c, one level up**: a quality
step written as an INSTRUCTION instead of an enforced GATE. Phase 3
routes on these envelopes; the orchestrator needs to know that the
agent did its **whole** process, not just that the JSON output passes
schema validation. As long as the cross-check lived only in prose, an
agent could ship a valid envelope without ever having enumerated its
own state in plain text — the exact loop E1.a was meant to close.

### The structural fix (single source of truth)

`pe gate parse` now has two modes:

- **Default (transcript mode)**: input must contain BOTH the fenced
  envelope AND an "Envelope key values" cross-check block whose 6
  required fields literally equal the envelope. Missing cross-check or
  any value mismatch → exit 4 (same code as schema error, same
  orchestrator handling).
- **`--bare`**: legacy raw-JSON tolerance, for fixtures only. Agents
  must NOT use `--bare` in self-validation.

The agent's self-validation step now writes a TRANSCRIPT
(`/tmp/gate-envelope-draft.md`) containing both blocks, not raw JSON.
The same exit-code contract enforces both — one parser, one path.
The agent literally cannot pass self-validation without producing the
cross-check.

### What this protects

- Phase 3 escalation router from making routing decisions on envelopes
  whose authors skipped the introspection step.
- Future contract additions: any further "you must enumerate X" step
  can be folded into the same `pe gate parse` exit-code contract by
  extending the parser, without inventing a parallel gate.
- The 3 E1.1-ported agents (security-reviewer / tdd-guide / e2e-runner)
  from shipping with the same silent-skip behavior as the security
  reviewer's runtime test demonstrated.

### Re-test required after E1.d

Every agent ported under E1.1 must pass a fresh invocation runtime
cross-check confirming:
1. `model_used: claude-sonnet-*` (tier routing still holds)
2. transcript-mode `pe gate parse` exits 0/1/2/3 — i.e., the agent
   actually emitted the cross-check, not just the envelope
3. orchestrator-side `pe gate parse <full-transcript>` reproduces
   the same exit code

E1.1 does not "hold" until all 3 ported agents pass. Until then,
PR #5's test plan checkboxes stay unchecked.
