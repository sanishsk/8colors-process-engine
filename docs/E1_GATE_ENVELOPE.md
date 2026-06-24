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

E1 deliberately does not implement the orchestrator that consumes the
envelope. Three viable approaches, all compatible with this contract;
the choice does not need to be made until Phase 4 (parallel DAG):

| Option | Mechanism | Best for | Tradeoff |
|---|---|---|---|
| **A. Subagent burst** | Spawn multiple `Agent(...)` invocations in one Claude Code message | Short-lived, shared-context fan-outs | Loses true parallelism on long tasks; subagents share the parent's context budget |
| **B. Headless `claude -p`** | Run background `claude -p` sessions, each emits an envelope to a file | True parallelism, isolation | No shared context between workers; cross-worker conflicts surface only at the merge gate |
| **C. External Python orchestrator** | A driver script that schedules workers, parses envelopes via `pe gate parse`, drives escalation | Maximum control, observability, scheduling logic | More code to own; requires a long-running process |

Phases 0–3 are entirely sequential (one worker → one gate → maybe
retry → next worker). The A/B/C decision only bites at Phase 4. The
envelope contract is identical for all three.

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
  `e2e-runner`, `database-reviewer`. Pure mechanical work. ~1h each.
- **E1.2** — add a `pe gate validate-schema` subcommand that asserts
  the schema file itself is valid JSON Schema draft-07 (currently
  done implicitly by the parser; explicit subcommand helps in CI).
- **E2** (next slot) — Phase 0 baseline harness. Pick 3 8CStudio slot
  types; record wall-clock + tokens + pass-rate + rework-rate. Output
  to `docs/baselines/`.
- **E3** — bump remaining Haiku gate agents to Sonnet+ once they
  adopt the envelope. Track per-iteration cost impact.
- **Open** — should `gate_name` allow project-defined values (for
  custom gates in adopter projects), or stay closed-enum? Default
  closed; revisit if the first beta tester asks.

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

The contract is real. The first downstream consumer (Phase 3's
escalation router) can be built against it without further design
work on this layer.
