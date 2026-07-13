# Functional Journey Testing — Validation & Extension Plan

> **Date:** 2026-07-12 · **Owner:** Sanish · **Status:** PLANNING-COMPLETE, ready for slots
> **The ask:** "when a fix lands I'm asked to manually check billing, invoice creation,
> quotes, hours… these are repetitive; they must be part of the deployment process, and
> every new feature must keep extending them." This doc validates what exists (3-agent
> audit of the ai-testing-agent, the engine A9 integration, and 8CStudio's test/deploy
> pipeline, 2026-07-12) and plans the extension. **Priority: lands BEFORE the Kadha/UX
> master-plan work begins** (operator decision 2026-07-12).
> **Authority:** wins on functional-testing design. `TESTING_TOPOLOGY.md` still defines
> the static-vs-dynamic division of labor; `ROADMAP.md` (product repo) still owns wave
> sequencing.

---

## 1. Validation — what's actually in place (verified)

### 1.1 The ai-testing-agent (~/Documents/AI Agents/ai-testing-agent) — READY
The critical finding: **multi-step functional journeys are a mature, core feature — not
a gap.** `JourneyExecutor` (`src/executors/journey.py`) runs dependency-ordered steps with
context passing (`outputs: {"quote_id": "$.id"}` → injected into later steps), shared HTTP
client (cookies/session persist), **auto-login with CSRF handling** (`AI_TEST_AUTH_*` env),
cross-request `post_assertions` (after DELETE, assert GET 404), and state-machine testing
(draft→sent→accepted→invoiced with invalid-transition checks). Invocable as CLI
(`ai-test journey --suite journeys.json --base-url …`) and as MCP tools (10, including
`run_pipeline`, `test_intent` — natural language "test the quotes module"). Multi-env
profiles (`AI_TEST_ENV=staging`). 679 tests pass. Beta-maturity but validated on real apps.

### 1.2 The engine integration (A9.1–A9.5) — WIRED, BUT REVIEW-TIME ONLY
8 MCP tools registered (`templates/mcp/ai-testing-agent.mcp.json.template`); review agents
call them: code-reviewer→`compare_api_specs`, security-reviewer→`run_security_scan`/
`run_dast_scan`, design-critic→`run_visual_regression`, performance-reviewer→
`run_resilience_tests`, e2e-runner→`run_pipeline`/`extract_apis`. Pre-commit hooks:
boot-smoke, migration-lint, design-lint, api-contract, sast, perf-gate, test-run.
**Gap: everything fires at commit/review time against code — nothing enforces or runs
FUNCTIONAL journeys, and no gate requires new features to add E2E coverage** (tdd-guide
enforces 80% unit/integration only; e2e-runner is opt-in with no trailer enforcement).

### 1.3 8CStudio test + deploy pipeline — STRONG BASE, SMOKE-ONLY E2E
- ~3,831 unit/integration tests. Business logic IS well covered at the Flask-test-client
  layer: invoices (~30: quote→invoice, payments, credit notes, status transitions),
  quotes/double-margin (~35), expenses (~85), hours (~10, thin).
- Browser E2E = **45 smoke tests**: page loads, auth redirects, healthz, PWA registration.
  **Zero business-flow E2E.** They run **unauthenticated** — they physically cannot
  exercise flows.
- Deploy gates: local pre-flight (double-margin CLI + pytest) → staging deploy + mandatory
  29-test smoke E2E (10-min freshness stamp) → prod promote (backup gate, health gate,
  smoke re-verify **advisory only** on prod) → Sentry 10-min spike monitor with
  auto-rollback.
- **No seeded test tenant on staging** (staging copies the prod DB); no demo fixtures for
  E2E; no post-deploy functional verification.

### 1.4 Net verdict
The three layers are individually healthy and *almost* connected. What's missing is
exactly one layer: **a functional journey suite (the operator's manual checklist, codified)
+ a seeded place to run it + gates that run it + a process rule that grows it.** No new
tooling needs to be built — this is authoring + wiring + one engine gate.

---

## 2. Design decisions (locked here so slots don't re-litigate)

1. **Journeys run at the API layer first, browser layer second.** The testing-agent's
   journey executor (HTTP+session) covers the business-outcome question ("does accepting
   a quote create a correct invoice?") fast (~seconds/journey, no flake). Browser-level
   journeys (Playwright) are added ONLY for flows where the UI itself is the risk
   (quote-builder UX, offline shoot log). Rationale: API journeys catch the regressions
   the operator is manually checking for, at 1/10th the maintenance cost of browser tests.
2. **A dedicated E2E tenant on staging** (`e2e-tests@8cs.internal`, seeded client/tariff/
   project/rates via an idempotent seed script). Multi-tenancy makes this safe by
   construction — and it doubles as an RLS isolation canary (journey asserts it can NEVER
   see the operator tenant's data — turning the B2/RLS concern into a permanent test).
3. **Prod runs read-only journeys only.** Mutating journeys run on staging (which is a
   prod-DB copy, so data-shape realism is preserved). On prod: smoke + read-only
   verifications (list pages return data, totals endpoints compute, healthz deep checks).
   Never create business records in the live tenant. Revisit only if a sandboxed prod
   tenant is ever justified.
4. **Journey definitions live in the product repo** (`tests/journeys/*.json` in 8CStudio),
   versioned with the code they test; the engine owns the gate + templates, not the suites.
5. **Naming: the suite is the "operator checklist"** — each journey maps 1:1 to a thing
   Sanish currently checks by hand. That's the acceptance test for this whole plan: the
   manual checklist becomes a file list.

---

## 3. Journey catalog v1 (the manual checklist, codified)

Priority order = how often the operator is asked to re-check them. Each journey = one
JSON suite file, one owner module, deterministic seed data, cleanup by unique-marker
(`E2E-<runid>` prefix on created records, deleted in teardown steps).

| # | Journey (suite file) | Steps (abbreviated) | Asserts the thing that breaks |
|---|---|---|---|
| J1 | `quotes_lifecycle` | login → create client → create quote (2 items, known rates) → **assert double-margin totals to the cent** → send → accept → **assert invoice auto-created with matching totals** | The margin engine + quote→invoice bridge (the #1 manual check) |
| J2 | `invoice_direct` | create direct invoice (quote-less path) → record partial payment → assert status `partial` + cashbook entry → record rest → assert `paid` | BACKLOG #189 path + payment state machine |
| J3 | `invoice_credit` | invoice → issue partial credit note → assert balances | Credit-note math |
| J4 | `hours_flow` | create hour entries (2 days, known durations) → assert weekly totals → assert project hours aggregation → (if billing link exists) assert billable rollup | Hours module (currently thinnest coverage) |
| J5 | `expenses_flow` | create expense with line items → assert category totals + project attribution → validation rejects (bad VAT class) | Expense engine |
| J6 | `btw_readonly` | (read-only) BTW aangifte period view returns computed boxes for seeded quarter; totals match seeded fixtures | Tax computation surface |
| J7 | `project_finance_view` | project → finance tab shows quote+invoice+expense rollup consistent with J1/J2/J5 records | The cross-module rollup (classic silent-breakage point) |
| J8 | `client_portal_share` | create share link → fetch unauthenticated → assert correct scoping (and NOTHING else leaks) | share_links security + function |
| J9 | `kadha_prep_chain` | import fixture script → assert scenes parsed → create shot → create shoot day → generate call-sheet PDF (assert 200 + size) | The Kadha spine (protects the master-plan work) |
| J10 | `tenant_isolation_canary` | as E2E tenant: enumerate list endpoints → assert zero rows from operator tenant | RLS/isolation regression alarm (runs FIRST, always) |
| J11 | `auth_lifecycle` | login → session persists → logout → protected route redirects | Already smoke-covered; port to journey form for auth-context reuse |

v1 = J1, J2, J4, J10 (the operator's actual weekly asks + the safety canary).
v1.1 = J5–J8. v1.2 = J3, J9, J11. Browser-layer additions (quote-builder UI, offline
shoot-log) come later as JB-series, only after the API layer is stable.

---

## 4. Wiring into the deployment process

```
local pre-flight   (unchanged: double-margin CLI + pytest)
      │
staging deploy ──► smoke E2E (existing 29, mandatory)
      │            + seed-check (E2E tenant present/refreshed)
      │            + **journey suite vs staging (mandatory, blocking)**  ← NEW
      │              `ai-test journey --suite tests/journeys/ --env staging`
      ▼
promote-to-prod ─► freshness window honors BOTH smoke + journey stamps  ← extend
      │            backup gate, health gate (unchanged)
      ▼
prod verify ─────► smoke (existing, stays advisory→ upgrade to blocking)
                   + **read-only journeys vs prod (blocking)**          ← NEW
                   + Sentry spike monitor (unchanged)
      ▼
nightly cron ────► full journey suite vs staging + report artifact      ← NEW
                   (catches drift between deploys; failures → operator
                   notification, not silent)
```

Failure policy: any journey failure on staging blocks promote (same as smoke today).
Read-only journey failure on prod triggers the existing rollback decision path (operator
notified with the journey report; auto-rollback stays Sentry-driven only — a failing
GET is evidence, not yet proof, and rollback has its own blast radius).

---

## 5. The self-extending part (engine enforcement — the piece that keeps it alive)

This is the answer to "going forward all projects and new functionality must add these."

1. **New engine gate: `journey-coverage` (deterministic, pre-commit).**
   `.process-engine.yaml` gains a `journeys:` map — `module path → suite file(s)`.
   When a diff touches routes/models under a mapped module and no journey file changed,
   the gate fails with the exact suite file to update. Escape hatch: a
   `Journey-impact: none — <reason>` trailer (logged, auditable, same pattern as
   existing skip-reasons). New modules with no mapping = WARN for one release, then FAIL.
2. **Pipeline step, not afterthought:** `/new-feature`'s brief template gains a mandatory
   "Functional journey impact" section (which journey covers this, or which new journey
   ships with it). The tdd-guide RED phase already demands failing tests first — extend
   its checklist: features that change business outcomes need a journey step, not only
   unit tests.
3. **e2e-runner agent upgraded from opt-in to draft-generator:** on a journey-coverage
   FAIL, the orchestration invokes e2e-runner to DRAFT the journey JSON (the testing
   agent's `extract_apis` + rule-based generator do 80% of this) — human approves. Writing
   journeys must be near-free or the gate becomes a nag.
4. **Operator on-demand command:** a small skill/command (`/check <module>` or
   `./scripts/check.sh quotes`) wraps the MCP `test_intent` tool — "test the quotes
   module" any time, without waiting for a deploy. This directly replaces the ad-hoc
   manual check ritual.
5. **Portability:** the gate + templates + seed-script pattern ship as engine templates
   (like all P5 gates), so Delivery, Kadha-as-product, and any future repo inherit the
   same contract: **every product ships with a journeys/ directory or explains why not.**

---

## 6. Execution slots (engine-ready, sized)

| Slot | What | Repo | Size/Model | DoD |
|---|---|---|---|---|
| F1 | **E2E tenant seed** — idempotent `scripts/seed_e2e_tenant.py` (tenant, user, client, tariff, project, hour/expense fixtures, known BTW quarter); wire into staging-up + deploy-staging seed-check; unique-marker cleanup helper | Product | M, Sonnet | Re-runnable; staging has deterministic fixtures; operator tenant untouched |
| F2 | **Journey suite v1** — J1, J2, J4, J10 as `tests/journeys/*.json` + `AI_TEST_*` env profile for staging; run green locally + staging | Product | M, Sonnet (J1 numbers reviewed by operator) | J1 asserts double-margin to the cent; J10 returns zero foreign rows |
| F3 | **Deploy-gate wiring** — deploy-staging.sh runs journeys (blocking) + stamps freshness; promote-to-prod honors stamp; prod read-only set + upgrade prod smoke to blocking; nightly cron + report artifact + failure notification | Product | M, Sonnet | Broken margin math cannot reach prod; nightly report lands |
| F4 | **`journey-coverage` gate** — engine hook + `.process-engine.yaml` `journeys:` map + trailer escape hatch + templates | Engine | M, Opus (gate semantics) | Touching `modules/accounting_finance/` without journey change = FAIL naming the suite |
| F5 | **e2e-runner draft mode + `/check` command** — journey-draft generation on gate failure; operator `test_intent` wrapper | Engine | M, Sonnet | `/check quotes` produces a pass/fail report in <2 min |
| F6 | **Journey suite v1.1/v1.2** — J3, J5–J9, J11 (J9 lands with/before Kadha K1 work) | Product | M, Sonnet, batchable | Catalog complete; manual checklist retired |
| F7 | **Process docs** — TESTING_TOPOLOGY.md gains the journey layer; brief template + tdd-guide checklist updated (§5.2); CLAUDE.md pointer | Engine | S, Haiku | New-feature pipeline shows the journey step |

Sequencing: **F1→F2→F3 first (one focused week — this is the "in place before major
plans" bar), F4/F5 next, F6/F7 fill.** F1–F3 are product-repo work that does not
conflict with the ROADMAP wave lock (it hardens the deploy path every wave depends on;
it IS Wave-0-spirit work). Dependencies: none on #227 dev-env repair for staging-side
slots (journeys run against staging), but F2 local runs benefit from #227 landing first.

---

## 7. Risks / honest notes

- **Testing-agent beta-maturity:** it's validated but young; if `journey` execution hits a
  blocker on the real app (CSRF edge, Zitadel OIDC flow), fallback is pytest+requests
  journeys in the same JSON spirit — the *catalog and gates* (the durable value) are
  tool-agnostic. Decide only if F2 hits the wall; don't pre-build the fallback.
- **Staging = prod-copy DB:** seeded E2E tenant mitigates, but journeys must never assume
  a clean DB — all assertions scoped to E2E-tenant data.
- **Flake budget:** any journey that flakes twice in a week gets quarantined (e2e-runner
  already has quarantine semantics) and fixed or demoted — a flaky blocking gate erodes
  trust in the whole system faster than no gate.
- **Zitadel auth on staging:** J-suite needs a non-OIDC test login path or a stored
  refresh-token bootstrap for the E2E user — resolve in F1 (the PWA auth work already
  built `/api/v1/auth/*` machinery to lean on).
- **Cost discipline:** journeys are deterministic JSON — no LLM calls at run time. LLM
  (via e2e-runner/test_intent) is used only at authoring time.
