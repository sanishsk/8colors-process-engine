# Phase 3 — Escalation Router + Circuit Breaker

**Status:** Brief approved 2026-06-26. Implementation in flight on
`feat/phase-3-escalation-router`. Ships in **shadow-mode only** —
decisions logged, never enforced — until graduation criteria (§9) are
met against forward-going slots.

**Prerequisites (all landed):**
- E1 envelope contract (PR #1, `4a17865`'s ancestor) — every L3 gate
  emits machine-parseable verdict + severity + `failure_class`.
- E1.1 propagation (PRs #5, #8) — all five L3 gates (`code-reviewer`,
  `security-reviewer`, `tdd-guide`, `e2e-runner`, `database-reviewer`)
  speak the envelope.
- E1.d (PR #6) — `pe gate parse` enforces the cross-check, so
  "exit 0/1/2/3" reliably means "the agent did the whole process," not
  just "JSON parses." Phase 3 routes on this guarantee.
- E2 baseline (PR #2) — 3 slots captured in `docs/baselines/`. Quality
  bar that Phase 3 must not regress.

**Phase 3 explicitly does NOT ship:**
- Parallel DAG scheduling — deferred to Phase 4 per E1 §9.
- Merge gate — Phase 4 dependency (no parallelism yet, no merge needed).
- Token telemetry capture — E2.1 dependency (router will record where
  it would be informative; values stay null until E2.1 wires
  per-invocation telemetry).
- Enforcement — Phase 3 is shadow-mode. Graduation to enforcement is a
  separate gate, evaluated against §9 criteria.

---

## 1. Why this exists

v2 design §5.2 promises a tiered ladder (Haiku → Sonnet → Opus →
human) that delivers cheap-model speed on easy work and top-tier
quality on hard work. §6 wraps that loop in a circuit breaker so a
runaway escalation cannot blow the budget. Both depend on the L3
gate emitting a programmatically routable verdict — E1 shipped that
contract; nothing has consumed it yet.

Phase 3 is the consumer. Without it, the envelope is observational
only (powers dashboards, fixture corpora). With it, the engine
realises the cost/speed claim v2 was built around — provided the
quality bar holds.

---

## 2. Five design decisions (locked 2026-06-26)

These are the decisions the brief surfaced before any code. Approved
by operator with refinements; refinements are folded in below.

### A. Orchestrator mechanism — **CLI subprocess**

`scripts/pe_orchestrator.py` drives the loop. It shells out to
`pe gate parse` for each gate run and reads the parsed envelope back.
The worker invocation is also a subprocess call to the Claude Code
agent CLI surface.

**Why:** E1 §9 deliberately defers DAG/daemon to Phase 4. CLI
subprocess matches the engine's stdlib-only stance, keeps the
"swappable gate provider" property (CodeRabbit later writes its
envelope to a file; the orchestrator reads the file with the same
`pe gate parse` call), and stays interruptible by the operator from
any terminal.

### B. Escalation policy — **table-driven, keyed off `failure_class`**

`policy/failure_class_routing.toml` maps each E1 failure class to one
of: `escalate_one_tier`, `halt_to_human`. The routing table is short
because the E1 schema's `failure_class` enum is intentionally
short — 4 FAIL classes + `none` for PASS/WARN. The whole point of
keeping it tight is that the orchestrator's decision logic stays
trivially auditable.

**The good news from reading `pe gate parse`:** the gate parser
already exit-codes this classification (0=PASS, 1=FAIL escalatable,
2=FAIL non-escalatable, 3=WARN, 4=schema error). The policy table
below is the *receipt* of the rule the orchestrator applies; the
runtime decision is `pe gate parse` exit code + current tier.

| `failure_class` | Action | Why |
|---|---|---|
| `worker_quality` | `escalate_one_tier` | Worker reached its ceiling; next tier may clear it. `pe gate parse` exit 1. |
| `worker_quality` **at top tier (Opus)** | `halt_to_human` (terminal) | **Operator refinement.** Top-tier worker_quality FAIL has nowhere to escalate. The policy layer names this terminal state explicitly — do not leave it for the breaker to catch. |
| `task_underspecified` | `halt_to_human` | The task is the problem — climbing tiers cannot fix an underspecified ask. E1 §3 bias rule. `pe gate parse` exit 2. |
| `blocked` | `halt_to_human` | External dependency (missing migration, missing secret, network, broken fixture). No tier solves this. `pe gate parse` exit 2. |
| `out_of_scope` | `halt_to_human` | Worker reached outside slot allowlist. Tier change makes it worse, not better. `pe gate parse` exit 2. |
| `none` (PASS / WARN) | continue (no decision) | `pe gate parse` exit 0 or 3. WARN is logged + surfaced. |
| schema error | `halt_to_human` | Default. Never silent-pass. `pe gate parse` exit 4. |

**Confidence override** (E1 envelope field): when present and < 0.6,
the orchestrator treats the verdict as advisory and surfaces to
human regardless of `failure_class`. This catches the case where a
gate marks PASS with low self-confidence — exactly the "rubber-stamp
review gate is worse than none" failure mode v2 §11 warns about.

### C. Circuit breaker — **both caps, cumulative is the primary guard**

Two distinct caps:

1. **Per-slot iteration cap** — hard stop on worker invocations within
   one slot. Justified against E2 baseline (§3 below). Stops a single
   runaway slot.
2. **Cumulative token budget** — across all slots in a loop /
   campaign. **Primary safety backstop, per operator refinement.**
   A router that escalates *every* slot to Opus stays under each
   per-slot cap while blowing the total. Per-slot stops one runaway;
   cumulative stops death-by-a-thousand-escalations.

**Gate cost is tracked separately from worker cost** in the breaker
ledger. Per E1 §4: bundling them misdiagnoses budget overruns as
"worker was expensive" when the driver is "five iterations × Sonnet
gate." The shadow log (§10) records both axes.

### D. Validation — **shadow-mode first, graduate on forward-going slots**

The router emits a routing decision per gate failure but does not
act on it. The worker / human pipeline continues as today. The
decision and the actual outcome are joined post-slot to answer:
"would the router's choice have beaten reality?"

**Why not retroactive replay:** pre-E1 gates emitted prose, not
envelopes. There is no honest envelope corpus to replay against —
synthetic envelopes would validate the router against synthetic data.
Shadow-mode is the same "prove it live, don't trust it" principle as
E1.c and the E1.d cross-checks.

### E. OSS-first check — **hand-roll, ~150 LOC Python**

Per `OSS_SEARCH_ORDER.md` doctrine, the search must be documented even
when concluding "build." Search performed 2026-06-26:

| Candidate | What it is | Why not Phase 3 |
|---|---|---|
| LangGraph | DAG-based agent orchestrator | Phase 4 tool — heavyweight DAG runtime is exactly what E1 §9 defers |
| Inngest | Durable workflow runtime | Adds a server/queue dependency; engine's stdlib-only stance forbids it for L1 |
| Temporal | Distributed workflow engine | Same as Inngest, more so |
| Anthropic Agent SDK (subagent loop) | Native multi-agent within Claude Code | A viable Phase-3+ option if/when the SDK exposes per-tier model routing as a primitive — today the loop is still hand-rolled around it |
| awesome-mcp-servers | MCP registry scan for "router," "orchestrator," "escalation" | No match for the L3-gate-driven escalation ladder pattern; matches were broker / proxy MCPs (different problem) |

**Conclusion:** the actual work is `subprocess.run(pe gate parse) →
match failure_class → reinvoke worker at next tier → log decision`.
~150 LOC of stdlib Python. None of the OSS options carry their
weight at this scope. Re-evaluate at Phase 4 when DAG + merge gate
land — LangGraph or Anthropic SDK become live candidates then.

---

## 3. Per-slot iteration cap — justified against E2 baseline

The cap must be tied to observed reality, not a round number. E2
baseline iteration counts:

| Slot | `slot_kind` | Iterations |
|---|---|---:|
| 1M.5 | `feature_incremental` | **1** |
| 1m.5.1 | `hotfix` | **1** |
| 1M.3 | `feature_multi_iteration` | **18** |

Two profiles in the data:
- "Lands in one shot" (1M.5, 1m.5.1) — cap need only protect against
  a degenerate retry loop.
- "Multi-iteration by nature" (1M.3) — 18 worker rounds before
  landing. This is the exact profile Phase 3's ladder is supposed to
  compress: instead of retrying at the same tier 18 times, escalate.

**Decomposed cap structure** (matches v2 §5.2 mermaid more precisely
than a single "iteration cap"):

| Knob | Default | Rationale |
|---|---:|---|
| `tier_retry_cap` | **1** | One retry at same tier before escalating. Allows 2 attempts per tier. |
| `ladder_max_steps` | **3** | Haiku → Sonnet → Opus → halt. Fixed by the ladder definition; not a knob. |
| `slot_iteration_cap` | **6** | `tier_retry_cap * 3 + 3` = 2 attempts × 3 tiers. Headroom for 1M.5 / 1m.5.1 (1 iter, well under); hard halt long before 1M.3's 18. |

**Honest framing:** under this cap, 1M.3's 18-iteration profile
would have been halted-to-human at iter 6 instead of grinding to 18.
That is *the intended outcome* — v2's promise is that escalation
catches the multi-iteration profile and routes it up rather than
retrying the same tier indefinitely. The shadow log will record
whether each of those halts would have been a correct call.

`slot_iteration_cap` is configurable per `slot_kind` in the policy
file. The defaults above are the conservative starting point.
Per-`slot_kind` overrides are an option once forward-going data
shows the multi-iteration profile reliably needs more headroom.

---

## 4. Cumulative token budget — primary safety guard

`cumulative_token_budget` is enforced across all slot invocations in
a loop / campaign / day, depending on how the operator scopes the
breaker. Default scope: **per-campaign** (i.e. one operator session).

The breaker tracks **two budgets in parallel**:
- `worker_tokens_cumulative` — sum across all worker invocations.
- `gate_tokens_cumulative` — sum across all gate invocations.

If either crosses its budget, breaker trips, all in-flight slots
halt to the operator. The split exists because E1 §4 documents the
"gate-agent paradox": gates run at Sonnet+ regardless of worker
tier, so on a 5-iteration slot, gate cost can dominate. Surfacing
the two budgets separately makes the diagnosis instant.

Initial budget values are deliberately **not** set in this brief.
They are tuned against the first forward-going slot's actual token
consumption (E2.1 lands per-slot token telemetry). The router runs
in shadow-mode with budgets set to `inf` until E2.1 produces real
numbers.

---

## 9. Graduation criteria — concrete, falsifiable

Per operator refinement: define these BEFORE building, or eyeballing
becomes inevitable when the build is exciting and the metric is
inconvenient.

**Metrics evaluated:**

1. **`rework_72h`** — 72h-window rework count on slots routed in
   shadow vs. baseline rate. Captured by existing baseline harness.
2. **`gate_pass_rate`** — fraction of slots that PASS on first envelope
   emission, post-router-decision. Captured forward-going (pre-E1
   slots are null by definition).
3. **`sentry_incidents_7d`** — release-tagged Sentry issue count in
   7d window post-merge. **Currently null on all 3 baselines pending
   MCP auth.** This is a hard graduation block (see §11).

**What "non-regression" means** (locked, conservative):

- `rework_72h`: shadow-mode median ≤ baseline median + 0 tolerance.
  Rework is a binary signal at this sample size; any uptick halts
  graduation.
- `gate_pass_rate`: shadow-mode rate ≥ baseline rate. Baseline is
  null forward-going-only, so the comparison is "first N
  post-router-decision slots" vs. "next N slots' pass rate without
  router." This requires running an A/B for N≥3 slots in each arm.
- `sentry_incidents_7d`: shadow-mode median ≤ baseline median. With
  3 backfilled baselines + 3 shadow-mode slots, this is small-N. The
  rule is **strict: any Sentry uptick = no graduation**, regardless
  of speed/cost wins.

**Sample size for graduation:** N≥3 slots routed in shadow-mode
across at least 2 distinct `slot_kind`s. Smaller samples risk
declaring graduation on a single lucky slot; larger samples delay
the cost win unnecessarily.

**Graduation gate (all required):**
- [ ] Sentry MCP authed AND 3 baselines backfilled with real counts.
- [ ] N≥3 forward-going shadow-mode slots logged with full
      reconciliation (§10).
- [ ] No regression on any of the 3 metrics above.
- [ ] Operator reviews the shadow-log diff: "would the router have
      changed the outcome on slot X?" — and signs off.

If any item is unmet, Phase 3 stays in shadow-mode. There is no
partial-graduation: enforcement is all or nothing.

---

## 10. Shadow-log schema — falsifiability is the test

Operator's explicit ask: if the log cannot answer "would the
router's choice have beaten reality?", shadow-mode is unfalsifiable
and the experiment is worthless. The schema below records the
counterfactual at decision time AND the actual outcome post-slot.

**Per-decision record** (written to `.pe/decisions.jsonl` at the
moment a gate envelope arrives):

```json
{
  "decision_id": "uuid",
  "ts": "ISO8601 UTC",
  "slot_id": "1M.6",
  "slot_kind": "feature_incremental",
  "iteration": 3,
  "gate_name": "code-reviewer",
  "envelope": { "...verbatim E1 envelope..." },
  "router_decision": {
    "action": "escalate_one_tier | retry_same_tier | halt_to_human",
    "from_tier": "haiku",
    "to_tier": "sonnet",
    "rule_matched": "worker_quality -> escalate_one_tier",
    "rule_source": "policy/failure_class_routing.yaml v1"
  },
  "breaker_state_at_decision": {
    "slot_iterations_used": 3,
    "slot_iteration_cap": 6,
    "worker_tokens_cumulative": null,
    "gate_tokens_cumulative": null,
    "cumulative_budget_remaining": null
  },
  "enforced": false
}
```

**Per-slot reconciliation** (joined post-slot by `pe shadow
reconcile <slot-id>`, writes to `.pe/reconciliations.jsonl`):

```json
{
  "slot_id": "1M.6",
  "merge_commit": "abc1234",
  "ultimate_outcome": "merged | abandoned | reverted_within_72h",
  "actual_iterations_used": 5,
  "actual_tier_progression": ["haiku", "haiku", "sonnet", "sonnet", "sonnet"],
  "router_decisions": [ "...decision_ids in order..." ],
  "router_correctness": {
    "decisions_matching_reality": 4,
    "decisions_diverging_from_reality": 1,
    "would_have_saved_iterations": null,
    "would_have_saved_tokens": null,
    "would_have_caused_extra_rework": false,
    "notes": "Operator's free-form annotation"
  }
}
```

**Reconstructable questions the schema must answer:**
1. For each shadow decision, what would the router have done? ✓
   (`router_decision.action` + `to_tier`)
2. What actually happened? ✓ (`actual_tier_progression`)
3. Did the router's choice diverge from reality? ✓
   (`decisions_diverging_from_reality`)
4. Did the router's would-action correlate with better or worse
   outcomes? ✓ (`router_correctness` + `ultimate_outcome` joined
   across N slots)
5. What was the gate-vs-worker cost split at each decision? ✓
   (`breaker_state_at_decision`, once E2.1 wires token capture)

If the schema cannot answer any of these for a given slot, the
reconciliation is incomplete and that slot does not count toward
N≥3.

---

## 11. Sentry backfill — graduation block

Sentry MCP auth is pending operator action (2026-06-26 session).
While unblocking, this:

- **Does NOT block building** — shadow-mode + skeleton + schema all
  proceed against the slot work already underway.
- **DOES block graduation.** `sentry_incidents_7d` is one of three
  non-regression metrics. Two of three baselines (1M.5, 1M.3) are
  currently null on this field. Graduating to enforcement on
  "2 of 3 metrics" is exactly the corner-cutting operator named as
  the failure mode.

Explicit guardrail: graduation checklist item #1 is "Sentry MCP
authed AND 3 baselines backfilled." No exceptions for "auth was slow."

---

## 12. Open issues / follow-ups

- **Initial budget calibration.** `cumulative_token_budget` defaults
  are deliberately deferred to E2.1 (per-slot token capture). Until
  then, breaker tracks-but-does-not-enforce token totals.
- **Slot-kind overrides for `slot_iteration_cap`.** Conservative
  default = 6 for all kinds. After ≥3 forward-going slots per kind,
  re-evaluate whether `feature_multi_iteration` legitimately needs
  more headroom or whether the multi-iter profile compresses under
  escalation (the v2 promise).
- **Reconciliation effort.** `pe shadow reconcile` requires the
  operator to annotate `router_correctness.notes` post-slot. This is
  a real cost. If annotation gets skipped, the experiment degrades.
  Open question: can the reconciliation be partially automated from
  git log + envelope history?
- **Same-class FAIL across all three tiers on the same slot** — a
  strong signal the gate itself needs review, not the worker. The
  envelope schema has no `gate_calibration` class today (intentional —
  the gate cannot self-diagnose calibration drift). Record this case
  in the shadow log with a derived flag (`tier_progression_exhausted`)
  so the operator can spot the pattern across slots.
- **Anthropic Agent SDK** as a Phase-3+ alternative — re-evaluate
  once the SDK exposes per-tier model routing as a primitive. CLI
  subprocess buys us the same observability without the SDK
  dependency; the migration path stays open.

---

## 13. What this slot ships (build punch-list)

1. `scripts/pe_orchestrator.py` — the loop driver. Shadow-mode only.
2. `policy/failure_class_routing.yaml` — the routing table from §2.B.
3. `policy/circuit_breaker.yaml` — the caps from §3 + §4.
4. `.pe/decisions.jsonl` write path — appended to per decision.
5. `pe shadow reconcile <slot-id>` subcommand — joins decisions to
   actual outcome, writes `.pe/reconciliations.jsonl`.
6. Forward-going hook into `scripts/baseline.py` — emit a marker per
   shadow-routed slot so the graduation harness can find them.
7. Tests: smoke fixture covering all four `failure_class` branches
   + the top-tier-terminal-halt rule + the cap-trip cases.
8. `docs/PHASE_3_ESCALATION_ROUTER.md` (this file).

Out of scope, explicitly:
- Enforcement, gate-cost telemetry, Phase-4 DAG, merge gate.
