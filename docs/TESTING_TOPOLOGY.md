# Testing Topology — engine ⟷ ai-testing-agent division of labor

> **Date:** 2026-07-03 · **Purpose:** the single authoritative statement of
> *which layer owns which check*, so engine work never rebuilds what the
> testing-agent already does (and vice-versa). Read this before building any
> new S / PF / D item. Ties to `ENHANCEMENT_PLAN_V2.md` and
> `AI_TESTING_AGENT_VALIDATION.md`.

## The model — two axes, one rule

There are two orthogonal axes, and they cleanly separate the two codebases:

| | **Engine (`8colors-process-engine`)** | **Testing-agent (`ai-testing-agent`)** |
|---|---|---|
| **When** | commit-time (pre-commit / pre-push hooks) | on-demand / CI (needs a running app) |
| **What** | STATIC — reads the diff & source | DYNAMIC — probes a live `base_url` |
| **How** | deterministic gates + judgment agents | executes tests, returns structured results |
| **Owns** | orchestration + the **verdict** | **execution** of the heavy runtime testing |

**The rule:** *if a check needs a running application, it belongs to the
agent; if it reads source or the diff at commit-time, it belongs to the
engine. Never build the same check on both sides.* The engine calls the
agent's MCP tools (`mcp__ai-testing-agent__*`) and judges the results — it
does not re-implement dynamic probing, fuzzing, load, resilience, visual
diffing, or api-diffing.

This is why A9 was worth doing: it makes the agent's 38k LOC the **execution
tier** and keeps the engine the **policy tier**. They are complementary, not
redundant.

## Security coverage

The honest shape: the engine does **static** security (source analysis at
commit); the agent does **dynamic** security (payloads against a live app).
Neither alone is sufficient; together they cover both halves.

| Concern | Engine (static / commit) | Agent (dynamic / runtime) | Who owns it |
|---|---|---|---|
| Vuln patterns in source (injection sinks, unsafe eval, crypto) | **S1** `sast-scan.sh` (semgrep + bandit + gosec) ✅ | — | **Engine** |
| Security judgment on the diff | **S2** `security-reviewer` ✅ | — | **Engine** |
| Live injection / XSS / SSRF / command probes | — | `run_security_scan` (OWASP API Top-10 payloads) ✅ | **Agent** |
| Deep DAST (spider + full passive ruleset) | — | `run_dast_scan` (OWASP ZAP baseline) ✅ | **Agent** |
| Auth-bypass probing (missing/empty/malformed/wrong-scheme token) | — | `run_security_scan` auth journeys ✅ | **Agent** |
| BOLA / rate-limit / mass-assignment / CORS / method-tampering | — | `run_security_scan` journeys ✅ | **Agent** |
| Property/spec fuzzing | — | `schemathesis` + `hypothesis` ✅ | **Agent** |
| Breaking API change | **A9.2** `api-contract-check.sh` (calls `ai-test api-diff`) ✅ | `compare_api_specs` (same differ) ✅ | **Engine gate, agent differ** |
| Dependency / CVE (SCA) | `deps-audit` (pip-audit/npm-audit) ✅ | — | **Engine** |
| Secrets in the diff | `secrets-scan` (gitleaks) ✅ | — | **Engine** |
| Auth/payment/webhook **test templates** (HMAC, amount authority) | **S3** pytest templates — *engine ships them* | agent *runs* the resulting tests | **Engine (templates), agent (exec)** |
| **LLM / agent threat** (prompt-injection, transcript secret-scrub, `pe verify`) | **S4** — *engine only* | ❌ nothing | **Engine** ⚠️ agent has zero coverage |
| Container / IaC / secrets-history depth | **S5** | ❌ | **Engine** |
| Tenant-isolation (cross-tenant leak) | **S6** `tenant-isolation-auditor` | ❌ | **Engine** |

**Verdict on "are the security checks good enough?"** Materially stronger now.
The built-in `run_security_scan` is still a shallow *probe* (~2 payloads at the
first writable endpoint per category), but `run_dast_scan` (OWASP ZAP baseline —
**SHIPPED 2026-07-03**) adds real spider + full-passive-ruleset DAST depth on
top. Combined with the engine's static SAST + SCA + secrets, that is a genuine
security battery (static + probe + deep DAST). The remaining structural gap is
**S4** — the agent covers *none* of the
LLM/agent-threat class, which is the scariest for SaaS built *by* agents.

## Performance coverage

| Concern | Engine (static / commit) | Agent (dynamic / runtime) | Who owns it |
|---|---|---|---|
| Endpoint latency SLA (p95 budget) | — | `ai-test perf --threshold` ✅ | **Agent** |
| Load / stress baseline ("50 VUs, p95<X, 0 err") | — | Locust gen + concurrent-load ✅ | **Agent** (PF5 delegates here) |
| Resilience (timeout / retry / concurrent / error-rate) | — | `run_resilience_tests` ✅ | **Agent** |
| Cache-behaviour validation | — | `CacheTestGenerator` ✅ | **Agent** |
| **N+1 / query-count regression** ⭐ | **PF1** in-process query-count pytest template ✅ (`templates/tests/query-count.test.py.template`) | latency proxy ✅ (`generate_n_plus_one_journeys`, list-vs-detail ×5) | **BOTH — complementary** (see note) |
| Unbounded-query / missing-index (static) | **PF2** semgrep + `database-reviewer` | — | **Engine** |
| Frontend budgets (LCP/TBT/bundle) — Lighthouse | **PF3 / D2** Lighthouse CI | — | **Engine** |
| Perf judgment on the diff (blocking work, algo complexity) | **PF6** `performance-reviewer` (judgment) | supplies the runtime evidence | **Engine gate, agent exec** |
| Memory-leak / soak | **PF4** | ❌ *(chaos runner extensible)* | NEITHER — candidate for agent |

**Verdict on "are the performance checks good enough?"** Latency + load +
resilience + cache is a decent runtime battery, and **N+1 / query-count (PF1)
is now covered on BOTH sides — correctly split.**

> **CORRECTION (2026-07-03):** an earlier draft of this doc said "build N+1 in
> the agent (A9.4)." That was wrong. A **black-box** HTTP client physically
> cannot count the SQL a single request emits — it only has a *latency proxy*
> (list-vs-detail ×5), which the agent **already ships**
> (`generate_n_plus_one_journeys`). Real query-count detection is **inherently
> in-process**, so it lives as an **engine** pytest template the adopter runs
> in its own suite (`templates/tests/query-count.test.py.template`, SQLAlchemy
> + Django variants — **SHIPPED**). Correct split: **engine = the real detector
> (in-process count); agent = complementary black-box latency smoke.** Neither
> replaces the other; nothing to "build in the agent" here.

Lighthouse (frontend) remains the one genuine perf hole and stays engine-side
(shared with D2 a11y).

## What this means for engine load (the "don't rebuild it" list)

These plan items are now **DELEGATED to the agent** — the engine should
*call* the tool and judge, not build the runtime harness:

- **PF5 (load baseline)** → `run_resilience_tests` / Locust in the agent. Don't build a second k6 harness.
- **PF6 (performance-reviewer)** → keep the *agent* (judgment) in the engine, but its runtime evidence comes from the agent's resilience/perf tools.
- **PF1 (N+1)** → **SPLIT, not delegated.** Engine owns the real in-process
  query-count template (SHIPPED); the agent's latency-proxy smoke already exists.
  Do not "build it in the agent" — that was a corrected error (see the note above).
- **S3 (dynamic auth probing)** → the agent's `run_security_scan` covers the *runtime* half; the engine only ships the pytest **templates** + the security-review path-gate.
- **D3 (visual regression)** → `run_visual_regression` in the agent; engine wires the design-critic to call it.

These stay **engine-only** (static / commit-time / policy — the agent cannot
do them): S1, S2, PF2, PF3-Lighthouse, S4, S5, S6, api-contract *gate*,
deps-audit, secrets-scan, and every judgment agent (as a thin orchestrator).

## OSS tools to add (prioritized — power-ups, not duplication)

Only tools that fill a *real* gap and don't duplicate something already
present (semgrep, bandit, schemathesis, locust, playwright, deepdiff,
pact are already integrated):

1. ~~**OWASP ZAP** (baseline/active scan) → agent~~ — ✅ **SHIPPED 2026-07-03**
   as `run_dast_scan` / `ai-test dast` (feature-detected ZAP binary or Docker,
   graceful advisory when absent). Was the biggest single security upgrade.
2. **`nplusone`** (Python, SQLAlchemy/Django) → **engine template** (NOT the
   agent). It's an *in-process* ORM hook, so it belongs in the adopter's own
   test suite via `templates/tests/query-count.test.py.template` (already
   shipped with hand-rolled counters). The agent cannot use it — it's out of
   process.
3. **Lighthouse CI** → **engine** (PF3 + D2). Frontend perf + a11y budgets;
   nothing else covers the frontend. Shared gate.
4. **Trivy** (or Grype) → **engine** (S5). Container + broader SCA + IaC +
   secrets-history — deeper than `deps-audit`'s pip/npm-audit.
5. *(Optional)* **Nuclei** → agent, for known-CVE template scanning if ZAP
   isn't enough.

**Do NOT add:** a second load tool (Locust is enough — the plan's k6 mention
should defer to it), a second SAST (semgrep covers it), or a second fuzzer.

## The one-line policy

> **Static & commit-time & judgment → engine. Dynamic & runtime & execution →
> agent. The engine calls the agent and owns the verdict. Build each check
> once, on the side that matches its axis.**
