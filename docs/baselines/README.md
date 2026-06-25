# Phase 0 Baselines

> **Purpose:** record the **current-engine** speed, size, and quality
> profile of representative slot types **before** Phase 3 ships the
> escalation ladder. Phase 3's success criterion = "didn't get worse"
> against these numbers.
>
> **Constraint:** quality is the bar. Faster + cheaper does not count
> if rework or Sentry incidence goes up.

---

## Why this corpus exists

The engine v2 design (`process-engine-enhancement-design.md` →
critique in operator session 2026-06-24) promises faster + cheaper
output via tiered routing + escalation. The critique caught the gap:
**without a baseline, "faster" claims are unverifiable and
"quality-preserved" claims are uncheckable.**

E2 captures that baseline. The metrics are deliberately scoped to what
git history + Sentry MCP can answer **retrospectively** (so the
baseline can be measured against existing 8CStudio history without
running anything). Forward-going metrics (tokens, gate-pass-rate) are
explicitly nulled with `measurable_notes[]` receipts so the
retrospective-vs-forward-going line is visible.

## Slot corpus (3 slots)

| Slot | Kind | Merge | Justification |
|---|---|---|---|
| **1M.5** | `feature_incremental` | `776b435` | Single-merge feature with multi-file diff (13 files, +1169/-4). Representative of "ship a contained slot in one go." |
| **1M.3** | `feature_multi_iteration` | `88c4cc5` | 18 commits across phases 6.1.5–6.1.9, 43 files, +6628/-68. Real-world "took multiple iterations to land" profile — the exact shape Phase 3's escalation ladder is supposed to compress. |
| **1m.5.1-sw-cache-bump** | `hotfix` | `c90f13b` | Single-commit, single-file follow-up (1 file, +7/-1). Baseline for the "trivial" end of the distribution. |

## Captured metrics (2026-06-24)

| | 1M.5 | 1M.3 | 1m.5.1 |
|---|---:|---:|---:|
| **wall_clock_hours** | 0.25 | **189.70** | 0.00 |
| **iterations** | 1 | **18** | 1 |
| **files_changed** | 13 | 43 | 1 |
| **lines_added** | 1169 | 6628 | 7 |
| **lines_removed** | 4 | 68 | 1 |
| **rework_72h** | **1** | **1** | 0 |
| **sentry_incidents_7d** | _null (MCP unauthed)_ | _null (MCP unauthed)_ | _n/a_ |
| **gate_pass_rate** | _null (pre-E1)_ | _null (pre-E1)_ | _null (pre-E1)_ |
| **tokens** | _null (pre-E2.1)_ | _null (pre-E2.1)_ | _null (pre-E2.1)_ |

(Source files: `1m.5.json`, `1m.3.json`, `1m.5.1.json` in this directory.)

### Rework receipts

- **1M.5** — flagged commit `c90f13b` (the SW cache bump). Rule:
  `slot_id_in_subject`. This is genuine rework: 1M.5 shipped without
  bumping the service-worker cache name, so installed PWAs were stuck
  on the old shell and never picked up the new `bootstrapTokens()`
  call. Caught + fixed within hours, but it counts.
- **1M.3** — same commit `c90f13b`, this time matched by
  `file_overlap` because `static/sw.js` was touched in both slots.
  Cross-slot rework signal: 1M.5's hotfix is reworking a file 1M.3
  also owned.
- **1m.5.1** — 0 rework (clean hotfix, no follow-up needed).

## What is NOT measurable in this baseline (honest accounting)

The harness records every "not measured" field with a `status` and a
`reason` so future readers don't conflate "no data" with "zero":

| Field | Status | Reason |
|---|---|---|
| `quality.gate_pass_rate` | `null_retrospective` | Pre-E1, gates emitted prose, not envelopes. First measurable on the **next** slot shipped post-E1 (PR #1). |
| `cost.*` (tokens) | `null_retrospective` | Claude Code did not emit per-slot token telemetry pre-E2.1. Forward-going slot harness will. |
| `quality.sentry_incidents_7d` | `null_unavailable` | Sentry MCP requires OAuth at capture time. Operator can rerun harness with `--sentry-count <n>` once authed; the records will update in place. |

## Detection rules — known false-positive risks (and the fix in place)

- **`slot_id_in_subject`** fires on **any** commit subject mentioning
  the slot ID in the 72h window. Filtered by `HOUSEKEEPING_PREFIX_RE`
  (excludes `docs:`, `test:`, `chore:`, `refactor:`, `ci:`, `build:`,
  `perf:`, `style:` prefixes — completion-ritual commits, not rework).
  Without this filter the 1M.5 and 1M.3 records would each show
  `rework_72h=2` from docs commits; with it, both show the single
  genuine fix.
- **`file_overlap`** fires only when a `fix|hotfix|patch|revert`
  prefix coincides with overlap of files the slot touched. Tight by
  design.
- **`fix_prefix_in_window`** is the catch-all: a fix-prefixed commit
  in the 72h window with no file overlap. Surfaces cross-cutting
  fixes; included for completeness but rarely fires on shipped slots.

## Phase 3 success criterion

When the escalation ladder + circuit breaker ship, the same 3 slots
will be re-run **end-to-end through the engine** (workers + gates +
orchestrator). New records will be written to
`docs/baselines/post-phase-3/<slot-id>.json`. The diff with these
pre-Phase-3 records is the verdict.

**Phase 3 ships only if all of the following hold:**

1. `quality.rework_72h` **does not increase** on any slot.
2. `quality.sentry_incidents_7d` **does not increase** on any slot
   (with Sentry MCP authed at re-run time).
3. `quality.gate_pass_rate` is **≥ 0.80** averaged across the 3 slots
   (i.e. the escalation ladder doesn't burn five tiers on every task).
4. `speed.wall_clock_hours` is **less than or equal** to the baseline
   on at least 2 of 3 slots.

Rules 1–3 protect quality. Rule 4 is the "actually faster" check, but
it's deliberately the **last** criterion — quality non-regression is
the gate, speed is the reward.

## Rerunning / extending

Add another slot to the corpus:

```
pe baseline capture \
  --project /path/to/8CStudio \
  --slot-id <id> \
  --slot-kind <feature_incremental|feature_multi_iteration|bug_fix|hotfix|refactor|docs> \
  --branch <branch-name> \
  --merge-commit <sha> \
  [--sentry-count <n>] \
  --output docs/baselines/<slot-id>.json
```

Add Sentry counts in place (records re-emit cleanly):

```
pe baseline capture --sentry-count 0 ... --output docs/baselines/1m.5.json
```

The schema lives at `schemas/baseline.schema.json`. The harness lives
at `scripts/baseline.py` (stdlib only, no runtime deps).

## Follow-ups

- **E2.1** — Claude Code session hook that emits per-session token
  counts on slot-branch sessions, into `docs/baselines/sessions/`.
  Closes the retrospective gap for `cost.*` going forward.
- **Sentry-count backfill** — quick operator pass once Sentry MCP is
  authed; rerun the harness with `--sentry-count` and re-commit. No
  schema change needed.
- **More slots** — Add 1F.11a (markdown character import — a third
  archetype: hybrid LLM+deterministic) once the existing corpus is
  validated by Phase 3.
