# Engine Backlog

> Engine-side gaps, priorities, and polish. Each priority block lists what's
> in scope, what's deliberately deferred, and the trigger that promotes a
> deferred item.
>
> Originally seeded 2026-06-29 from the Origyn cross-environment install test
> (the engine's first new-env reusability proof). Reorganized 2026-06-29 into
> three priorities after the distribution-bundle scoping session.

---

## Priority overview

| # | Block | State | Trigger to start |
|---|---|---|---|
| **P1** | Distribution bundle (5 items, locked order) | ✅ **SHIPPED in v0.8.0** (2026-06-30) | — |
| **P2 Stage A** | Coupling map | ✅ **SHIPPED** — `docs/COUPLING_MAP.md` (2026-06-30) | — |
| **P2 Stage B** | Phase 4 DAG scheduler | ⏸️ **PARKED** — clean clusters, no pervasive tangle | COUPLING_MAP §7 re-eval triggers |
| **P3** | Auto-update suggestion surfacer | ⏸️ **PARKED** | ≥1 concrete recurring "we keep noticing X" pattern from adopter feedback |
| **E1.c.2** | Reconciling `pe install` (broken-symlink cleanup) | ✅ **SHIPPED in v0.9.0** (2026-07-01) | — |

Original findings #1–#5 (2026-06-29 Origyn test) shipped in v0.8.0 P1 bundle.
Finding #6 (research_index.py SIM102) shipped in v0.8.0 as commit `9ec6cb5`.
Finding #5 (8CStudio `.process-engine.yaml`) resolved out-of-band during that
session. Details below preserved as history — see per-item ✅ markers.

---

# PRIORITY 1 — Distribution bundle (engine-repo only) — ✅ SHIPPED v0.8.0

**Status 2026-06-30:** all 5 items landed under `[0.8.0]` in CHANGELOG.md.
See per-item commit refs below. Kept in this doc as history — the spec
is the source of the shipped behavior.

**Goal:** make "everyone gets engine improvements" real via reviewed, pulled
distribution. Engine never self-modifies; humans review + version + pull.

**Locked order** (resequenced from original BACKLOG findings — subset shapes sync):

```
5-prep  →  1  →  4  →  3  →  2  →  5-finalize
```

**Confirmations carried from scoping session:**
- (a) Order — confirmed 5-prep → 1 → 4 → 3 → 2 → 5-finalize.
- (b) Subset — `pe install <project> --subset {gate-only|core|full}`, default `full`. Option (a) lean preset wins over (b) all-or-nothing because the catalog §8 already promises subset. `full` default = no-surprise default.
- (c) `pe sync` smoke test — ADD a minimal test of the safety contract: "re-points a stale symlink correctly" + "does NOT overwrite a differing file without confirmation." Not full `scripts/pe` coverage — just proof the destructive path is gated.

**Changelog discipline:** ONE bump to `0.8.0` for the whole bundle; five entries under `[0.8.0]`.

**Out of scope for this bundle (do NOT scope-creep — backlog if tempting):**
Phase 4, E2.1, auto-tier-routing, watchpoint tooling, `pe install` reconciling
(E1.c.2). All deferred — they belong to P2 or later.

## P1.5-prep — VERSION + CHANGELOG skeleton — ✅ SHIPPED (`3c15b3d`)

Bundled INTO item 1's commit. Open `[0.8.0]` heading in `CHANGELOG.md` so
every subsequent commit drops its entry under it. No "unreleased" gap.

## P1.1 — Version-awareness (cosmetic + non-breaking — smallest blast radius first) — ✅ SHIPPED (`3c15b3d`)

- Bump `VERSION` `0.7.0` → `0.8.0`.
- `scripts/pe` line 56: drop `"(no enforcement)"`. Replace with `"(enforce gated by --enforce; graduated 2026-06-28)"`.
- Extend `pe doctor <project>` to print:
  - Engine version banner (from `VERSION`).
  - Per-agent staleness summary (data already collected by the `cmd_doctor` SHADOWED block at `scripts/pe:348-386` — just surface the count + names at the top).
- Add CHANGELOG entry under `[0.8.0] - 2026-06-29`.

**Originated from:** original Finding #1 (VERSION drift after Phase 3
graduation). Fix path locked.

## P1.4 — PATH fix in INSTALL.md (docs-only) — ✅ SHIPPED (`ea3ab63`)

Done before P1.3 so it doesn't conflate with code changes.

- After the `~/.local/bin/pe` symlink step, add a PATH check snippet that detects whether `~/.local/bin` is on `$PATH` and prints the export line for `~/.zshrc` if not.
- Add CHANGELOG entry.

**Originated from:** original Finding #3 (`~/.local/bin` not on PATH on fresh
macOS — first-30-seconds friction surfaced during Origyn test).

## P1.3 — Subset install preset — ✅ SHIPPED (`2367e56`)

- `pe install <project> --subset <preset>` where preset ∈ `{gate-only, core, full}`.
  - `gate-only` = 5 gate agents only (`code-reviewer`, `security-reviewer`, `database-reviewer`, `tdd-guide`, `e2e-runner`).
  - `core` = gates + `planner` + `brief-writer` + `architect`.
  - `full` = current behavior. **Default.**
- Update `pe install` usage + `pe help install` to document the flag.
- Update `CAPABILITY_CATALOG.md` §1 / §3 to point at the new flag (catalog already promises subset; now it can deliver).
- Add CHANGELOG entry.

**Originated from:** original Finding #2 (`pe install` all-or-nothing
contradicts catalog §8 subset promise). Path (a) lean preset chosen.

## P1.2 — `pe sync` command (largest item — last in bundle) — ✅ SHIPPED (`9ce0fc3`)

THE contract: **diff-before-clobber**. Never blanket-overwrite.

- New subcommand: `pe sync <project>`.
- Re-points project's symlinks at current engine for the project's installed subset (preserves the subset chosen at install time — read from `.process-engine.yaml` or infer from existing symlinks).
- For each engine-managed link/file in project:
  - **Symlink already points at current engine** → skip (idempotent).
  - **Symlink points elsewhere OR regular file that differs from engine** → show unified diff, prompt `y/N`, NEVER overwrite without explicit confirmation.
  - **File matches engine byte-for-byte** → upgrade to symlink silently.
- Add `--dry-run` (show what would change, no writes).
- Document `pe sync` as the canonical fix for stale-user-globals propagation: future projects pick up engine improvements via `pe sync`, no manual diff-and-delete needed.
- **Smoke test (per confirmation (c)):** minimal test proving (1) stale symlink gets re-pointed; (2) differing file does NOT get overwritten without confirmation. Failure mode of untested = clobbers a customized agent.
- Add CHANGELOG entry.

**Originated from:** original Finding #4 (stale user-global gate agents
shadow engine in projects without project-local symlinks). `pe sync`
retires the manual cleanup concern for all future projects.

## P1.5-finalize — CHANGELOG discipline check — ✅ SHIPPED (`8352265`)

Last step before closing the bundle:
- Verify every commit in the bundle has an entry under `[0.8.0]`.
- Add release date line.
- Run engine self-check (`pe doctor` with no args; should report ✓ at 0.8.0).
- Dogfood gate: run `code-reviewer` on the cumulative bundle diff, address CRITICAL/HIGH before merging.

---

## P1-adjacent (carry forward, not blocking bundle)

### Finding #7 (new, 2026-07-01 Origyn T1) — `worker_quality` failure_class is a poor fit for house-rule violations · design

**Trigger observed:** Origyn slot `origyn-trainer-cockpit-t1`, iteration 1,
code-reviewer emitted CRITICAL `file-line-count-hard-gate` (blueprints/trainer.py
grew to 824 lines, exceeding CLAUDE.md §5 pre-commit gate 7's 800-line hard
block). Router correctly fired `action=escalate_one_tier` (first-fire of the
escalation ladder for the T1 slice). Operator flagged the watchpoint, decided
against escalation, extracted helpers to a new file, re-reviewed → PASS.

**The mismatch:** the escalation-ladder semantics assume `worker_quality` means
"the worker (a specific tier) wasn't smart enough — retry at a higher tier."
Here the failure was that a project house-rule (file-size gate) was violated.
Escalating haiku → sonnet on the code-reviewer or the presumed worker would
not change the file's line count. The finding is real but the remediation is
mechanical (extract to a new module), not "throw a smarter model at it."

**Proposed shape (not urgent):** a new failure_class, e.g.
`house_rule_violation` or `structural_refactor_required`, with router action
`halt_to_human` (or `require_refactor`). Distinct from `worker_quality`
(actual code bug) and `out_of_scope` (touched files outside slot allowlist).
Better matches the operator's actual response — this class of finding is
"fix mechanically then re-review," never "escalate to a bigger worker."

**Blast radius of NOT fixing:** small. Operators can override the router
decision manually (as done here), record the choice in reconciliation
`router_correctness` notes, and move on. Just makes the audit trail slightly
noisier and the router's semantic promise slightly weaker.

**Priority:** P2 or P3, no rush. The next observation of the same pattern
will strengthen the case for a new failure_class.

**Reference:** Origyn `.pe/decisions.jsonl` — slot `origyn-trainer-cockpit-t1`
(FAIL/escalate first-fire) and `origyn-trainer-cockpit-t1-fix` (PASS/continue).

---

### Finding #6 (new, 2026-06-29 Origyn slice 1) — `scripts/research_index.py` SIM102 trips downstream lint · cosmetic — ✅ SHIPPED (`9ec6cb5`)

`scripts/research_index.py:715` has nested `if` statements ruff flags as SIM102.
The file gets symlinked into consuming projects via `pe install`, so consuming
projects that run `ruff check .` on their full tree (Origyn does) hit the
warning. Origyn worked around by excluding the symlinked path in its
`pyproject.toml`. The fix belongs upstream so every adopter doesn't need the
same exclude.

**Fix:** combine the nested `if args.cmd == "rebuild"` + `if not corpus.exists()`
into a single conjunction, or add `# noqa: SIM102` with rationale.

**Trigger:** before the next `pe install` into a fresh project that runs ruff.

### Original Finding #5 — 8CStudio missing `.process-engine.yaml` · cosmetic — ✅ RESOLVED (2026-06-30, file present on disk)

`pe doctor /Users/sanishsasikumar/Documents/8Colors/8CStudio` reports
`Missing .process-engine.yaml — re-run 'pe install' to create it`.

**Fix:** re-run `pe install /Users/sanishsasikumar/Documents/8Colors/8CStudio`
(idempotent for symlinks; copies YAML if absent). Or manually copy
`templates/.process-engine.yaml.template`.

**Trigger:** before any `pe launchd` run on 8CStudio. Not bundle-critical.

### E1.c.2 — reconciling `pe install` (broken-symlink cleanup) — ✅ SHIPPED v0.9.0 (2026-07-01)

Closes GitHub issue #10. Originally deferred out of the P1 bundle (see
"Out of scope for this bundle" line above) — promoted to active in the
first post-v0.8.0 session once the bundle was proven stable.

**What shipped:**
- `pe install` silently removes BROKEN symlinks in `.claude/agents/` and
  `.claude/commands/` on every install. Real files (customizations)
  untouched. Skills (user-global) untouched.
- New smoke test `tests/test_pe_install_reconcile.sh` (10 assertions
  passing) — mirrors the shape of `test_pe_sync.sh`.
- TROUBLESHOOTING.md §4 refreshed + new §4b: "Why does my project
  have a broken symlink I didn't create?"

**Design split (documented in `install.sh` header comment):**
- **`pe install`** = silent removal of BROKEN symlinks only.
- **`pe sync`** = interactive removal of subset-downgrade orphans
  (fine symlinks to agents no longer in the current subset). Prompted
  per-file because widening a subset back is common and clobbering
  without confirmation would surprise the operator.

**Deferred (separate policy call — not part of E1.c.2):**
- Consuming-end story for `.process-engine.yaml` + `scripts/research_index.py`
  untracked byproducts in adopters. Original issue #10 mentions this but
  it's an adoption-policy decision, not a bug fix. Belongs in a follow-up.

### Resolved-but-document — stale user-globals (was Finding #4)

Six user-global agents (`code-reviewer.md`, `architect.md`,
`database-reviewer.md`, `e2e-runner.md`, `security-reviewer.md`,
`tdd-guide.md`) at `~/.claude/agents/` differ from current engine versions
(pre-graduation timestamps, smaller line counts).

**Status 2026-06-29:** Both currently-active projects (8CStudio, Origyn) are
protected by project-local symlinks. `pe sync` (P1.2) is the structural fix
for any FUTURE project — no manual diff-and-delete required. The 6 stale
user-globals do NOT need manual cleanup; leave them.

**Lesson preserved:** `pe install` warning is load-bearing — keep its
"diff-before-delete" recommendation prominent. The `cmp -s` shadow detection
in `scripts/pe` is the propagation-gap canary; do not weaken it.

---

# PRIORITY 2 — Coupled-parallelism

**Promoted from backlog 2026-06-29.** No longer premature. Real, justified
problem surfaced by working sessions on 8CStudio + Origyn.

**Stage A resolved 2026-06-30 — see `docs/COUPLING_MAP.md`.** Both 8CStudio
and Origyn cluster cleanly. Stage B (Phase 4 build) is **NOT justified by
current data** — parked with defined re-evaluation triggers in
COUPLING_MAP.md §7. Stage A (session-per-cluster workflow) is the answer;
the cluster table lives in COUPLING_MAP.md §5.

## The problem

Modules aren't independent. Sales ↔ finance are coupled (quotes ↔ invoices),
client ↔ trainer in Origyn affect each other, hotfixes touch modules a feature
session is also in. Running them as SEPARATE blind sessions TANGLES — the
sessions don't know what each other is doing, PRs collide, operator pauses
to explain/untangle. So "just use separate sessions" does NOT solve it for
COUPLED work. This is the genuine coordinated-parallelism wall.

## Two stages, cheapest first — do NOT jump straight to Phase 4

### Stage A — Workflow fix (cheap, try FIRST) — ✅ RESOLVED 2026-06-30

Split sessions by COUPLING BOUNDARY, not by module name:
- Coupled work in ONE session (sales+finance together; client+trainer
  interactions together — don't split what's coupled).
- Only GENUINELY INDEPENDENT work goes to separate sessions.

**Diagnostic question answer:** both apps **CLUSTER CLEANLY** (parallel
Explore-agent surveys of both repos, synthesized in `docs/COUPLING_MAP.md`).

**Cluster table (session-split guide):**
- **8CStudio:** 3 domain clusters (Production Pipeline, Money, Reporting) +
  5 utilities/placeholders. 4 cross-cluster edges, all WEAK or intentional.
- **Origyn:** 3 domain clusters (Coaching, Exercise library, Payment) +
  shared infra. Client + Trainer merged into a single "Coaching" cluster
  due to the STRONG unavoidable border edge `trainer → Lead` — this is the
  most important operational finding.

Stage A verdict: session-per-cluster works for free, no build. **Rule of
thumb:** "don't split what's coupled" now has a concrete cluster-membership
answer per repo.

### Stage B — Phase 4 build (real engineering, ONLY if Stage A map shows pervasive tangle)

Phase 4 = dependency-AWARE coordinated scheduler. **The value is
COORDINATION, not just parallel execution.** Parallel execution WITHOUT
dependency-awareness just reproduces the blind-sessions tangle inside one
orchestrator.

Three parts, **in order**:

1. **E2.1 token telemetry FIRST (hard prereq).** Parallel workers =
   concurrent multiplied token spend; orchestrator runs `inf` budgets today
   (per `policy/circuit_breaker.toml` — `worker_tokens_budget = "inf"`,
   `gate_tokens_budget = "inf"`). The cumulative budget guard MUST become
   load-bearing before any parallel execution lands. Non-negotiable —
   coupled/many-worker scenario is exactly why.
2. **Dependency model.** A way to declare which modules are coupled and HOW
   (what conflicts, what must sequence, what can parallelize). Design work,
   not just code. The Stage A coupling map feeds directly into this.
3. **DAG scheduler / parallel executor.** Runs the graph: parallel where
   independent, sequenced where coupled, ONE coordinator aware of the whole
   graph, respecting a worker-concurrency cap + the E2.1 budget.

### Stage B start conditions (BOTH must hold)

- P1 distribution bundle SHIPPED and dogfooded — ✅ done 2026-06-30
  (engine v0.8.0 on origin/master).
- Stage A coupling map confirms PERVASIVE TANGLE (not clean clusters).
  ❌ **Current data shows clean clusters** (COUPLING_MAP.md §5). Stage B
  is parked; re-evaluation triggers listed in COUPLING_MAP.md §7. Any of
  those firing = re-open this block.

---

# PRIORITY 3 — Auto-update suggestion (backlog, do not build now)

The "everyone gets improvements" half = the P1 distribution bundle. The
engine must **NEVER** auto-detect-and-self-commit improvements to git — a bad
auto-improvement would propagate to EVERY project via `pe sync`, unreviewed.

| Mode | Allowed | Why |
|---|---|---|
| Distribution (human improves → review → version/changelog → pull) | ✅ YES | This is what P1 ships. |
| Self-modification (engine commits its own improvements) | ❌ NEVER | One bad change propagates to all projects unreviewed. |
| **Suggestion surfacer** (engine LOGS improvement candidates; human reviews + applies via normal flow) | ⚠️ Backlog — safe middle ground | Surfaces signal without taking the action. |

**Trigger to start P3:** P1 shipped, P2 settled (Stage A documented or
Stage B built), and at least one concrete recurring "we keep noticing X
across sessions" pattern that would have been worth surfacing.

---

## Source-document pointers

| If verifying... | Read |
|---|---|
| Distribution bundle scoping decisions (a/b/c) | This file, P1 block |
| 5-layer architecture + Phase 4 design rationale | `../process-engine-enhancement-design.md` |
| Why subset belongs in `pe install` | `docs/CAPABILITY_CATALOG.md` §8 |
| Phase 3 graduation state (informs "no enforcement" string fix) | `docs/PHASE_3_ESCALATION_ROUTER.md` |
| Gate envelope contract (informs dogfood gate on bundle commits) | `docs/E1_GATE_ENVELOPE.md` |
| Current budget posture (informs E2.1 prereq for Stage B) | `policy/circuit_breaker.toml` |
