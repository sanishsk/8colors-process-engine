# Operator Workflow V3 — the Fable-5-era operating model

> **Date:** 2026-07-02 · **Status:** proposed → adopt section-by-section
> **What this is:** an evidence-based analysis of how the operator has been
> using Claude Code across all projects, plus the new operating model for the
> Claude 5 era. Written so Opus/Sonnet can implement every checklist item
> without re-deriving the analysis. Companion to `IMPROVEMENT_PLAN.md`
> (P5/P6/P7 reference this doc).
> **Scope:** not just coding — testing, design, product, cadence, and safety.

---

## 1. What the usage analysis found (evidence first)

Measured on this machine, 2026-07-02:

| # | Finding | Evidence | Impact |
|---|---|---|---|
| 1 | **~25k tokens of always-loaded context per turn.** 8CStudio `CLAUDE.md` = 74KB (~19k tok); global `~/.claude/CLAUDE.md` + 11 rules files = 22KB more. Re-processed on EVERY turn of EVERY session. | `wc -c` on the files | This — not session length — is why the weekly cap got hit on day 5 (2026-05-14 incident). The CLAUDE.md "token discipline" section fights the symptom while its own host file is the cause. ~30 turns × 25k = 750k tokens/session of pure overhead. |
| 2 | **CLAUDE.md is a changelog, not an instruction file.** The top ~150 lines are Wave 1L/1M milestone narratives duplicated from session docs; model guidance inside it is stale (recommends Sonnet 4.6/Opus 4.5). | CLAUDE.md lines 1-30, performance.md | Instructions the model must obey are buried in history it must skim. Stale routing = wrong model choices. |
| 3 | **The feedback loop is dead.** Last dev-log digest: 2026-W21 (~6 weeks ago). The Friday CEO retro — the engine's flagship cadence — has been running on empty/stale input. | `docs/dev-log/daily/` listing; engine P2.5 | The system designed to catch process drift has itself drifted, silently. No one noticed — which is itself the finding. |
| 4 | **Skills/agents sprawl.** 67 global skills (ECC wholesale) + 15 global agents + project copies; four skills appear twice (user+project); `~/.claude/agents/code-reviewer.md` is a stale May fork WITHOUT the envelope contract (shadows the engine gate in un-symlinked projects — caused the E1_b incident class). | `ls ~/.claude/skills|agents`; engine P2.10 | Choice paralysis for the router, silent gate-shadowing, and maintenance surface nobody audits. |
| 5 | **Discipline exists but concentrates on process, not environment.** Envelope contract, slot rhythm, session logs, HANDOFF docs are genuinely good. But the 8CStudio local env couldn't boot (4 independent failures, undetected for months) and prod-only table creation meant no model could ever verify its work locally. | PRODUCT_RESTRUCTURE_PLAN §4.3 | Agents "verified" work in an environment where verification was impossible → false confidence, and cheap-model implementation of the restructure plan would have failed at step 1. |
| 6 | **Modern primitives unused.** No worktree parallelism, no headless `claude -p` batch runs, no background agents in the documented workflow; everything is serial interactive sessions with the operator as the event loop. | CLAUDE.md workflow sections | The operator's time is the bottleneck; mechanical work (template migration, lint fixes) occupies interactive sessions it doesn't need. |
| 7 | **What's working — keep it:** feature-branch + staging→prod gates, per-slot session docs, gotchas.md as institutional memory, brief→architect→planner pipeline, Sentry ritual, backups awareness, the instinct to extract patterns into the engine (this repo). | throughout | V3 builds on these, it does not replace them. |

---

## 2. Context diet (do this first — it pays for everything else)

**Rule: CLAUDE.md is an instruction file with a token budget. History lives
elsewhere. Anything loadable-on-demand must not be always-loaded.**

Checklist (Sonnet-implementable, ~half a day):

- [ ] **8CStudio CLAUDE.md → ≤300 lines / ≤12KB.** Move: milestone
      narratives → `docs/PHASE_HISTORY.md` (already exists for older ones);
      module pointers table stays (it's cheap and load-bearing); double-margin
      spec stays (business-critical); session-token-discipline section shrinks
      to 3 lines once the file itself is small. Keep: rules, commands,
      pointers. Test: a new session can still find everything via pointers.
- [ ] **Global rules → skills.** `~/.claude/rules/common/*.md` (testing,
      performance, patterns, api-credentials, hooks, agents…) become
      on-demand skills or get folded into the engine's agents. Keep in global
      CLAUDE.md only: boundaries table, security absolutes, data-model rules
      (~60 lines total).
- [ ] **Dedupe skills:** remove the 4 user/project duplicates; run
      `/skill-stocktake`; target <20 curated global skills. ECC extras get
      uninstalled, not hoarded — they're reinstallable.
- [ ] **Reconcile `~/.claude/agents/`** per engine P2.10: delete or symlink
      stale forks (the shadow-gate hazard).
- [ ] **Wire `hooks/claude-md-size.sh`** (exists, unwired) as a real hook:
      warn at 12KB, fail at 20KB. The diet must be enforced or it regrows.
- [ ] **Update stale model guidance** everywhere it appears (global
      performance.md, engine yaml `claude-opus-4-7` pin) per §3.

Expected effect: ~15-20k tokens saved per turn in 8CStudio sessions →
roughly **2-3× more work per weekly cap**, faster turns, better cache hits.

---

## 3. Model routing — Claude 5 era

Replace all older routing tables with this one:

| Tier | Model | Use for | Engine mapping |
|---|---|---|---|
| **Judgment** | **Fable 5** | Audits, architecture, design direction, product strategy, root-cause debugging that resists one attempt, retro synthesis, anything where being *wrong quietly* is expensive | architect, ceo/retro, security gate on foundational slots, "session 1" of any new initiative |
| **Heavy build** | **Opus 4.8** | Foundational implementation: RLS/tenancy, auth flows, payment paths, migration engines, multi-file refactors with tricky invariants | impl agent on `foundational: true` slots (the no-stacking class) |
| **Default build** | **Sonnet 5** | Everyday feature slots, tests, reviews on non-foundational paths | impl + most gates |
| **Mechanical** | **Haiku 4.5** | Template/token migrations, lint-driven fixes, doc moves, rename sweeps — anything with a deterministic verifier behind it | batch work via headless runs (§4) |

Routing rules of thumb:
- The **verifier determines the floor, not the task**: mechanical work is
  Haiku-safe *only because* design-lint/tests/jscpd catch failures
  deterministically (IMPROVEMENT_PLAN P5/P6). No deterministic verifier →
  route one tier up.
- **Escalation ladder stays** (engine failure-class routing): retry same tier
  once → one tier up → operator. Never argue with a red gate.
- **Fable 5 is the planner, not the typist.** Its output for a big initiative
  is briefs/specs/slot lists that cheaper models execute — exactly how
  PRODUCT_RESTRUCTURE_PLAN and this doc were produced.

---

## 4. Session & execution patterns

**4.1 The three lanes.** Classify every piece of work into a lane before
starting; the lane picks the pattern:

| Lane | Pattern | Example |
|---|---|---|
| **Judgment** (new territory, taste, risk) | Interactive session, plan mode first, Fable/Opus, operator engaged | Design direction A+.2, RLS FORCE flip, pricing |
| **Standard slot** (known shape) | Interactive or background agent; brief exists; engine pipeline brainstorm→brief→architect→plan→tdd→impl→simplify→review | A typical 1X.N feature slot |
| **Mechanical batch** (deterministic verifier exists) | **Headless**: `claude -p` per work-item, or one session driving a worktree fleet; gates decide, operator reviews the diff summary once | A2 template migration (20 templates), lint remediation, copy lint fixes |

**4.2 Worktrees for parallelism.** Mechanical batches and independent slots
run in `git worktree` copies so they can't trample each other or the
operator's working tree. One orchestrating session fans out, collects
diffs, runs gates, and presents ONE review to the operator. (This replaces
"operator as event loop".)

**4.3 Headless batches.** For N similar items:
`claude -p "<tight brief + reference + DoD>" --allowedTools ...` per item
(or the Agent SDK), each followed by the deterministic gate. Items that fail
their gate get one retry, then queue for the interactive session. The
operator's involvement: write the brief once, review the batch report once.

**4.4 Session hygiene (updated, replaces the old 40-turn rule-of-fear):**
- Open with `/start-session`; close with `/end-session` (both shipped).
- One slot per session stays. But with the §2 context diet, the binding
  constraint becomes *focus*, not tokens — compact at phase boundaries
  (autocompact is already set at 70%), don't ration turns.
- Plan mode for anything touching >3 files or any foundational path.
- Every session's last act: update HANDOFF/session doc (already habit — keep).

**4.5 Verification is environmental, not rhetorical.** A model saying "done"
counts for nothing; a gate passing counts. Priority order for making this
real: boot-smoke (P5.1) → tests (P1.2, shipped) → design lint (P5.3) →
console/route smoke (P5.5). **A cheap model + a strong verifier beats an
expensive model + no verifier.**

---

## 5. Beyond coding — the full-lifecycle guardrails

**Testing:** keep the pyramid (`TEST_PYRAMID.md`) and add the audit-derived
gates: boot-smoke, migration-chain-on-empty-DB, console-error smoke, 375px
viewport check, auth-adversarial template (IMPROVEMENT_PLAN P5.1/2/5/8).
Longer term: seeded-defect eval harness (P3.5) so gate quality is measured,
not assumed.

**Design:** tokens v2 + reference board are the law (PRODUCT_RESTRUCTURE_PLAN
Phase A+); design-lint (P5.3) enforces deterministically; ui-ux agent reviews
with the AI-aesthetic tells rubric (P5.9); v0 budget stays (1 prompt/module).
Implementation prompts say "match the locked reference", never "make it
professional".

**Product:** no new modules/features without a brief AND a named revenue gate
(PRODUCT_RESTRUCTURE_PLAN §5.4). The wedge order (Lipi → vReview → Kadha →
bundle) is the sequencing authority; the weekly CEO retro checks work against
it and flags drift.

**Code simplicity:** Ponytail at generation time; ruff-C901/xenon/vulture/
knip/jscpd at commit time; `/simplify` stage after green tests
(IMPROVEMENT_PLAN P6). The retro trends net-LOC, duplication %, complexity
grade — "are we getting simpler" becomes a number.

**Security:** unchanged absolutes (global rules) + engine P3.9 additions
(auth-flow + payments checklists, per-stack scanners, tenant-isolation
auditor generalized).

**Data/ops safety:** fix the broken launchd backup (move to server-side cron
+ weekly restore drill — also PRODUCT_RESTRUCTURE_PLAN B4); `pe doctor --all`
across adopters once P3.12 lands; version-pinned engine installs before any
beta widening (P3.3).

---

## 6. Cadence (the loop that keeps V3 alive)

| When | What | Input | Output |
|---|---|---|---|
| Session start | `/start-session` + Sentry ritual | MEMORY, HANDOFF, calendar | first task |
| Per slot | engine pipeline + gates (now incl. simplify) | brief | merged slot + envelope |
| Daily 08:00 (automated) | dev-log collector — **fix first (P7.3): it's been dead since W21** | transcripts/git | daily digest |
| Friday 17:00 | CEO retro — reads digests + gate envelopes + LOC/duplication trends | week's data | weekly plan + drift flags |
| Monthly | skills stocktake + memory consolidation + `pe doctor` + restore drill | — | pruned config, verified backups |
| Quarterly | this doc + IMPROVEMENT_PLAN review: what did the gates miss? Convert every miss into a new P5-class check | audits | updated plans |

The quarterly rule is the engine's real growth mechanism: **every incident
becomes a check, every check becomes portable.** That's the path from
"process discipline" to "the future is safe": not more rules to remember —
fewer things that depend on anyone remembering.

---

## 7. Implementation order (hand this to Opus/Sonnet)

1. **Day 1 (Sonnet):** §2 context diet — CLAUDE.md slim, rules→skills,
   dedupe, wire size hook, update model tables. Verify: new 8CStudio session
   starts with <15KB project context.
2. **Day 1 (Sonnet, same sitting):** unstall the retro (P7.3) — collector fix
   or git-derived degraded mode; run `/retro` on the backlog gap as its
   first real input.
3. **Day 2 (Sonnet):** P6.1 Ponytail install + P6.2 complexity/dead-code/
   duplication gates in the engine templates; run baseline numbers on
   8CStudio so the ratchet has a starting point.
4. **Week 1 (Opus):** P5.1 boot-smoke + P5.2 migration-lint + P5.3
   design-lint — the three gates the product audit proved were missing.
5. **Week 2 (Sonnet):** P5.5 console/route smoke + P5.6 nav budget + P5.7
   copy lint + P6.3/P6.4 LOC budgets + simplify stage in `/new-feature`.
6. **Then:** resume PRODUCT_RESTRUCTURE_PLAN Phase A0/A+ in 8CStudio — now
   executed *under* the new gates, as the first honest test of V3.

**Definition of success (3 months):** weekly cap never hit at equal output;
zero silent-failure incidents (everything fails loud); duplication % and
complexity trending down; one mechanical batch shipped via headless worktrees
end-to-end; retro ran every Friday on real data.
