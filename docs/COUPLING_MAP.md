# Coupling Map — 8CStudio + Origyn

> **Created 2026-06-30.** Stage A deliverable per `docs/BACKLOG.md` P2.
> Input to the binary decision: do modules cluster cleanly (Stage A workflow
> fix suffices) or are they pervasively tangled (Stage B / Phase 4 justified)?
>
> **Verdict — see §5:** **BOTH APPS CLUSTER CLEANLY.** Stage A (session-per-
> cluster) is the answer. Stage B (Phase 4 dependency-aware scheduler) is
> **NOT justified by current data** — parked with a defined re-evaluation
> trigger in §7.

---

## §1. Method

For any pair of modules (A, B), they are **coupled** if any of these hold:

1. **Data flow** — A writes a domain object that B reads
2. **Shared entity** — both read/write the same DB table or model
3. **Cross-module imports** — code in A imports from B
4. **Foreign key relationship** — rows in A reference rows in B
5. **Cross-module URL/route reference** — A's templates link to or post to B

**Severity:**
- **STRONG** — changes in A frequently require coordinated changes in B (shared model, FK, transactional flow)
- **WEAK** — A references B but the boundary is stable (one-way read, utility import)

**Sources:** parallel Explore-agent surveys of both codebases, 2026-06-30. Total files sampled: ~65 (8CStudio: ~30; Origyn: ~35). Confidence: HIGH on cluster structure and STRONG couplings; MEDIUM on the long tail of WEAK edges (some may exist that neither survey found).

---

## §2. 8CStudio — 19 modules, 3 clean clusters + 5 utilities

### Cluster A — Production Pipeline (4 modules, heavy intra-coupling)
- `project_management` (anchor — everything FKs to `project_id`, ~500 references)
- `pre_production` (scripts, scenes, shots, shoot days — Kadha)
- `character_management` (arcs, tags — reads pre_production scripts via shared `cast_extractor`)
- `time_tracking` (hours per project/shoot day)

**Why it's a cluster:** schema anchor is `project_id`, shared script/scene structures cascade across all four. Estimated 3–5 cross-module calls per feature.

### Cluster B — Money (4 modules, heavy intra-coupling)
- `client_management` (quotes, packages, contracts — anchors on `client_id`)
- `accounting_finance` (invoices, expenses, receipts — owns `project_budget_item`)
- `inventory_equipment` (equipment + service definitions, referenced by quotes)
- `budget_management` (thin client of `accounting_finance` API)

**Why it's a cluster:** 4 FK edges, quote embeds Equipment/Service objects, projects FK to `client_id` + `quote_id` + `invoice_id`, budget wraps accounting. Quote→invoice→budget→equipment-cost pipeline is co-dependent.

### Cluster C — Reporting (3 modules, LIGHT coupling)
- `tax_compliance` (BTW filing, year-end)
- `analytics_reporting` (API cost dashboard)
- `post_production` (video reviews, captions — reads project context)

**Why it's a cluster:** each reads upstream (accounting, pre_production, project_management) but owns no shared entities and writes nothing back. Loose by design.

### Utilities / isolated (5)
- `team_admin` — RLS + auth + permissions, cross-cutting but mediated by decorators (no code imports from other modules)
- `communication` — messages/notifications, only imports `Role` for permission checks
- `automation_integrations` — pure service layer
- `standalone` — landing pages
- `asset_management`, `crew_management`, `production` — placeholders (not shipped)

### 8CStudio cross-cluster edges (4 notable, all WEAK or intentional)
1. `post_production → client_management` — notification callback only
2. `pre_production → analytics_reporting` — cost logging (write-only aggregation)
3. `budget_management → accounting_finance` — thin API wrapper, intentional
4. `team_admin ← all modules` — RLS framework, decorator-mediated, stable

### 8CStudio verdict: **Clusters cleanly.** 3 domain clusters + 5 utility/placeholder modules. Cross-cluster edges are countable and stable.

---

## §3. Origyn — 11 blueprints + ~15 models/services, 3 domain clusters + shared infra

### Cluster D — Coaching (heavy intra-coupling, includes ONE strong border edge)

Origyn's Client and Trainer sides are close to distinct clusters — but a **STRONG unavoidable border edge** binds them. Treated as a single working cluster for session-split purposes.

- **Client sub-cluster:** `client` blueprint, `client_workout` blueprint, `Lead` model, `WorkoutSession` model, `Routine` model, `intake` blueprint
- **Trainer sub-cluster:** `trainer` blueprint, `WorkoutPlan` model, `WorkoutGenerator`, `AIService`, `TrainingPlan` model
- **Border edge (STRONG):** `trainer → Lead` (trainer generates plans by reading client Lead + workout history) — unavoidable by domain design; splitting into separate sessions would tangle

### Cluster E — Exercise library (read-heavy, stable)
- `Exercise`, `Contraindication`, `WorkoutTemplate`, `Training rules` models
- `MuscleWikiService` (external sync)

**Why it's a cluster:** contraindications filter exercises, templates contain exercise slots, training rules govern selection. Read-heavy: trainer + WorkoutGenerator read this cluster but never write back. Stable API surface.

### Cluster F — Payment (heavy intra-coupling)
- `subscriptions` blueprint
- `payment_service` (abstraction)
- `dodo_provider`, `webhooks`, `webhooks_dodo`
- `Subscription` + `SubscriptionPlan` models

**Why it's a cluster:** subscription creates via payment service → dodo/razorpay, webhooks update subscription status, `SubscriptionModel` FKs to `users.id`. Only external touch point is user identity.

### Shared infrastructure (NOT a cluster — utility layer)
- `auth`, `auth_oidc`, `Settings` model
- `email_service`, `brand_configs`, `backup_manager`

Used by every domain cluster; consuming code imports but doesn't reshape them. Treat as stable library dependencies.

### Origyn cross-cluster edges
1. `trainer → Lead` — **STRONG, unavoidable** (border edge that binds Client + Trainer sub-clusters into the single Coaching cluster)
2. `trainer → Exercise library` — WEAK, read-only, stable interface
3. `webhooks → Subscription` — STRONG but intra-cluster (Payment)
4. `all → shared infra` — WEAK utility usage

### Origyn verdict: **Clusters cleanly, with one important merge.** Client + Trainer must be treated as ONE working cluster (the Coaching cluster) because trainer operations structurally depend on client data.

---

## §4. Cross-product overlap

**None functional.** 8CStudio and Origyn share no code and no data. The only overlap is the engine itself (this repo), consumed by both via `pe install`. Engine-side changes propagate uniformly; product-side work is independent per repo.

**No engine-side coupling introduced** by having both projects consume the engine — engine only ships stateless agents/commands/scripts.

---

## §5. VERDICT — clusters cleanly

**Both apps cluster cleanly.** The coupled-parallelism wall the operator hit — "modules aren't independent, running them as separate blind sessions tangles" — is real, but the cause is **wrong session split, not wrong tooling.** The fix is workflow discipline: split sessions by **coupling cluster**, not by module name.

### Working clusters (session-split guide)

| Product | Cluster | Modules in-cluster | Rule |
|---|---|---|---|
| 8CStudio | Production Pipeline | project_management, pre_production, character_management, time_tracking | One session per cluster. Cross-cluster work = plan the sequence explicitly. |
| 8CStudio | Money | client_management, accounting_finance, inventory_equipment, budget_management | (same) |
| 8CStudio | Reporting | tax_compliance, analytics_reporting, post_production | Read-heavy — can usually operate on committed upstream state |
| 8CStudio | Utilities | team_admin, communication, automation_integrations, standalone | Independent; can evolve alongside any cluster's session |
| Origyn | Coaching (Client + Trainer merged) | client, client_workout, trainer, intake, Lead, WorkoutPlan, WorkoutSession, WorkoutGenerator, AIService, TrainingPlan | One session — the trainer↔Lead border edge is STRONG and unavoidable |
| Origyn | Exercise library | Exercise, Contraindication, WorkoutTemplate, Training rules, MuscleWikiService | Read-heavy — independent of Coaching for feature work |
| Origyn | Payment | subscriptions, payment_service, dodo_provider, webhooks, webhooks_dodo, Subscription models | Independent — only touch point is user identity |

### The "don't split what's coupled" rule (concrete)

- **8CStudio:** ✅ Sales+finance in one session (both live in the Money cluster). ❌ Splitting quote logic from invoice logic into two sessions.
- **Origyn:** ✅ Client + Trainer in one session (the STRONG border edge means they can't be split without tangle). ❌ Editing trainer's plan-generation logic in a session that isn't loading client Lead context.

### The "hotfix touches an active session" case

If a hotfix lands in the SAME cluster as an active feature session → hold the hotfix or fold into the active session (same-cluster changes must be sequenced anyway). If it lands in a DIFFERENT cluster → parallel-safe.

---

## §6. Next actions

**Immediate (workflow, no build):**
1. Adopt the §5 cluster table as the session-split rule for both products.
2. When starting a new session, name the cluster it belongs to (in the operator's session-start ritual — could be a one-line field in the memory banner).
3. When a task spans clusters, plan the sequence explicitly BEFORE any parallel session opens.

**Deferred (backlog, do not build now):**
- **Phase 4 (Stage B) is PARKED.** The current data does not justify building a dependency-aware scheduler. See §7 for the re-evaluation trigger.
- Formalizing the cluster table into a machine-readable `.process-engine.yaml install.clusters` block — possible future engine work, but only if we start automating on it (P3-adjacent).

---

## §7. Re-evaluation triggers — when to promote Stage B (Phase 4) back to active

Stage B becomes justified if **any** of these fire:

1. **Cluster boundaries erode.** A refactor introduces ≥3 new STRONG cross-cluster edges within a quarter that we couldn't design away. Signal: `git log` in the last 90 days shows the same PR routinely touching modules from ≥2 clusters.
2. **A single feature genuinely requires spanning clusters.** Not "the operator chose to do them together" but "the design cannot be split without violating a domain invariant." Example: a feature that must transactionally write across `client_management` (Money) + `pre_production` (Production Pipeline) at the same commit.
3. **A third product joins** that itself is pervasively tangled (map it before deciding).
4. **Session-collision incidents recur.** ≥3 recorded incidents per quarter of "two sessions I opened by cluster boundary still collided" — with root causes that couldn't be attributed to misapplied §5 rules. If it's operator error, that's not a Phase 4 signal.

If ANY trigger fires: update this map first, then re-decide Stage A vs Stage B with fresh data. Phase 4's prereq order remains locked: **E2.1 token telemetry → dependency model → DAG scheduler.**

---

## §8. Confidence + honesty

- **8CStudio cluster structure:** HIGH confidence (~85%). Clean modules/ tree, explicit MODULE.md documentation, comprehensive FK evidence.
- **Origyn cluster structure:** HIGH confidence on Coaching + Payment; MEDIUM on Exercise library boundary (some services may cross that I didn't fully trace).
- **The Trainer↔Client border edge in Origyn** is the most important finding here. Treating them as separate clusters would produce exactly the tangle the operator described. Merging them into the Coaching cluster is the workflow fix.
- **What I did not verify:** every service-layer file in either repo; template-side route references; test-suite imports (which don't affect runtime coupling anyway). None of these would flip the verdict but could add weak edges to the tables above.

---

**End of coupling map.** Update this document if the codebase changes materially or if a §7 re-evaluation trigger fires.
