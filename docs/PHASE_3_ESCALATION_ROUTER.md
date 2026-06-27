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
| `tier_retry_cap` | **1** | One retry at same tier before escalating. Allows **2 attempts per tier** (initial + 1 retry). |
| `ladder_max_steps` | **3** | Haiku → Sonnet → Opus → halt. Fixed by the ladder definition; not a knob. |
| `slot_iteration_cap` | **6** | `(tier_retry_cap + 1) * ladder_max_steps` = 2 × 3 = **6 worker invocations**. The cap is derived from ladder shape, not picked. Plotted against E2: 1M.5 used **1 iter** (5 below cap, fits), 1m.5.1 used **1 iter** (5 below cap, fits), 1M.3 used **18 iters** (12 *over* cap → halt at 6 is **the intended outcome**, see below). |

**Honest framing — 1M.3 specifically** (added 2026-06-26 after
post-push review): reading 1M.3's 18 commit subjects shows they were
**productive multi-fix iteration, not thrashing**. Phases 6.1.1 →
6.1.9 are nine distinct field-test-discovered fixes (silent file
drop, sticky offline state, bridge UUID cache, server FK guard,
drain refresh after deploy, etc.) — each surfaced by operator
airplane-mode testing between staged deploys. Cap=6 would have
killed the slot eight working fixes short.

What this means for the cap design:

1. **Phase 3's iteration counter is the WRONG axis to count
   operator-driven discovery.** The counter governs gate-FAIL →
   retry-or-escalate loops on the *same task*, not new constraints
   surfaced by external testing. Each post-deploy discovery is a
   new slot iteration that starts at `iter=1`, not iter=N continuing
   from yesterday.
2. **The earlier "intended compression" framing was wrong for
   1M.3.** Multi-fix slots like 1M.3 are not the failure mode v2
   §5.2's escalation ladder was built to compress.
3. **Cap=6 may still be the right value** for its actual scope (one
   gate-driven retry/escalate loop within one work attempt), but
   that proposition is now explicitly empirical, not theoretical.
4. **The shadow log will tell us.** If forward-going slots
   accumulate gate-driven `iter=6` halts that the operator then
   overrides to "actually we needed more attempts at this," cap=6
   is too tight for at least that slot_kind.

**Validation deferred to graduation** — see §9 for the new
explicit criterion. We ship cap=6 because we have to ship *some*
number to start measuring; we do not graduate on a theoretical cap.

`slot_iteration_cap` is configurable per `slot_kind` in the policy
file. Defaults are the starting point, calibrated **against the
gate-driven loop scope only**. Per-`slot_kind` overrides become
warranted once forward-going data shows a slot kind reliably
needs more headroom for gate-driven retries.

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
- [ ] **Sentry gate is FORWARD-GOING ONLY** (revised 2026-06-26 after
      backfill attempt revealed pre-PR#79 release tagging was broken).
      For slots deployed before PR #79 (engine fix commit `b04d428`),
      `sentry_incidents_7d` is permanently NULL by design —
      release-tagging was broken at deploy time, events from that
      period are tagged `release: unknown` in Sentry, and events are
      immutable. The three E2 baselines (1M.3, 1M.5, 1m.5.1) all fall
      in this category and carry `null_retrospective` with the
      evidence chain in `measurable_notes`.
      **Criterion is satisfied when:** (a) shadow-mode slots
      (which now have real release tagging post-#79) accumulate
      sentry_incidents_7d measurements, AND (b) those measurements
      show no release-tagged regression against zero (the implicit
      bar: a healthy slot ships zero new release-tagged Sentry
      issues in its 7d window — release-tagging now works, so this
      bar is real).
      **DO NOT** "fix" the pre-#79 nulls by inventing a number
      (e.g. zero from the broken-tag query) — that would create a
      fake baseline to compare against, defeating the gate. The
      null IS the receipt.
- [ ] N≥3 forward-going shadow-mode slots logged with full
      reconciliation (§10).
- [ ] No regression on any of the 3 metrics above.
- [ ] **Cap validation against real shadow slots** (added 2026-06-26
      after the 1M.3 reread): at least ONE shadow slot in the corpus
      must have run ≥4 gate-driven iterations *within the same
      work attempt*. If the shadow log shows any case where the
      router would have halted-at-cap a slot that the operator
      ultimately landed (the "would-have-killed-good-work"
      signature), raise the cap before graduating. Without this
      criterion, cap=6 graduates on a theoretical baseline (no
      multi-iter gate-driven loop has been observed forward-going).
- [ ] **Un-triggered ≠ validated — but fail-safe mechanisms may
      graduate untested with explicit flags** (added 2026-06-26,
      generalized 2026-06-27): if at graduation time NO shadow slot
      has exercised a given routing-policy mechanism, that mechanism
      is **UNVALIDATED**, not validated. Absence of the
      would-have-killed-good-work signature is meaningless if the
      mechanism was never approached (same "no CI fired ≠ CI passed"
      failure mode as the trigger-filter saga in 8CStudio's #225
      work).

      **Mechanisms this clause covers:**
      - **`slot_iteration_cap` (cap)** — per-slot iteration budget,
        currently 6.
      - **`severity_override` (severity-floor)** — PASS/WARN with
        HIGH/CRITICAL findings halts to human. Added 2026-06-26 per
        §10.2.
      - **`worker_quality → escalate_one_tier` (escalation-ladder)**
        — tier promotion on worker_quality FAIL.

      **Two paths for each mechanism, independently:**
      - (a) **Keep accumulating shadow slots** until at least one
        exercises the mechanism, then re-evaluate against §9. This
        is the rigorous path.
      - (b) **Graduate with explicit "untested-conservative" flag**
        on the mechanism. The mechanism's status in
        `policy/failure_class_routing.toml` (or
        `policy/circuit_breaker.toml` for cap) must carry
        `tested = false  # see §9 watchpoint` until path (a)
        closes the loop. **Path (b) requires a concrete-now
        watchpoint obligation, not aspirational tooling** — the
        safety argument for (b) is "retrospection catches the
        first miscall before a second slot suffers," and that's
        only real if the surfacing mechanism exists today.

      **Path (b) watchpoint obligation — concrete, executable
      today, no orchestrator change required:** the operator
      manually reviews the first **M=3** enforce-mode slots'
      `.pe/decisions.jsonl` specifically for first-fires of any
      `tested=false` mechanism. First-fire detection rules (against
      the existing decision-record schema in §10):
      - **cap first-fire:**
        `breaker_state_at_decision.breaker_would_trip == true`
        AND `enforced == true`.
      - **severity-floor first-fire:**
        `router_decision.rule_matched` starts with
        `severity_floor:` AND `enforced == true`.
      - **escalation-ladder first-fire:**
        `router_decision.action == "escalate_one_tier"` AND
        `enforced == true`.

      The manual-review commitment is **recorded in the graduation
      signoff** with the M value (default 3, matches §9 cohort
      minimum) and the scope (which mechanisms are `tested=false`
      at graduation). When a first-fire is detected, the operator
      inspects whether the router's call matched what they would
      have done; if it diverges, the policy is tightened OR the
      mechanism's `tested=false` is escalated to a real
      graduation re-evaluation before the next slot runs. **The
      watchpoint is the operator's commitment, not a tool — it
      must be carried out, not assumed.**

      **Eligibility for path (b) — fail-safe requirement:** path
      (b) is only available for mechanisms whose unexpected-case
      behavior is **provably fail-safe** (degenerate or
      unanticipated input routes to halt_to_human, never to
      continue or silent retry). The proof must be in writing — a
      static-analysis trace through the orchestrator code citing
      every degenerate branch and showing it routes to halt — and
      cited in the graduation-checklist signoff.

      - **Cap:** fail-safe (can only cut work short, never extend
        a runaway; iteration counter is monotonic).
      - **Severity-floor:** fail-safe **conditional on reviewer
        calibration**. Floor cannot silently pass a HIGH the
        reviewer **holds**; a HIGH the reviewer over-downgrades
        upstream of the envelope never reaches the floor (see
        `memory/project_phase_3_severity_floor_held_highs_only.md`
        in the consuming project + §10.2 for the original
        receipt). Eligibility for path (b) **preserved** —
        over-halting on held HIGHs is still over-halting, never
        under-halting — but the conditional must be **named in
        the graduation signoff**, not rounded up to unconditional.
      - **Escalation-ladder:** fail-safe per static-analysis
        2026-06-27 — top-tier exhaustion → halt via
        `top_tier_worker_quality`; unknown tier → halt; unknown
        failure_class → halt; schema error → halt; confidence
        below threshold → halt. No fallback-to-continue anywhere
        on the escalate path. **Caveat:** static ≠ runtime;
        first-fire in enforcement requires the same scrutiny that
        slot 1M.3.224b got.

      Path (b) is acceptable for the three named mechanisms
      because each is conservative — over-halts or cuts short,
      never silently extends a runaway or auto-merges bad work.
      The path (b) watchpoint catches the first miscall and
      tightens the policy before any second slot suffers — but
      only if the watchpoint is actually carried out per the
      signoff commitment.
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

### 10.1 Unstated precondition — slots must exercise the gate layer to count

**Added 2026-06-26 after the first shadow-mode slot ran.** §9's
"N≥3 forward-going slots" criterion has a precondition that was
implicit in the original draft and surfaced only when a real slot
ran: **a slot counts toward N only if it actually invokes the L3
gate layer.** Pure-diagnosis slots — investigation without a code
change that fires an agent — produce zero `pe shadow decide`
invocations and therefore zero per-decision records. There is
nothing for the router to decide on, and §2.D explicitly forbids
manufacturing synthetic envelopes to fill the gap ("would validate
the router against synthetic data").

This is one layer up from the un-triggered≠validated principle: a
slot that *ran* is not necessarily a slot that *exercised the
router*. The N≥3 bar is N≥3 router-exercising slots.

**Concrete consequence for slot selection:**

| Slot kind | Counts toward N? | Why |
|---|---|---|
| Code change that fires ≥1 L3 gate | YES | Real envelope → real router decision → real reconciliation |
| Pure-diagnosis (no code change) | NO | Zero envelopes → null-by-design reconciliation |
| Code change firing gates but all PASS (failure_class=none) | YES, but low-signal | Records `continue` decisions; useful as plumbing proof but doesn't exercise escalation/halt paths |
| Code change triggering escalation, halt, or near-cap | YES, and high-signal | The slots where the router does its interesting work — graduation cohort should include ≥1 of these |

**Selection heuristic:** the N≥3 cohort must collectively cover at
least one slot that exercises **escalation or halt or near-cap**,
not three thin PASS-only slots. Three PASS slots prove plumbing,
not routing. The receipt for graduation is the router actually
making non-trivial decisions, not just logging them.

**The good-faith-attempt clause** (added 2026-06-27): the selection
heuristic above says the cohort must INCLUDE a slot that exercises
escalation/halt/near-cap — not that the slot must *organically*
trigger. The distinction matters because some mechanisms
(worker_quality FAIL → escalation; near-cap from ≥4 iter loops)
cannot be scheduled — they happen when reality produces them, not
on operator pace. Holding graduation hostage to an unscheduled
event has no upper bound and contradicts §9's "larger samples
delay the cost win unnecessarily" framing.

**Therefore the heuristic is satisfied when:** the cohort INCLUDES
≥1 slot SELECTED for substantive non-trivial potential (real
surface area likely to produce a held HIGH, a worker_quality FAIL,
or a multi-iter loop) AND run in good faith. If that slot
organically exercises escalation/halt/near-cap, the relevant
mechanism is `tested=true` at graduation — bonus. If it does not,
graduation may proceed with the relevant mechanism `tested=false`
per §9's "Un-triggered ≠ validated" path (b), provided:
- The slot's selection rationale is recorded in the reconciliation
  `notes` field. "Selected for substantive non-trivial potential"
  is not boilerplate — name the surface area expected to produce
  the trigger.
- The mechanism is on §9's fail-safe eligibility list.
- The operator watchpoint per §9 path (b) is committed in the
  graduation signoff (concrete-now obligation, not aspirational
  tooling).

**Anti-pattern this clause forbids:** running three thin PASS-only
slots ALL picked for smallest-mechanical count-clearance, then
graduating on the basis that none organically fired. The cohort
must contain ≥1 slot whose selection rationale is
substantive-non-trivial-potential; the "did it actually fire"
question becomes the bonus, not the gate.

**Anti-pattern this clause does NOT forbid:** picking a real
substantive slot, running it honestly, and graduating with the
mechanism `tested=false` when reality didn't produce the trigger.
That's good engineering, not a shortcut.

**Origin:** caught by the first shadow-mode slot run
(2026-06-26, 8CStudio BACKLOG #224 diagnosis). The slot did real,
disciplined work — diagnosed hypothesis (a), found it didn't pan
out, stopped per the timebox rule, reverted cleanly — but
generated zero shadow records because the diagnosis path never
fired an agent. Surfaced the gap before graduation, not during it.

### 10.2 Severity-aware routing — finding severity is NOT advisory

**Added 2026-06-26 after slot 1M.3.224b surfaced the second
unstated precondition on real shadow data.** The original
routing policy keyed off `verdict + failure_class` only. Finding
severity was invisible to the router: a `WARN` envelope with 3
HIGH findings routed identically to a clean `WARN`. That's not
how consumer projects treat HIGH findings — 8CStudio's commit
policy (CLAUDE.md §9): "CRITICAL must block; HIGH should be
fixed before commit unless explicit `Code-skip-reason: <reason>`
trailer is logged." So the router said "continue" on a state
where the consumer's own discipline said "stop."

**The rule** (now encoded in `policy/failure_class_routing.toml`
`[severity_override]`): a PASS or WARN envelope carrying findings
of severity in `block_severities` (default: `["HIGH",
"CRITICAL"]`) overrides the verdict→continue mapping and routes
to `halt_to_human`. FAIL verdicts are untouched — those still
route via `failure_class` as before. The severity floor fires
after schema-error + confidence-override and before the
verdict→continue lookup.

**Why this matters at enforcement:** without this rule, the first
time the router is taken off shadow-mode, it would silently
auto-merge any WARN+HIGH or PASS+HIGH work that the consumer
project's commit-time hooks would have blocked. The router exists
to AUTOMATE the operator's commit-time judgment; a blind spot at
this layer would actively contradict the operator's own discipline.

**Receipt:** slot 1M.3.224b (8CStudio, 2026-06-26) generated 3
envelopes — code-reviewer WARN+1HIGH, database-reviewer PASS+0HIGH,
security-reviewer WARN+3HIGH. Under the pre-fix policy, all three
routed `continue` (`rule_matched=none`). Reconcile recorded
`decisions_matching_reality: 1, decisions_diverging_from_reality:
2` — the operator stopped on the 4 HIGH findings per project
policy; the router would have proceeded. That mismatch in
`.pe/reconciliations.jsonl` is the receipt this rule fixes.

**Cohort reset:** shadow records produced under the pre-fix
policy (slot 1M.5.1 + slot 1M.3.224b on engine baseline
`8e533ce` or earlier) cannot validate the corrected policy.
Honest accounting: N effectively resets toward 0 after this rule
lands. That's not a setback — it's the cheap-now-vs-catastrophic-
later read: catching this at 2 records is the whole point of
shadow-mode. New shadow cohort accumulates against the corrected
policy starting at the next gate-exercising slot.

**Test coverage** (`tests/test_phase_3_orchestrator.sh`):
- 6a: WARN + 1 HIGH → halt (rule_matched=`severity_floor:HIGH`)
- 6b: PASS + 1 CRITICAL → halt (rule_matched=`severity_floor:CRITICAL`)
- 6c: WARN + only MEDIUM/LOW → continue (no false positive)
- 6d: PASS + empty findings → continue (regression guard)
- 6e: FAIL + HIGH finding → routes via `failure_class`, severity floor does NOT shadow the FAIL path

---

## 11. Sentry baseline — forward-going only by design

**Status revised 2026-06-26 after backfill attempt.** Original
framing assumed pre-#79 baselines could be retroactively populated
once Sentry MCP auth completed. They can't. Here's what we learned
and what it means.

**What happened (2026-06-26):**
- Sentry MCP OAuth flow broken (`mcp.sentry.dev` proxy loses state
  during GitHub federated login). Confirmed across 4 attempts —
  not user-fixable.
- Pivoted to direct Sentry REST API via user auth token (per
  CLAUDE.md §9 + §12b API-credentials pattern). Auth succeeded
  cleanly.
- Queried each merge SHA (`776b435`, `88c4cc5`, `c90f13b`) for
  release-tagged issues in 7d post-merge window. **All three
  returned 0.**

**Why "0 across the board" is not a clean result:**
The Sentry release-tagging fix (PR #79 / engine commit `b04d428`)
landed 2026-06-25 — **three weeks AFTER** the 1M.3 / 1M.5 / 1m.5.1
deploys (2026-06-04 / 06-04 / 06-05). Before #79, `deploy-staging.sh`
didn't propagate `GIT_SHA` over SSH → docker compose substituted
`unknown` → app.py reported `release: unknown` to Sentry. Verified
directly: 3 issues exist in the deploy week of 2026-06-04 → 06-11;
**2 of them are tagged `release: unknown`**; 0 are tagged with any of
{`776b435`, `88c4cc5`, `c90f13b`}. Sentry events are immutable —
retroactive retag is impossible.

**Conclusion: `sentry_incidents_7d` is a forward-going-only metric
for the engine.** Pre-#79 baselines carry `null_retrospective` with
the evidence chain in `measurable_notes`. Forward-going slots will
have real release tagging and ARE measurable.

**What this changes for graduation (§9 criterion #1, updated):**
The Sentry gate is no longer "backfill the 3 baselines"; it is
"shadow-mode slots show no release-tagged regression against zero,
where zero is now a real bar because release-tagging works." Same
"don't compare against a fake number" discipline as the un-triggered
≠ validated branch in the cap-validation criterion.

**Anti-pattern flagged:** a future session might be tempted to
"resolve" the null by recording 0 (or any number) into the 3
baseline JSONs. **Don't.** Null with the receipt is the structural
truth; 0 would be a phantom baseline.

**Other two graduation metrics unaffected:**
- `rework_72h` — derived from git history, retrospectively
  measurable, remains valid for all 3 baselines.
- `gate_pass_rate` — already `null_retrospective` for all 3 (pre-E1
  gates emitted prose, not envelopes), unchanged.

So the graduation gate stays meaningful on 2 of 3 metrics
retrospectively + all 3 metrics forward-going. Net: weaker than the
original assumption but honest.

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
