# Capability Catalog — engine-vetted tools + reusable agents

> **Created 2026-06-29, post-Phase-3-graduation.** Single reference doc capturing every tool we evaluated and every agent we built during the engine redesign. Recorded once so we never re-investigate.
>
> **Source documents** (don't re-read these to make a decision — this catalog summarizes their conclusions):
> - **`../process-engine-enhancement-design.md`** (sibling to engine repo) — **CANONICAL high-level architecture** (5-layer model: L0 Knowledge / L1 Orchestration / L2 Workers / L3 Gates / L4 Checkpoints) + non-negotiable principles + tiered routing + escalation ladder + parallelism model. Read this FIRST for the design north-star.
> - `docs/AGENT_INVOCATION_RULES.md` — gate-agent chain matrix
> - `docs/OSS_SEARCH_ORDER.md` — canonical search order
> - `docs/RAG.md` — embedding-provider decisions
> - `docs/PHASE_3_ESCALATION_ROUTER.md` — gate envelope contract, severity floor, fail-safe eligibility
> - `docs/E1_GATE_ENVELOPE.md` + `schemas/gate-envelope.schema.json` — envelope schema
> - **Historical evidence (lives in 8CStudio repo — read only when verifying a specific tool decision):**
>   - 8CStudio `docs/research/process-v2-research-2026-05-11.md` — Agent A internal audit + Agent B external MCP/tooling market scan + §6 per-agent re-evaluation
>   - 8CStudio `docs/research/1M.3-oss-decisions.md` — per-phase OSS adopt/custom decisions (Wave 1M.3 offline sync)

---

## ⚠️ Architecture note — read before adding anything

Per `../process-engine-enhancement-design.md` §3, the engine has **five layers**:

| Layer | Lives in | Owned by | Status today | Purpose |
|---|---|---|---|---|
| **L0 — Knowledge** (pluggable, per-project) | Consuming project — RAG index + project spec / domain rules | Consuming project | ✅ Partial: consuming project's `docs/research/` indexed via `scripts/research_index.py` (RAG.md). Project spec = CLAUDE.md + MEMORY.md (consuming-project-side). | Domain knowledge — the ONLY layer where project facts live. Swapping projects means swapping L0. |
| **L1 — Orchestration** | This repo (`scripts/pe_orchestrator.py` + `policy/*.toml`) | Engine | ✅ Live, enforce mode active 2026-06-28. | Task decomposition, scheduler, circuit breaker. Model-neutral logic. |
| **L2 — Workers (tiered, parallel)** | Worker invocation = Claude Code session (operator routes to Haiku / Sonnet / Opus per task) | Operator workflow + engine policy (`policy/failure_class_routing.toml [ladder]`) | ⚠️ Partial: tiers defined in ladder (`haiku`/`sonnet`/`opus`); escalation logic exists; **no auto-routing of tasks to tiers yet** — operator picks tier today. Per-tier worker definitions not formalized. | The agents that DO the work. Tiered: cheap-first, escalate on gate failure. |
| **L3 — Validation gates** | This repo `agents/*.md` (5 gate agents), symlinked into consuming project's `.claude/agents/` via `pe install` | Engine, installed per-project | ✅ Live, battle-tested via Phase 3 cohort. Severity-floor tested=TRUE; cap + escalation-ladder tested=false carry. | Quality is enforced HERE, identically for all tiers. `code-reviewer`, `security-reviewer`, `database-reviewer`, `tdd-guide`, `e2e-runner`. |
| **L4 — Human checkpoints** | Operator's workflow discipline (e.g., staging approval, prod-promote signoff, deploy gates) | Operator | ✅ Live; M=3 watchpoint commitment is the active L4 obligation post-graduation. | Phase boundaries, destructive ops, sensitive data — never automated away. |

**Critical rule from design doc §2 / §5:** speed and cost are optimised in L1/L2; quality is fixed in L3. The two never trade against each other. A cheap model does NOT get a cheaper bar.

**Capabilities in this catalog are L0 / L2 / L3 reuse pointers — NOT engine-bundled.**

- Each project runs `pe install [--subset gate-only|core|full] <project_path>` to symlink the subset of L3 agents + supporting agents it needs into its own `.claude/`. Presets shipped in v0.8.0: `gate-only` (5 gate agents), `core` (gates + planner + brief-writer + architect = 8 agents), `full` (all agents, default). The chosen subset is persisted to `.process-engine.yaml` under `install.subset` so `pe sync` honors it on re-points.
- The engine stays thin (L1 only). "Engine gets better each time" = **the catalog grows** (more agents documented, more tools vetted, more knowledge-pack templates) — NOT the engine binary carries more weight.
- **Do NOT propose bundling L0 knowledge, L2 worker definitions, or L3 agents into the engine core.** That would break the separation that makes the engine reusable across products (8CStudio, fitness app, future products). Design doc §8 calls this the "knowledge pack + project config" contract.
- New project = `pe install` + supply L0 knowledge pack + pick the L3 agents from this catalog that match its domain. That's the entire onboarding loop.

**Today's gaps relative to the design's full 5-layer vision** (NOT graduation blockers — explicitly deferred to product work):
- **L2 auto-tier-routing** is operator-manual today (operator picks Haiku/Sonnet/Opus per task). Auto-routing per `[ladder]` would be a future engine enhancement, but the orchestrator's escalation path already handles failed work climbing tiers — so the gap is "starting tier choice," not "escalation."
- **L0 knowledge-pack abstraction** (design doc Phase 5) is not formalized. Today each project has its own CLAUDE.md + MEMORY.md + research index, but there's no canonical "project config" YAML/TOML the engine reads. Adding this is a future engine enhancement; current per-project CLAUDE.md is sufficient for the 1-product-at-a-time workflow.

---

## §1. Tools Evaluated (sweep — what we already decided)

Recovered from 8CStudio-side `process-v2-research-2026-05-11.md §2`, 8CStudio-side `1M.3-oss-decisions.md`, engine `RAG.md`, and the MCP catalog in consuming-project `.mcp.json` / `claude mcp list`.

> **Engine ⟷ testing-agent division of labor:** see `docs/TESTING_TOPOLOGY.md`
> — the authoritative "build each check once, on the side that matches its axis"
> matrix (static/commit → engine; dynamic/runtime → agent). Consult it before
> building any new S / PF / D item.

### MCP servers

| Tool | What it does | Conclusion | Why |
|---|---|---|---|
| **ai-testing-agent MCP** | 9 tools: `extract_apis`, `list_modules`, `test_intent`, `run_pipeline`, `run_security_scan` (OWASP API Top-10), `run_resilience_tests` (chaos/load), `run_visual_regression` (SSIM/perceptual-hash → D3), `compare_api_specs` (breaking-change), `get_test_history` (flaky/perf trends) | **ADOPTED** (A9) | Engine model (A): the engine orchestrates + owns verdicts, the standalone testing-agent executes. Register via `templates/mcp/ai-testing-agent.mcp.json.template`; launch with `ai-test-mcp` (or `ai-test mcp serve`). Tools appear as `mcp__ai-testing-agent__*`. Fills S3 (api-diff + security exec) and PF6 (resilience). Full map + gate-consumer table in `templates/mcp/README.md`; validation in `docs/AI_TESTING_AGENT_VALIDATION.md`. |
| **Sentry MCP** | Error monitoring queries, search issues, view stack traces, Seer analysis | **ADOPTED** (with caveat) | Already paying Sentry; OAuth shipped Feb-Apr 2026; ~30 min setup; replaces manual paste-Sentry-error-into-Claude loop. **Caveat:** `mcp.sentry.dev` OAuth proxy is currently broken (state-mismatch on GitHub federated login, 4 attempts confirmed). Fallback path: direct user-token + REST API (`sentry.io/settings/account/api/auth-tokens/`, scopes `event:read + org:read + project:read`) — proven working via Design 2 credential bridge (8CStudio PR #85). Configured in consuming-project `.mcp.json`. |
| **Serena MCP** | Symbol-aware code navigation (LSP-backed) — find symbols, references, call sites without loading whole files | **ADOPTED** | Token-saving vs Read on large files (~5-10× cheaper on symbol queries). Usage rubric at consuming-project `docs/SERENA.md`. Configured in `.mcp.json` → `mcp__serena__*`. Use for bug diagnosis / refactor impact; skip for text enumeration / frontend-only / migrations. |
| **context7 MCP** | Current docs lookup for libraries/frameworks (Anthropic, Flask, Postgres, etc.) | **ADOPTED** | Prefer over web search for library docs — fresher than training data. Configured globally. Use when touching unfamiliar API surfaces. |
| **GitHub MCP** | Issues, PRs, code search, commits — all via natural language | **ADOPTED** | Configured globally. Used routinely in this session for PR management. Faster than `gh` CLI for multi-step PR workflows. |
| **Playwright MCP** | Browser automation, snapshots, console messages, network requests | **ADOPTED** | Configured globally. Use for E2E debugging + visual verification. Per-project E2E suites stay in `tests/e2e/` (Playwright-direct, not MCP). |
| **Figma MCP** | Design-to-code, code-to-design, FigJam diagrams | **DECIDE / DEFER** | Per process-v2 Agent B: "Configured in `.mcp.json` but unused; commit-and-use or remove." 8CStudio has no Figma workflow today. Reusable for projects that DO have a Figma source-of-truth. |
| **Google Drive + Gmail + Calendar MCP** | Drive file ops, Gmail search/draft, Calendar OAuth | **ADOPTED** (globally) | Configured globally. Use when slot work needs to read a doc the operator put in Drive or trigger a calendar event. Not load-bearing for code work. |
| **v0 MCP** | React-component generation from prompts | **REJECTED** | React lock-in — doesn't fit 8CStudio's Alpine/Tailwind/Jinja stack. Re-evaluate if a future project is React-native. |
| **CodeRabbit CLI** | Automated code review on PRs | **DEFER** | Per process-v2 Agent B: "Useful if PR backlog grows." We have `code-reviewer` agent in-session (workflow-gate, not async PR review). Re-evaluate if multi-developer + queue depth become a thing. |

### Embedding / RAG providers (per `RAG.md`)

| Tool | What it does | Conclusion | Why |
|---|---|---|---|
| **fastembed (BAAI/bge-small-en-v1.5, 384 dims)** | Fully-local embedding (no API key) | **ADOPTED as default** | Adopter "just works" after `pip install fastembed` (~150 MB + 33 MB model first use). Good for ≤10k doc corpora — 8CStudio's `docs/research/` is ~70 docs. |
| **Gemini embedding (768 dims, asymmetric task-types)** | Free-tier + paid Google embeddings | **AVAILABLE — opt-in via `GEMINI_API_KEY`** | When adopter already has a Gemini key for other reasons. Higher quality than fastembed for cross-document retrieval. |
| **Voyage / OpenAI embeddings** | Commercial high-quality embeddings | **AVAILABLE — opt-in** | Power-user path. Not needed for current corpus size. |

### Sync / offline (Wave 1M.3 decisions — 8CStudio-side)

| Tool | What it does | Conclusion | Why |
|---|---|---|---|
| **Pydantic v2** | Schema validation with type annotations, Rust-core fast | **ADOPTED** | Matches 8CStudio `core/sync/envelope.py`'s shape exactly; replaces ~100 LOC of `isinstance` checks. Locked at `pydantic>=2.5,<3` in `requirements.txt`. 8CStudio CLAUDE.md §6 "validate at the boundary" rule was written for this case. |
| **Workbox 7.4.1** (npm, MIT, Google) | Service Worker library with `BackgroundSyncPlugin` for offline queue/replay | **LOCKED BY BRIEF — pragmatic Phase 6.1 deviation** | Originally locked in the offline-mobile-PWA brief. Phase 6.1 shipped a hand-rolled ~150 LOC `sync_queue.js` instead because iOS Safari has no Background Sync API and the value differential didn't justify mid-wave swap. 8CStudio BACKLOG #220 tracks the eventual Workbox adoption when Android Chrome usage > iOS. |
| **Dexie 4.x** (npm, Apache 2) | Typed IndexedDB wrapper | **ADOPTED** | Locked in Wave 1M.2; in active use across the offline-write-queue subsystem. |
| **RxDB / PouchDB / Replicache** | Full DB replication frameworks | **REJECTED** | Full DB replacement / wrong backend protocol / paid license for commercial. Mid-project swap cost too high; our 4 conflict strategies (`last_writer_wins`, `append_only`, `operator_merge`, `reject`) are deliberately simpler than CRDT. |
| **AutoMerge / Yjs** (CRDT libraries) | Conflict-free replicated data types | **REJECTED** | Overkill for operator-led production app. The 4 strategies don't need commutative ops. Re-evaluate only for multi-replica concurrent-edit scenarios (unlikely in 8Colors product line). |
| **xstate** (npm, MIT, 27k stars) | Gold-standard FSM library with visualizer | **REJECTED** | 5-state sync orchestrator is ~30 LOC; xstate's ~30 KB bundle + dev-tools don't justify the dep at this scale. Re-evaluate for nested/parallel substates. |
| **flask-idempotency / idempotency-header-django** | HTTP idempotency-key middleware | **REJECTED** | Per-record `(idempotency_key, user_id)` scoping doesn't match opinionated middleware shape. ~50 LOC custom is right tax. Re-extract trigger: if pattern stabilizes for 3+ months across apps. |
| **alembic** | SQLAlchemy migration framework | **REJECTED** | Carries Django/SQLAlchemy assumptions we don't want. 8CStudio's `migrate_NNN_*.py` pattern is the established convention. |
| **python-registry** | Thin dict wrapper for module registries | **REJECTED** | 15 LOC custom registry is below the dep-cost threshold. |

### Source-input / digest

| Tool | What it does | Conclusion |
|---|---|---|
| **Simon Willison RSS** | Weekly applied-AI/tooling digest | **SUBSCRIBE** (per process-v2 Agent B) — 15 min/week Monday skim |
| **Latent Space (free tier)** | Applied-AI podcast/blog | **SUBSCRIBE** — same cadence |
| **awesome-mcp-servers GitHub watch** | Weekly digest of new MCP servers | **SUBSCRIBE** — catches new ecosystem capabilities |

### Static analysis + security scanning (CI-only, not in-session)

| Tool | What it does | Conclusion | Why |
|---|---|---|---|
| **Ruff** | Python linter (Rust-fast) | **ADOPTED** | Pre-commit hook + CI. Established. |
| **Semgrep** | Multi-language SAST | **ADOPTED** | CI gate per consuming-project `.github/workflows/ci.yml`. Catches OWASP patterns the agent reviewer might miss. |
| **pip-audit** | Python dependency vulnerability scanner | **ADOPTED** | CI gate. Catches CVEs in pinned `requirements.txt`. |
| **sqlglot** | SQL parser for portability checking | **ADOPTED** | Pre-commit hook + CI. Enforces SQLite ↔ Postgres dialect compatibility. |
| **Bandit** | Python-specific security linter | **AVAILABLE — opt-in** | Not currently in 8CStudio CI but is the canonical Python SAST. Add via `pip install bandit` + workflow step if Semgrep coverage proves thin. |
| **DAST scanners (OWASP ZAP, Burp Suite Pro)** | Dynamic application security testing | **DEFER — design doc §9 "scoped pentest worker" reference** | Future capability per `../process-engine-enhancement-design.md` §9: "scoped pentest worker that orchestrates established tools (e.g. DAST scanners) against own systems only, behind a human checkpoint. Treated as human-assisted, not fire-and-forget." Triggers: pre-launch hardening; compliance audit; suspected vulnerability. |

### Cost/speed techniques (not tools, but architectural patterns)

| Technique | Status | Source |
|---|---|---|
| **Tiered model routing (Haiku/Sonnet/Opus, cheapest-capable first)** | ✅ Encoded in `policy/failure_class_routing.toml [ladder]`; escalation path tested via static analysis (graduation fail-safe proof). Auto-routing of starting tier = future enhancement. | Design doc §4 + §5.2 |
| **Always-on token-discipline / YAGNI skill** | ⚠️ **NOT YET BUILT** — design doc §9 + §10: "always-on YAGNI/anti-over-engineering skill that minimises generated code." Today the discipline lives in CLAUDE.md prose + operator review, not in an automated skill. Could be formalized as a `token-discipline.md` skill (engine-installable) that prepends YAGNI reminders to each worker invocation. Defer until cost telemetry (E2.1) is wired and we can measure cost-per-slot. | Design doc §9 |
| **Prompt caching on stable context** | ✅ Used implicitly via Claude Code's caching of system prompt + CLAUDE.md. Maximize cache window per consuming-project `docs/SERENA.md` + the "session token discipline" section of CLAUDE.md. | Design doc §10 |
| **Parallel-safe decomposition + merge gate** | ⚠️ Partial — parallel agent invocations supported (Agent tool, parallel pattern in `AGENT_INVOCATION_RULES.md`), but no automated merge gate that re-validates the integrated result. Today the operator does the merge-validate manually. | Design doc §5.3 + §7 |
| **Circuit breaker (token budget + iteration cap)** | ⚠️ Partial — iteration cap = `slot_iteration_cap=6` is encoded in `policy/circuit_breaker.toml` and exercised by orchestrator. Token budget = `worker_tokens_budget = "inf"` and `gate_tokens_budget = "inf"` until E2.1 wires per-slot token capture. | Design doc §6 + §10 |

### Tools we evaluated and never wrote down (flagged honestly)

None surfaced by the doc-sweep. Every tool referenced in either 8CStudio `process-v2-research-2026-05-11.md` or `1M.3-oss-decisions.md` is captured above. If a tool comes up in conversation that's not here, ADD IT to this doc when the decision is made, don't leave it implicit.

---

## §2. Agents Built (the reusable agent catalog)

**Architectural reminder:** these are L2 capabilities. They live in this repo's `agents/*.md` and are **symlinked into each project's `.claude/agents/`** via `pe install`. Adding an agent to a project = `pe install` once, then the agent is invocable via Claude Code's Agent tool.

### Gate agents (Phase 3 escalation router emitters)

All 5 emit the **gate envelope** (machine-parseable JSON block with `verdict`, `failure_class`, `findings[]`, `confidence`, `model_used`) per `schemas/gate-envelope.schema.json`. Envelope drives the Phase 3 router's halt/escalate/continue decision.

| Agent | What it does | Lives at | Validation status | Install |
|---|---|---|---|---|
| **`code-reviewer`** | Reviews staged files for CRITICAL / HIGH / MEDIUM / LOW findings; emits gate envelope. Workflow gate — MANDATORY before any slot commit per consuming-project CLAUDE.md §9 step 5. | `agents/code-reviewer.md` → symlinked to project `.claude/agents/code-reviewer.md` | ✅ Battle-tested: 12 cohort invocations in Phase 3 graduation cohort, including the N=3 round-1 organic floor-fire (caught held HIGH on `missing-cross-tenant-isolation-test` that 2 of 3 reviewers held). | `pe install <project_path>` (auto-included in base install) |
| **`security-reviewer`** | OWASP / auth / payments / RLS / secrets review. Emits gate envelope with the same severity scale. | `agents/security-reviewer.md` → symlinked | ✅ Battle-tested: 4 cohort invocations + N=3 round 1 (correctly rated cross-tenant gap MEDIUM where other 2 held HIGH — the conditional-on-reviewer-calibration caveat in §9 was named here). Multiple convergent HIGH/MEDIUM findings across N=2 secret-handling slot. | `pe install` (auto-included) |
| **`database-reviewer`** | PostgreSQL schema / migration / RLS / tenant isolation review. Codebase-specific to projects using company-as-tenant + RLS (8CStudio architecture). Emits gate envelope. | `agents/database-reviewer.md` → symlinked | ✅ Battle-tested: 4 cohort invocations; surfaced held HIGH on N=3 cross-tenant isolation independently of code-reviewer. Note: assumes 8CStudio-style architecture (RLS PERMISSIVE per ADR-001, projection-layer cascade-rebuild) — re-evaluate the agent definition for projects with different multi-tenancy model. | `pe install` (auto-included) |
| **`tdd-guide`** | Enforces write-tests-first methodology; ensures 80%+ coverage including unit + integration + E2E. Emits gate envelope on test review. | `agents/tdd-guide.md` → symlinked | ⚠️ Adopted but rarely invoked in 8CStudio (per process-v2 Agent A: **0 invocations** before the gate-envelope adoption). Should be invoked PROACTIVELY when writing new features / bug fixes / refactoring per the system-prompt agent description. **Action item for fitness app:** wire trigger so it actually fires on new-feature slots. | `pe install` (auto-included) |
| **`e2e-runner`** | Vercel Agent Browser (preferred) with Playwright fallback. Generates + runs E2E tests, manages test journeys, quarantines flaky tests. | `agents/e2e-runner.md` → symlinked | ⚠️ Adopted but narrowed per process-v2 §6: invoke only when staging E2E flakes 2× in a row (deploy-staging.sh already runs E2E). Re-evaluate if browser-test complexity grows. | `pe install` (auto-included) |

### Supporting agents (non-gate; pipeline-stage roles)

| Agent | What it does | Lives at | Validation status | Install |
|---|---|---|---|---|
| **`brief-writer`** | Converts brainstorm notes → 1-page brief with alternatives + market check. MANDATORY before any feature implementation (consuming-project CLAUDE.md §9 step 0). | `agents/brief-writer.md` → symlinked | ✅ Used routinely (Wave 1M briefs, BACKLOG #189 invoice slot, shoot-log redesign). Step-0 invocation is the rule. | `pe install` |
| **`architect`** | Software architecture specialist — system design, scalability, technical decisions. Use when planning new features, refactoring large systems, or making architectural calls. | `agents/architect.md` → symlinked | ✅ Used in shoot-log redesign + Wave 1M.3 design + Wave 1K BreakdownProjector. RAG-indexed (consults `docs/research/` at step 0). | `pe install` |
| **`planner`** | Implementation planning for complex features and refactoring. Auto-activated for planning tasks. | `agents/planner.md` → symlinked | ✅ Used routinely. Wave 1M planner doc was canonical reference for graduation cohort N=3 slot selection. | `pe install` |
| **`researcher`** | OSS/MCP scout. Searches awesome-mcp-servers, Glama, PyPI/npm in that order per `OSS_SEARCH_ORDER.md`. Outputs 1-page eval doc. Can run in parallel with implementation. | `agents/researcher.md` → symlinked | ✅ Used for offline-mobile (Wave 1M), shoot-log industry scan, filename auto-increment. Direct input to brief-writer + architect. | `pe install` |
| **`ceo`** | Weekly retro orchestration. Cross-feature prioritization. Reads dev-log digests + Sentry + Process v2 triggers + backlog. Produces weekly plan. | `agents/ceo.md` → symlinked | ⚠️ Quarterly: shipped + working, but dev-log digest broken since 2026-05-10 (8CStudio BACKLOG #201) makes its input thin. Fix dev-log first to restore. | `pe install` + launchd wire-up via `./install_launchd.sh` for Friday 18:00 auto-trigger |
| **`doc-updater`** | Codemaps + documentation specialist. Runs `/update-codemaps` + `/update-docs`, generates `docs/CODEMAPS/*`, updates READMEs. | `agents/doc-updater.md` → symlinked | ✅ Working — runs on demand. Could be auto-fired monthly (1st Monday 09:00) per process-v2 §6 recommendation. | `pe install` |
| **`build-error-resolver`** | Build + TypeScript error resolution. Minimal-diff fixes, no architectural edits. | `agents/build-error-resolver.md` → symlinked | ⚠️ Adopted as escape hatch — invoke if same build fails 3× per process-v2 §6. Direct fix faster for one-shot errors. | `pe install` |
| **`memory-consolidator`** | Quarterly memory hygiene — archives resolved RESUME HERE blocks, dedupes index lines, flags stale entries, keeps MEMORY.md < 20 KB. | `agents/memory-consolidator.md` → symlinked | ✅ Used 2026-06-17 to consolidate 8CStudio MEMORY.md to current shape. Use quarterly OR when MEMORY.md > 25 KB / >1 RESUME HERE block. | `pe install` |
| **`retrospective-agent`** | Daily / weekly / monthly self-improvement retro. Reads `docs/dev-log/{daily,weekly}/*.json` digests, identifies process gaps, proposes CLAUDE.md / agent / process improvements. | `agents/retrospective-agent.md` → symlinked | ⚠️ Blocked on dev-log pipeline fix (8CStudio BACKLOG #201). Once fixed, run every morning after `run_daily.sh`. MUST implement ≥1 action per retro per consuming-project CLAUDE.md §9. | `pe install` + dev-log pipeline working |

### Project-domain-specific agents (8CStudio-only, not generic)

These live in `.claude/agents/` on 8CStudio but are NOT installed by `pe install` because they assume 8CStudio-specific architecture:

| Agent | Why 8CStudio-only |
|---|---|
| `data-model-auditor` | Generic in concept, but its current ruleset assumes Python/SQLite/PG models. Could be promoted to engine catalog if generalized. |
| `tenant-isolation-auditor` | Assumes company-as-tenant + RLS PERMISSIVE (per 8CStudio `docs/MULTI_TENANCY_USERS_ROLES_DESIGN.md`). Reusable for any project with the same multi-tenancy model. |
| `ui-ux-design-agent` | Assumes Tailwind + Alpine + Jinja stack + v0 budget discipline (Design Engine). Reusable for projects with the same stack. |
| `project-kickstarter` / `project-onboarder` | Meta-agents that scaffold projects + audit existing ones against standard rules. Could be promoted to engine catalog. |
| `claude-code-guide` / `statusline-setup` | Pure Claude Code UX agents — already user-global. |

---

## §3. "If a Project Needs X" pointers (vetted but not adopted — install instructions for later)

For tools the engine considered but didn't adopt today. Each row is a one-line pointer for a future project that needs the capability — NOT an integration plan to execute now.

| If you need... | Use | Install hint |
|---|---|---|
| **React-component scaffolding from text prompts** | v0 MCP (NOT adopted in 8CStudio due to Alpine lock) | `claude mcp add v0 -- npx -y @v0/mcp@latest` — only if project is React/Next.js native |
| **Async PR review (multi-developer queue)** | CodeRabbit CLI | `npm install -g coderabbit-cli` + GitHub app install. Only when in-session code-reviewer can't keep up. |
| **Multi-replica concurrent-edit conflict resolution** | AutoMerge (Python port) OR Yjs | `pip install automerge` or `npm install yjs` — only for true CRDT need (not 8Colors product line) |
| **Background sync with native API support** | Workbox `BackgroundSyncPlugin` 7.4.1 | `npm install workbox-background-sync@7.4.1` — currently deferred per 8CStudio BACKLOG #220 (Android Chrome usage threshold) |
| **DB replication framework (not just sync queue)** | RxDB OR PouchDB | `npm install rxdb` or `npm install pouchdb` — only if full client-side DB is needed (rejected in 8CStudio — Dexie + custom sync is sufficient) |
| **Visual FSM with dev-tools** | xstate | `npm install xstate @xstate/inspect` — only if state machine grows beyond ~5 states with nesting/parallelism |
| **Higher-quality embeddings than fastembed** | Gemini OR Voyage | `pip install google-generativeai` + `export GEMINI_API_KEY=...` OR `pip install voyageai` + key. Default fastembed is sufficient for <10k-doc corpora. |
| **Cross-app idempotency middleware** | Extract `8colors-idempotency` package from the existing Phase 1 helpers | Only after pattern is stable for 3+ months across apps (8CStudio + Lipi + vReview) per the trigger condition in 8CStudio `1M.3-oss-decisions.md`. |
| **Figma design-to-code workflow** | Already-configured Figma MCP | `claude mcp list` shows it connected — just invoke `/figma-use` skill. Adopt for any project with a Figma source-of-truth. |
| **Generic schema/model audit (not 8CStudio's data-model)** | Promote `data-model-auditor` agent to engine catalog | Generalize the ruleset → move from `8CStudio/.claude/agents/` to engine `agents/` → expose via `pe install`. ~1 hour. |
| **Tenant-isolation audit (any multi-tenant project)** | Promote `tenant-isolation-auditor` to engine catalog | Same shape as above. ~1 hour. |
| **Project scaffolding (new repos)** | Promote `project-kickstarter` to engine catalog | Same shape. Useful for fitness app onboarding actually. ~1 hour. |
| **Token-discipline / YAGNI as automated skill** (vs prose-only in CLAUDE.md) | Build a `token-discipline.md` skill that prepends YAGNI reminders to each worker prompt | New skill in engine `skills/` → installed via `pe install`. Defer until E2.1 cost telemetry exists; otherwise can't measure if the skill actually reduces tokens. Design doc §9 source. |
| **Automated security pentest behind a human checkpoint** | Build a scoped pentest worker that orchestrates DAST scanners (OWASP ZAP / Burp) against own systems only | Future engine capability per design doc §9: "human-assisted, not fire-and-forget." Triggers: pre-launch hardening; compliance audit; suspected vulnerability. NOT for general slot work. |
| **Auto-routing of starting tier (Haiku vs Sonnet vs Opus per task)** | Extend `policy/failure_class_routing.toml [ladder]` with task-type → starting-tier rules + wire orchestrator to honor them | Today operator picks starting tier manually; escalation path handles failed work climbing tiers. Auto-routing is a future engine enhancement (design doc §4 + §7) — defer until cost telemetry exists to validate the tier choices empirically. |
| **L0 knowledge-pack abstraction** (canonical project-config YAML/TOML the engine reads) | Define a `.process-engine.yaml` schema for tier policy + checkpoint definitions + scope boundaries + enabled tools | Design doc §8 + Phase 5 of the roadmap (§11). Today each project uses CLAUDE.md + MEMORY.md as ad-hoc knowledge pack. Formalize when onboarding a 3rd+ project — until then, ad-hoc is fine. |
| **Native multi-agent code review for high-stakes changes** | ALREADY DOCUMENTED: parallel `code-reviewer` + `security-reviewer` + `database-reviewer` invocation per `AGENT_INVOCATION_RULES.md` | Not a pointer — already in active use. Design doc §9 reference is realized today. |

---

## What this catalog does NOT do

- **Does NOT integrate anything** — pointers only.
- **Does NOT modify the engine** — engine stays at master `70177f7` (Phase 3 GRADUATED) untouched by this doc.
- **Does NOT bundle tools into engine core** — see Architecture Note at top. Each project picks what it needs via `pe install` + the per-project subset.
- **Does NOT lock decisions in stone** — re-evaluate triggers are listed where applicable. Anything in "rejected" or "deferred" can be revisited when the trigger condition fires.

---

## How to use this catalog

**Starting a new project (e.g., fitness app):**

1. `pe install [--subset gate-only|core|full] /path/to/fitness-app` — symlinks the chosen agent subset + commands + skills into the project's `.claude/`. Pick `gate-only` for the leanest install (5 gate agents), `core` (8) for the full brief→plan→review pipeline, `full` (default) for everything in the catalog.
2. Skim §1 to know what's already vetted; skim §3 for "I need X" pointers.
3. If you adopt a new tool not in this catalog, ADD A ROW when you decide — don't leave the decision implicit.
4. If you DON'T need a particular agent (e.g., fitness app has no PG → no `database-reviewer`), just don't invoke it. No need to uninstall.

**Adding a new capability to the catalog:**

1. Decide adopt/reject/defer with a 1-line rationale.
2. Add the row to the appropriate §1 table.
3. If it's a new agent installable via `pe install`, the agent's `.md` lives in this repo's `agents/` directory — DON'T copy it into the consuming project's repo; let `pe install` symlink it.
4. If the agent is project-domain-specific (assumes architectural facts of one project), keep it in that project's `.claude/agents/` and note "8CStudio-only" / "fitness-app-only" in the catalog row.

---

## Source-document pointers (for verification, not re-investigation)

| If you want to verify... | Read |
|---|---|
| **The canonical 5-layer architecture + non-negotiable principles + tiered routing** | **`../process-engine-enhancement-design.md`** (sibling to engine repo) |
| Why we rejected v0 / picked Sentry MCP / etc. | 8CStudio `docs/research/process-v2-research-2026-05-11.md` §2 |
| Why Pydantic + Workbox + Dexie chosen for 1M.3 | 8CStudio `docs/research/1M.3-oss-decisions.md` |
| The agent-chain matrix (which agents in which slot type) | `docs/AGENT_INVOCATION_RULES.md` |
| The OSS search order (awesome-mcp-servers → Glama → PyPI/npm) | `docs/OSS_SEARCH_ORDER.md` |
| Embedding provider trade-offs (fastembed / gemini / voyage / openai) | `docs/RAG.md` |
| Phase 3 graduation criteria + severity-floor + escalation-ladder semantics | `docs/PHASE_3_ESCALATION_ROUTER.md` |
| Gate envelope contract + schema | `docs/E1_GATE_ENVELOPE.md` + `schemas/gate-envelope.schema.json` |
| Enhancement roadmap (Phase 1-5, what's done vs deferred) | `../process-engine-enhancement-design.md` §11 |

---

**End of catalog.** Next time something is evaluated, ADD A ROW here so we never re-investigate it.
