# Engine Improvement Plan — full audit results (2026-07-02)

> Produced by a 4-track deep audit of engine v0.9.0: (1) shell layer,
> (2) Python core, (3) agentic layer, (4) architecture/strategy.
> Several bugs below were **empirically confirmed by repro on this
> machine** — marked ✅repro.
>
> **How to use this doc:** items are grouped P0→P4. Each item is
> self-contained: ID, severity, effort (S/M/L), exact files/lines,
> problem, and the concrete fix. Any model (Opus/Sonnet) can pick an
> item and implement it without re-deriving the analysis. Check items
> off here as they land; move shipped items to CHANGELOG.
>
> **One-paragraph verdict:** the engine is a genuinely disciplined
> *process* layer (envelope contract, failure-class taxonomy,
> shadow-then-graduate empiricism, honest-nulls baselines) wrapped
> around two big holes: (a) its headline promises — mandatory review,
> TDD — have almost **zero deterministic enforcement** (no Claude Code
> hooks exist; git trailers are self-attested and off by default), and
> (b) the **domain layer is missing** — 100% of code serves "how we
> work", 0% serves "what SaaS apps are made of" (no scaffold, no
> reusable auth/tenancy/billing modules). Plus a handful of confirmed
> crashes in `pe sync` / hooks / router fail-safe. Fix P0, build P1+P3,
> stop polishing the rest.

---

## P0 — Confirmed bugs (fix immediately; mostly one-liners)

### P0.1 `pe sync` crashes on every "differs" file — confirm path unreachable ✅repro
- **Severity:** CRITICAL · **Effort:** S · **File:** `scripts/pe:414`
- `diff -u … | sed … | head -40` — diff exits 1 when files differ (always,
  in this branch); under `set -euo pipefail` the pipeline kills the script.
  Sync prints the diff, exits 1, never shows the confirm prompt, never
  scans commands/scripts, never prints Summary. The `confirm` branch at
  pe:418 is dead code. Any adopter with ONE customized agent gets a broken
  partial sync every time.
- **Fix:** append `|| true` to the diff pipeline (or `|| [ $? -eq 1 ]`).
- **Test trap:** `tests/test_pe_sync.sh` Test 2 currently PASSES *because*
  of this crash (`|| true` at test:74,102 swallows exit 1; assertions are
  satisfied by crashing before the prompt). In the same commit add
  assertions that `Summary:` appears in sync output and exit code is 0.

### P0.2 Router fail-safe hole: `FAIL + failure_class="none"` → continue ✅repro
- **Severity:** CRITICAL · **Effort:** S · **Files:**
  `scripts/pe_orchestrator.py:230-231`, `policy/failure_class_routing.toml:37`,
  `schemas/gate-envelope.schema.json:44-51`
- Schema documents `none` as "only valid when verdict is PASS or WARN" but
  has no conditional enforcing it, so FAIL+none validates. `route()` does
  `rules.get("none")` → `"continue"`. Severity floor only fires on
  PASS/WARN, so **FAIL + none + CRITICAL findings also continues**. This
  falsifies the graduation signoff's "no fallback-to-continue on the
  escalate path".
- **Fix (all three):** (a) in `route()`, halt when verdict==FAIL and
  resolved action is continue; (b) route gate exit code 2 directly like
  exit 4; (c) add draft-07 `if/then` conditional to the schema + a
  verdict/failure_class consistency check in `pe_gate.py`. Add a bash test
  case (FAIL+none fixture) to `test_phase_3_orchestrator.sh`.

### P0.3 Stacking pre-push hook blocks every ordinary push ✅repro
- **Severity:** CRITICAL · **Effort:** S · **File:** `hooks/stacking-rule-check.sh:48-50`
- When no commit subject contains a slot ID, `grep -oE` exits 1 inside the
  command substitution → `set -euo pipefail` errexit → hook exits 1 →
  push blocked **silently**. Also fires when `$range` can't be resolved.
- **Fix:** `… | { grep -oE '…' || true; } | sort -u | wc -l | tr -d ' '`
  (mirror lines 53-54 which already guard `foundational_hits`).

### P0.4 `pe install` silently clobbers operator-forked agent files
- **Severity:** CRITICAL · **Effort:** S · **Files:** `scripts/install.sh:125,142,159`
- `ln -sf` unconditionally replaces the destination — including a regular
  file the operator customized. Unrecoverable data loss; contradicts
  `pe sync`'s diff-before-clobber contract and doctor's own "fork is not a
  collision we manage" classification (pe:640-643).
- **Fix:** before `ln -sf`: if dest exists AND is not a symlink AND
  `! cmp -s` with engine source → skip + warn "customized file preserved;
  run `pe sync` to review". Only clobber symlinks and byte-identical files.
  Add the colliding-name fork case to `test_pe_install_reconcile.sh`.

### P0.5 Bare `python3` → crashes on stock macOS (3.9, no tomllib) ✅repro
- **Severity:** HIGH · **Effort:** S · **Files:** `scripts/pe:801,833,897`,
  `scripts/pe_orchestrator.py:120`
- Xcode CLT python3 is 3.9.6; `pe shadow decide` dies with raw
  `ModuleNotFoundError: tomllib`, exit 1 (outside the 0/2/4 contract).
- **Fix:** version guard at top of pe_orchestrator.py
  (`sys.version_info < (3,11)` → actionable exit); use `sys.executable`
  for the pe_gate subprocess; have `pe` probe for a ≥3.11 interpreter.

### P0.6 `pe eject` broken on stock macOS bash 3.2 ✅repro
- **Severity:** HIGH · **Effort:** S · **File:** `scripts/pe:753,771,777`
- `${confirm,,}` is bash-4-only ("bad substitution", aborts mid-eject);
  `"${removable[@]}"` on empty array under `set -u` crashes bash ≤4.3.
- **Fix:** `case "$confirm" in y|Y|yes|YES)` (idiom already used at
  pe:350); guard empty arrays `[ ${#removable[@]} -gt 0 ]`. Or declare
  bash≥4 required and check `BASH_VERSINFO` at pe:20 (macOS default
  `/usr/bin/env bash` is still 3.2 without Homebrew).

### P0.7 Invalid subset value → installs 0 agents / prompts to delete all
- **Severity:** HIGH · **Effort:** S · **Files:** `scripts/install.sh:56-73`,
  `scripts/pe:321`, `scripts/_subset.sh:16-32`
- Only the `--subset` flag is validated. A typo in yaml (`ful`) or a
  quoted value (`"core"` — awk returns it WITH quotes) makes
  `agent_in_subset()` return 1 for everything: install skips all agents;
  `pe sync` classifies every installed agent as orphan (with `--yes`:
  deletes them all).
- **Fix:** validate resolved subset in both places
  (`case … in gate-only|core|full) ;; *) die ;; esac`); strip quotes in
  `read_subset_from_yaml`.

### P0.8 `pe doctor` launchd check 100% broken on macOS (BSD sed `\s`) ✅repro
- **Severity:** HIGH · **Effort:** S · **File:** `scripts/pe:705-706`
- BSD sed doesn't support `\s`; org_tag parses as `org_tag:acme` → plist
  path never matches → check silently never fires. Gated behind Darwin,
  so it only runs where it's broken.
- **Fix:** `sed -E 's/^[[:space:]]*org_tag:[[:space:]]*//'` — or better,
  one shared `yaml_get` helper (see P2.6).

### P0.9 Breaker sidecar: silent corruption reset, non-atomic writes ✅repro
- **Severity:** HIGH · **Effort:** S-M · **File:** `scripts/pe_orchestrator.py:320-327,387-404`
- Corrupt `breaker-cumulative.json` → silent `pass` → ledger zeroed with
  **zero stderr** (this file is the "PRIMARY safety guard" per
  circuit_breaker.toml). Plain `write_text`, no temp+rename, races under
  concurrent decide.
- **Fix:** on corrupt: WARN + preserve to `.corrupt` sidecar; write via
  `tempfile` + `os.replace`; `fcntl.flock` around read-modify-write.

### P0.10 Gate cross-check ordering + retry bugs ✅repro
- **Severity:** HIGH · **Effort:** S · **File:** `scripts/pe_gate.py:235,249`
- (a) Cross-check block AFTER the fence passes, though the E1.d contract
  (and pe_gate's own error text) requires before — the "enumerate state
  before emitting" property isn't actually checked. (b) First-cross-check-
  wins vs last-fence-wins: a legitimate retry transcript (stale first
  block + corrected second) exits 4, burning escalations on false errors —
  retry-and-re-emit is exactly what E1.a §13 mandates.
- **Fix:** search `CROSSCHECK_HEADER_RE` only in `text[:last_fence.start()]`
  and take the LAST cross-check block before the last fence.

### P0.11 Agents with a MANDATORY step they physically cannot run
- **Severity:** CRITICAL (for the workflow) · **Effort:** S · **Files:**
  `agents/brief-writer.md`, `agents/architect.md`
- Both mandate Step 0: `python3 scripts/research_index.py query …` but
  neither has **Bash** in `tools:`. architect is also told to write an
  architect doc with no **Write** tool. The engine's flagship anti-rework
  mechanism (semantic search of prior briefs — the "Workbox-miss"
  prevention) is unexecutable by the two agents required to run it; they
  silently skip it.
- **Fix:** add `Bash` to both; add `Write` to architect; give architect an
  output contract (path + required sections) mirroring brief-writer's.

### P0.12 Version/inventory drift across five files
- **Severity:** HIGH (credibility) · **Effort:** S · **Files:** `VERSION`
  (0.9.0), `plugin.json` (0.7.0, "13 agents"), `README.md` badge (0.7.0,
  "9 specialist agents", "4 slash commands", roadmap "v0.7 (current)",
  CLI reference missing sync/eject/gate/shadow/baseline),
  `INSTALL.md` ("14 agents (v0.7)", "uninstall manual for v0.2"),
  `docs/launch/BETA_TESTER_BRIEF.md` ("v0.8.0")
- **Fix:** update all to 0.9.0 / 15 agents / 5 commands; add a release
  checklist step or `pe docs check` that greps VERSION against badges and
  counts `agents/*.md` vs claims (see P2.9).

---

## P1 — Enforcement: make the headline promises real — ✅ SHIPPED v0.10.0 (2026-07-02)

All 6 items landed. `hooks/hooks.json` exists, `pe install` wires
both Claude Code hooks + git-side pre-commit by default, evidence
replaces self-attest on behavior paths, chaining skills ship. 12
new tests in `tests/test_hooks.sh`.

Architectural fact found by the audit: **all shipped hooks are git
hooks; there is no `hooks/hooks.json` (Claude Code hooks) anywhere.**
`pe install` does not wire git hooks; the yaml template defaults
`pre_commit_enabled: false`. So a default install has ZERO deterministic
enforcement — "mandatory code review" and TDD are prompt-hope.

| Promise | Current enforcement | Gap |
|---|---|---|
| Code review every commit | commit-msg trailer, ≥5 files only, self-attested text, not installed by default | CRITICAL |
| CRITICAL findings block commit | nothing reads the envelope at commit time; orchestrator is shadow-mode | CRITICAL |
| TDD / 80% coverage | nothing — no test hook, no coverage gate, CI template greps trailers only | CRITICAL |
| Brief before code | nothing checks a brief exists | HIGH |
| Security review on auth/payment paths | nothing deterministic; no secrets scanner shipped | HIGH |
| Envelope validity | `pe gate parse` ✓ (best engineering in repo) — but consumers are shadow | MEDIUM |
| Stacking rule | pre-push hook ✓ genuinely deterministic (after P0.3 fix) | OK |

### P1.1 Ship Claude Code hooks (`hooks/hooks.json`) — ✅ SHIPPED v0.10.0
- **Effort:** M
- (a) **PreToolUse on Bash matching `git commit`** → block unless a fresh
  validated code-reviewer envelope (PASS/WARN) exists for the staged
  diff — have gates write envelopes to `.claude/gates/last-gate.json` via
  `pe gate parse`; hook compares a staged-diff hash. (b) PostToolUse on
  Edit/Write → lint the touched file. (c) Stop hook → remind /end-session
  if uncommitted changes. This closes the self-attestation hole from the
  deterministic side.

### P1.2 Test-run + coverage pre-commit hook (the only way TDD becomes real) — ✅ SHIPPED v0.10.0
- **Effort:** M — detect runner (pytest / npm test / go test), run scoped
  to changed packages, optional coverage-delta floor. Add to
  `.pre-commit-config.yaml.template` and the CI template.

### P1.3 Secrets scanning + dependency audit — ✅ SHIPPED v0.10.0
- **Effort:** S — add gitleaks (or detect-secrets) + `pip-audit`/`npm audit`
  to the pre-commit template and a second CI template (lint + typecheck +
  tests + coverage floor + secret scan). The engine promises "fewer
  vulnerabilities" and ships no scanner.

### P1.4 Wire git hooks by default — ✅ SHIPPED v0.10.0
- **Effort:** S — `pe install` runs `pre-commit install` (opt-out flag);
  flip template default `pre_commit_enabled: true`.

### P1.5 Upgrade trailers from self-attestation to evidence — ✅ SHIPPED v0.10.0
- **Effort:** M — `code-review-trailer.sh` requires
  `Code-reviewed: <envelope-sha>` verifiable against `.claude/gates/`;
  drop the ≥5-file threshold to 1 for behavior-changing paths
  (src/, app/, modules/). Path-based security trailer: commits touching
  `auth|login|oauth|session|payment|webhook` require Security-reviewed.

### P1.6 `/new-feature` + `/pre-commit` chaining skills — ✅ SHIPPED v0.10.0
- **Effort:** M — `/new-feature` walks brainstorm→brief→architect→plan→tdd,
  checks each artifact exists before advancing, refuses to skip stages
  (strongest brief-before-code enforcement available without hooks).
  `/pre-commit` (or `/ship`) runs the right gates for the staged paths,
  validates envelopes via `pe gate parse`, constructs the commit with
  verified trailers. Also ship the missing `/retro` command
  (retrospective-agent references it; it doesn't exist).

---

## P2 — Agent/portability/consistency fixes

### P2.1 De-project-ify `database-reviewer` (38KB, 100% 8CStudio-specific) — ✅ SHIPPED v0.11.0
- **Severity:** CRITICAL for adopters · **Effort:** M — it references
  `scripts.content_fountain`, migrate_093, Casbin ADR-001, gotchas §43 —
  meaningless in any other repo; produces false CRITICALs or `blocked`.
  Move it to 8CStudio's `.claude/agents/`; ship a **generic** DB reviewer
  (tenant-scoping, migration idempotency, parameterized SQL, index/FK,
  RLS patterns — the Phase 4/5 material in the current file is already
  generic and excellent). Add a project-overlay mechanism (engine agent +
  optional `.claude/agents/overrides/`).

### P2.2 Remove Write/Edit from gate agents — ✅ SHIPPED v0.11.0
- **Effort:** S — security-reviewer and database-reviewer have Write+Edit;
  a reviewer must not modify the code it judges (breaks the escalation
  ladder's reviewer/worker separation). Decide e2e-runner's identity:
  test-author (worker, keeps Write) or gate (loses it) — currently it
  self-grades tests it wrote.

### P2.3 Extract the duplicated ~350-line gate-envelope contract — ✅ SHIPPED v0.11.0
- **Effort:** M — near-verbatim in 5 agents (code-reviewer,
  security-reviewer, tdd-guide, e2e-runner, database-reviewer); any schema
  change = 5 synchronized edits. Extract `agents/_gate-contract.md` and
  template it in at install time (or have `pe install` concatenate).
  Also: remove hardcoded `model_used: "claude-sonnet-4-6"` from exemplars
  (agents copy exemplars literally → envelope lies about the model).

### P2.4 Rewrite `tdd-guide` as an executable state machine — ✅ SHIPPED v0.11.0
- **Effort:** M — currently ~85 lines of generic advice + 350 of envelope;
  no framework detection, no hard refusal rule. Fix: (1) detect test
  runner per stack; (2) write test; (3) run, paste failing output
  VERBATIM before any implementation (hard rule); (4) implement;
  (5) run green; (6) coverage command per stack. Add `Glob` (only agent
  missing it). Resolve its gate-vs-worker identity (envelope says
  reviewer, body says author).

### P2.5 Fix broken/unportable agents — ✅ SHIPPED v0.11.0
- **Effort:** S-M each:
  - **ceo.md**: hardcoded 8CStudio files + "Sanish"/"LANE 1"; Sentry MCP
    read is impossible (explicit `tools:` list excludes MCP tools) —
    parameterize via `.process-engine.yaml`, omit `tools` or add MCP names.
  - **retrospective-agent**: depends on dev-log collector scripts the
    engine doesn't ship — ship them or add degraded mode (derive from
    `git log --numstat`). Also the flagship Friday retro has run on broken
    input for ~7 weeks (8CStudio #201) — fix the digest or make the retro
    read git/decisions.jsonl/baselines directly.
  - **researcher**: haiku under-tiered for fit-score judgment → sonnet;
    soften brittle "<100 stars = reject" rule.
  - **build-error-resolver**: TS-only; add stack detection; fix dangling
    `refactor-cleaner` pointer.
  - **doc-updater**: references scripts/commands that don't exist in the
    engine — feature-detect or drop.
  - **planner**: no Write tool but workflow expects planner artifacts on
    disk + no research-index Step 0 (the original Workbox-miss vector) —
    add both.
  - **data-model-auditor**: weak description (won't auto-fire) — add "Use
    PROACTIVELY when…"; has Edit but not Write though it's told to create
    files.
  - **/brainstorm**: Soniox/8CStudio references — make tool-agnostic.

### P2.6 One shared YAML reader — ✅ SHIPPED v0.11.0
- **Effort:** S — four independent ad-hoc readers (awk in `_subset.sh`,
  python heredoc in `install_launchd.sh`, broken grep/sed in pe doctor,
  awk+sed writer in install.sh); one is broken (P0.8), one is
  code-injectable (P2.7). Single `yaml_get KEY FILE` python helper.

### P2.7 Injection hygiene in `install_launchd.sh` — ✅ SHIPPED v0.11.0
- **Effort:** S — (a) `read_yaml` splices `$CONFIG`/`$1` into a python
  heredoc — a path with a single quote breaks it; pass via `sys.argv`.
  (b) sed template rendering injects unescaped `PROJECT_ROOT`/`CLAUDE_BIN`
  into launchd-executed scripts — validate charset or render with python
  literal replacement. (c) Missing org_tag/root dies with ZERO output
  under `set -e` — add actionable error messages.

### P2.8 Shell robustness batch (one PR) — ✅ SHIPPED v0.11.0
- **Effort:** S each — `scripts/pe`: quote `$py` (doctor, pe:686-695);
  canonicalize both sides of symlink comparison before equality
  (pe:362-367, 634-637 — realpath, not raw readlink); anchor eject's
  ownership check (`case "$(readlink "$f")" in "$ENGINE_DIR"/*)` not
  substring grep, pe:745); nullglob guards on `*.md` loops
  (pe:432,474; install.sh:109,141); atomic upgrade-to-symlink
  (pe:391-395); dry-run shouldn't count declines (pe:417); `return 1`
  not `return $broken` (pe:580); install.sh: dedupe-proof subset
  persistence (198-210); create .gitignore if absent (173-179); resolve
  symlinked $0 (line 17); docs copy → copy-if-absent + allowlist (213 —
  currently ships HANDOFF/BACKLOG/session notes to every adopter and
  clobbers project edits); `--dry-run` for install; prompts read
  `/dev/tty` with stdin fallback.

### P2.9 Frontmatter + inventory consistency — ✅ SHIPPED v0.11.0
- **Effort:** S — normalize `tools:` to one style (3 styles today);
  document or remove non-standard `effort:`/`memory:` fields (silently
  ignored — false sense of configuration); model alias not pinned string
  (`claude-opus-4-7` in yaml template breaks on deprecation); fix
  dangling references (ui-ux-design-agent in AGENT_INVOCATION_RULES,
  tenant-isolation-auditor in database-reviewer, QUALITY_CALENDAR.md) —
  ship or de-reference. Add `pe docs check`: grep VERSION vs badges,
  count agents/commands vs README/plugin.json claims.

### P2.10 Reconcile `~/.claude/agents/` stale forks (operator machine) — ✅ SHIPPED in v0.11.1 (2026-07-02)
- **Effort:** S — global `code-reviewer.md` was a May-22 haiku copy WITHOUT
  the envelope contract; in any project without project symlinks the old
  agent shadowed the engine gate silently (this exact class caused the
  E1_b incident).
- **Delivered:** 11 stale user-global agent copies replaced with symlinks
  into the engine (`architect`, `build-error-resolver`, `code-reviewer`,
  `data-model-auditor`, `database-reviewer`, `doc-updater`, `e2e-runner`,
  `planner`, `retrospective-agent`, `security-reviewer`, `tdd-guide`).
  3 genuinely-global agents promoted into the engine and symlinked
  (`tenant-isolation-auditor`, `project-kickstarter`, `project-onboarder`);
  `ui-ux-design-agent.md` moved from user-global to 8CStudio project-local
  (content is 8CStudio-specific). Engine agent surface: 15 → 18. README /
  plugin.json / `pe docs check` all consistent. Adopters re-installed;
  zero collision warnings.

### P2.11 Python hygiene batch — ⏸️ DEFERRED (Session 5)
- **Effort:** S each — pe_gate: engine version from schema `examples`
  (IndexError if empty; move to const); `--bare` must precede path
  (argparse-ify); `utf-8-sig`; missing failure_class defaults to
  escalate (make explicit). Orchestrator: budget `isinstance(int)` only
  (float silently disables enforcement); `campaign` scope never resets
  (add campaign-id + `pe shadow reset` + idempotency); policy KeyError →
  exit 4 with message; reconcile accepts all-null payload (validate
  required keys + enum); `--iteration` accepts 0/negative; cache_read
  tokens counted at full weight. baseline.py: `chore(fix)` never counted
  (housekeeping regex short-circuits — dead alternation); git errors are
  raw tracebacks with stderr swallowed; docstring/code mismatch on
  file-overlap. research_index: catch TypeError from protobuf-on-3.14
  (documented incident!) not just ImportError; don't record doc row when
  chunks failed to embed (permanent index holes); compare model not just
  dim; split oversized paragraphs (BGE truncates ~512 tokens — long code
  blocks are silently unindexed); batch embedding calls; dedupe before
  top-K; wrong-parent YAML key matching.

---

## P3 — Strategic (the moves that actually reach the goal)

### P3.1 Build the domain layer: `pe new <app>` scaffold ⭐ biggest gap
- **Effort:** L — the owner's goal is "build SaaS apps with less code,
  fewer issues, fewer vulnerabilities" — and the engine has NO domain
  layer: no scaffold, no codegen, no reusable modules. Every new app
  rewrites auth/tenancy/billing from scratch with only process discipline
  protecting it. Ship `pe new`: Flask/Postgres/pytest skeleton (the
  proven stack of both adopters), CI gate template pre-wired, engine
  pre-installed, CLAUDE.md/MEMORY.md/session.yaml seeds, TDD directory
  structure. Promote `project-kickstarter`/`project-onboarder` into the
  engine (CAPABILITY_CATALOG already estimates ~1h each).

### P3.2 Extract 3 reusable SaaS modules from the production apps
- **Effort:** L (incremental) — the raw material already exists and is
  inventoried: **8c-tenancy** (8CStudio's proven company-as-tenant RLS +
  generalized tenant-isolation-auditor as its gate), **8c-billing**
  (Origyn's payment_service/provider/webhook stack), **8c-credentials**
  (invoice-system's managed-secrets pattern — already documented as the
  reference implementation in the operator's global rules). Each module
  ships WITH its tests and its reviewing agent — that's how "fewer
  vulnerabilities with less code" materializes.
- **Candidate #4 (added 2026-07-02 evening): 8c-delivery** — once 8CStudio's
  Delivery wedge ships (client galleries: tokened share links + PIN, image
  derivative pipeline, proofing loop, ZIP-on-demand — see 8CStudio
  `docs/PIXIESET_REPLACEMENT_PLAN.md`), the gallery engine is a prime
  extraction: "client file delivery with proofing" generalizes beyond
  photography (design proofs, document delivery, video dailies).

### P3.3 Migrate distribution to a native Claude Code plugin
- **Effort:** M — `plugin.json` is a homegrown manifest, not the native
  format (no `.claude-plugin/`). The symlink model has consumed two
  releases + three docs fighting its pathologies (shadowing, breakage,
  orphans) and has NO version pinning — every adopter rides engine HEAD
  the moment `pe upgrade` runs, which contradicts the engine's own "one
  bad change propagates everywhere" doctrine. Native plugins give
  versioned installs + enable/disable for free; v1.0 roadmap already
  targets marketplace publication. Keep `pe` for what plugins can't do:
  launchd/systemd wiring, RAG index, doctor, gate/shadow/baseline CLIs.
  **Do this before widening the beta cohort** — every symlink-onboarded
  tester is migration debt.

### P3.4 Wire E2.1 token telemetry; make the breaker real
- **Effort:** M — budgets are `"inf"`; the "primary safety guard" is
  decorative; E2.1 is the named prerequisite for FOUR parked roadmap
  items; the core economic thesis (tiered routing is cheaper at equal
  quality) is currently unfalsifiable. Parse Claude Code transcripts or
  OTEL usage events into decisions.jsonl.

### P3.5 Gate efficacy eval harness
- **Effort:** M — zero evidence of gate catch-rate today (no seeded-bug
  corpus; rework_72h is the only quality signal and it's confounded).
  Build 10-20 seeded-defect fixtures per gate; measure catch rate +
  false-verdict rate per model tier; run on every gate-prompt change.
  Also settles the beta severity-calibration question with data.

### P3.6 Close the execution loop (orchestrator invokes workers)
- **Effort:** M-L, **gated on P3.4** — today "graduated enforce mode"
  means the operator obeys a printout; `escalate_one_tier` is a lookup
  table a human executes. Use headless `claude -p` / Agent SDK so
  escalation actually re-invokes at the next tier. The judgment layer
  (failure-class taxonomy, severity floor, shadow→graduate empiricism)
  is genuinely good and worth keeping — it's the plumbing that stops
  short.

### P3.7 Replace the hand-typed envelope cross-check with hook/SDK enforcement
- **Effort:** M — E1.d makes every gate hand-type an "Envelope key
  values" block + run a self-validation ritual (≤3 retries) on EVERY
  iteration — hand-rolled structured outputs. A PostToolUse/Stop hook
  running `pe gate parse` (or SDK structured outputs) gives the same
  guarantee at near-zero marginal cost, removing 5-10 tool calls per
  gate iteration.

### P3.8 Doc consolidation + drift automation
- **Effort:** S-M — commit the EXTERNAL canonical design doc
  (`../process-engine-enhancement-design.md` — currently unversioned,
  invisible to adopters) into the repo as `ARCHITECTURE.md`; absorb
  E1/E1_b/E1_c/PHASE_3 session journals into `docs/adr/` as dated
  decision records; fix the stale claims (E1 §11 lists shipped items as
  open; §6 bare-JSON artifact path contradicted by E1.d — either add a
  sanctioned `--artifact` mode or fix the doc; PHASE_3 documents
  `tier_retry_cap`/`retry_same_tier`/`tier_progression_exhausted` that
  code never implements — implement or delete from policy+docs;
  doc says `policy/*.yaml`, shipped as `.toml`).

### P3.9 SaaS review coverage additions
- **Effort:** M — generalize+ship **tenant-isolation-auditor** (THE
  SaaS-differentiating gate, already written, sitting in ~/.claude);
  add auth-flow checks to security-reviewer (session fixation, OAuth
  redirect-URI, JWT alg/exp/aud, reset-token handling, step-up auth) +
  payments checklist (webhook signature verification, idempotency keys,
  out-of-order events, server-side amount authority, test/live key
  separation); add per-stack scanners (bandit/pip-audit/semgrep — it's
  Node-only today); ship generic migration-reviewer guidance
  (expand/contract, rollback) and an API-contract check (oasdiff or
  schemathesis smoke in CI); seed-data/fixture convention template.

### P3.10 Python test suite + contract parity tests
- **Effort:** M — **zero Python tests exist**; pe_gate (the most
  load-bearing component) is untested; the exit-code table lives in 4
  places with a comment saying "MUST stay in lock-step" (that's a test,
  not a comment). One `tests/test_python.py` (~30 parametrized cases):
  pe_gate validator + cross-check extraction against the fixture corpus
  + adversarial cases (FAIL+none, bool-vs-int, empty examples);
  exit-code/policy/schema parity (every failure_class in the schema enum
  has a TOML rule); baseline rework classifier; chunk_markdown; validate
  baseline.py output against baseline.schema.json. Run on 3.11-3.14 in
  CI. Shell: bats or plain tests for doctor/eject/subset/hooks — all
  currently 0% covered (eject's bash-3.2 crash and the sync crash both
  had zero coverage). Run every test under a path containing spaces.

### P3.11 RAG quality: hybrid retrieval
- **Effort:** M — dense-only retrieval misses exact-token queries (slot
  IDs, SHAs, error strings) — precisely what this corpus gets queried
  for. Add SQLite FTS5 (zero new deps) + reciprocal-rank fusion with
  cosine. Then: store normalized vectors, batch embeds, heading-path
  prefix in chunks. Skip vector DBs entirely at this scale.

### P3.12 Fleet operations + version pinning
- **Effort:** S-M — no adopter registry: write `~/.config/pe/adopters`
  on install → `pe doctor --all`, `pe sync --all`, `pe status --all`.
  Persist `install.engine_version` + `engine_sha` in the project yaml so
  doctor can report drift ("installed at 0.7, engine at 0.9, N new
  files"). Add `pe launchd --remove` + `pe eject --with-skills`
  (uninstall currently punts the system-level half to manual rm).

---

## P5 — Generic quality gates extracted from the 2026-07-02 8CStudio product audit

> The product audit (`8CStudio/docs/PRODUCT_RESTRUCTURE_PLAN.md`) found whole
> *classes* of defect that no current gate catches. Each item below converts a
> one-off finding into a portable engine check so the mistake class can't recur
> in ANY adopter project. Same contract as above: self-contained, any model can
> implement without re-deriving.

### P5.1 App-boot smoke gate ("fresh clone boots") ⭐ highest catch-rate
- **Severity:** HIGH · **Effort:** M · **New files:** `hooks/boot-smoke.sh`, CI template job
- **What happened:** 8CStudio local dev could not boot at all — 4 independent
  failures (wrong interpreter, table creation only in Docker entrypoint,
  migration runner dying silently, login 500 on legacy hash). Nobody noticed
  because nothing ever tested "fresh environment → app answers".
- **Generic check:** CI job + `pe doctor` extension: create a throwaway DB,
  run the project's bootstrap + migrations, start the app, assert `/` or
  `/login` returns <500, assert zero ERROR-level log lines during startup.
  Project declares its boot command in `.process-engine.yaml`
  (`boot_check: {setup: …, run: …, probe_url: …}`); hook skips politely when absent.

### P5.2 Migration-contract lint
- **Severity:** HIGH · **Effort:** S · **New file:** `hooks/migration-lint.sh`
- **What happened:** `migrate_030` calls `sys.exit(0)` in its skip path —
  killed the runner, 107 migrations silently unapplied; `migrate_045` had a
  different call signature and crashed. Both invisible for months.
- **Generic check (pre-commit, paths `migrations/**`):** (a) forbid
  `sys.exit|os._exit|SystemExit` inside migration files; (b) every migration
  defines the runner's expected entrypoint signature (configurable regex);
  (c) CI: run the full migration chain against an EMPTY database and assert
  exit 0 + applied-count == file-count. (c) is the real gate; (a)/(b) fail fast.

### P5.3 Design lint (deterministic, not prompt-hope)
- **Severity:** HIGH · **Effort:** M · **New files:** `hooks/design-lint.sh` + `templates/design-lint.config.template`
- **What happened:** a well-written design system had ~48% compliance: 159
  copy-pasted button variants, 77 hand-rolled modals, 1,400 off-spec radii,
  354 inline styles. Root cause: zero enforcement — every AI-generated page
  drifted. (This is the "AI-generated look" vector too.)
- **Generic check (PostToolUse on Edit/Write of templates + pre-commit):**
  config-driven allowlists — permitted color tokens, radius set, spacing set;
  deny new `style=` attributes, deny `gradient`/`blur` classes if config says
  so, deny raw `<div class="fixed inset-0` modals when a modal macro exists.
  Ships as a generic linter reading `.design-lint.yaml`; 8CStudio's tokens v2
  becomes the first config. Fail = envelope-style FAIL, not a warning.
- **Multi-theme requirement (added 2026-07-02 evening):** the config must
  support multiple named theme scopes per project (path-pattern → theme), not
  one global palette. 8CStudio now has a dark studio-facing shell AND a light
  client-facing Delivery theme (galleries/tenant websites — see 8CStudio
  `docs/PIXIESET_REPLACEMENT_PLAN.md`), each with its own token allowlist.
  One token system, two configs, path-scoped.

### P5.4 Duplication budget (jscpd) — ✅ SHIPPED in v0.13.0 (2026-07-03)
- **Severity:** HIGH · **Effort:** S · **Files:** pre-commit + CI templates
- **What happened:** the 159-button/77-modal explosion is *measurable*
  copy-paste. AI agents duplicate rather than extract — every adopter will
  hit this.
- **Delivered:** `hooks/duplication-gate.sh` runs jscpd project-wide,
  compares current % against baseline in `.jscpd-baseline.json`
  (default 3.0% + 0.1% tolerance for new projects). Any commit that
  RAISES the ratio is blocked. `templates/complexity/jscpd.json.template`
  seeds format allowlist (Python + JS/TS + HTML/Jinja + CSS) with
  standard ignore paths (node_modules, dist, migrations, tests).
  Graceful advisory-skip when jscpd not installed.

### P5.5 Runtime-console + route-integrity smoke (Playwright)
- **Severity:** MEDIUM-HIGH · **Effort:** M · **New file:** `templates/e2e/smoke.spec.ts` template
- **What happened:** every page in the walkthrough logged console errors
  (`/api/me/companies` 500, `/api/v1/auth/me` 401); a sidebar item 404'd
  (`/finance`); placeholder nav items led to dead ends. All invisible to
  pytest.
- **Generic check (E2E stage):** for each nav item discovered from the app's
  nav registry (or a declared list): page loads <500, **zero console.error**,
  no 404s in network log. One extra viewport pass at 375px asserting no
  horizontal scroll on table pages. This single spec would have caught 4
  distinct audit findings.

### P5.6 Confusion-budget test (nav ≤ N items/group)
- **Severity:** MEDIUM · **Effort:** S
- **What happened:** 50+ sidebar items, one group with 18 — the #1 "feels
  cluttered" cause. 8CStudio even HAS a documented confusion-budget rule
  (max 5 primary actions); nothing enforces it.
- **Generic check:** unit test template that imports the project's nav
  registry and asserts per-group item count ≤ configured budget, and that
  every route referenced actually resolves (no placeholder targets unless
  flagged `hidden`/`beta`). Budget lives in `.process-engine.yaml`.

### P5.7 In-app copy lint
- **Severity:** MEDIUM · **Effort:** S
- **What happened:** login page shipped LLM-manifesto copy ("Imagine.
  Create. Together.", floating word-chips); empty states used emoji-as-icon;
  labels mixed Title Case / sentence case. These are the strongest
  "AI-generated" tells and they're grep-able.
- **Generic check (pre-commit on templates):** configurable banned-phrase
  list (default seeded with marketing-fluff patterns: `Innovate`, `Boundless`,
  `Imagine\.`, `Unleash`, `Empower`, emoji in `<button>`/headings), plus
  Title-Case-label detector for buttons. Warn-level by default, FAIL when
  `strict_copy: true`.

### P5.8 Auth-path robustness cases in security-reviewer + test template
- **Severity:** MEDIUM · **Effort:** S
- **What happened:** login 500'd (`ValueError: Invalid salt`) on a legacy
  password hash — unhandled exception in the most public code path.
- **Generic check:** add to security-reviewer's checklist: "auth endpoints
  must not raise on malformed stored credentials / cookies / tokens — assert
  graceful None/401". Ship a pytest template with the standard adversarial
  cases (malformed hash, oversized input, null bytes, expired token).

### P5.9 AI-aesthetic tells → reviewer checklist
- **Severity:** MEDIUM · **Effort:** S · **File:** ui/design reviewer agent (or code-reviewer UI section)
- Codify the tells list from PRODUCT_RESTRUCTURE_PLAN Phase A+ as a review
  rubric: stock-token dark+cyan+gradient palette, glow effects, manifesto
  copy, card-grid-as-menu dashboards, over-padding, emoji icons, default
  font pairing, no signature element. Verdict rule: ≥3 tells on a new screen
  = FAIL with "match the locked reference screen" instruction. Pairs with
  P5.3 (deterministic) — this catches what lint can't.

---

## P6 — Code-simplicity toolchain ("less code" made enforceable)

> Goal: stop AI overbuild at BOTH ends — generation time (skill/prompt) and
> commit time (deterministic gates). AI agents reliably fail at brevity when
> asked; they comply when the environment refuses verbose output.

### P6.1 Adopt **Ponytail** at generation time — ✅ SHIPPED in v0.13.0 (2026-07-03)
- **Effort:** S · **Where:** engine install step + agent preambles
- [Ponytail](https://github.com/DietrichGebert/ponytail) is an open-source
  Claude Code skill forcing a decision ladder before code: *needs to exist? →
  stdlib? → platform-native? → installed dep? → one line? → only then write
  minimum*. Published evals: ~54% avg LOC reduction, 100% safety held.
- **Delivered:** `pe install --with-ponytail` (via `scripts/install.sh`
  flag) — idempotent git clone into `~/.claude/skills/ponytail/`;
  graceful skip on missing git / offline. tdd-guide + build-error-
  resolver preambles reference the ladder in a short paragraph that
  points at the skill path when installed and falls back to inline
  prose when not. Kept short — the skill owns the deep spec.

### P6.2 Deterministic complexity + dead-code gates — ✅ SHIPPED in v0.13.0 (2026-07-03)
- **Effort:** S-M · **Files:** pre-commit + CI templates
- **Delivered:** `hooks/complexity-gate.sh` feature-detects and runs:
  * Python: `ruff check --select C901,PLR,B,SIM,RET,UP` (mccabe ≤ 10 +
    pylint refactor + bugbear + simplify + returns + pyupgrade),
    `xenon --max-absolute B`, `vulture` (with allowlist file support).
  * JS/TS: `knip` (dead exports/files/unused deps) + `eslint`
    (`complexity` ≤ 10 + `max-depth` 4 + `max-lines-per-function` 50).
  Config templates ship at `templates/complexity/{ruff,vulture-
  allowlist,knip,eslintrc-complexity}.*` and get copied to
  `docs/templates/complexity/` by `pe install`. Toggle via
  `.process-engine.yaml → complexity_gate.enabled` (default true) +
  `complexity_gate.strict` (default false — xenon exit code becomes
  blocking only under strict).

### P6.3 Net-LOC + size budgets in CI — ✅ SHIPPED in v0.13.0 (2026-07-03)
- **Effort:** S
- **Delivered:** `hooks/size-budget.sh` — pre-commit hook enforcing
  net-LOC WARN 250 / FAIL 600 (bypass via `Size-justified:` trailer),
  per-file FAIL 800 lines (only on source paths — `src/`, `app/`,
  `modules/`, `lib/`, `scripts/`, `hooks/`, `agents/`, `commands/`,
  `internal/`, `pkg/`, `cmd/`), per-function FAIL 50 lines for
  `.py` (AST-based, exact) and `.js/.ts` (regex-lite, under-catches
  but never over-catches). Toggle + tune via
  `.process-engine.yaml → size_budget.*`. Bypass one commit:
  `PE_SKIP_SIZE_BUDGET=1`. 4/4 threshold + bypass paths tested.

### P6.4 `/simplify` stage in the slot pipeline — ✅ SHIPPED in v0.13.0 (2026-07-03)
- **Effort:** S
- **Delivered:** new `commands/simplify.md` — Post-GREEN cleanup
  pass. Precondition: tests pass. Postcondition: tests still pass
  AND diff is smaller or the same (net_lines_delta > 0 = FAIL).
  Five-step scan (dead code → reuse over rewrite → altitude → size
  cross-check → re-run tests). Envelope goes into
  `.claude/gates/last-gate.json` like other stages.
  `/new-feature` chain updated: brainstorm → brief → architect →
  plan → tdd → impl → **simplify** → code-review.

### P6.5 Duplication ratchet
- Covered by P5.4 — listed here because it's also the strongest simplicity
  metric: duplication % + complexity grade + net-LOC trend together give the
  retro an objective "are we getting simpler" answer (feeds P3.4 telemetry).

---

## P7 — Operator workflow upgrades (Claude Code usage)

> Full analysis + the new operating model: **`docs/OPERATOR_WORKFLOW_V3.md`**
> (written 2026-07-02). Headline findings, kept here for the checklist:

- **P7.1 Context diet (engine half) — ✅ SHIPPED in v0.12.0 (2026-07-02)**
  `hooks/claude-md-size.sh` rewritten as dual-mode guard: PostToolUse
  (fires the instant CLAUDE.md is edited in a Claude Code session) +
  pre-commit (blocks at hard limit). Thresholds split: WARN=12KB,
  FAIL=20KB. Wired in `hooks/hooks.json` PostToolUse chain +
  `hooks/.pre-commit-config.yaml.template`. Model-tier updates:
  `templates/process-engine.yaml.template` swapped the `claude-opus-4-7`
  pin for `claude-opus-4-8` + a documented Claude 5 era ladder;
  `install_launchd.sh` threads `ceo_weekly.model` through as
  `{{CEO_MODEL}}`; the 3 Run-Weekly templates (launchd/systemd/Windows)
  no longer hardcode. Illustrative examples across 5 gate agents +
  gate-envelope schema updated to `sonnet-5` / `opus-4-8` / `haiku-4-5`.
  (Product half — trimming 8CStudio CLAUDE.md from 74KB → ≤12KB — is
  8CStudio-side work and stays with the product track.)
- **P7.2 Model routing is stale:** operator global rules still route to
  "Sonnet 4.6 / Opus 4.5 / Haiku 4.5" and yaml pins `claude-opus-4-7`.
  Update to the Claude 5 era: Fable 5 (audits/architecture/design
  direction/hard debugging), Opus 4.8 (foundational slots: RLS, auth, money),
  Sonnet 5 (default dev), Haiku 4.5 (mechanical batches). See V3 doc §3.
  (Engine yaml pin already dropped in v0.12.0 P7.1; global rules
  update stays operator-side.)
- **P7.3 Retro unstall — ✅ SHIPPED in v0.12.0 (2026-07-02)**
  New `scripts/dev-log-collect.sh` + `pe collect` subcommand — portable,
  git-derived, zero Claude tokens. Reads `git log --numstat` +
  `.claude/gates/*.json` in the window; writes
  `docs/dev-log/daily/<date>.{json,md}`. `retrospective-agent` Step 0
  now runs `pe collect` before reading anything, guaranteeing a fresh
  digest even in adopters that never wired the previous private
  collector. Degraded-mode fallback documented + strengthened.
  `docs/RHYTHM.md` gained a "Wiring the collector" section (launchd /
  cron / manual). Every adopter now has the same working feedback loop.
- **P7.4 Skills/agents sprawl:** 67 global skills + duplicated
  project/user copies (data-audit, health, kickstart, onboard each appear
  twice) + stale `~/.claude/agents` forks (P2.10). Run a skills stocktake;
  keep <20 curated; engine owns the rest via subset.
- **P7.5 Missing modern primitives:** no worktree parallelism, no headless
  `claude -p` batch runs for mechanical slots, no background-agent usage in
  the documented workflow. V3 doc §4 defines when each applies.

---

## P4 — Deliberately NOT now

- **Phase 4 DAG scheduler** — stays parked (COUPLING_MAP data supports it).
- **Auto-tier-routing** — gated on P3.4 telemetry (correctly).
- **Engine self-modification** — never, by design (correct).
- **Dedicated vector DB** — overkill at this corpus scale.
- **pe_core Python package** — only if a 5th script appears; parity
  tests (P3.10) cover the drift risk at current size.

---

## Suggested execution order

1. **Session 1 (S, mostly one-liners):** P0.1-P0.12 + tests hardened in
   the same commits → v0.9.1 patch release.
2. **Session 2 (M):** P1.1-P1.6 enforcement bundle → v0.10.0 "promises
   are now real".
3. **Session 3 (M):** P2.1-P2.5 agent portability bundle (generic
   database-reviewer, gate-contract extraction, tdd-guide rewrite,
   ceo/retro parameterization) → v0.11.0.
4. **Session 4+ (L):** P3.1 `pe new` + P3.2 first module (8c-tenancy) —
   the domain layer. In parallel: P3.3 plugin migration before beta
   widening; P3.4 telemetry; P3.10 test suite.
5. **Validation:** P3.5 eval harness, then build the third app through
   `pe new` and treat every gap it hits as P1 backlog — that's the only
   honest test of "less code, fewer issues".
6. **Session 5 (added 2026-07-02):** P7.1 context diet + P7.3 retro unstall
   + P6.1 Ponytail + P6.2 complexity gates (all S, one sitting) → immediate
   token savings + working feedback loop. Then P5.1/P5.2/P5.3 boot-smoke +
   migration-lint + design-lint as v0.11.0 gate additions, P5.4-P5.9 +
   P6.3-P6.4 following. Operator workflow changes:
   `docs/OPERATOR_WORKFLOW_V3.md`.

> **SEQUENCED BY THE PRODUCT ROADMAP (2026-07-02):** engine work is now
> interleaved with the 8CStudio product build, not run as a separate track.
> The authoritative order lives in **`../../8CStudio/docs/ROADMAP.md`**
> (created 2026-07-02) — engine gates map to its waves as: P7.1/P7.3 = Wave 0.2/0.3;
> P5.1/P5.2 boot-smoke + migration-lint = Wave 0.4/0.5 (harden #227's fixes);
> P5.3 design-lint = Wave 1.3 (after tokens v2 locks); P6.1/P6.2 = Wave 1.4;
> P5.4-P5.9 + P6.3-P6.4 = the parallel backfill lane. P0/P1/P2 already SHIPPED
> (v0.9.1/0.10.0/0.11.0). Pick engine slots by which product wave they de-risk,
> not by P-number order.
