# Session Handoff

> **Rolling doc — rewritten at each session end.** Read this at the top
> of your next session (after `/start-session`) to orient in <2 minutes.
>
> **Last updated:** 2026-07-04 (v0.41.0 shipped — D8
> signature-system gate. hooks/signature-lint.sh + design-critic
> tell #9 upgraded to HARD FAIL on flagship screens when
> docs/design/SIGNATURE.md declares signature tokens. Opt-in per
> adopter (no SIGNATURE.md → gate inert). templates/design/
> SIGNATURE.md.template documents the declaration format;
> install.sh drops it into docs/templates/design/. hooks count
> 16 → 17. Twenty-two V2 items shipped, one PARTIAL (A4 loop).
> D-row progress: D1+D2+D4+D5+D6+D7+D8 shipped — design ceiling
> wave COMPLETE. D3+A9.3 remain (visual-regression, tool wiring).)

---

## Current state — v0.41.0 (`7911b8f` → `<v0.41.0 sha>` this session)

**V2 progress against `docs/ENHANCEMENT_PLAN_V2.md`:**

| Item | Status | Release |
|---|---|---|
| S1 SAST hook | ✅ SHIPPED | v0.17.0 |
| S2 Python-first security-reviewer | ✅ SHIPPED | v0.17.0 |
| S6 tenant-isolation-auditor cron | ✅ SHIPPED | v0.25.1 |
| D1 design-critic agent | ✅ SHIPPED | v0.18.0 |
| D2 a11y + Lighthouse a11y | ✅ SHIPPED | v0.18.0 |
| D4 spacing/radius/shadow tokens | ✅ SHIPPED | v0.25.1 |
| PF3 perf budgets | ✅ SHIPPED | v0.18.0 |
| PF2 static perf gate | ✅ SHIPPED | v0.18.1 |
| A1 telemetry parser | ✅ SHIPPED | v0.19.0 |
| A2 gate-efficacy corpus | ✅ SEEDED (5 gates + holdout subcorpus) | v0.19.0 → v0.25.1 |
| L1 OTel spans + tool-call tree | ✅ SHIPPED | v0.25.1 |
| L2 trajectory + held-out corpus | ✅ SHIPPED | v0.25.1 |
| L4 retro cost surfacing | ✅ SHIPPED | v0.25.1 |
| TOK1 prompt-cache hygiene | ✅ SHIPPED | v0.25.1 |
| TOK2 read hygiene | ✅ SHIPPED | v0.25.1 |
| A3 incident synthesizer | ✅ SHIPPED | v0.22.0 |
| A4 exec primitive + auto-escalation loop | ⚠️ PARTIAL — primitive shipped v0.21.0; **auto-escalation loop MISSING** (cmd_decide records shadow decision but invokes nothing) | v0.21.0 (primitive) |
| A5 Ponytail universal prereq | ✅ SHIPPED | v0.23.0 |
| L3 memory governance | ✅ SHIPPED | v0.24.0 |
| A6 scaffold + api-credentials + auth + tenancy + billing | ✅ SHIPPED (module library COMPLETE) | v0.25.0 → v0.28.0 |
| S3 auth/payment/webhook pytest templates + test-evidence gate | ✅ SHIPPED | v0.29.0 |
| S4 transcript-guard + pe verify (LLM/agent threat hardening) | ✅ SHIPPED | v0.30.0 |
| S5 container + secrets-history + license CI gates | ✅ SHIPPED | v0.31.0 |
| A7 cross-session agent memory (pe recall + FTS5 hybrid + retro §7b) | ✅ SHIPPED | v0.32.0 |
| A8 native plugin manifest + per-project version pin | ✅ SHIPPED | v0.33.0 |
| PF1 perf-gate commit-msg trailer (query-count enforcement) | ✅ SHIPPED | v0.34.0 |
| PF4 soak template (RSS-slope + gc-reclaim + tracemalloc) | ✅ SHIPPED | v0.35.0 |
| PF5 k6 load template + workflow_dispatch CI job | ✅ SHIPPED | v0.35.0 |
| PF6 performance-reviewer agent (judgment 20% gate) | ✅ SHIPPED | v0.37.0 |
| D5 design-critic ceiling mode (Awwwards scoring, stub refs) | ✅ SHIPPED | v0.38.0 |
| D6 motion-craft gate (motion-lint + prefers-reduced-motion + effect-stacking + critic rubric) | ✅ SHIPPED | v0.39.0 |
| D7 curated visual reference library + Style Dictionary token pipeline + /design-scan ritual | ✅ SHIPPED | v0.40.0 |
| D8 signature-system gate (signature-lint + SIGNATURE.md template + design-critic tell #9 HARD FAIL on flagship) | ✅ SHIPPED | v0.41.0 |

**PARTIAL count: 1** — A4's auto-escalation loop.
Every other V2 item is either SHIPPED, GATED with a named
prerequisite, on a specific release queue, or explicitly not yet
started.

**Not started yet:** A9 higher tiers, D3 (visual-regression),
A9.3 (visual-regression tool wiring).

## 🔴 RESUME HERE — first action next session

1. **Adopters need to be re-installed at v0.41.0** —
   `hooks/signature-lint.sh` lands + wires into
   `.claude/settings.json` PostToolUse and
   `.pre-commit-config.yaml` (hooks count 16 → 17).
   `templates/design/SIGNATURE.md.template` lands in
   `docs/templates/design/` via install.sh. The gate is
   **opt-in** — no `docs/design/SIGNATURE.md` in adopter project
   → gate is inert (no behavior change). Adopters who declare a
   SIGNATURE.md get the flagship-path enforcement.
   Bypass: `PE_SKIP_SIGNATURE_LINT=1`.

2. **Continue V2 per remaining priority order** (operator's call
   each release):

   - **A4 completion** — orchestrator auto-escalation loop.
     Consumes the `pe agent run` primitive shipped in v0.21.0.
     Requires `--auto-execute` flag gated by `--enforce` (still
     `tested = false` per §9 watchpoint). Ship AFTER first-fire
     evidence on enforce-mode.
   - **D3 + A9.3** — visual-regression baselines (D3) and
     wiring the orphaned `run_visual_regression` MCP tool into
     design-critic (A9.3). Requires a Percy/Chromatic account or
     equivalent — pick one, wire the CI job, add the trailer
     gate. This is what's left of the D-row after v0.41.0
     completes the design ceiling wave.
   - **D3 + A9.3** — visual-regression baselines + wiring the
     orphaned `run_visual_regression` MCP tool into the critic.
   - **A4 auto-escalation loop** — the loop itself (status
     honesty landed v0.36.0; implementation is a future release).
   - **TOK3** — terse-output mode for mechanical agents (real
     token win, deferred).
   - **A9 higher tiers** — extend the shadow-decide primitive
     with more test-generation + eval tiers.
   - **D3** — visual-regression (Percy / Chromatic wired into
     Playwright).
   - **A6 extensions** — module library baseline is COMPLETE
     (scaffold + api-credentials + auth + tenancy + billing all
     shipped). Only extensions remain deferred: email flows
     (verify + password-reset), Razorpay adapter, subscription
     billing. Each ships when a real adopter needs it.
   - **A7** — cross-session agent memory (retrieve prior decisions +
     RAG upgrade to SQLite FTS5 hybrid). Depends on A1, A2 —
     unblocked now.
   - **PF1** — runtime N+1 gate via query-count assertions.
     Complements PF2's static gate.
   - **PF4/PF5** — soak + load templates (perf-reviewer agent
     PF6 covers these as a package).
   - **A8** — native Claude Code plugin migration (before widening
     the beta).

3. **8CStudio #227 dev-env repair** — deliberately deferred until
   V2 items settle per operator direction. Product tests can
   proceed with 8CStudio / Origyn while V2 continues.

## Real-project validation (v0.23.1 live-mode smoke — 2026-07-03)

Live-mode gate-efficacy invoked end-to-end against the real
Anthropic API caught two silent-zero bugs in `pe agent run`'s cost
accounting (fixed as v0.23.1, 5 regression tests added, verified
with second live invocation). Total live-mode spend so far: **$0.28**.

- 8CStudio: `pe telemetry collect` → 3475 turns, ~$2309 grand total
- Origyn: `pe telemetry collect` → 454 turns, ~$332 grand total
- security-reviewer/pass-parameterized-orm live: correct PASS
  verdict, cost $0.150 accurate

## Historical: what shipped in earlier waves

The v0.17.0 → v0.25.0 sequence expanded the engine substantially:

- **v0.17.x** — S1 SAST hook + S2 security-reviewer rewrite
- **v0.18.x** — D1 design-critic + D2 a11y gate + PF3 perf budgets +
  PF2 static perf gate
- **v0.19.0** — A1 telemetry + A2 corpus (security-reviewer seeded) +
  L1/L2/L4 partial
- **v0.20.0** — A2 fill-out (all 5 gates seeded + schema drift fix)
- **v0.21.0** — A4 primitive (`pe agent run`) + `--live` mode
- **v0.22.0** — A3 incident synthesizer + Proposal Envelope schema
- **v0.23.0/1** — A5 Ponytail default-on + preflight hook + cost fix
- **v0.24.0** — L3 memory governance (`pe memory`)
- **v0.25.0** — A6 partial (`pe new` scaffold + `api-credentials`)

## What the v0.10.0 P1 bundle ships (6 items — condensed)

| Item | What landed |
|---|---|
| **P1.1 Claude Code hooks** | `hooks/hooks.json` + three scripts: `pre-commit-envelope-check.sh` (blocks `git commit` unless PASS/WARN envelope matches staged diff — the deterministic backstop for "code review every commit"), `post-edit-lint.sh` (advisory linter for Python/JS/shell/JSON/YAML), `stop-uncommitted-reminder.sh`. Bypasses via `PE_SKIP_COMMIT_GATE=1` etc. — always logged. |
| **P1.2 test-run + coverage** | `hooks/test-run.sh` detects pytest/npm test/go test/cargo test, runs scoped to changed packages. `ENGINE_COVERAGE_MIN` opt-in floor. `ENGINE_TEST_CMD` override for exotic stacks. |
| **P1.3 secrets + deps audit** | `hooks/secrets-scan.sh` (gitleaks → detect-secrets → trufflehog) + `hooks/deps-audit.sh` (pip-audit / npm audit / govulncheck / cargo audit). Fires only when a dep manifest is staged. Plus `templates/ci/engine-quality.yml.template` — second CI workflow: lint + typecheck + tests + coverage + secrets + deps for python/node/go. |
| **P1.4 wire by default** | `pe install` merges `hooks.json` into `.claude/settings.json` (idempotent) + renders `.pre-commit-config.yaml` + runs `pre-commit install`. Opt-out via `--no-claude-hooks` / `--no-git-hooks`. Yaml template default flipped: `pre_commit_enabled: true` + new `claude_hooks_enabled: true`. |
| **P1.5 evidence trailers** | `code-review-trailer.sh` rewritten: commits touching `src/`, `app/`, `modules/`, `lib/`, `scripts/`, `hooks/` require `Code-reviewed: <envelope-sha>` that resolves to a PASS/WARN record in `.claude/gates/`. Legacy `Code-reviewed: code-reviewer` self-attest allowed only on non-behavior paths. New `security-review-trailer.sh` fires on auth/session/payment/webhook paths. |
| **P1.6 chaining skills** | `/new-feature <topic>` walks brainstorm → brief → architect → plan → tdd with per-stage artifact checks + refusal to skip. `/pre-commit` runs the right gates for staged paths, records envelopes, constructs commit with verified trailers. `/retro` (previously referenced by retrospective-agent but missing) ships. |

`pe gate parse` gained `--record <path>` + `--diff-sha <sha>` — writes
an evidence sidecar on PASS/WARN. `.claude/gates/last-gate.json` is the
canonical location the PreToolUse hook checks.

## What the P0 bundle (v0.9.1) fixed (12 items — condensed)

| Fix | Why it matters |
|---|---|
| `pe sync` crash at `scripts/pe:414` | `diff` exit 1 under `set -euo pipefail` killed sync on every customized file; overwrite-confirm prompt was unreachable dead code. Old test passed because of the crash — test hardened to assert exit 0. |
| Router fail-safe hole | Schema-valid FAIL + `failure_class:"none"` routed to `continue` even with CRITICAL findings — **falsified the graduation signoff**. Now caught at 3 layers (schema conditional + `pe_gate` coherence check + `route()` guard) + regression test. |
| Stacking pre-push hook | Silently blocked every push with no slot IDs. Fixed. |
| `pe install` fork preservation | No longer clobbers operator-forked files. Preserves + reports + points at `pe sync` for review. |
| Interpreter hardening | Stock macOS `python3` is 3.9 (no `tomllib`). `pe` now probes for 3.11+, orchestrator exits with actionable message, subprocesses use `sys.executable`. Orchestrator test suite **couldn't run on your machine** before this — now 33/33. |
| Plus: `pe eject` bash-3.2 crash · BSD-sed doctor launchd bug · invalid-subset zero-install trap · breaker sidecar silent-corruption / non-atomic writes · gate cross-check ordering + retry bugs · brief-writer/architect missing Bash tool for MANDATORY Step 0 · version drift (0.7.0 badges vs 0.9.0, "9 agents" vs 15) |

**Test totals:** 52 pass (9 sync + 10 install-reconcile + 33 orchestrator).
All schema fixtures exit expected codes.

## Three findings that reshape priorities (from the audit)

These are P1–P3 in IMPROVEMENT_PLAN.md — do NOT start until P0 is
committed + adopters synced, but keep them in view when planning.

1. **Headline promises have no deterministic enforcement.**
   Mandatory review + TDD are prompt-hope backed by self-attested git
   trailers that aren't installed by default. There are NO Claude Code
   hooks anywhere in the engine.
   **→ P1: `hooks.json` commit gate, test-run hook, secrets scanner,
   `/new-feature` chaining skill.** This is what makes the promises real.
2. **The domain layer is missing entirely.**
   100% of the engine governs *how you work*; 0% is *what SaaS apps
   are made of*.
   **→ P3.1 / P3.2: `pe new` scaffolding + extract tenancy / billing /
   credentials modules that already exist in 8CStudio, Origyn, and
   invoice-system.** Each ships with its tests + reviewing agent.
   Highest-leverage move once P0/P1 are in.
3. **Symlink distribution should become a native Claude Code plugin
   before the beta widens.**
   Two releases fought pathologies the plugin marketplace solved;
   symlinks also have no version pinning.
   **→ P3.3: convert to native plugin.**

## Session rituals — start and end

The engine ships two skills — `/start-session` and `/end-session` — that
are THE rituals. Learn these and everything else falls into place.

### Case A — brand new project (first-time onboarding)

One-time setup per project, then it enters the daily flow (Case B).

```bash
# 1. Install the engine into the project
pe install /path/to/new/project
# — or with a leaner agent set —
pe install --subset gate-only /path/to/new/project    # 5 gate agents
pe install --subset core /path/to/new/project         # 8 agents
pe install --subset full /path/to/new/project         # 15 agents (default)

# 2. Edit the auto-created config with REAL values
#    (never commit template placeholders — acme / Acme Corp / /Users/you/…)
$EDITOR /path/to/new/project/.process-engine.yaml
# Set: project.org_tag, project.display_name, project.root

# 3. (Optional, macOS) Wire the Friday weekly retro
pe launchd /path/to/new/project

# 4. Verify install is healthy
pe doctor /path/to/new/project
```

Then continue with Case B every day. Create/grow `CLAUDE.md` +
`MEMORY.md` in the project root as work happens — the session skills
read them.

### Case B — continuing work on a project (daily flow)

**Start of session:**

1. Open Claude Code in the project directory.
2. Type `/start-session` — the skill reads CLAUDE.md, MEMORY, weekly
   plan, git state; surfaces active focus + stale plans + first-task
   recommendation and **STOPS waiting for you.** Never starts work
   autonomously.
3. If you recently pulled engine changes, run
   `pe sync --dry-run /path/to/project` to preview any updates the
   engine wants to propagate. Then `pe sync` (no `--dry-run`) if you
   want them applied. Diff-before-clobber protects your customizations.
4. Decide the task. Work.

**End of session:**

1. Type `/end-session` — the skill runs the close-out: git status, sync
   check (ahead/behind origin), MEMORY banner updates (surfaces diffs —
   **never auto-writes**), deliverables ledger (commits + hashes),
   unresolved items, next-session pickup pointer.
2. Review its output. Apply MEMORY updates it surfaces if you agree
   (you commit them manually).
3. Commit + push if you have work to ship (the skill never pushes for
   you).

Both skills are project-agnostic — they discover files via fallback
chains. Tune per-project via `.claude/session.yaml`.

### Case C — working ON the engine repo itself (this session's kind)

Same shape as Case B, plus one thing:

**Start:** `/start-session` → then read this doc (`docs/HANDOFF.md`)
for state carried over from the last engine session.

**End:** before typing `/end-session`, **update this doc**:

- Bump "Last updated" date
- Refresh "One-line state"
- Roll shipped commits into "What shipped in the last session"
- Add any new gotchas discovered

Then `/end-session` and commit the updated HANDOFF.

### Rule of thumb

| Situation | Ritual |
|---|---|
| First time on a project | `pe install` + edit yaml + `/start-session` |
| Daily start | `/start-session` |
| After engine has new upstream commits | `pe sync --dry-run` → `pe sync` |
| Daily end | `/end-session`, then commit + push if applicable |
| Engine-repo session end | Update this doc **before** `/end-session` |
| Something's off | `pe doctor /path/to/project` — engine version + freshness + shadowed count |

### Why this works

- `/start-session` does the "where was I?" work — no wasted re-orient time.
- `/end-session` prevents "wait, what did I actually do today?" via the
  ledger + surfacing what to remember.
- `pe sync --dry-run` is the safe default — see what would change before
  anything changes.
- Neither skill auto-commits, auto-edits memory, or auto-pushes. You stay
  in control of what lands.
- This doc is the engine-repo's memory anchor. Small enough to read at
  the top of every session.

Full detail on both skills lives in `skills/start-session/` and
`skills/end-session/`. The `BETA_TESTER_BRIEF.md` §"What to try first"
walks through a 30-minute first session touching all the pieces.

## The only queued task

**Task #8 — P3 auto-update suggestion surfacer.** **DO NOT BUILD YET.**
Waits on ≥1 concrete recurring "we keep noticing X across sessions"
pattern from operator/adopter feedback. If a candidate pattern surfaces
(e.g. in beta tester feedback on GitHub issues, or in your own retros),
that's the signal to promote it.

## Signals that promote parked work back to active

| Signal | Promotes | Where to check |
|---|---|---|
| Recurring "we keep noticing X" pattern | Task #8 (P3) | Session feedback / beta tester GitHub issues |
| Any of 4 triggers in `docs/COUPLING_MAP.md` §7 fires | Phase 4 / Stage B | Re-run the coupling survey first, then decide |
| Beta severity-calibration feedback arrives | Gate agent rubric tuning | `BETA_TESTER_BRIEF.md` explicitly asks about this — watch GitHub issues + DMs |
| 3rd product adopts the engine | Re-run coupling survey for it; possibly formalize L0 knowledge-pack | `docs/CAPABILITY_CATALOG.md` §3 |

## What is explicitly OFF the runway (do NOT propose building these)

- **Phase 4 dependency-aware DAG scheduler** — parked; both apps cluster
  cleanly per `docs/COUPLING_MAP.md` §5. Re-open only if §7 triggers.
- **Engine self-modification / auto-commit** — never, by design. One bad
  auto-change would propagate to every adopter via `pe sync`.
- **Auto-tier-routing** — deferred until cost telemetry (E2.1) exists.

## Docs to read first (in priority order)

1. `docs/BACKLOG.md` — Priority overview + P1-adjacent items
2. `docs/COUPLING_MAP.md` §5 (session-split guide) + §7 (re-eval triggers)
3. `CHANGELOG.md` — what shipped in v0.8.0
4. `docs/CAPABILITY_CATALOG.md` §3 — "If you need X" pointers (avoid
   re-investigating tools already evaluated)
5. `docs/launch/BETA_TESTER_BRIEF.md` — what's being shared with adopters

## Gotchas / things to remember

- **Origyn's real path** is `/Users/sanishsasikumar/Documents/Origyn`
  (NOT under `8Colors/`). This mistake was made twice this session — do
  not repeat.
- **8CStudio's `org_tag` is `8colors`** (matches its
  `com.8colors.ceo.*.plist` LaunchAgents already installed).
- **8CStudio-side coupling rule:** work in ONE cluster at a time — pick
  from Production Pipeline / Money / Reporting per COUPLING_MAP §5.
- **Origyn-side coupling rule:** Client + Trainer MUST share a session.
  The STRONG border edge `trainer → Lead` cannot be split without
  reproducing exactly the tangle we've seen.
- **Never commit `.process-engine.yaml.template` placeholders**
  (`acme` / `Acme Corp` / `/Users/you/code/acme`) — replace with real
  project values BEFORE the commit whenever `pe install` writes a new
  yaml in a fresh project.
- **`pe sync --dry-run` is the safe default** for investigating an
  adopter's state — never run non-dry-run without checking dry-run first.
- **uvx-hosted MCPs may need an explicit `--python` pin.** As of
  2026-07-02, `semgrep-mcp` (and any MCP that transitively imports
  `google.protobuf`) crashes under Python 3.14 with
  `TypeError: Metaclasses with custom tp_new are not supported`. Fix:
  register the MCP with `uvx --python 3.12 <tool>` (see the semgrep
  entry in `~/.claude.json` for the exact shape). Symptom in the wild:
  `claude mcp list` shows `✗ Failed to connect`.
- **Install-time engine improvements do NOT propagate via `pe sync`.**
  `pe sync` re-points symlinks; it never re-runs `install.sh`. So
  changes to `scripts/install.sh` (e.g. E1.c.2 reconciling) reach an
  adopter the next time the adopter runs `pe install`, not on the next
  `pe sync`. Don't be surprised when a `pe sync` post-`install.sh`-change
  reports "0 changes" — that's correct.

## Common operations

### Onboarding a new project

```bash
pe install [--subset gate-only|core|full] /path/to/new/project
# edit .process-engine.yaml (org_tag + display_name + root)
# then, for macOS weekly retro:
pe launchd /path/to/new/project
```

### Adopter reports a sync issue

```bash
pe sync --dry-run /path/to/their/project   # always dry-run first
pe doctor /path/to/their/project           # get freshness summary + shadowed count
```

### Pulling engine updates into all known adopters

```bash
cd /path/to/8colors-process-engine && git pull
pe sync /Users/sanishsasikumar/Documents/8Colors/8CStudio    # 8CStudio
pe sync /Users/sanishsasikumar/Documents/Origyn              # Origyn
```

## What shipped in the last session (2026-07-02 P2, v0.11.0)

Nine P2 items — agent portability, gate identity separation, shell
robustness. All 64 tests pass. Uncommitted at session end.

| Change | What |
|---|---|
| `agents/database-reviewer.md` (rewrite) | Generic Postgres + multi-tenant reviewer. 8CStudio's version forked to `8CStudio/.claude/agents/database-reviewer.md` |
| `agents/_gate-contract.md` | SPEC (not runnable) — canonical E1 gate-envelope contract. All 5 gate agents point at it. `install.sh` + `pe sync/doctor` skip `_*.md` |
| `agents/security-reviewer.md`, `agents/database-reviewer.md` | Removed `Write`/`Edit` — reviewers no longer modify code they judge |
| `agents/tdd-guide.md` (rewrite) | Executable state machine — stack detection, RED-first verbatim paste, GREEN, REFACTOR-tests-stay-green, 80% coverage floor. `Glob` added |
| `agents/e2e-runner.md` | Gate-identity note: hybrid worker+envelope, never self-grades tests it authored |
| `agents/planner.md` | `Bash`+`Write` added, MANDATORY Step 0 (semantic-index query), output-artifact spec |
| `agents/ceo.md` | "Sanish"/"LANE 1" 8CStudio-isms → "the operator" phrasing |
| `agents/researcher.md` | `haiku` → `sonnet`, softened "<100 stars = reject" to weighted signal |
| `agents/build-error-resolver.md` | Phase 0 multi-stack detection (TS/Py/Go/Rust/Java); per-stack commands |
| `agents/data-model-auditor.md` | Description upgraded to "Use PROACTIVELY..." pattern; `Write` added |
| `agents/doc-updater.md` | Feature-detect commands; graceful degradation; multi-stack tooling |
| `agents/retrospective-agent.md` | Degraded mode — derives from git log + decisions.jsonl + baselines when dev-log absent |
| `commands/brainstorm.md` | Soniox/8CStudio/Lipi references removed; tool-agnostic |
| 5 gate agents | Hardcoded `claude-sonnet-4-6` → `<your-model-id>` placeholder with substitution note |
| `scripts/_yaml.sh` | Shared `yaml_get <dot.path>` + `yaml_bool_get`. Replaces 4 ad-hoc readers |
| `scripts/install_launchd.sh` (rewrite) | Injection hygiene — sys.argv passing, python str.replace rendering, actionable errors, charset guards |
| `scripts/install.sh` | Docs allowlist (9 files), `.gitignore` create-if-absent, `nullglob`, hooks-wiring paths |
| `scripts/pe` | `cmd_sync` realpath canonicalization, `cmd_doctor` exit-code normalize, `cmd_docs check` subcommand |
| Tools frontmatter | Normalized to `["Read", ...]` quoted-array style across all 15 agents |
| `VERSION` 0.10.0 → 0.11.0, `plugin.json`, `README.md` badge, `CHANGELOG.md`, `IMPROVEMENT_PLAN.md` P1 + P2 marked SHIPPED | Version bookkeeping |

## What shipped in the session before (2026-07-02 P1, v0.10.0)

Six P1 items — deterministic enforcement layer for the engine's
headline promises.

| Change | What |
|---|---|
| `hooks/hooks.json` + 3 scripts | Claude Code PreToolUse/PostToolUse/Stop bundle |
| `hooks/test-run.sh` | Stack-detecting scoped test runner (pytest/npm/go/cargo) |
| `hooks/secrets-scan.sh`, `hooks/deps-audit.sh` | Pre-commit secrets + vulnerability audit |
| `hooks/code-review-trailer.sh` (rewrite) | Evidence-backed trailer — behavior paths require an envelope sha |
| `hooks/security-review-trailer.sh` | Auth/session/payment paths require Security-reviewed |
| `templates/ci/engine-quality.yml.template` | Second CI workflow — lint + typecheck + tests + coverage + secrets + deps |
| `templates/process-engine.yaml.template` | `pre_commit_enabled: true` + `claude_hooks_enabled: true` defaults |
| `scripts/pe_gate.py` | `--record <path> --diff-sha <sha>` writes evidence sidecar on PASS/WARN |
| `scripts/install.sh` + `scripts/_hooks.sh` | Merges hooks into `.claude/settings.json` + renders `.pre-commit-config.yaml` + runs `pre-commit install`; `--no-claude-hooks` / `--no-git-hooks` opt-out |
| `commands/new-feature.md`, `commands/pre-commit.md`, `commands/retro.md` | Chaining skills — brief-before-code + gated commit + missing `/retro` |
| `tests/test_hooks.sh` | 12-assertion smoke test |
| `VERSION` 0.9.1 → 0.10.0, `plugin.json`, `README.md` badge, `CHANGELOG.md` | Version bookkeeping |

## What shipped 2 sessions before (2026-07-02 P0, v0.9.1)

3 engine commits + 2 config edits at Origyn (yaml placeholders +
Serena MCP) + 1 user-global MCP fix (Semgrep Python 3.12 pin):

| Commit / change | Repo / scope | What |
|---|---|---|
| `3b43e03` | engine | 0.9.1 — P0 audit bundle (12 fixes: sync crash, router fail-safe, install clobber guard, interpreter + bash-3.2 portability, plus 7 more) + `docs/IMPROVEMENT_PLAN.md` as new active roadmap. 52/52 tests pass. **Not pushed yet.** |
| `c229b8a` | engine | docs(HANDOFF): roll in v0.9.0 + adopter health + uvx-python-pin gotcha |
| `f689895` | engine | 0.9.0 — reconciling `pe install` (silent broken-symlink cleanup), smoke test, BACKLOG housekeeping sweep, TROUBLESHOOTING §4 refresh. Closes #10. |
| `.process-engine.yaml` | Origyn | replaced template placeholders (`acme` / `Acme Corp`) with real values (`origyn` / `Origyn` / real root) |
| `.mcp.json` | Origyn | added Serena MCP scoped to Origyn (was missing) |
| `~/.claude.json` | user-global | Semgrep MCP re-registered with `uvx --python 3.12` — fixes `✗ Failed to connect` under Python 3.14 |

## What shipped 2 sessions before (2026-06-30)

Retained for context — 10 commits on the engine + 2 on 8CStudio:

| Commit | Repo | What |
|---|---|---|
| `07465e3` | engine | BACKLOG reorganized into P1/P2/P3 priorities |
| `3c15b3d` | engine | 0.8.0 — VERSION bump + shadow string fix + `pe doctor` extension |
| `ea3ab63` | engine | 0.8.0 — INSTALL.md PATH check |
| `5e40316` | engine | Finding #6 backlog note |
| `2367e56` | engine | 0.8.0 — `pe install --subset` preset |
| `9ce0fc3` | engine | 0.8.0 — `pe sync` diff-before-clobber + smoke test |
| `8352265` | engine | 0.8.0 release date sealed |
| `a3f7765` | engine | P2 Stage A — coupling map + Phase 4 parked |
| `9ec6cb5` | engine | Finding #6 fix — research_index.py SIM102 |
| `de16dd5` | engine | BETA_TESTER_BRIEF refreshed for v0.8.0 |
| `245a5e9` | 8CStudio | track `scripts/research_index.py` engine symlink |
| `c617a81` | 8CStudio | add engine `.process-engine.yaml` + `.gitignore` updates |

## Session close pattern

At the end of each session, update this doc before ending. Specifically:
- Bump the "Last updated" date
- Update "One-line state"
- Move any newly-shipped items into "What shipped in the last session"
- Add any new gotchas discovered
- If the queued task changed, update "The only queued task" section

This doc is the memory the next session needs. Keep it lean and current.
