# Engine Enhancement Plan V2 — 360° re-audit (2026-07-03)

> **Supersedes forward-looking work in `IMPROVEMENT_PLAN.md`.** That plan's P0/P1/P2/P5/P6/P7
> are SHIPPED (engine went v0.9 → **v0.16.0**). This doc is the NEXT layer: hardening security
> to pentest-grade, making design-checks as critical as code-checks, and the autonomy/
> "toward-AGI" roadmap (P3 was always parked — it's the real frontier now).
>
> **Produced by:** a fresh 3-track deep audit (security/pentest, design-check, agent-architecture)
> of the CURRENT engine + direct file calibration. Findings marked [SHIPPED]/[PARTIAL]/[MISSING]
> against v0.16.0 reality, not the old plan.
>
> **How to use:** same contract as IMPROVEMENT_PLAN — every item is self-contained (ID, severity,
> effort S/M/L, model tier, exact files/tools, the fix). Opus/Sonnet pick an item; Haiku does the
> mechanical parts (template files, config). Check off as they land; move shipped → CHANGELOG.
>
> **One-paragraph verdict:** the engine's *discipline* layer is now genuinely strong — the
> silent-failure gate suite (boot-smoke, migration-lint, design-lint, console-smoke,
> tenant-isolation) systematically covers the exact 8CStudio gap pattern. Four frontiers remain:
> (1) **security is a prompt-checklist, not a scanner** — no SAST runs, the reviewer is
> Node-centric while every adopter is Flask/Python, and LLM-agent-specific threats are unguarded;
> (2) **design is self-attested** while code is evidence-verified — no a11y/visual gate, no
> design-critic agent; (3) **performance is not checked at all** — no perf agent, no perf hook,
> N+1 only as a static checklist line, nothing measures query counts / memory / latency / load
> (see PF); (4) the **whole autonomy + domain layer** (telemetry, eval harness, closed execution
> loop, `pe new` scaffold, reusable modules) is unbuilt — the engine still prints instructions a
> human executes, and the domain layer is exactly as empty as the first audit found it (no
> `modules/`, no `pe new`). Ponytail shipped but is opt-in on 2 of 10 code agents. Fix S1
> (security) and D1 (design parity) first — operator's stated priorities and highest
> risk-per-effort — with PF1/PF3 close behind (they share tooling with D2 and catch the
> real-world slowness class).

---

## 0. The pattern behind the 8CStudio gaps (answering the operator directly)

**Yes, the 8CS gaps have a single pattern, and the engine now largely handles it.** Every gap
found in the product audit — app won't boot, migrations silently unapplied, design drift,
console errors, nav clutter, RLS-permissive leak — is the same class: **"invisible until a human
looks" failures with no deterministic verifier.** The v0.13–v0.14 gate suite converted each
*found* instance into a permanent gate. The meta-principle to encode explicitly (and the one
thing that makes this future-proof):

> **Every class of silent failure becomes a gate. Gates are deterministic (hook/test) or expert
> (agent review) — never prompt-hope. Every new incident → classify the failure-class → ship the
> matching gate.** (This is the "quarterly rule" — currently manual; item **A3** automates it.)

What's still NOT covered by this pattern: **cross-system semantic failures** (OAuth flow bugs,
payment idempotency, tenant-isolation logic) are caught only by *agent rubric*, which is
expensive and unmeasured. S1/S2 make those deterministic where possible; A2 measures whether the
agent gates actually catch anything.

---

## S — SECURITY: from prompt-checklist to pentest-grade (operator's #1 priority)

> The security-reviewer is 494 lines of good OWASP checklist + envelope contract, but it **runs no
> tools** (its `tools:` includes Bash; the prompt never calls it) and its examples are **all
> Node.js** (`npm audit`, `process.env`, `execFile`) while 8CStudio/Origyn are **Flask/Python**.
> secrets-scan (gitleaks cascade) and deps-audit (pip-audit/npm) are shipped and good. The gap is
> SAST, auth/payment depth, and LLM-agent threats. Principle for "critical without drowning":
> **tiered enforcement (CRITICAL blocks / HIGH surfaces / MED-LOW advisory) + per-repo allowlist
> baselines + confidence scoring** — the failure_class routing already supports this.

### S1 Wire real SAST — semgrep as the backbone ⭐ biggest security gap — ✅ SHIPPED in v0.17.0 (2026-07-03)
- **Severity:** CRITICAL · **Effort:** M · **Model:** Sonnet
- **Files:** `hooks/sast-scan.sh` (new), `hooks/hooks.json`, `hooks/.pre-commit-config.yaml.template`,
  `agents/security-reviewer.md` (Step 1), `agents/code-reviewer.md:159` (already names `bandit -r .`
  but nothing runs it).
- **Fix:** new `hooks/sast-scan.sh` feature-detects and runs, per language:
  `semgrep --config=p/security-audit --config=p/owasp-top-ten` (primary, low-FP), `bandit -rq`
  (Python), `gosec` (Go), `eslint-plugin-security` (JS). Wire as pre-commit + a step in
  security-reviewer's analysis. semgrep unifies most CWE coverage (SQL injection incl. Python
  f-string/`.format()` queries, XSS, SSRF, unsafe crypto MD5/SHA1-for-passwords, insecure
  deserialization `yaml.load`/`pickle`). **Note: the semgrep MCP in this environment is
  deprecated — use the semgrep CLI, not the MCP.**
- **FP control:** ship `.semgrep-allowlist.txt` template (one rule-id per line); soft-warn if
  semgrep absent (`pipx install semgrep`), never hard-block on missing tool.

### S2 De-Node-ify + deepen the security-reviewer (Python-first) — ✅ SHIPPED in v0.17.0 (2026-07-03)
- **Severity:** HIGH · **Effort:** M · **Model:** Sonnet
- **File:** `agents/security-reviewer.md`.
- **Fix:** (a) make examples stack-agnostic — Python-first (SQLAlchemy string-interp, `subprocess`
  shell=True, `flask` session config) alongside Node; (b) add the P3.9 depth that never shipped:
  session security (HttpOnly/Secure/SameSite, CSRF, session-fixation → new id on login), JWT
  (reject `alg:none`, require exp/aud, flag `verify_signature=False` as CRITICAL), OAuth
  (redirect-uri allowlist not substring, state param, no `javascript:`/`data:` URIs),
  password-reset tokens (≥128-bit, ≤1h, one-time, rate-limited); (c) add **confidence scoring**
  per finding (0-1) so low-confidence findings route to human rather than block.

### S3 Auth + payment security TEST templates (secure-by-default)
> **COVERAGE (see `TESTING_TOPOLOGY.md`):** the *dynamic* auth-bypass/injection
> probing is already DELEGATED to the agent (`run_security_scan`). Engine builds
> ONLY the pytest **templates** (webhook HMAC, payment authority) + the
> security-review path-gate — do not rebuild a runtime auth prober here.
- **Severity:** HIGH · **Effort:** M · **Model:** Sonnet (templates), Haiku (fill) · **[SHIPPED v0.29.0 — all 6 pytest templates (session/jwt/oauth/webhook/payment/reset-token) + security-review-trailer test-evidence gate + tests/test_security_review_trailer.sh with 10 cases]**
- **Files:** `templates/tests/{session,jwt,oauth,webhook,payment,reset-token}-security.test.py.template`
  (only `auth-robustness.test.py.template` + `nav-confusion-budget` exist today).
- **Fix:** ship pytest templates covering: webhook HMAC signature verification + replay/idempotency,
  payment amount server-side authority (never trust client, Decimal not float, idempotency-key
  dedup), test/live key separation. security-reviewer then requires code+test evidence for
  commits touching `payment|webhook|billing` paths (extends the existing security-review-trailer
  path-gate). This is what makes "critical about security" real for the Delivery store phase (BACKLOG #234).
- **Shipped v0.29.0:** all 6 templates are in `templates/tests/`. The trailer hook now BLOCKS commits
  that touch `payment|billing|webhook` paths unless test files are co-staged in the same commit
  (or a `Security-tests-skip-reason:` trailer is present). Escape hatches: `Security-skip-reason:`
  blanket-skips both gates; `ENGINE_SECURITY_TEST_PATHS` overrides the money-path regex.
  Test coverage: `tests/test_security_review_trailer.sh` (10 cases).

### S4 LLM/agent-specific threat hardening ⭐ existential for agent-built SaaS
- **Severity:** HIGH · **Effort:** M · **Model:** Opus (design), Sonnet (impl) · **[SHIPPED v0.30.0 — transcript-guard PostToolUse hook (9 injection markers + 11 secret patterns, last-4 previews only) + pe verify (MANIFEST.sha256 checksum of 66 load-bearing surfaces with --update/--json/--engine modes and adopter-side auto-resolve) + hooks.json wiring on Bash/Read/WebFetch/WebSearch]**
- **Files:** new PostToolUse hooks in `hooks/hooks.json`, `hooks/transcript-guard.sh` (new),
  `scripts/pe` (`pe verify` subcommand).
- **Fix (three layers):** (a) **prompt-injection detection** — PostToolUse hook scans Bash/Read
  outputs for injection payloads ("ignore previous instructions", "new system prompt") before the
  agent consumes them → WARN + human review; agent preambles warn against trusting fetched
  content. (b) **secret scrubbing in transcripts** — redact `sk_live_`/`sk_test_`/`Bearer `/JWT
  patterns from tool outputs before they enter session history. (c) **`pe verify`** — checksums
  all agents + hooks against engine git SHA, fails on divergence (catches poisoned agent/hook
  files — a real supply-chain vector now that agents auto-run on commit). These are unguarded
  today and are the scariest class for a multi-tenant SaaS built BY agents.

### S5 Container + secrets-history + license, feature-detected
- **Severity:** MEDIUM · **Effort:** S each · **Model:** Haiku · **[SHIPPED v0.31.0 — engine-quality.yml.template extended with container-security (hadolint + trivy fs, Dockerfile-guarded, continue-on-error), secrets-scan-history (gitleaks full-git-history, schedule + workflow_dispatch only), license-audit (pip-licenses / license-checker, ENGINE_LICENSE_FAIL_ON default AGPL/GPL-3.0, ENGINE_LICENSE_WARN_ON default LGPL, feature-detected per stack). All three new gates are continue-on-error: true — visibility, not blocking. Test coverage: tests/test_ci_template_s5.sh (15 cases).]**
- **Fix (all advisory, feature-detected):** `hadolint` on any `Dockerfile` + `trivy image` in CI;
  `gitleaks detect --source git` (full history) as a WEEKLY CI job (not per-commit — too slow);
  license check (`pip-licenses`/`license-checker`) flagging AGPL/GPL3 (HIGH for a resold SaaS),
  warning LGPL. Wire into `templates/ci/engine-quality.yml.template`.

### S6 Automate the tenant-isolation-auditor
- **Severity:** MEDIUM · **Effort:** S · **Model:** Sonnet · **[SHIPPED v0.25.1 — launchd Monday 09:00 plist + run wrapper + advisory GH Actions job (schedule-triggered, continue-on-error)]**
- **Fix:** the auditor is the engine's strongest security asset but only runs when the operator
  remembers. Wire a weekly launchd/cron (templates exist) + an advisory CI gate (WARN). Add
  SQLAlchemy-ORM-relationship + materialized-view (`SECURITY DEFINER` bypass) checks it currently
  misses.

---

## D — DESIGN: make design-checks as critical as code-checks (operator's #2 priority)

> **The core asymmetry:** `code-review-trailer.sh` VERIFIES against `.claude/gates/` (evidence);
> `design-review-trailer.sh` accepts a bare `Design-reviewed: self` PROMISE (no envelope). Code is
> evidence-based, design is honor-system. That's precisely why design drifts. Deterministic
> `design-lint` + `copy-lint` shipped (good, multi-theme), and a P5.9 AI-aesthetic rubric lives
> inside code-reviewer — but there is NO design *agent*, NO accessibility gate, NO visual
> regression. Design catches ~7 of 9 AI-tells via regex; the 2 that matter most (palette identity,
> composition) need vision.

### D1 Design-critic agent + verified envelope (close the asymmetry) ⭐ — ✅ SHIPPED in v0.18.0 (2026-07-03)
- **Severity:** HIGH · **Effort:** M-L · **Model:** Sonnet (vision-capable)
- **Files:** `agents/design-critic.md` (new — engine-level; distinct from 8CStudio's project-local
  ui-ux-design-agent), `hooks/design-review-trailer.sh` (upgrade), `agents/_gate-contract.md`.
- **Fix:** (a) extract the P5.9 AI-aesthetic rubric out of code-reviewer into a standalone gate
  agent that scores a UI diff against the 9 tells + density/hierarchy/tabular-numerals/empty-states/
  responsive, emits a real gate envelope (`≥3 tells → FAIL "match the locked reference"`), and can
  read a reference screenshot via its vision. (b) **upgrade design-review-trailer to verify the
  envelope** like code-review-trailer does — `Design-reviewed: <sha>` resolves against
  `.claude/gates/last-design-review.json`. This single change makes design a first-class gate.

### D2 Accessibility as a gate — axe-core + Lighthouse (the strongest OSS "design agents") — ✅ SHIPPED in v0.18.0 (2026-07-03)
- **Severity:** HIGH · **Effort:** M · **Model:** Sonnet
- **Files:** `templates/e2e/a11y-audit.spec.ts.template` (new), `.axe-config.json` template,
  `templates/ci/lighthouse-ci.yml.template` (new). Playwright is already present (P5.5 smoke).
- **Fix:** `@axe-core/playwright` runs WCAG 2.1 AA on each nav path (violations → FAIL, incomplete →
  advisory): catches contrast, touch-target size, focus order, form labels, heading hierarchy — the
  exact things that read as "unprofessional." Lighthouse CI enforces perf+a11y budgets
  (`{accessibility: 90, performance: 75}`) — a commit that lowers the score fails. This is the
  highest-ROI design enhancement: real, deterministic, and it directly measures "premium feel."
  Feeds the Delivery gallery's "Lighthouse ≥90 or don't ship" gate (ROADMAP C4).

### D3 Visual-regression baseline + reference lock-in
- **Severity:** MEDIUM · **Effort:** S-M · **Model:** Sonnet · **[MISSING]**
- **Files:** `templates/e2e/visual-baseline.spec.ts.template`, `docs/design/reference/README.md`.
- **Fix:** Playwright native screenshot diffing (no new dep) on ≤5 key pages at 1280px + 375px;
  drift flags for human review (not auto-fail — designer approval loop). Plus the "reference lock"
  process: every shipped page has a `docs/design/reference/<page>.png`; the design-critic (D1)
  compares against it. This operationalizes "match the locked reference, never make-it-professional"
  — the rule that stops AI-aesthetic regeneration.

### D4 Extend design-lint to spacing/radius/shadow tokens
- **Severity:** MEDIUM · **Effort:** S · **Model:** Haiku · **[SHIPPED v0.25.1 — hooks/design-lint.sh reads spacing_tokens/radius_tokens/shadow_tokens per theme, WARN/FAIL under strict; template documents the shape]**
- **File:** `hooks/design-lint.sh` (~60 LOC), `templates/design-lint.config.template`.
- **Fix:** design-lint enforces colors + inline-style + modals today; add `spacing_tokens` (allow
  `p-4/6/8`, forbid `p-3/5/7`), `radius_tokens` (the exact 8CStudio "1,400 `rounded-lg` vs 129
  `rounded-xl`" drift), `shadow_tokens`. Optional `stylelint + stylelint-config-tailwindcss` for
  class-order + custom-CSS-that-should-be-a-token. Graceful skip if adopter hasn't populated lists.

> **D1–D4 above are the design FLOOR (prevent bad + enforce consistency + a11y). D5–D8 below are the
> CEILING (reach for award-grade). Full research + tooling + method: `docs/DESIGN_EXCELLENCE.md`.
> Key model: engine deterministically owns ~70% (usability/perf/consistency/a11y); the 20%
> creativity is scored + referenced + human-bought, never fully automated. Bar is
> SURFACE-DIFFERENTIATED: client-facing (galleries/tenant sites) target Awwwards ≥8.0; internal app
> targets Linear/Stripe "quiet excellence" ≥7.0 — NOT flash.**

### D5 Upgrade design-critic from floor to ceiling ⭐ highest-leverage design item
- **Severity:** HIGH · **Effort:** M · **Model:** Sonnet (vision) · **[MISSING — critic ships as floor-only]**
- **File:** `agents/design-critic.md` (extend the shipped rubric), `docs/DESIGN_EXCELLENCE.md` §5.
- **Fix:** keep the 9-tell floor; ADD (a) Awwwards-dimension scoring (Design 40 / Usability 30 /
  Creativity 20 / Content 10), surface-differentiated target (client ≥8.0, internal ≥7.0);
  (b) scoring against an *aspirational* reference (D7), not just the drift reference; (c) a concrete
  "top-3 changes to gain the next point" output. FAIL client surfaces below bar. Turns the critic
  from "not-bad?" into "how far from great, and why."

### D6 Motion-craft + CWV-under-motion gate
- **Severity:** MEDIUM · **Effort:** M · **Model:** Sonnet · **[MISSING]**
- **File:** `agents/design-critic.md` (motion dimension) + Lighthouse budget config (D2/PF3 reuse).
- **Fix:** when a diff adds animation (GSAP/Motion/CSS transitions), require `prefers-reduced-motion`
  honored, NO Core-Web-Vitals regression (Lighthouse budget holds *with* motion), and motion-has-
  purpose (critic judgment — communicates state/space, not decoration). Blocks effect-stacking (the
  #1 amateur tell). Tooling: **GSAP** for Jinja/Alpine surfaces, **Motion** only if React,
  **Lenis** for smooth-scroll.

### D7 Aspirational reference library + Style Dictionary token pipeline
- **Severity:** MEDIUM · **Effort:** M · **Model:** Sonnet + operator taste · **[MISSING]**
- **Files:** `docs/design/aspirational/<archetype>.png` (marketing/gallery/dashboard/form), adopt
  **Style Dictionary** for the token source.
- **Fix:** curate 1 award-grade reference per surface archetype (source: Awwwards/Godly/Land-book/
  Mobbin per DESIGN_EXCELLENCE §4) — this is what D5 scores against. Adopt Style Dictionary so tokens
  v2 become a single source (CSS-vars/Tailwind/per-tenant theme) that outlives Tailwind. Feeds
  8CStudio's tokens v2 as the first consumer.

### D8 Signature-system requirement
- **Severity:** MEDIUM · **Effort:** S · **Model:** Sonnet · **[MISSING]**
- **File:** `agents/design-critic.md` (upgrade tell #9 from soft to hard on flagship screens),
  product design docs.
- **Fix:** every product must have ≥1 signature element + a distinctive type system (for 8CStudio:
  the film-slate/timecode/slugline motifs already proposed). The critic FAILs "no signature" on
  flagship/marketing screens (not every screen). Turns the deepest AI-tell ("nothing ties this to
  the product") into a product requirement.

> **Future-proofing ritual (mirrors L0):** a **quarterly design-scan** — CEO/retro agent reviews
> recent Awwwards/CSSDA winners + new motion/perf/token tools, refreshes `docs/design/aspirational/`,
> files new capability as D-items. This is the "always best in market" mechanism — design trends
> churn; the ritual keeps the ceiling current without a rebuild. Start NOW (ritual, not a build).

---

## PF — PERFORMANCE: make "fast" a gate, not a hope (added 2026-07-03 per operator)

> **Current state: there is NO performance agent and NO performance hook.** N+1 is mentioned as a
> static checklist line in `code-reviewer.md:188` and `database-reviewer.md:124,175` — it catches
> the obvious `for row in rows: db.execute(...)` shape by eye, but nothing measures runtime: actual
> query counts, memory growth, unbounded result sets, latency regressions, or load behavior. That's
> the difference between "a reviewer might notice" and "the build fails if it's slow." The world-class
> posture is the same as security/design: **deterministic gates catch ~80% (query-count assertions,
> latency budgets, load thresholds, unbounded-query lint), a dedicated agent judges the other 20%
> (blocking-in-request-path, cache invalidation, memory-accumulation).** Below, each dimension →
> the OSS tool + how it becomes a gate. Goal: apps are fast by construction and the operator never
> hand-tunes performance.

### PF1 Runtime N+1 + query-count regression gate ⭐ biggest real-world perf win
> **COVERAGE — CORRECTED 2026-07-03 (was wrong):** the earlier note said "delegate
> query-counting to the agent." Recon proved that's architecturally impossible — a
> BLACK-BOX agent cannot count the SQL a request emits; it only has a *latency
> proxy* (list-vs-detail ×5), which the agent ALREADY ships
> (`generators/performance_tests.py::generate_n_plus_one_journeys`). Real
> query-count N+1 detection is INHERENTLY in-process, so it lives as an ENGINE
> pytest template the adopter runs in its own suite. Correct split:
> **engine = the real detector (in-process query count); agent = complementary
> black-box latency smoke.** Neither replaces the other.
- **STATUS: ✅ template SHIPPED 2026-07-03** — `templates/tests/query-count.test.py.template`
  (SQLAlchemy `before_cursor_execute` counter + Django `CaptureQueriesContext` variant;
  two tests: bounded-ceiling + does-not-scale-with-N). Remaining: an optional `hooks/perf-gate.sh`
  wrapper + a database-reviewer rubric line pointing at it.
- **Severity:** HIGH · **Effort:** M · **Model:** Sonnet · **[template done; hook/rubric open]**
- **Files:** `templates/tests/query-count.test.py.template` (new), `hooks/perf-gate.sh` (new),
  `agents/database-reviewer.md`.
- **Why:** N+1 is the #1 silent performance killer in SaaS — fine with 10 rows in dev, dies with
  10k rows in prod. Static review misses it because the loop is often indirect (a template
  iterating a lazy relationship, a serializer touching `.related` per item). Only RUNTIME counting
  catches it.
- **Fix:** ship a pytest fixture that counts DB queries per request and asserts a ceiling
  (`assert_max_queries(10)`), plus **`nplusone`** (Python, works with SQLAlchemy/Django) wired to
  FAIL tests on detection. Add a query-count baseline to `baseline.py` so a commit that raises the
  per-endpoint query count on a hot path is flagged (ratchet). This is the single highest-ROI perf
  item.

### PF2 Unbounded-query + missing-index static gate — ✅ SHIPPED in v0.18.1 (2026-07-03)
- **Severity:** HIGH · **Effort:** S · **Model:** Sonnet
- **File:** `agents/database-reviewer.md` + a semgrep rule pack (reuse S1's semgrep).
- **Fix:** flag `SELECT`/`.query()` without `LIMIT`/pagination on list endpoints (the query that's
  instant on 100 rows and OOMs on 1M), and FK/`WHERE`/`ORDER BY` columns without an index. Pair
  with an `EXPLAIN ANALYZE` step in the database-reviewer's rubric for any new query on a large
  table (interpret seq-scan-on-big-table as a finding). Add `pg_stat_statements` / `auto_explain`
  guidance for prod slow-query capture.

### PF3 Performance budgets — Lighthouse (frontend) + endpoint latency (backend) — ✅ SHIPPED in v0.18.0 (2026-07-03)
> **COVERAGE (see `TESTING_TOPOLOGY.md`):** SPLIT. Backend p95-latency is
> DELEGATED to the agent (`ai-test perf --threshold`). Engine builds ONLY the
> Lighthouse-CI frontend budgets (shared with D2) — the agent has no frontend
> perf/a11y capability.
- **Severity:** HIGH · **Effort:** M · **Model:** Sonnet · **[MISSING — shares tooling with D2]**
- **Files:** `templates/ci/lighthouse-ci.yml.template` (also serves D2), `templates/perf/lhci.json`,
  `templates/tests/latency-budget.test.py.template`.
- **Fix:** **Lighthouse CI** enforces frontend budgets (LCP, Total Blocking Time, bundle size,
  unoptimized/lazy images — the "hero <200KB, sub-2s" rule from the 8CStudio design system) — a
  commit that regresses the score fails. Backend: a p95-latency assertion per hot endpoint in the
  smoke/e2e suite. This makes "premium feel = fast" a measurable gate, and it's shared with the
  Delivery gallery's "Lighthouse ≥90 or don't ship" bar (ROADMAP C4).

### PF4 Memory-leak / soak detection
- **Severity:** MEDIUM · **Effort:** M · **Model:** Sonnet · **[MISSING]**
- **Files:** `templates/tests/soak.test.py.template`, CI job.
- **Fix:** a soak test — fire N sustained requests against the running app, assert process RSS
  plateaus (doesn't grow linearly) → catches unbounded caches, accumulating globals, unclosed
  connections (the gunicorn-worker-starvation class 8CStudio hit, gotcha §32). Use `tracemalloc`
  snapshot-diff for Python and `memray`/`py-spy` for on-demand profiling when the soak flags growth.
  Advisory in CI (WARN) — leaks are noisy to gate hard, but the trend must be visible.

### PF5 Load / stress baseline (before any "scales to N" claim)
> **COVERAGE (see `TESTING_TOPOLOGY.md`):** DELEGATED to the agent — it already
> ships Locust generation + concurrent-load via `run_resilience_tests`. Do NOT
> build a second k6 harness; the engine calls the agent and records the ceiling.
- **Severity:** MEDIUM · **Effort:** M · **Model:** Sonnet · **[MISSING]**
- **Files:** `templates/perf/load-test.k6.js.template` (or locust), CI (manual-trigger) job.
- **Fix:** a **k6** (or locust) script — "50 concurrent virtual users, p95 < Xms, 0 errors" — run
  on-demand before scale decisions (e.g., 8CStudio's "what breaks at 50 tenants" question, which
  RESTRUCTURE §4.1 flagged as untested). Not per-commit (expensive); a gate before launch/scale
  milestones. Establishes the honest ceiling instead of guessing.

### PF6 A dedicated `performance-reviewer` agent (the judgment 20%)
> **COVERAGE (see `TESTING_TOPOLOGY.md`):** the *agent* (judgment) stays
> engine-side, but its runtime evidence is DELEGATED — it calls the testing-agent's
> `run_resilience_tests` / `perf` instead of running its own load. Keep this thin:
> orchestrate + judge, don't re-implement execution.
- **Severity:** MEDIUM · **Effort:** M · **Model:** Sonnet · **[MISSING]**
- **File:** `agents/performance-reviewer.md` (new gate agent, envelope contract, no Write).
- **Fix:** what deterministic tools can't see: blocking/expensive work in the request path (AI
  calls, transcode, sync HTTP → should be queued/out-of-band), cache-invalidation correctness,
  memory-accumulation patterns, algorithmic complexity in hot loops, over-eager serialization,
  missing pagination on APIs, and interpreting `EXPLAIN ANALYZE`. Runs on diffs touching
  routes/models/queries; emits the standard gate envelope. This is the perf equivalent of
  security-reviewer/design-critic — and, like them, item **A2's eval harness** must include perf
  fixtures (a seeded N+1, an unbounded query, a blocking call) so we can prove it actually catches
  them.

---

## A — AUTONOMY: from "prints instructions" toward self-improving agents (the "toward-AGI" ask)

> This is the entire P3 layer — always parked, now the frontier. The engine's judgment is
> excellent (envelope contract, failure-class routing, shadow→graduate) but the plumbing stops
> short: the orchestrator DECIDES escalation then a **human executes** it; token budgets are
> `"inf"` so the circuit breaker is decorative; there's ZERO measurement of whether gates actually
> catch bugs; and agents start every session from scratch (no cross-session learning). Sequence
> matters: telemetry → eval harness → closed loop, because you can't route or self-improve what
> you can't measure.

### A1 Wire real telemetry (E2.1) — prerequisite for everything else
- **Severity:** HIGH · **Effort:** M · **Model:** Opus · **[SHIPPED v0.19.0]**
- **Files:** `scripts/telemetry.py` (parser + OTel span emitter + cost table), `scripts/pe`
  (`pe telemetry collect|summary` subcommand), `policy/circuit_breaker.toml` (empirical baseline
  comment; budgets still `"inf"` in shadow-mode until enforce-mode graduates),
  `tests/test_telemetry.py` (13 unit tests), `tests/test_telemetry.sh` (wrapper).
- **What shipped:** parses `~/.claude/projects/<slug>/*.jsonl` assistant records → structured
  `TurnRecord` (session_id, uuid, model, per-usage-key token counts, cost cents, git branch) →
  appends to `<project>/.pe/telemetry.jsonl` deduped by uuid + emits OTel-shaped spans to
  `.pe/traces/<session>.jsonl`. Cost table (`CENTS_PER_MTOKEN`) covers opus/sonnet/haiku prefixes
  with 2026-07 pricing. Smoke-tested against this engine's own transcripts: 2948 turns,
  $1846 grand total. Circuit-breaker guidance updated to cite that baseline as the enforce-mode
  starting guess (`worker_tokens_budget = 4M`, `gate_tokens_budget = 2M`) — derived from
  measurement, not selected from a hat.

### A2 Gate-efficacy eval harness (seeded-defect corpus) — prove the gates work
- **Severity:** HIGH · **Effort:** M · **Model:** Sonnet · **[SEEDED v0.20.0 — 5 gates × ~3 fixtures each; live-mode still deferred to A4 wiring]**
- **Files:** `evals/README.md` (corpus contract), `evals/fixtures/<gate>/` for security-reviewer
  (4 fixtures), code-reviewer / database-reviewer / tdd-guide / design-critic (3 fixtures each),
  `tests/test_gate_efficacy.sh` (shape-mode runner), `schemas/gate-envelope.schema.json`
  (design-critic added to gate_name enum — v0.20.0 corpus caught the drift from v0.18.0).
- **What shipped:** per-gate fixture layout `<verdict>-<slug>/{input.md, expected-envelope.json}`
  where the directory prefix carries the expected verdict class. Runner iterates every fixture,
  validates the expected envelope against `schemas/gate-envelope.schema.json` via
  `pe gate parse --bare`, and asserts the exit code matches the contract
  (pass→0, fail-escalate→1, fail-halt→2, warn→3, adversarial→0 = safe-lookalike must not FP).
  Zero API cost — catches schema drift + mislabeled fixtures. **16/16 fixtures pass shape check.**
  First real drift the corpus caught: `design-critic` was missing from the gate_name enum since
  v0.18.0 — every design-critic envelope was silently invalid until v0.20.0.
- **What's left (deferred to A4):** live-mode (`--live`) requires a headless `pe agent run`
  interface — that's A4-scoped (orchestrator invokes workers headlessly via
  `claude -p "<brief>" --allowedTools ...`). Once A4 lands, the same corpus becomes
  precision/recall measurement of real agent verdicts.

### A3 Incident → gate synthesizer (automate the "quarterly rule") ⭐ the self-improvement loop
- **Severity:** MEDIUM · **Effort:** M · **Model:** Opus · **[SHIPPED v0.22.0]** · **depends: A2**
- **Files (shipped):** `agents/incident-synthesizer.md` (new specialist, tools deliberately
  restricted to Read/Grep/Glob/Bash — NO Write/Edit so engine self-modification is impossible
  at the plugin layer), `schemas/proposal-envelope.schema.json` (distinct from gate-envelope;
  `proposed_files[].path` regex rejects absolute paths + `..`),
  `scripts/incident_synth.py` (`pe incident propose|list` CLI: brief assembly + envelope
  extraction on distinct `\`\`\`json proposal-envelope` fence + shallow validation +
  materialization to `.pe/incident-proposals/<slug>/files/` in the CALLER's project),
  `scripts/pe` (`cmd_incident` dispatch), `tests/test_incident_synth.py` (19 unit tests
  covering extraction, validation, materialization defence-in-depth, and brief assembly).
- **Anti-abuse contract shipped verbatim:** (1) synthesizer has NO Write/Edit tool; (2) CLI
  writes only to the CALLER's `.pe/incident-proposals/` — never to the engine repo; (3) no
  `--auto-apply` flag exists. Materializer verifies via `Path.resolve()` prefix check that
  no proposed path escapes the slug's `files/` subtree; a regression test locks it
  (`test_rejects_escaping_path_defence_in_depth`).
- **Validation coupling to A2:** every proposal MUST cite
  `validation_plan.corpus_fixture = {gate, slug, expected_verdict}` — the fixture is A2's
  proof that the proposal actually catches the incident class. A proposal without a
  fixture is rejected at schema validation.

### A4 Close the execution loop (orchestrator invokes workers)
- **Severity:** MEDIUM · **Effort:** M-L · **Model:** Opus · **[SHIPPED v0.21.0 for the primitive; auto-escalation loop GATED on enforce-mode first-fire evidence per §9 watchpoint]** · **depends: A1**
- **Files (shipped v0.21.0):** `scripts/agent_runner.py` (headless `claude -p` wrapper),
  `scripts/pe` (`pe agent run` subcommand), `tests/test_gate_efficacy.sh` (`--live` mode
  wired onto `pe agent run`), `tests/test_agent_runner.py` (22 unit tests).
- **What shipped:** `pe agent run <name> [--brief <file>|-] [--out <path>] [--model <alias>]
  [--timeout <s>] [--dry-run]` loads `agents/<name>.md` frontmatter (model + tools) + body
  (system prompt), invokes `claude -p --output-format json --model <alias>
  --append-system-prompt <body> --allowedTools <list>`, parses the JSON result robustly
  (missing keys → zero; raw blob retained for drift inspection), computes cost via A1's
  price table, and persists `.pe/runs/<slug>/{brief.md, run.json, output.txt}`. Live-mode
  gate-efficacy (`--live`) now invokes each gate against every fixture and compares
  emitted vs expected envelope — first real precision/recall measurement path is live.
  Feature-detected: `claude` missing → exit 3 (clean SKIP); no `ANTHROPIC_API_KEY` →
  live-mode preflight skips.
- **What's still open:** the orchestrator's auto-escalation loop itself. On
  `worker_quality` FAIL, `pe_orchestrator.py::cmd_decide` should (a) call `pe agent run
  <next-tier-agent> --brief <fail-envelope-summary>`, (b) re-run `pe gate parse` on the
  produced artifact, (c) loop bounded by A1's token budget + the iteration cap, (d) halt
  on `task_underspecified/blocked/out_of_scope` per policy. Requires a stateful loop
  inside cmd_decide + an `--auto-execute` flag gated by `--enforce` (which is itself
  tested=false per §9 watchpoint). Ship in a follow-up once first-fire evidence is
  reviewed on enforce-mode.

### A5 Ponytail as a universal prerequisite (not opt-in on 2 of 10 agents)
- **Severity:** MEDIUM · **Effort:** S · **Model:** Sonnet · **[SHIPPED v0.23.0]**
- **Files (shipped):** `scripts/install.sh` (`WITH_PONYTAIL=1` default; `--no-ponytail` opt-out;
  `--with-ponytail` retained as no-op for back-compat), `hooks/ponytail-preflight.sh` (new,
  advisory PreToolUse hook; exits 0 always so it can never block a Write),
  `hooks/hooks.json` (new PreToolUse entry for `Edit|Write|MultiEdit`), five agent files
  (`agents/architect.md`, `agents/data-model-auditor.md`, `agents/e2e-runner.md`,
  `agents/project-kickstarter.md`, `agents/project-onboarder.md`) — each got a "Ponytail
  decision ladder (A5 universal prerequisite)" preamble section right after their opening
  paragraph. `agents/build-error-resolver.md` and `agents/tdd-guide.md` already had it.
- **Coverage:** **7 of 7 code-writing agents** now reference the ladder. Non-code-writing
  agents (gates, planners, meta-agents, incident-synthesizer) deliberately excluded — applying
  the ladder to a gate muddles its role.
- **Hook design (deliberately advisory):** small writes get a one-line reminder; ≥50-line
  writes get the verbose "any new dep requires an explicit `Ponytail: allow <reason>`" block.
  Back-to-back small writes within a 10-minute TTL dedupe (state in
  `.pe/ponytail-preflight-seen.state`). Large writes ALWAYS surface. Malformed JSON, missing
  python3, or empty stdin all silently exit 0 — the hook can never turn into a Write
  rejection the operator can't diagnose.
- **Tests:** `tests/test_ponytail_preflight.sh` — 7/7 pass (small, large, non-writing tool
  suppressed, empty stdin, dedup, malformed JSON, always-exit-0 invariant). All 10 test
  scripts + `pe docs check` green.

### A6 Domain layer — `pe new` scaffold + extract reusable SaaS modules
- **Severity:** MEDIUM · **Effort:** L · **Model:** Opus · **[SHIPPED v0.25.0 for scaffold + api-credentials; SHIPPED v0.26.0 for auth (closes api-credentials placeholder decorators); SHIPPED v0.27.0 for tenancy (Organization + Membership + OrgRole + FORCE-mode RLS helper + org switcher blueprint); SHIPPED v0.28.0 for billing (Charge + Refund + PaymentEvent + Stripe adapter + HMAC webhook + idempotency-by-event_id + FORCE-mode RLS + server-side amount authority + Decimal-only money helpers). A6 module library COMPLETE for the operator's SaaS baseline; only extensions (email flows, Razorpay adapter, subscription billing) remain deferred.]**
- **STATUS (2026-07-03, post-v0.25.0):** the SCAFFOLD half is shipped and the FIRST module
  (`api-credentials`) is materialized as proof-of-shape. Full module library — `auth`,
  `tenancy`, `billing` — is DEFERRED to follow-up releases per the "extract, don't architect
  in advance" principle: each ships when the pattern proves itself across ≥ 2 adopters. The
  original plan's "do after 8CStudio Delivery settles" constraint applies to the remaining
  modules, NOT the scaffold — the scaffold has zero dependency on any specific module shape.
- **Files (shipped v0.25.0):** `scripts/pe_new.py` (~230 lines — stack detection, placeholder
  substitution, git init, chained `pe install`), `scripts/pe` (`cmd_new` + `cmd_module`
  dispatch), `templates/scaffold/python-flask/` (9 files: run.py + pyproject.toml +
  CLAUDE.md + README.md + .gitignore + .env.example + modules/__init__.py + tests/__init__.py
  + tests/test_smoke.py), `templates/scaffold/generic/` (stack-agnostic minimal tree),
  `templates/domain-modules/api-credentials/` (8 files: models, credential_service,
  admin_credentials blueprint, admin templates, migration, coverage-floor tests),
  `docs/SCAFFOLD.md` (doctrine), `tests/test_pe_new.sh` (27 smoke tests: scaffold + module +
  overwrite refusal + placeholder substitution + git init + idempotency).
- **What shipped exactly:** `pe new "Acme Invoices" --stack python-flask` scaffolds a fresh
  project in ~30 seconds, git-init'd, `pe install`-completed, with a passing smoke test.
  `pe module add api-credentials` materializes the encrypted-API-key admin pattern
  (Fernet-encoded rows + write-only admin UI + audit log + env-var fallback for migration).
  Complementary to `agents/project-kickstarter.md` — that agent runs interactive Q&A + Opus
  reasoning; `pe new` is the deterministic drop when the operator already knows the stack.
- **What's still open:** `auth` module (session + JWT + OAuth + password reset — closes the
  placeholder decorator gap in `api-credentials`), `tenancy` module (RLS + tenant-isolation-
  auditor as its gate), `billing` module (payment_service/webhook stack + S3 payment templates
  as its gate). Extract each AFTER the pattern proves stable in ≥ 2 adopters (8CStudio +
  Origyn are the current calibration corpus).

### A7 Cross-session agent memory (learn from prior decisions)
- **Severity:** LOW-MEDIUM · **Effort:** M · **Model:** Sonnet · **[SHIPPED v0.32.0 — pe recall (Jaccard token overlap over .pe/decisions.jsonl + reconciliations.jsonl, per-slot trajectory collapse, --json/--limit/--min-score); research_index.py FTS5 sparse index + RRF fusion (reciprocal-rank k=60) for hybrid dense+sparse retrieval, --no-hybrid A/B flag, graceful degrade on legacy indexes; retrospective-agent §7b instructs pattern-synthesis into feedback auto-memory via pe memory add (≥3-slot recurrence trigger, ceiling 3 new memories per retro). Test coverage: tests/test_pe_recall.sh (11 cases) + tests/test_research_index_hybrid.sh (5 cases).]** · **depends: A1, A2**
- **Fix:** today the RAG index is query-only and decisions.jsonl is write-only — agents start each
  slot from CLAUDE.md alone. Add `retrieve_prior_decision(pattern)` so an agent can see "this slot
  is 30% similar to 1M.3; that approach passed review in 2 iterations" and teach retrospective-agent
  to synthesize recurring patterns into MEMORY.md. Also the P3.11 RAG upgrade (SQLite FTS5 hybrid
  retrieval — dense-only misses exact-token queries like slot IDs/SHAs/error strings). This is what
  makes agents get BETTER over time rather than merely consistent — the closest thing to "toward
  AGI" that's honestly achievable at this layer.

### A8 Distribution: native plugin + version pinning
- **Severity:** MEDIUM · **Effort:** M · **Model:** Sonnet · **[MISSING]** · **before widening beta**
- **Fix:** the symlink model has no version pinning (every adopter rides HEAD on `pe sync`) and the
  shadowing hazard cost the E1_b incident (partly fixed v0.11.1). Migrate to native `.claude-plugin/`
  format: versioned installs, enable/disable per project, Windows-friendly, marketplace path. Do
  this before onboarding more testers — each symlink-onboarded adopter is migration debt.

---

## TOK — TOKEN ECONOMY: spend less per session (added 2026-07-03 per operator, re: lean-ctx)

> **The key insight the operator needs:** token spend is THREE distinct buckets, each needs a
> different tool, and `lean-ctx` only attacks one of them. Chasing a single silver-bullet tool
> misses two-thirds of the cost. The buckets:
> 1. **Always-loaded context** (system prompt + CLAUDE.md + tool schemas) — re-billed EVERY turn.
> 2. **Read/tool-output tokens** (file reads, bash/grep output) — grows with how the agent explores.
> 3. **Output tokens** (what the model writes) — **3–10× more expensive per token than input.**
>
> `lean-ctx` (local Rust MCP binary: tree-sitter AST reads, shell-output compression, cached
> re-reads ~13 tok, claims 60–90% on reads/shell) attacks **bucket 2 only**. `Headroom` is a
> compression *proxy* between agent and LLM (60–95%, can wrap lean-ctx). `Caveman` is a terse-output
> skill (bucket 3, ~65%). The engine already handles most of bucket 1. **Order of attack below is by
> ROI-and-safety, not by hype — and NOTHING gets adopted before TOK0 (measurement), because a lossy
> compressor you can't measure can silently drop gate catch-rate.**

### TOK0 Measure before optimizing (hard prerequisite) — depends on A1/L1
- **Severity:** HIGH (gating) · **Effort:** — (it IS A1/L1) · **[BLOCKED: budgets still `"inf"`]**
- **Why:** you cannot prove any compression tool helps — or, worse, catch when it *hurts* a gate's
  catch-rate — without per-run token telemetry. Budgets are hardcoded `"inf"` today (A1 unbuilt).
  **Do not adopt lean-ctx/Headroom/any lossy layer before A1+L1 emit per-run token counts.**
  Adopting blind is the exact trap A2 (eval harness) exists to prevent.

### TOK1 Prompt-cache hygiene — the biggest FREE lever, native, do now ⭐
- **Severity:** HIGH · **Effort:** S · **[SHIPPED v0.25.1 — hooks/cache-hygiene-warn.sh PostToolUse advisory + docs/OPERATOR_WORKFLOW_V3.md § Cache hygiene]**
- **Why:** Claude's prompt cache gives a **~90% discount on cached input tokens** — but only on the
  UNCHANGED prefix (system prompt → CLAUDE.md → tool set → early history). Every time CLAUDE.md is
  edited mid-session, or the tool set shuffles, or an agent rewrites early context, the cache
  **breaks** and the whole prefix is re-billed at full price. The context diet (P7.1) shrank the
  prefix; cache hygiene keeps it *stable*.
- **Files:** `docs/OPERATOR_WORKFLOW_V3.md` (new "Cache hygiene" rule under §2), optional
  `hooks/cache-hygiene-warn.sh` (PostToolUse on Edit/Write of `CLAUDE.md`/`*.rules.md` mid-session →
  soft WARN "editing loaded-prefix mid-session breaks the prompt cache; batch to session end").
- **Fix:** codify as an operator rule + the soft check above: don't mutate CLAUDE.md/rules mid-session
  (batch doc edits to session end); keep a stable tool set (this env's deferred-tools/ToolSearch
  already helps — tool schemas load lazily, not all upfront); avoid agents that rewrite early history.
  This is free money the engine leaves on the table today.

### TOK2 Read hygiene — retrieve, don't slurp (engine-native, mostly there)
- **Severity:** MEDIUM · **Effort:** S · **[SHIPPED v0.25.1 — docs/OPERATOR_WORKFLOW_V3.md § Read hygiene documents the preference order (RAG → grep+offset/limit → subagent → whole-file)]**
- **Why:** bucket 2 grows fastest when agents `Read` whole large files instead of querying. The
  engine already has the right tools — `research_index.py` (RAG retrieval) and symbol/grep search —
  but no *discipline* enforcing their use over whole-file reads.
- **Fix:** a soft PostToolUse/preamble nudge: prefer RAG/symbol/grep/`Read` with `offset+limit` over
  whole-file reads; the subagent pattern (already heavily used) is the strongest native lever — a
  subagent burns its own context and returns a summary, so a 50-file sweep costs the parent ~1
  summary, not 50 files. **This is what lean-ctx automates; the engine gets ~70% of it free via
  subagents + RAG.** Lean-ctx's marginal win is AST-compressing the reads that remain.

### TOK3 Output-token discipline — highest $/token, under-attacked ⭐
- **Severity:** MEDIUM-HIGH · **Effort:** S · **[MISSING for prose]**
- **Why:** output tokens cost **3–10× input**. Ponytail (P6.1) already cuts *code* output ~54%, but
  the engine's agents emit long prose (envelope contracts, multi-page reports). That's the most
  expensive token class, largely unmanaged.
- **Files:** a shared `agents/_terse-output.md` snippet (like `_gate-contract.md`) templated into the
  MECHANICAL agents' frontmatter/preamble: `agents/{doc-updater,build-error-resolver}.md` + the
  headless-batch preambles. Do NOT add it to `agents/{architect,code-reviewer,security-reviewer,`
  `design-critic,retrospective-agent,ceo}.md`.
- **Fix:** a `terse-output` mode (Caveman-style) for the MECHANICAL agents (doc-updater, build-error-
  resolver, mechanical batches) — structured, minimal prose. **Keep the JUDGMENT agents verbose**
  (architect, reviewers, retro — their reasoning IS the product). Selective, not blanket. Cheapest
  high-ROI item here.

### TOK4 lean-ctx / Headroom — pilot as an optional read/shell compressor, gated
- **Severity:** MEDIUM · **Effort:** M · **[EVALUATE — do not default-adopt]**
- **Verdict:** legitimate and it fills the real bucket-2 gap TOK2 can't fully close — BUT adopt only
  after TOK0/1/2/3, and only through a gated pilot, because of three real risks:
  1. **Lossy on precision-critical reads.** A security/design reviewer needs the EXACT code; an
     AST-summarized or compressed read can drop the detail the gate depends on → lower catch-rate.
     Pilot must run against the A2 eval corpus and prove catch-rate is unchanged before adoption.
  2. **Tool-schema bloat (ironic).** lean-ctx ships "76 MCP tools" — tool schemas are *always-loaded*
     (bucket 1). A token-reducer that injects 76 schemas could net-*increase* per-turn cost. Only
     viable if tools load lazily (deferred/ToolSearch, as this env does). Verify before wiring.
  3. **Supply-chain / injection surface (ties to S4).** A layer that "decides what agents read" is a
     man-in-the-middle on every read — a powerful prompt-injection and exfiltration point, from a
     young single-maintainer project. Treat as an untrusted dependency: pin a version, sandbox, and
     put it behind `pe verify` (S4) before it touches real repos.
- **Recommendation:** wire it in a throwaway worktree, measure (TOK0) read-token delta AND gate
  catch-rate (A2) on the same tasks; adopt only if it cuts tokens materially *without* dropping
  catch-rate and *without* inflating bucket 1. Prefer using it as a targeted read-compressor for
  the mechanical lanes, NOT globally in front of the gate reviewers.

### What to SKIP
- **Don't** put a lossy compression proxy globally in front of the gate reviewers — precision beats
  brevity where catch-rate is the product.
- **Don't** adopt any 76-tool MCP server that loads schemas eagerly — measure bucket-1 impact first.
- **Don't** optimize tokens before A1 telemetry exists — you'd be flying blind on both savings and
  quality regressions.

---

## L — LANDSCAPE: 2026 market-informed gaps (things a codebase audit can't surface)

> Sourced from a scan of leading agentic-engineering practice (agent observability playbooks,
> the "Agent Development Lifecycle," trajectory-eval + Agent-as-a-Judge research, agent-memory
> benchmarks, and AI-FinOps). The value here isn't "copy the market" — most of it is
> enterprise control-plane bloat irrelevant to a solo-operator engine. It's the **4 categories
> that genuinely apply** and the **method** for scanning periodically (L0). Where an item extends
> an existing A-item, it's noted.

### L0 Adopt a repeatable "landscape scan" ritual (the durable answer to "how do I look for more")
- **Severity:** LOW (process) · **Effort:** S · **Model:** Fable (quarterly)
- **Fix:** once a quarter, the CEO/retro agent runs a structured scan of 4 axes and files gaps as
  L-items: (1) **observability** — is the full agent run traceable? (2) **evaluation** — do we
  measure trajectory quality, not just pass/fail? (3) **memory** — is cross-session state
  governed (inspect/delete/stale)? (4) **cost** — is spend attributed to outcomes? These four are
  the stable spine of agentic maturity; benchmarks and tools churn, the axes don't. This ritual is
  worth more than any single item below — it makes the engine self-updating against the field.

### L1 OpenTelemetry-standard agent tracing (observability) — extends A1
- **Severity:** MEDIUM · **Effort:** M · **Model:** Sonnet · **[SHIPPED v0.25.1 — per-turn spans + nested tool-call children]**
- **What shipped in v0.19.0:** A1's telemetry parser emits OTel GenAI-conforming spans per
  assistant turn to `<project>/.pe/traces/<session-id>.jsonl` — attributes include
  `gen_ai.system`, `gen_ai.request.model`, `gen_ai.usage.{input,output,cache_read,cache_creation}_tokens`,
  `gen_ai.response.finish_reasons`, plus `8colors.cost_cents / git_branch / cwd`. Local-first
  (never ships to a vendor). Portability principle honored: instrument once, choose backend later.
- **What's left for full L1:** nested span tree (currently one span per turn, no parent hierarchy
  for tool calls / gate verdicts / retries), plus an optional lightweight HTML trace viewer for
  local browsing. Enough shipped now that L4 (cost attribution) is usable; enough remaining that
  "why did this slot loop 8 times" is still traced at turn-granularity only.

### L2 Trajectory evaluation + eval-gaming defense — extends A2 ⭐ important caveat
- **Severity:** MEDIUM-HIGH · **Effort:** M · **Model:** Sonnet · **[SHIPPED v0.25.1 — adversarial + held-out subcorpus + `--metrics` JSONL emits cost/duration/turns/tool_calls per fixture]**
- **v0.19.0 partial:** the eval runner honors an `adversarial-*` directory prefix (safe lookalike
  that must NOT false-positive) alongside pass/fail; security-reviewer's seed corpus includes an
  `adversarial-safe-string-format` fixture proving the shape. Held-out (unseen-during-development)
  subdirs and trajectory metrics (step count, loops, retries, wall-clock per gate turn) are
  designed into `evals/README.md` but require the `--live` mode to actually measure — they ride
  on the same live-invocation path A2 defers to v0.20.0.
- **Why:** A2 as scoped is a seeded-defect corpus (input → did the gate catch it?). 2026 research
  (AgentLens' "Lucky Pass Problem"; Berkeley RDI showing *every* major benchmark — SWE-bench,
  WebArena, GAIA — is exploitable) is a direct warning: **a pass/fail corpus can give false
  confidence.** Leading practice adds **trajectory evaluation** — score the full run (tool
  selection, step count vs. minimum, loops, recovery), not just the final verdict — and prefers
  **pairwise comparison** (relative judgment) over absolute LLM-as-judge scores (which have length/
  position/self-preference bias and are non-deterministic).
- **Fix:** (a) A2's corpus must include **held-out/adversarial** fixtures the gates haven't seen,
  refreshed over time, so we measure real catch-rate not memorized answers; (b) add trajectory
  metrics to the eval (did the agent loop? take 8 steps for a 2-step task?); (c) where an agent
  judges quality, use pairwise ("is diff A or B better against this rubric?") not absolute scores.
  This is the difference between "we think the gates work" and "we've proven it against inputs they
  can't game."

### L3 Memory governance (inspect / correct / delete / staleness / access) — extends A7 + ties to S4
- **Severity:** MEDIUM · **Effort:** M · **Model:** Sonnet · **[SHIPPED v0.24.0]**
- **Files (shipped v0.24.0):** `scripts/pe_memory.py` (stdlib-only parser + 5 subcommand
  handlers), `scripts/pe` (`cmd_memory` dispatch), `docs/MEMORY_GOVERNANCE.md` (doctrine),
  `tests/test_pe_memory.py` (25 unit tests: frontmatter parser, entry loader, staleness rule,
  index I/O, desync detection, stamp_verified round-trip).
- **What shipped:** `pe memory ls|show|rm|verify|stale` covers the inspect / correct / delete
  surface. Optional new frontmatter fields — `freshness_days`, `last_verified`, `scope` — are
  all backward-compatible; existing entries keep working unchanged with per-type default
  freshness windows (user 90d, feedback 60d, project 14d, reference 180d, unknown 30d).
  Staleness rule is `now - max(mtime, last_verified) >= freshness` — `pe memory verify` stamps
  today's date, resetting the clock without editing the body (the *endorse* path).
  MEMORY.md index kept in sync automatically by `pe memory rm`; drift between on-disk files
  and index lines surfaces as a warning in `pe memory ls`.
- **What's deliberately deferred:** access-control enforcement (`scope: agent` is a tag today,
  not a gate — Claude Code decides who can write; enforcement waits for a write-hook surface).
  Auto-write side stays with Claude Code + operator's global memory rules — L3 ships the
  inspection side only. Poisoned-memory scanning (S4 tie-in) rides on the audit surface L3
  now provides.
- **Smoke against engine's own memory dir:** ~6 project entries; `ls`, `show`, `stale`,
  `verify` all worked end-to-end and stamped a real entry with `last_verified`.

### L4 Cost attribution — spend per outcome, not just per run — extends A1
- **Severity:** LOW-MEDIUM · **Effort:** S · **Model:** Sonnet · **[SHIPPED v0.25.1 — retro-agent Step 0 now runs `pe telemetry collect|summary` and cites per-session per-model totals in the Cost section]**
- **v0.19.0 partial:** `CENTS_PER_MTOKEN` in `scripts/telemetry.py` covers opus/sonnet/haiku with
  2026-07 pricing; every `TurnRecord.cost_cents` is populated in `.pe/telemetry.jsonl` + surfaced
  as `8colors.cost_cents` on OTel spans. `pe telemetry summary` aggregates per-session per-model
  totals. Empirical baseline captured (this engine: 2948 turns / $1846) and cited in
  `policy/circuit_breaker.toml` as the enforce-mode budget guess.
- **What's left:** surface cost in the Friday retro. `retrospective-agent` Step 0 should call
  `pe telemetry summary --since <week-start>` and include the per-session totals in the digest so
  "this Haiku slot spent 50k tokens looping — should've been Sonnet" becomes visible on the
  weekly cadence. Cheap add — the ledger already exists.

### What to DELIBERATELY SKIP (market hype that's wrong for this engine)
- **Enterprise "AI control plane" / unified multi-cloud governance platforms** (Galileo, Arthur,
  Arize enterprise tiers) — built for orgs running many agents across many frameworks/clouds. A
  single-operator, single-framework (Claude Code) engine gets the same safety from local hooks +
  gates at ~0 cost. Emit OTel (L1) so you *could* plug one in later; don't buy one now.
- **Dedicated vector DB for memory** — SQLite FTS5 + the existing embeddings (P3.11) is right at
  this scale; a vector DB is ops overhead you don't need.
- **SWE-bench / public leaderboard chasing** — the research consensus is these are gamed and
  training-contaminated; your eval that matters is L2's held-out corpus against YOUR gates on
  YOUR stack, not a leaderboard number.
- **SOC2/compliance-automation tooling** — relevant when you sell the *engine* or hit enterprise
  buyers; today the audit trail (decisions.jsonl + session docs) is sufficient. Revisit at a real
  compliance trigger, not speculatively.
- **Real-time hallucination-detection models on every turn** — too expensive per the research
  (a full model call per judgment); the gate-at-commit + PostToolUse-hook posture is the right
  cost/coverage trade for code work.

---

## A9 — Integrate the AI Testing Agent as an MCP tool (converts D3 + parts of S3/PF from build→wire)
- **Severity:** MEDIUM · **Effort:** S-M · **Model:** Sonnet · **[NEW 2026-07-03]**
- **Why:** the operator's standalone `ai-testing-agent` (38k LOC, 679 passing tests) already
  implements several gaps this plan listed as unbuilt, and ships an **MCP server** (8 tools) — the
  clean reuse path. Full assessment: `docs/AI_TESTING_AGENT_VALIDATION.md`.
- **Fix (call it, don't reimplement):** register its MCP server; then (A9.2) wire `compare_api_specs`
  as the **S3 API-contract check** (breaking-change gate — replaces the planned oasdiff build);
  (A9.3) build **D3 visual regression** on its `visual_tester` + `advanced_comparison` (SSIM/hash +
  baselines — most of D3 already written); (A9.4) expose `run_resilience_tests` to the PF6
  performance-reviewer and add the PF1 query-count hook onto its chaos runner; (A9.5) pull its OWASP
  payload constants into the S3 templates (payloads only — the SAST scanner is still S1/semgrep).
- **Prereq:** clean the testing-agent first (ruff --fix, migrate `google.generativeai`→`google.genai`,
  fix the awaited-coroutine test, strip the 2k-LOC licensing subsystem) so the exposed tool is
  trustworthy. **Model decision: engine ORCHESTRATES + owns verdicts; testing-agent EXECUTES** (do
  A9 before building S3-contract/PF-resilience/D3 from scratch — it converts them to integration).
- **STATUS (2026-07-03) — A9.1 DONE + prereqs DONE:**
  - **Testing-agent cleaned & MCP completed** (in the `ai-testing-agent` repo):
    - `run_security_scan` MCP tool was a **stub** ("security scan would run here") → now runs a real
      OWASP scan via a new shared `integrations/security_scan.py` (used by both the MCP tool and the
      `ai-test security` CLI — no duplication).
    - Added launcher: `ai-test mcp serve` / `ai-test mcp tools` CLI + `ai-test-mcp` console script
      (`integrations/mcp_launcher.py`) so the engine registers a stable command.
    - Migrated `google.generativeai` → `google-genai` (SDK 1.x `Client` API); verified with a live
      Gemini call in the integration suite.
    - Fixed the coroutine-never-awaited test bug (`test_graphql_executor.py`); suite is clean under
      `-W error::RuntimeWarning`.
    - `ruff check --fix`: 3,422 auto-fixed (4,250 → 814 residual, non-auto-fixable style/complexity).
    - **All 679 tests pass, 1 skipped.**
  - **Engine-side registration (A9.1):** `templates/mcp/ai-testing-agent.mcp.json.template` +
    `templates/mcp/README.md` (per-gate tool-consumer map); catalogued in `docs/CAPABILITY_CATALOG.md`
    (MCP servers → ADOPTED). Smoke-tested: server builds, lists all 8 tools.
  - **NOT yet done (follow-ups):** A9.2 wire `compare_api_specs` into code-reviewer as the S3 gate;
    A9.3 build D3 on `visual_tester` (not yet an MCP tool); A9.4 add PF1 query-count hook to the chaos
    runner; A9.5 pull OWASP payloads into S3 templates. **Licensing not stripped** — the operator's
    uncommitted WIP already neutralizes it (all gates return unlocked), and the MCP path never calls
    it; full removal deferred as low-priority.
  - **A9.2 DONE (v0.17.1, 2026-07-03):** shipped as a **deterministic pre-commit gate**, not an
    agent-only MCP call. Mechanism chosen: a new `ai-test api-diff` CLI wrapping the same `APIDiffer`
    the MCP `compare_api_specs` tool uses (one source of truth), called by `hooks/api-contract-check.sh`
    — blocks the commit on a breaking change to a committed OpenAPI/Swagger spec; advisory skip if
    `ai-test`/`deepdiff` absent (mirrors `sast-scan`). Wired into `.pre-commit-config.yaml.template`,
    `api_contract_gate` in `process-engine.yaml.template`, and a new **API contract (HIGH)** section in
    `code-reviewer.md`. NOTE on scope: the S3 *item* is broader (auth/payment pytest templates —
    webhook HMAC, payment authority); A9.2 covers only the **breaking-change** half. Config-generated
    or uncommitted specs aren't gated (no baseline to diff) — the code-reviewer section is the human
    backstop there.
- **STATUS (2026-07-03, round 2) — hardening + future-proofing DONE:**
  - **`run_visual_regression` is now the 9th MCP tool** (new `integrations/visual_scan.py` over
    `visual_tester`, sync Playwright run in a worker thread, graceful degradation if the `[visual]`
    extra is absent). **This lifts A9.3 to a near-complete state:** the visual capability is callable;
    the only remaining A9.3 work is engine-side — wire the **design-critic** gate to call it on key
    pages and fail below the similarity threshold. Registered in `templates/mcp/README.md`.
  - **Future-proofing:** migrated `config.py` off the deprecated Pydantic `Field(env=...)` to
    `validation_alias` / `AliasChoices` + `populate_by_name` (removes ~19 deprecation warnings; safe
    for Pydantic v3). Suite warnings 40 → 21.
  - **Licensing neutralized cleanly** (not ripped — 2,068 LOC across 10 files + tests, too risky):
    `get_license_manager()` now defaults to unlocked ENTERPRISE on every path; confirmed no real
    network call existed (`_validate_with_server` was already a mock); documented as self-hosted.
  - **Docs honesty:** archived 6 completion-theater markdowns to the testing-agent's `docs/archives/`;
    rewrote its README (dropped "world-class / 100% complete / 71-71" → "beta, 679 tests", added the
    MCP section, replaced the fake pricing tiers with a self-hosted note).
  - **No double work by design:** SAST stays the engine's S1 (`hooks/sast-scan.sh`); the agent's
    security is *dynamic* (payloads vs a live app) — complementary, not duplicate. Documented in the
    agent README + `templates/mcp/README.md`.
  - **Still all 679 tests pass; new files ruff-clean.**

---

## Loose ends from the audits (small, do opportunistically)

- **e2e-runner self-grades tests it wrote** — violates the reviewer/worker separation; split into
  test-author (worker, keeps Write) + a gate that grades. (S, Sonnet)
- **tdd-guide hybrid identity** — envelope says "reviewer", body says "author"; pick one. (S)
- **Non-standard frontmatter fields** `effort:`/`memory:` are silently ignored — document or
  remove (false sense of configuration). (S, Haiku)
- **database-reviewer** missing API-contract (oasdiff/schemathesis) + seed-data convention checks
  (P3.9 remnant). (S)

---

## Suggested execution order

1. **S1 + S2 (security core)** → v0.17.0. SAST wired + Python-first reviewer. Biggest risk
   reduction per effort; the operator's stated #1.
2. **D1 + D2 + PF3 (design parity + a11y + perf budgets)** → v0.18.0. Design becomes an
   evidence-verified gate; Lighthouse CI (shared by D2 and PF3) catches both "unprofessional" AND
   "slow" in one wiring. Operator's #2, and directly serves the 8CStudio Delivery gallery bar.
3. **PF1 + PF2 (runtime N+1 + unbounded-query gates)** → v0.18.x. The real-world slowness class;
   small effort, high impact, reuses S1's semgrep + the DB reviewer.
4. **A1 + A2 (telemetry + eval harness)** → v0.19.0. Measurement first — proves every gate above
   (security, design, perf) actually works; A2 fixtures MUST include seeded perf defects.
5. **S3 + S4 + A5 (payment/webhook templates + LLM-threat hardening + Ponytail-default)** →
   v0.20.0. Secure-by-default for the store phase; agents hardened; less code by default.
6. **PF6 + PF4 + PF5 (performance-reviewer agent + soak + load)** → v0.20.x, gated on A2.
7. **A3 + A4 (self-improvement loop + closed execution)** → the autonomy leap, gated on A2.
8. **A6 + A8 (domain scaffold + native plugin)** → after 8CStudio Delivery settles; the "less code
   for every future app" payoff + safe distribution. **A6 is still entirely unbuilt — see its
   STATUS note; the domain layer is NOT solid yet, by design.**
9. **A7 + loose ends** → ongoing backfill lane. **L3 (memory governance) lands WITH A7, not
   after** — governance is a retrofit if deferred.
10. **L-items interleave by affinity:** L1 rides with A1 (telemetry → OTel spans), L2 with A2
    (eval → trajectory + held-out), L4 with A1/L1 (cost attribution). L0 (quarterly landscape
    scan) starts NOW — it's a process ritual, not a build, and it's the durable answer to "how do
    we keep finding enhancements."
11b. **D5–D8 (design ceiling / award-grade) — after the D1–D4 floor is solid, invest on
    client-facing surfaces:** D5 (critic floor→ceiling) is the highest-leverage; D7 (aspirational
    references + Style Dictionary) feeds it; D6 (motion craft) + D8 (signature) on flagship/Delivery
    surfaces. Full spec: `docs/DESIGN_EXCELLENCE.md`. The quarterly design-scan ritual starts NOW.
    Sequence relative to product: these serve 8CStudio's Delivery gallery "beats Pixieset" bar
    (ROADMAP C4) — do D5+D7 before the gallery viewer ships.
11. **TOK (token economy) — start the FREE items now, gate the rest on A1:** TOK1 (cache hygiene)
    + TOK3 (terse mechanical output) are zero-risk, do them alongside step 1–2. TOK2 (read hygiene)
    is mostly-present (subagents/RAG) — codify the nudge opportunistically. **TOK0/TOK4 are BLOCKED
    on A1 telemetry (step 4)** — do not pilot lean-ctx before then, and only via the gated worktree
    eval in TOK4. A9 (testing-agent MCP integration) interleaves with D3/S3/PF — do A9 FIRST where
    it converts a build to a wire.

**Cross-reference:** this plan is sequenced to serve `../../8CStudio/docs/ROADMAP.md` — S1/S2/D2
harden the gates the Delivery build (Wave 2) runs under; A6 (domain modules) is the "extract what
Delivery proved" payoff after Gate 0. Pick engine items by which product wave they de-risk.
