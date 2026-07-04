# A4 first-fire — §9 watchpoint evidence bundle

> **Status:** §9 watchpoint CLOSED (2026-07-05).
> `policy/failure_class_routing.toml` flipped
> `worker_quality → escalate_one_tier` from `tested=false` to
> `tested=true`.

## What the watchpoint said

`policy/failure_class_routing.toml` shipped v0.42.0 with the A4
auto-escalation loop implemented but explicitly marked
`tested=false` on the worker_quality escalation rule. The
graduation cohort had no organic worker_quality FAIL, so the
ladder was untested against real behavior. Flipping to
`tested=true` required:

1. A live A4 loop invocation against a real `claude -p`
   subprocess (not a mock invoker).
2. Reviewer judgment that the router's escalation choice matched
   what the operator would have done.
3. A `.pe/decisions.jsonl` row where
   `router_decision.action == "escalate_one_tier" AND
   enforced == true`.

## The experiment

**Slot ID:** `A4-FIRST-FIRE-001`
**Date:** 2026-07-05
**Engine version:** v0.43.0 (v0.44.0 flips the flag)

### Seed (iteration 1, tier haiku)

Working file `billing_util.py` — deliberate real code smells:

```python
import json, os, sys, hashlib   # all unused

def calculate_fee(amount, rate):
    """Return the calculated fee. Note: uses float; should be Decimal for money."""
    return amount * rate
```

Seed envelope (`00-seed-envelope.json`) declared:

- `verdict: "FAIL"`
- `failure_class: "worker_quality"`
- Two findings:
  - `HIGH money-float-not-decimal` — the float-arithmetic-for-money smell
  - `MEDIUM unused-imports` — the four unused imports on line 1

### Invocation

```bash
python3 scripts/pe_orchestrator.py decide \
  --envelope seed_envelope.json \
  --slot-id A4-FIRST-FIRE-001 \
  --slot-kind code-review \
  --iteration 1 \
  --current-tier haiku \
  --bare \
  --auto-execute \
  --enforce \
  --agent code-reviewer \
  --max-iterations 2 \
  --campaign-id first-fire
```

### Observed trajectory

Full log in `02-trajectory.jsonl`. Summary:

| Iteration | Tier   | Verdict | Duration | Notes |
|---:|---|---|---|---|
| 1 | haiku  | FAIL (seed)        | — | Router: `escalate_one_tier` to sonnet |
| 2 | sonnet | PASS (real claude) | ~56s wallclock | Both findings resolved |

Iteration-2 envelope emitted by the sonnet-tier `claude -p`
invocation (`03-iter-2-envelope.txt`):

- `verdict: PASS`
- `failure_class: none`
- `confidence: 0.97`
- `findings: []`
- `summary: "Fixed: replaced float arithmetic with Decimal for
  monetary amounts; removed all unused imports (json, os, sys,
  hashlib). No remaining CRITICAL or HIGH findings."`

Loop terminated with `A4_EXIT_CONTINUE` (exit 0). Trajectory
`halt` record: `{"kind": "halt", "reason": "continue",
"final_iteration": 2}`.

## Operator judgment

The router's escalation choice was **correct**:

- The seeded FAIL was legitimately `worker_quality` — a
  reviewer at a higher tier could reasonably resolve it.
- `escalate_one_tier` from haiku to sonnet is the policy-
  correct move (per the ladder in
  `policy/failure_class_routing.toml`).
- The sonnet-tier response addressed both findings and framed
  the fix in the summary — exactly what a human operator would
  have accepted.

No divergence between what the router did and what the
operator would have done. **Watchpoint closed.**

## Cost / performance notes

- One escalation iteration = one `claude -p` subprocess.
- Wallclock: ~56 seconds (invoke → post_invoke).
- API cost: not measured this pass (the envelope cost fields
  from `claude -p --output-format json` weren't wired into the
  A4 trajectory summary; that's a follow-on shape improvement).
- The trajectory log at
  `.pe/a4-runs/<decision_id>/trajectory.jsonl` gives the
  post-mortem surface.

## What flips

- `policy/failure_class_routing.toml` — the ladder comment
  block now names the 2026-07-05 first-fire and the
  tested-true flip.
- HANDOFF + CHANGELOG record v0.44.0 as the release that
  closes the watchpoint.

## Follow-ons NOT done here

- Cost surfacing inside the trajectory log (deferred until an
  adopter needs a per-loop cost report).
- Multi-iteration fire (2+ escalations in one loop). A single
  iteration was enough to prove the wiring; if a real adopter
  sees a slot where sonnet also FAILs and opus is invoked,
  that's the next observation.
- Divergence handling. If a future first-fire matches the
  router's choice, the watchpoint stays closed. If a future
  fire diverges, the policy comment already documents the
  reversibility path: flip `tested=true` back to `tested=false`
  while the policy is tightened.

## Artifacts

- `A4_FIRST_FIRE_artifacts/00-seed-envelope.json` — the seeded
  FAIL envelope.
- `A4_FIRST_FIRE_artifacts/01-decisions.jsonl` — both shadow
  decision records (iterations 1 and 2, both `enforced=true`).
- `A4_FIRST_FIRE_artifacts/02-trajectory.jsonl` — full loop
  trajectory (loop_start / invoke / post_invoke / halt).
- `A4_FIRST_FIRE_artifacts/03-iter-2-envelope.txt` — the raw
  claude-p output text (validated envelope + wrapper text).
