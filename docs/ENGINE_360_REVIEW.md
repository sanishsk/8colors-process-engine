# Engine 360° Review — v0.45.0 (2026-07-05)

> End-to-end validation before pivoting the engine at real projects. Three parallel
> audits (retroactive-coverage, security-completeness, standards/correctness) +
> direct verification. **This is the fix-list for next session** — work top-down.
>
> **Headline:** the engine is genuinely strong and per-standards *for adopters*.
> 24/25 V2 items shipped, 32/33 shell tests green (the 1 fail is an in-progress
> A9.3 fixture header nit). The real gaps are not "is it built right" — they're
> two structural blind spots (validates NEW code not EXISTING; security is blind
> to logic-flaws) plus a dogfooding gap (engine doesn't gate itself).

---

## ✅ Confirmed FIXED since last session (don't re-audit)

- **sast-scan false-confidence** — no longer exits 0 silently when no SAST tool is
  installed + files are staged; it now BLOCKs (exit 1) naming the unscanned files.
- **Trailer duplication** — `hooks/_trailer-contract.sh` extracted; the 4 trailer
  hooks (code/security/design/perf) source it. DRY.
- **A4 auto-escalation loop** — SHIPPED v0.42.0 (`_run_a4_loop`, gated
  `--enforce --auto-execute --agent`, real `claude -p` invocation, first-fire
  evidence in `docs/incidents/A4_FIRST_FIRE.md`). *(An earlier note called this
  "partial" — that was a misread of the policy layer vs. the execution loop.)*

---

## 🔴 The two structural gaps that matter for pointing at real projects

### G1. FORWARD-ONLY: the engine validates NEW/changed code, not EXISTING code ⭐ #1
**This is the crux for 8CStudio (an existing app with existing debt).** Pre-commit
hooks constitutionally only see the staged diff. When installed on an existing
codebase, existing debt stays **invisible until someone edits that file**:
- Existing hardcoded secrets, 800-line functions, N+1s, insecure routes, ugly
  legacy screens → NOT caught on install.
- **Design specifically:** `design-critic` + `design-lint` only evaluate CHANGED
  templates. **There is no "audit all existing screens" command.** So "validate our
  existing look-and-feel" is not something the engine can do today.
- Only full-repo paths that exist: `duplication-gate` (full-tree, per-commit),
  `boot-smoke` (boots whole app), a ONE-TIME manual `project-onboarder` run, and
  weekly CI sweeps (gitleaks-history, trivy-fs) — **all advisory, non-blocking.**

**Fix (highest ROI): ship a `pe audit` full-repo mode.** One command that runs every
gate across the whole tree (not just staged), with a per-gate `--all` flag, and
crucially a **`design-critic --all-screens`** that sweeps every existing template.
Effort M. Without this, the design/security ceilings you built only apply to
tomorrow's code — the existing app is never scored.

### G2. SECURITY is blind to logic-dependent vulnerabilities (~10% genuine gap)
Static (engine SAST) + dynamic (ai-testing-agent DAST/ZAP) together cover ~60%
solid + ~30% partial. What they **systematically miss** (SAST can't see ownership
logic; needs multi-user orchestration or human review), ranked by risk:
1. **BOLA / object-level auth** (OWASP A01/API1) — CRITICAL for multi-tenant SaaS.
   `tenant-isolation-auditor` covers *tenant* scope; nothing checks *object* scope
   (user A reading user B's invoice within the same tenant). No gate.
2. **Rate-limit / anti-abuse enforcement** (A04/API3) — security-reviewer lists it
   as a checklist item; no detector. Missing rate-limit on /login = credential
   stuffing; missing idempotency on /pay = double-charge.
3. **Business-logic correctness** (state machines, idempotency, race conditions) —
   no tooling, human-review only.
4. **Model-DoS via token exhaustion** (LLM4) — no per-org token quota/ledger; a
   hosted-agent-SaaS availability threat.

**Fix:** these need NEW gates (BOLA multi-user journeys in the agent; a semgrep
rate-limit-decorator rule; a token-quota ledger) OR an explicit "human security
review required for auth/payment/multi-tenant" gate. Until then, **the honest
posture is: the engine catches injection/secrets/crypto/tenant-isolation well, and
you must NOT assume it catches access-control or business-logic flaws.** Name that
in the security-reviewer output so it's not silently over-trusted.

---

## 🟡 Real but smaller issues (fix-list)

| # | Issue | Severity | Fix | Effort |
|---|---|---|---|---|
| I1 | **Engine doesn't gate itself** — its own commits carry no `Code-reviewed:`/`Design-reviewed:` trailers; engine code touching agents/hooks/scripts lands ungated. Ironic for a gating tool. | HIGH | Add engine-repo `prepare-commit-msg` running its own review, OR document a PR-review exemption explicitly. | S |
| I2 | **Gate tests validate envelope SHAPE, not finding CORRECTNESS** — a fixture asserts the envelope parses, not that `findings[].rule == "the-right-rule"`. A gate that stops naming the right issue would still pass all tests. | MEDIUM | Add `assert findings[0].rule == <expected>` to the corpus fixtures; enable live-mode gate-efficacy (precision/recall) now that A4 exists. | M |
| I3 | **A4-escalated envelopes not persisted to `.claude/gates/`** — auto-escalation writes to `.pe/a4-runs/` but not the gates registry; a later trailer/`pe recall` misses the escalation outcome. | MEDIUM | After `pe gate parse` on the escalated envelope, also write `.claude/gates/<sha>.json`. | S |
| I4 | **A9.3/A9.4 fixture header nits** — 2 in-progress fixtures use `# <description>` not `# <slug>`; fails `test_gate_efficacy.sh` shape check. Logic is fine. | LOW | Rename first line to the slug; commit the WIP. | S |
| I5 | **`pe verify` supply-chain doesn't cover `.claude/gates/*.json`** — a poisoned gate-verdict record post-install isn't caught. | LOW | Add gates-registry to the manifest, or document it's out of scope. | S |

---

## What's genuinely SOLID (validated, don't touch)

- **Discipline layer:** 30 hooks, consistent exit codes (0/1/2), uniform `PE_SKIP_*`,
  uniform tool-absence handling, all 6 gate agents follow `_gate-contract.md`, no
  reviewer agent has Write/Edit, version sync clean (`pe docs check` green).
- **A6 domain modules** (auth/tenancy/billing/api-credentials): real FORCE-mode RLS,
  real Stripe HMAC + idempotency + server-side amount authority, tested. The
  "less code, fewer vulns" payoff is real.
- **A1/A2/A3/A7/A8:** telemetry (real token/cost), eval corpus, incident-synthesizer
  (proposes-not-applies), FTS5 hybrid memory, native plugin pinning — all solid.
- **Security STRENGTHS:** injection/secrets/crypto (SAST ~90%), tenant-isolation
  (~95%), LLM supply-chain via `pe verify` (~95%), prompt-injection via
  transcript-guard (~85%). Better LLM-threat coverage than most tools ship.
- **Test quality:** strong on wiring/shape/contract (see I2 for the one weakness).

---

## Recommended next-session order

1. **G1 `pe audit` full-repo mode + `design-critic --all-screens`** — unblocks
   pointing the engine at 8CStudio's *existing* code and design. Without it the
   whole review/design investment only touches new code.
2. **I1 dogfooding** — make the engine gate itself (cheap, closes the credibility gap).
3. **G2 security honesty + BOLA gate** — at minimum, have security-reviewer state
   "access-control/business-logic NOT auto-verified — human review required on
   auth/payment/multi-tenant paths"; then build the BOLA journeys gate.
4. **I2/I3/I4/I5** — the small correctness/test-quality items; batch them.
5. **A9.3 finish** (commit the WIP + header fix), then the engine is at a clean stop.

**Then pivot to the product** (8CStudio #227). The engine is more than ready; these
are refinements, and G1 is the one that materially changes what the engine can do
*for the existing app you're about to point it at*.
