# Changelog

All notable changes to `8colors-process-engine`.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.15.0] — 2026-07-03

> Python hygiene batch — P2.11. Twenty targeted fixes across
> `pe_gate.py`, `pe_orchestrator.py`, `baseline.py`, and
> `research_index.py`, each addressing a latent bug that would
> silently corrupt data or mis-route control flow. Ships with 22 new
> unittest cases (86 total tests pass).
>
> Last item on the "make engine perfect" backlog. P3.x stays parked
> per plan. Next: 8CStudio #227.

### Fixed

**pe_gate.py:**
- `ENGINE_SCHEMA_MAJOR` const replaces
  `schema.properties.schema_version.examples[0]` — an empty
  `examples` array would `IndexError` and kill the validator.
- `argparse`-based CLI replaces the hand-rolled flag loop; `--bare`
  can now appear after the positional path (`pe gate parse foo.txt
  --bare`) and vice-versa.
- Transcripts read with `utf-8-sig` — Windows Notepad-saved
  transcripts with a leading BOM used to parse-fail cryptically.
- `classify_exit` on `verdict=FAIL` with missing/None
  `failure_class` now explicitly defaults to `worker_quality`
  (escalate) via a named constant. Defaulting to a non-escalating
  class would silently absorb genuine worker failures.

**pe_orchestrator.py:**
- New `PolicyError` exception + `KeyError → PolicyError → exit 4`
  path. Previously a missing key in `circuit_breaker.toml` bubbled
  as a raw Python `KeyError` traceback with no fix-it hint.
- Budget-trip check accepts `int` OR `float` (rejects `bool`). A
  float budget in TOML used to silently disable enforcement.
- `cache_read_tokens` counted at 10 % weight (Anthropic's
  documented cache-read cost). Full-weight previously overcharged
  the gate budget and tripped the breaker early on cache-heavy runs.
  Weight configurable via `cumulative.cache_read_weight`.
- `reconcile` now validates the stdin payload: both `merge_commit`
  and `ultimate_outcome` are required; `ultimate_outcome` must be
  one of `{success, merged, reverted, abandoned, pending}`. All-null
  payloads used to be written to the reconciliations log silently.
- `--iteration` now enforced `>= 1` via a custom argparse type.
  Zero and negative iterations silently disabled the cap check.
- New `--campaign-id` flag on `decide`; new `pe shadow reset`
  subcommand. Cumulative breaker sidecar is now per-campaign, and
  can be reset idempotently. Pre-P2.11 cross-campaign runs
  contaminated each other's budgets forever.

**baseline.py:**
- `HOUSEKEEPING_PREFIX_RE` gained a negative lookahead
  `chore(?!\(fix\))` so `chore(fix): …` reaches the rework
  detector instead of being filtered as housekeeping. Documented
  `chore(fix)` fix prefix was silently dead.
- `FIX_PREFIX_RE` replaced `\b` (which never matched between two
  non-word chars — `)` and `:` are both non-word) with a positive
  lookahead `(?=[:(\s]|$)`. This was a pre-P2.11 latent bug that
  meant `chore(fix)` couldn't have matched even without the
  housekeeping regex bug. Both bugs together made the alternation
  fully dead.
- New `GitError` exception wraps `CalledProcessError` and surfaces
  git's `stderr` in the message. Previously raw tracebacks bubbled
  with stderr captured but never surfaced.

**research_index.py:**
- `FastEmbedEmbedder.__init__` catches `ImportError` AND `TypeError`
  (the protobuf-under-Python-3.14 incident). Actionable fix-it
  message includes both root cause and version-compat note.
- `chunk_markdown` splits paragraphs longer than `MAX_PARA_CHARS`
  (= `CHUNK_SIZE`, 800) before assembly. BGE-small silently
  truncated at ~512 tokens; long code blocks lost their tail from
  the embedding.
- New `Embedder.embed_docs_batch` interface + FastEmbed override.
  Rebuild loop now batches instead of one-embed-per-chunk.
- Rebuild loop embeds FIRST, then decides whether to insert the
  doc row. Previously the doc row was inserted before embedding, so
  if every chunk failed, an empty doc row with correct sha256 stayed
  forever — subsequent rebuilds skipped it (sha match), leaving a
  permanent index hole.
- Query-time embedder check now compares `MODEL` in addition to
  `DIM`. Two different models with the same dim used to silently
  mix embedding spaces.
- Result dedupe happens BEFORE trimming to top-K. "Top 5 all from
  doc X" used to collapse to 1 visible result; now the walk yields
  distinct docs up to top-K.
- `read_yaml_field` bails out when a subsequent line's indent goes
  shallower than the target indent — used to descend into sibling
  top-level blocks looking for a child key, matching wrong-parent
  values.

### Added

- **`tests/test_p2_11_python_hygiene.py`** — 22 unittest cases
  covering every listed P2.11 fix. Zero external dependencies
  (stdlib `unittest` + `unittest.mock`). Runs via
  `python3 tests/test_p2_11_python_hygiene.py` or via the shell
  wrapper `tests/test_p2_11_python_hygiene.sh` alongside the other
  4 test scripts.

### Test totals

86 pass (9 sync + 10 install-reconcile + 12 hooks + 33 orchestrator
shell + 22 P2.11 unittest).

### Backlog after v0.15.0

**P3.x stays parked** per the original plan:
- P3.1 `pe new <app>` scaffold — L effort, multi-week
- P3.2 3 SaaS modules (`8c-tenancy`, `8c-billing`, `8c-credentials`)
  — L effort each; needs 8CStudio settled after #227 to know the
  final module shape
- P3.3 Native Claude Code plugin migration
- P3.4 Telemetry

Next: switch to 8CStudio for #227 dev-env repair — the true
critical-path blocker. Engine returns for P3.x after #227 lands
and 8CStudio is stable.

---

## [0.14.0] — 2026-07-03

> Product-quality gates. Every finding from the 8CStudio audit gets a
> generic, config-driven gate that ships to every adopter. Eight P5.x
> items land together — four new pre-commit hooks, four new templates,
> two agent updates.
>
> Product-specific assertions (like #227's exact fixes) parameterize
> later; the scaffolds ship now.

### Added

- **`hooks/boot-smoke.sh`** (P5.1) — "fresh clone boots" gate.
  Reads `.process-engine.yaml → boot_check.{setup, run, probe_url,
  timeout_seconds, expected_max_status}`, brings up a throwaway env,
  probes the URL, kills the app. Fails on missing probe response,
  probe status ≥ configured max, OR any `^ERROR` / `^CRITICAL` line
  during startup. Wired for `pe doctor` + CI (NOT pre-commit — boot
  is slow).
- **`hooks/migration-lint.sh`** (P5.2) — pre-commit hook enforcing
  the migration contract. Forbids `sys.exit|os._exit|SystemExit`
  in migration files (the exact class that hid 107 unapplied
  8CStudio migrations for months). Optional entrypoint-regex check
  for adopters that want it. Path prefix configurable.
- **`hooks/design-lint.sh`** (P5.3) — multi-theme deterministic
  design lint. Pre-commit + PostToolUse dual-mode. Config at
  `.design-lint.yaml` with per-theme `path_patterns` +
  `forbid_class_fragments` + `forbid_inline_regex` + `color_tokens`
  allowlist. Enforces: no inline `style=`, no raw `<div class="…
  fixed inset-0"` modals, no `gradient-`/`blur-`/`backdrop-blur`
  class fragments, colors within the theme's allowlist (WARN or
  FAIL under strict).
- **`hooks/copy-lint.sh`** (P5.7) — in-app copy lint. Regex-driven
  banned-phrase list (default: `Imagine. Create. Together.`,
  `Innovate`, `Boundless`, `Unleash`, `Empower`, `Elevate`,
  `Seamless`, `Reimagine`, "Transform the …"), emoji-in-`<button>` /
  emoji-in-heading detection, Title-Case button-label detector.
  Default WARN; adopter flips `copy_lint.strict=true` to enforce.
- **`templates/design-lint.config.template`** — multi-theme schema
  starter. Three example themes (studio / delivery / _default) with
  commented-out token/allowlist blocks ready to fill.
- **`templates/e2e/smoke.spec.ts.template`** (P5.5) — Playwright
  spec that iterates the app's nav registry and asserts: page <500,
  zero `console.error`, zero 404/5xx in network log, no horizontal
  scroll at 375px on list/table pages. Two nav-discovery patterns
  supported (endpoint + static fallback).
- **`templates/tests/nav-confusion-budget.test.py.template`**
  (P5.6) — pytest template. Loads project nav registry, asserts per-
  group item count ≤ budget (from `.process-engine.yaml →
  confusion_budget.per_group`, default 5), verifies every non-hidden
  route resolves.
- **`templates/tests/auth-robustness.test.py.template`** (P5.8) —
  pytest template covering: wrong-password → 401, unknown-user → 401,
  malformed bcrypt hash → 401/400 (the exact 8CStudio audit case),
  empty stored hash, null bytes in password, oversized email,
  oversized password, null password, user-existence leak comparator.

### Changed

- **`agents/security-reviewer.md`** — OWASP §2 "Broken Auth" gained
  the P5.8 auth-path robustness checklist. Any 500 on an auth
  endpoint from the standard adversarial cases is now a CRITICAL
  finding, not HIGH.
- **`agents/code-reviewer.md`** — new "UI review — AI-aesthetic tells
  rubric (P5.9)" section under the v1.8 AI-Generated addendum. Nine
  telltales (stock-token palette, glow effects, manifesto copy,
  card-grid-as-menu, emoji-as-icon, over-padding, default fonts,
  word-chip UI, no signature element). ≥3 tells on a new/reworked
  screen → FAIL verdict, rule `p59.ai_aesthetic_rubric.tells_exceeded`,
  instruction to match a locked reference screen.
- **`hooks/.pre-commit-config.yaml.template`** — wires
  `migration-lint`, `design-lint`, `copy-lint` (boot-smoke is NOT in
  pre-commit — slow). Env-var comment updated with new `PE_SKIP_*`
  bypass keys.
- **`hooks/hooks.json`** — `design-lint.sh` added to the PostToolUse
  Edit|Write|MultiEdit chain so template edits surface violations
  during the same session turn.
- **`templates/process-engine.yaml.template`** — five new opt-in
  sections: `boot_check`, `migration_lint`, `design_lint`,
  `copy_lint`, `confusion_budget`. All configured with safe defaults;
  `boot_check` requires the operator to fill in commands (starts
  disabled).
- **`scripts/install.sh`** — copies `templates/design-lint.config.template`,
  `templates/e2e/*`, `templates/tests/*` into
  `<project>/docs/templates/`. Idempotent — never overwrites edits.
- **`plugin.json`** description reflects v0.14.0 additions
  (15 git-side hooks now; product-quality gates listed).

### Session pickup (v0.15.0 next, this session)

**P2.11 Python hygiene batch** — pe_gate + orchestrator + baseline +
research_index. ~15 sub-fixes; focused pytest coverage in the same
commit per the plan's own note. Last item on the "make engine
perfect" backlog.

Then P3.x parked as planned. Switch to 8CStudio for #227 after
v0.15.0 lands.

---

## [0.13.0] — 2026-07-03

> Simplicity toolchain — "less code" made deterministic. Ships the
> P6 code-simplicity backlog + P5.4 duplication ratchet in one
> coherent release. Five items land together because they share the
> same story: gates that make brevity enforceable at commit time.
>
> All existing tests pass; the new hooks feature-detect their tools
> and skip advisory-mode when unavailable — safe to install into any
> adopter without breaking their pipeline.

### Added

- **`hooks/complexity-gate.sh`** (P6.2) — pre-commit hook that
  feature-detects `ruff`, `xenon`, `vulture`, `knip`, and `eslint`;
  runs each against staged files with engine-recommended rules
  (`C901,PLR,B,SIM,RET,UP` for ruff; `--max-absolute B` for xenon;
  `complexity`/`max-depth`/`max-lines-per-function` for eslint).
  Advisory mode when a tool isn't installed; blocks the commit only
  when the tool ran AND failed.
- **`hooks/duplication-gate.sh`** (P5.4 / P6.5) — pre-commit hook
  that runs `jscpd` project-wide and enforces a RATCHETING baseline
  from `.jscpd-baseline.json`. Duplication % may only go DOWN;
  raises are blocked. Handles missing jscpd via graceful skip.
- **`hooks/size-budget.sh`** (P6.3) — pre-commit hook enforcing
  net-LOC (WARN 250 / FAIL 600), per-file (FAIL >800 on source
  paths), and per-function (FAIL >50 for `.py` via AST + `.js/.ts`
  via regex-lite). Net-lines gate accepts a `Size-justified:`
  trailer for legitimate large commits; per-file/per-function
  always block. Tested in isolation — 4/4 threshold/bypass paths pass.
- **`templates/complexity/`** — five config templates dropped into
  every adopter at `docs/templates/complexity/`:
  `ruff.toml.template`, `vulture-allowlist.txt.template`,
  `knip.json.template`, `eslintrc-complexity.json.template`,
  `jscpd.json.template`, plus a `README.md` explaining the ladder.
- **`commands/simplify.md`** (P6.4) — new `/simplify` chain stage.
  Runs AFTER green tests, BEFORE code review. Enforces the Ponytail
  ladder + dead-code / reuse / altitude cleanups. Its envelope's
  PASS condition is "tests still green AND diff ≤ input". FAIL
  reverts its own changes.
- **`commands/new-feature.md`** — Stage 6.5 (`/simplify`) inserted
  into the pipeline; existing 7-stage chain becomes 8-stage.
- **`scripts/install.sh`** `--with-ponytail` flag (P6.1) — clones
  `github.com/DietrichGebert/ponytail` into
  `~/.claude/skills/ponytail/`. Idempotent (git pull on re-run).
  Graceful skip on missing git / offline.
- **`agents/tdd-guide.md`** and **`agents/build-error-resolver.md`**
  gained a Ponytail decision-ladder preamble (P6.1) referencing the
  skill by path when installed, falling back to inline ladder prose
  when not. Kept short — the skill owns the deep spec (P2.3 lesson).
- **`templates/process-engine.yaml.template`** — four new opt-out-
  able sections: `complexity_gate`, `duplication_gate`,
  `size_budget`, `ponytail`. All default sensibly.

### Changed

- `hooks/.pre-commit-config.yaml.template` wires the three new
  gates as pre-commit stages. Env-var comments updated with all
  new `PE_SKIP_*` bypass keys.
- `README.md` badge → 0.13.0. Slash-commands count corrected
  9 (was stale at 5).
- `plugin.json` description reflects the v0.13.0 additions:
  9 commands, 11 git-side hooks, complexity/duplication/size gates,
  Ponytail, `/simplify`.

### Fixed

- The "less code" narrative had NO deterministic backstop. Global
  rules said 50-line functions, 800-line files, no dead code — but
  nothing checked. v0.13.0 ships the checkers.
- Duplication was invisible. First commit against a legacy project
  self-baselines at whatever it finds; every subsequent commit is
  gated on not raising it.

### Session pickup (v0.14.0 next)

Product-quality gates from the 8CStudio audit: P5.1 boot-smoke +
P5.2 migration-lint + P5.3 design-lint + P5.5 Playwright console+
route smoke + P5.6 confusion budget + P5.7 copy lint + P5.8
auth-robustness + P5.9 AI-aesthetic rubric. All shippable now as
generic scaffolds; 8CStudio-specific assertions parameterize when
#227 lands.

---

## [0.12.0] — 2026-07-02

> P7.1 context diet (engine half) + P7.3 retro unstall. Both were
> ROADMAP Wave 0.2/0.3. Pays off every subsequent session — the
> context-size guard cuts per-turn tokens, the collector restores
> the feedback loop that catches drift.
>
> All 64 tests pass.

### Added

- **`hooks/claude-md-size.sh`** rewritten as dual-mode guard (P7.1).
  - **Pre-commit mode:** invoked by git-side pre-commit framework.
  - **PostToolUse mode:** invoked by Claude Code after Edit/Write/
    MultiEdit; auto-detects when the edited path is `CLAUDE.md`.
  - Two thresholds instead of one:
    `ENGINE_CLAUDE_MD_WARN=12000` (advisory, exit 0) /
    `ENGINE_CLAUDE_MD_FAIL=20000` (blocks commit, exit 1).
  - Legacy `ENGINE_CLAUDE_MD_LIMIT` still respected (maps to FAIL).
  - Bypass via `PE_SKIP_CLAUDE_MD_SIZE=1`.
- **`hooks/hooks.json`** now wires `claude-md-size.sh` as a
  PostToolUse hook alongside `post-edit-lint.sh` (P7.1). Fires the
  size warning the moment CLAUDE.md crosses the soft limit —
  operators no longer wait until commit time to notice bloat.
- **`scripts/dev-log-collect.sh`** — new portable git-derived
  daily digest collector (P7.3). Reads `git log --numstat` +
  `.claude/gates/*.json` in the window; writes JSON + Markdown to
  `docs/dev-log/daily/<date>.{json,md}`. Zero Claude tokens.
  Replaces the 8CStudio-specific ambient collector that went stale
  after 2026-W21.
- **`pe collect`** subcommand — thin wrapper over the collector,
  bare-path positional syntax supported (`pe collect <project>`).
- **`agents/retrospective-agent.md`** — Step 0 now runs
  `pe collect` before reading anything; degraded-mode fallback
  strengthened ("collector unavailable" instead of "collector not
  installed" — accurate given the collector now always ships).
- **`docs/RHYTHM.md`** — "Wiring the collector" section documents
  daily launchd/cron wiring; retro sequence updated to include the
  Step 0 run.

### Changed

- **`templates/process-engine.yaml.template`** — `ceo_weekly.model`
  pin `claude-opus-4-7` → `claude-opus-4-8` + inline Claude 5 era
  ladder comment (Fable / Opus 4.8 / Sonnet 5 / Haiku 4.5) and
  explicit instruction to `claude --list-models` before adopting.
- **`scripts/install_launchd.sh`** — `ceo_weekly.model` now threads
  through as a template variable (`{{CEO_MODEL}}`) with charset
  validation. Templates no longer hardcode model IDs — one source
  of truth, adopter-controlled.
- **`templates/{launchd,systemd,windows-task-scheduler}/Run-Weekly.{sh,ps1}.template`**
  — `--model claude-opus-4-7` → `--model {{CEO_MODEL}}`.
- Illustrative model examples in prose across the 5 gate agents
  (`code-reviewer`, `security-reviewer`, `database-reviewer`,
  `tdd-guide`, `e2e-runner`) + `schemas/gate-envelope.schema.json`
  updated to Claude 5 era (`sonnet-5` / `opus-4-8` / `haiku-4-5`).
  Contract is unchanged: agents still report the runtime model ID,
  never hardcode.
- **`hooks/.pre-commit-config.yaml.template`** — hook name reflects
  new thresholds; env var comments updated (WARN/FAIL split;
  LIMIT deprecated with mapping note).
- **`.gitignore`** — `docs/dev-log/daily/`, `weekly/`, `monthly/`
  (regenerable, per-machine snapshots — not source).

### Fixed

- Retro feedback loop restored. Before: retrospective-agent
  expected `docs/dev-log/daily/*.json` files that were only
  produced by 8CStudio's private tooling — every other adopter
  ran degraded. After: `pe collect` ships with the engine, works
  identically in every adopter, and the agent's Step 0 guarantees
  a fresh digest.

### Session 6 pickup (per IMPROVEMENT_PLAN)

- **P6.1 Ponytail adoption** — `pe install --with-ponytail`
  (skill, not prose per P2.3 lesson).
- **P6.2 Deterministic complexity + dead-code gates** — ruff C901
  + xenon + vulture (Python) / knip + eslint complexity (JS/TS).
  ROADMAP Wave 1.4.
- Then #227 dev-env repair in the 8CStudio repo (product track,
  the true critical-path blocker) — engine returns for P5.1/P5.2
  after #227 lands so the gates encode the actual fixes.

---

## [0.11.1] — 2026-07-02

> P2.10 reconcile-operator-machine-agents follow-up. Structural fix,
> not a feature bump. Kills the E1_b propagation gap for good:
> `~/.claude/agents/` no longer holds any stale regular-file copies.
>
> All 64 tests pass.

### Added

- `agents/tenant-isolation-auditor.md` — promoted from user-global to
  engine (137 lines). Scans recent git history for new SQL crossing
  tenant boundaries without RLS context.
- `agents/project-kickstarter.md` — promoted from user-global to
  engine (190 lines). Scaffolds new projects with full structure,
  testing, linting, CLAUDE.md.
- `agents/project-onboarder.md` — promoted from user-global to
  engine (114 lines). Analyzes existing projects against standard
  rules, generates + applies improvement plan.
- Tools frontmatter of the three promoted agents normalized to the
  P2.9 array-of-strings style (`tools: ["Read", ...]`).

### Changed

- `~/.claude/agents/` reconciled (**operator machine**): 14 regular-
  file agent copies replaced with symlinks into
  `.../8colors-process-engine/agents/`. Every project without
  project-local symlinks now sees the engine version — no more
  silent shadowing of the E1 gate-envelope contract by
  pre-envelope-era user-global copies (the exact class that caused
  the E1_b incident).
- `~/.claude/agents/ui-ux-design-agent.md` moved to
  `8CStudio/.claude/agents/ui-ux-design-agent.md` (project-local).
  Content is 8CStudio-specific (v0.dev budget, Alpine/Tailwind/
  Jinja, filmmaker audience) — symmetric with the P2.1 project-local
  `database-reviewer.md` fork pattern.
- `plugin.json` description: "15 agents" → "18 agents".
- `README.md`: "15 specialist agents" → "18 specialist agents"; the
  Agents table gained rows for build-error-resolver,
  data-model-auditor, database-reviewer, e2e-runner,
  memory-consolidator, retrospective-agent, project-kickstarter,
  project-onboarder, tenant-isolation-auditor (previously 9 stale
  rows; now 18 matching disk).
- `INSTALL.md` heading `## v0.2.0 Optional: wire CEO weekly retro` →
  `## Optional: wire CEO weekly retro`. Removes false-positive drift
  warning from `pe docs check`. Historic origin captured in
  changelog.

### Fixed

- `pe docs check` was flagging INSTALL.md's `## v0.2.0 ...` heading
  as version drift. Heading rephrased; check now exits 0 cleanly.

### Adopter impact

- `pe install /path/to/adopter` picks up the 3 promoted agents
  automatically (no manual copy).
- 8CStudio and Origyn re-installed against v0.11.1 during this
  session — both report 18 clean engine symlinks (8CStudio 19 with
  the local `ui-ux-design-agent.md`), zero user-global collision
  warnings.

---

## [0.11.0] — 2026-07-02

> P2 agent-portability + shell-robustness bundle. Nine P2 items land.
> `IMPROVEMENT_PLAN.md` grew new P5 (product-audit gates), P6
> (code-simplicity toolchain), P7 (operator workflow V3) sections
> plus `docs/OPERATOR_WORKFLOW_V3.md`. Session 5 (per updated plan)
> picks up P7.1 + P7.3 + P6.1 + P6.2 first.
>
> All 64 tests pass (9 sync + 10 install-reconcile + 33 orchestrator + 12 hooks).

### Added

- `agents/_gate-contract.md` — SPEC (not runnable). Canonical source
  of truth for the E1 gate-envelope contract. All five gate agents
  point at it via a "Spec source of truth" note; scripts skip
  `_*.md` files so it doesn't ship as a runnable agent.
- `scripts/_yaml.sh` — shared `yaml_get <dot.path>` + `yaml_bool_get`
  helpers. One reader replaces four ad-hoc grep/sed/awk/python-
  heredoc readers previously scattered across `install.sh`,
  `install_launchd.sh`, `pe doctor`, and `_hooks.sh`.
- `pe docs check` — release-checklist subcommand. Greps VERSION
  against README badge + plugin.json + INSTALL.md, cross-checks
  agent/command counts on disk vs claimed. Exits 1 on any drift.

### Changed

- **`agents/database-reviewer.md` de-project-ified (P2.1).** Engine
  ships a **generic** Postgres + multi-tenant SaaS reviewer
  (tenant-isolation, migration-discipline, query-safety, schema-
  quality, index-quality). 8CStudio's architecture-specific version
  forked into `8CStudio/.claude/agents/database-reviewer.md` — that
  project-local override wins for 8CStudio; other adopters get the
  generic one.
- **`security-reviewer` and `database-reviewer` no longer have
  `Write` or `Edit` tools (P2.2).** Reviewers do not modify code they
  judge. Gate-identity boundary documented in each agent's
  frontmatter block.
- **`agents/tdd-guide.md` rewritten as an executable state machine
  (P2.4).** Phase 0 stack detection (pytest / npm / go / cargo / mvn
  / mix); Phase 1 RED-first with verbatim failure output paste;
  Phase 2 GREEN; Phase 3 REFACTOR (tests-stay-green); Phase 4
  COVERAGE with 80% delta floor. `Glob` added to tools. Identity
  clarified.
- **`agents/e2e-runner.md`** — gate-identity note added: hybrid
  worker+state-envelope, never self-grades tests it authored.
- **`agents/planner.md`** — `Bash` + `Write` added to tools;
  MANDATORY Step 0 (semantic-index prior-art query) documented;
  plan-artifact output path + required sections specified.
- **`agents/ceo.md`** — hardcoded "Sanish"/"LANE 1" 8CStudio-isms
  replaced with "the operator" phrasing.
- **`agents/researcher.md`** — bumped `haiku` → `sonnet`; brittle
  "<100 stars = reject" rule softened to a weighted signal.
- **`agents/build-error-resolver.md`** — Phase 0 stack detection
  (TS/JS, Python, Go, Rust, Java Maven/Gradle); per-stack diagnostic
  commands.
- **`agents/data-model-auditor.md`** — description upgraded to
  "Use PROACTIVELY when..." pattern; `Write` added.
- **`agents/doc-updater.md`** — command detection (feature-detect,
  don't assume); graceful degradation when project-specific tooling
  absent; multi-stack diagnostic commands.
- **`agents/retrospective-agent.md`** — degraded mode. Runs when
  dev-log collector absent by deriving from git log + decisions.jsonl
  + baselines alone. Report header notes the degradation.
- **`commands/brainstorm.md`** — Soniox/8CStudio/Lipi references
  removed; now tool-agnostic.
- **All 5 gate agents — hardcoded `claude-sonnet-4-6` in exemplars
  replaced with `<your-model-id>` placeholder** (P2.3). Header note
  in each agent explains the substitution. Fixes the "envelope lies
  about model" class.
- **Tool frontmatter normalised** (P2.9) — three styles collapsed to
  `tools: ["Read", ...]` across all 15 agents.
- **`scripts/install.sh` docs allowlist** (P2.8). Previously
  `cp -r docs/*` shipped HANDOFF/BACKLOG/session notes into every
  adopter. Now: 9-item allowlist, copy-if-absent.
- **`scripts/install.sh` creates `.gitignore` if absent** (P2.8);
  new pattern `.claude/gates/` added.
- **`scripts/install.sh` `shopt -s nullglob`** for empty-directory
  glob safety.
- **`scripts/install_launchd.sh` injection hygiene** (P2.7). Python
  heredoc → `sys.argv`; sed template rendering → python
  `str.replace`; missing `org_tag`/`root` → actionable error;
  charset-guard on operator-supplied values.
- **`scripts/pe cmd_sync` canonicalises symlink comparison via
  `realpath`** (P2.8). `/var/...` vs `/private/var/...` no longer
  registers as stale on macOS.
- **`scripts/pe cmd_doctor` normalises exit code** to 1 (P2.8).
- **`install.sh` + `pe` sync/doctor skip `_*.md` files** in agent
  iteration.

### Deferred to Session 5+

- **P2.10** — reconcile `~/.claude/agents/` stale forks on operator
  machine. Best done in a dedicated focused session.
- **P2.11** — Python hygiene batch (pe_gate + orchestrator +
  baseline + research_index). 10+ sub-items — best done in a focused
  Python session with pytest coverage in the same commit.

### Docs

- `docs/IMPROVEMENT_PLAN.md` — P1 items marked ✅ SHIPPED v0.10.0;
  P2 items marked ✅ SHIPPED v0.11.0 (except deferred P2.10/P2.11);
  new P5 (product-audit gates), P6 (code-simplicity toolchain), P7
  (operator workflow V3) sections; "Suggested execution order"
  Session 5 targets P7.1 + P7.3 + P6.1 + P6.2 as fast wins.
- `docs/OPERATOR_WORKFLOW_V3.md` — new canonical operating model
  (Fable 5 plans + judges, Opus 4.8 foundational, Sonnet 5 default,
  Haiku mechanical batches; worktrees + headless `claude -p`;
  quarterly incident-to-check rule).
- `docs/HANDOFF.md` — updated to reflect v0.11.0 shipped state and
  Session 5 pickups.

---

## [0.10.0] — 2026-07-02

> P1 enforcement bundle: the headline promises are now *deterministically*
> enforced instead of prompt-hope. Six items from
> `docs/IMPROVEMENT_PLAN.md` P1 land together:
>
> All 64 tests pass (9 sync + 10 install-reconcile + 33 orchestrator +
> 12 hooks).

### Added

- **Claude Code hooks (`hooks/hooks.json`)** — three deterministic
  gates fire from inside Claude Code:
  - `PreToolUse` on `Bash git commit` → blocks unless a fresh
    code-reviewer envelope (PASS/WARN) exists at
    `.claude/gates/last-gate.json` AND its recorded `diff_sha` matches
    the staged diff. Bypass via `PE_SKIP_COMMIT_GATE=1` (logged).
  - `PostToolUse` on `Edit`/`Write`/`MultiEdit` → best-effort lints
    the touched file (ruff/black for Python, eslint for JS/TS,
    shellcheck for shell, JSON/YAML validity). Advisory only.
  - `Stop` → reminds `/end-session` when uncommitted work exists.
- `hooks/pre-commit-envelope-check.sh`, `hooks/post-edit-lint.sh`,
  `hooks/stop-uncommitted-reminder.sh` — the three hook scripts.
- `hooks/test-run.sh` — pre-commit hook that detects the test runner
  (pytest / npm test / go test / cargo test) and runs it scoped to
  the packages changed by staged files. Optional coverage floor via
  `ENGINE_COVERAGE_MIN`. Override with `ENGINE_TEST_CMD`.
- `hooks/secrets-scan.sh` — pre-commit hook that runs
  gitleaks/detect-secrets/trufflehog (first available) on staged files.
- `hooks/deps-audit.sh` — pre-commit hook that runs
  pip-audit/npm audit/govulncheck/cargo audit when a dependency
  manifest is staged.
- `hooks/security-review-trailer.sh` — commit-msg hook that requires
  `Security-reviewed: <envelope-sha>` on commits touching
  auth/session/payment/webhook paths.
- `templates/ci/engine-quality.yml.template` — second GitHub Actions
  workflow: lint + typecheck + tests + coverage + secrets-scan +
  deps-audit for Python/Node/Go stacks.
- `pe gate parse --record <path> --diff-sha <sha>` — writes an
  evidence sidecar for PASS/WARN envelopes so the PreToolUse hook can
  verify a fresh review exists for the currently-staged diff.
- `commands/new-feature.md` — `/new-feature <topic>` chains
  brainstorm → brief → architect → plan → tdd, verifying each artifact
  before advancing. The strongest brief-before-code enforcement short
  of file-system hooks.
- `commands/pre-commit.md` — `/pre-commit` runs the right gates for
  the staged paths, records envelopes, and constructs the commit
  with verified trailers.
- `commands/retro.md` — the missing `/retro` command
  (retrospective-agent referenced it; it didn't exist).
- `tests/test_hooks.sh` — 12-assertion smoke test for the P1 hook
  bundle: gate satisfied / stale / missing / FAIL / dry-run / bypass
  paths; post-edit-lint never fails; stop-reminder respects clean vs
  dirty repo.
- `scripts/_hooks.sh` — helper module that merges `hooks/hooks.json`
  into `<project>/.claude/settings.json` (idempotent) and installs
  the pre-commit framework hooks.

### Changed

- **`pe install` now wires hooks by default.** Merges Claude Code
  hooks into `.claude/settings.json` and renders
  `.pre-commit-config.yaml` from the engine template if absent, then
  runs `pre-commit install` (all three hook types). New flags
  `--no-claude-hooks` and `--no-git-hooks` opt out.
- `templates/process-engine.yaml.template` — `hooks.pre_commit_enabled`
  flipped to `true`; new `hooks.claude_hooks_enabled: true` key.
  Fresh installs get hooks; legacy yamls must opt in.
- **`code-review-trailer.sh` upgraded from self-attest to evidence.**
  Commits touching behavior code (`src/`, `app/`, `modules/`, `lib/`,
  `scripts/`, `hooks/` by default) now require an envelope-sha trailer
  that resolves to a PASS/WARN record in `.claude/gates/`. The legacy
  `Code-reviewed: code-reviewer` self-attest is preserved for
  non-behavior commits.
- `hooks/.pre-commit-config.yaml.template` — adds `test-run`,
  `secrets-scan`, `deps-audit`, and `security-review-trailer`; new
  tuning env vars documented.
- `hooks/README.md` — new Claude Code hooks section, updated catalogue.
- `templates/ci/README.md` — documents the new
  `engine-quality.yml.template`.

---

## [0.9.1] — 2026-07-02

> P0 audit bundle. Consolidates a 4-track audit (shell layer, Python
> core, agentic layer, architecture/strategy) into all 12 P0 fixes.
> Full P0→P4 backlog lives in `docs/IMPROVEMENT_PLAN.md` (new).
>
> All 52 tests pass (9 sync + 10 install-reconcile + 33 orchestrator).

### Fixed

- **`pe sync` no longer crashes on customized files** (`scripts/pe:414`).
  `diff` exiting 1 under `set -euo pipefail` killed sync on every
  customized file, and the overwrite-confirm prompt was unreachable
  dead code. Test hardened to assert exit 0 (old test passed
  *because* of the crash).
- **Router fail-safe hole closed.** A schema-valid `FAIL +
  failure_class:"none"` envelope routed to `continue` even with
  CRITICAL findings — falsifying the Phase 3 graduation signoff. Now
  caught at three layers: schema conditional, `pe_gate` coherence
  check, and a `route()` guard. Regression test added.
- **Stacking pre-push hook** no longer silently blocks every push
  with no slot IDs.
- **`pe install` no longer clobbers operator-forked files** — new
  `install_link` helper preserves them, reports them, and points
  at `pe sync` for review.
- **Interpreter hardening.** Stock macOS `python3` is 3.9 (no
  `tomllib`). `pe` now probes for 3.11+; the orchestrator exits with
  an actionable message; subprocesses use `sys.executable`. The
  orchestrator test suite could not previously run on stock macOS —
  now 33/33.
- `pe eject` bash-3.2 crash · BSD-`sed` bug that made `doctor`'s
  launchd check never fire · invalid-subset "installs zero agents"
  trap (defensive re-validation after yaml resolution) · breaker
  sidecar silent-corruption + non-atomic writes · gate cross-check
  ordering + retry bugs · `brief-writer` / `architect` missing the
  Bash tool their MANDATORY Step 0 requires · version drift (0.7.0
  badges/manifest vs 0.9.0, "9 agents" vs 15).

### Added

- `docs/IMPROVEMENT_PLAN.md` — the canonical P0→P4 roadmap (~45
  items, each with file:line, severity, effort, fix). Supersedes
  `docs/BACKLOG.md`'s carry-forward section as the active worklist.

---

## [0.9.0] — 2026-07-01

> Single-item minor: reconciling `pe install`. Closes GitHub issue #10
> (E1.c.2). Ships with a smoke test and TROUBLESHOOTING §4 refresh.

### Added

- **`pe install` reconciles broken agent + command symlinks** (E1.c.2).
  When re-installing into a project, symlinks in `.claude/agents/*.md`
  and `.claude/commands/*.md` whose engine target no longer exists are
  now silently removed. This closes the "switched engine branches, now
  `pe doctor` reports a broken symlink I didn't create" hazard flagged
  in the original E1.c.2 issue.
- New smoke test `tests/test_pe_install_reconcile.sh` covers:
  broken-symlink removal (agents + commands), real-file preservation
  (customizations untouched), valid-symlink preservation.

### Changed

- `install.sh` now prints a `Reconciled: N broken symlink(s) removed` line
  when it drops any.
- TROUBLESHOOTING.md §4 updated to reference the reconciling install
  behavior, plus new §4b: "Why does my project have a broken symlink I
  didn't create?" per the E1.c.2 acceptance criteria.

### Design notes

Install reconciliation is deliberately **silent-broken-only**. Subset-
downgrade orphans (fine symlinks to agents not in the current subset)
remain a `pe sync` concern — `pe sync` prompts interactively per file
because widening a subset back is common and clobbering without
confirmation would surprise the operator. `install.sh` header comment
documents the split.

User-global skills (`~/.claude/skills/*`) are **out of scope** for
reconciliation — same reason as `pe sync`: they cross-cut every project.

---

## [0.8.0] — 2026-06-30

> Distribution bundle: makes "everyone gets engine improvements" real.
> Engine never self-modifies; humans review + version + pull. Shipped
> after a single-pass dogfood code-review of the cumulative bundle
> diff (0 CRITICAL, 0 HIGH, 1 MEDIUM noted as documentation clarity).

### Added

- **`pe sync <project>`** — new subcommand that re-points the project's
  engine-managed symlinks (agents in subset, commands, and
  `scripts/research_index.py`) at the current engine, with a
  **diff-before-clobber** safety contract. For each engine-managed file,
  sync classifies the project state as one of:
    - `current` — symlink already points at this engine (silent skip)
    - `stale-symlink` — symlink points elsewhere (prompts to re-point)
    - `matches` — regular file byte-identical to engine (silently upgrades to symlink)
    - `differs` — regular file differs from engine (shows unified diff +
      prompts y/N — NEVER overwrites without explicit confirmation)
    - `missing` — in-subset agent absent from project (silently re-adds)
    - `orphan` — agent symlink remains from a wider previous subset
      (prompts to remove — fixes the install.sh subset-downgrade caveat)
  Flags: `--dry-run` (no writes), `--yes` (auto-confirm prompts, including
  diff overrides — use sparingly). User-global skills are deliberately out
  of scope per BACKLOG P1.2 confirmation B: sync operates on project-local
  surfaces only.

  Documented as the canonical fix for the stale-user-globals propagation
  hazard (BACKLOG resolved-but-document section): future projects pick up
  engine improvements via `pe sync`, no manual diff-and-delete needed.

  Ships with `tests/test_pe_sync.sh` proving the safety contract:
  (1) stale symlink re-pointed when confirmed; (2) differing regular file
  NOT overwritten when prompt declined. Per BACKLOG P1.2 confirmation (c):
  the destructive path is gated by test, not by hope.
- **`scripts/_subset.sh`** — shared fragment sourced by `install.sh` and
  `pe sync` containing the preset rosters + yaml subset reader. Single
  source of truth so install and sync never disagree on which agents
  belong to which preset.
- **`pe install --subset <preset>`** — subset install presets land per
  CAPABILITY_CATALOG §8's "knowledge pack + project config" framing.
  Presets:
    - `gate-only` — 5 gate agents only (`code-reviewer`,
      `security-reviewer`, `database-reviewer`, `tdd-guide`,
      `e2e-runner`).
    - `core` — gate-only plus `planner`, `brief-writer`, `architect`
      (8 agents — smallest install that supports the
      brief→plan→implement→review pipeline).
    - `full` — current behavior, all engine agents. **Default.**
  The resolved subset is persisted to `.process-engine.yaml` under
  `install.subset` so `pe sync` (and re-runs of `pe install` without
  the flag) honor the operator's choice. Resolution order: explicit
  `--subset` > existing yaml value > `full` default. Invalid values
  exit non-zero with a clear message.

  **Known limitation:** subset downgrade (e.g. `core` → `gate-only`)
  leaves orphan symlinks from the wider install — `install.sh` only
  adds, never removes. Orphan cleanup lives in `pe sync` so it shares
  the diff-before-clobber gate.
- **INSTALL.md PATH check** — the quick-install snippet now includes a
  `case` block that detects whether `~/.local/bin` is on `$PATH` and
  prints the exact `export` line for `~/.zshrc` if not. Stock macOS zsh
  doesn't include `~/.local/bin`, which produced a first-30-seconds
  `pe: command not found` during the Origyn cross-environment install
  test. Also adds an explicit `mkdir -p ~/.local/bin` before the
  symlink in case the directory doesn't exist yet.

### Changed

- **`pe` CLI** — Phase 3 graduated 2026-06-28, so the subcommand summary
  for `shadow decide` no longer claims "(no enforcement)". It now reads
  "(enforce gated by --enforce; graduated 2026-06-28)". Functionality
  unchanged — corrects an advertised-version lie surfaced by the Origyn
  cross-environment install test.
- **`pe doctor`** — now reports the engine version at the top of both the
  self-check and the project-check, and prints an always-on per-agent
  freshness summary line (`N/M up to date`, with the existing detailed
  SHADOWED / MISSING blocks following). The summary fires regardless of
  whether anything is wrong, so operators know the freshness check
  actually ran on a clean install.

---

## [0.7.0] — 2026-06-17

### Added

- **4 new agents extracted from 8CStudio's user-global library:**
  - `build-error-resolver` (Haiku) — fix build/type errors with
    minimal diffs; no architectural edits.
  - `data-model-auditor` (Sonnet) — finds hardcoded business values
    and recommends moving them to the data model or configuration.
  - `e2e-runner` (Sonnet) — generates and runs E2E tests with
    Playwright or browser MCPs; manages journeys + artifacts.
  - `retrospective-agent` (Sonnet) — daily / weekly / monthly
    self-improvement retros from dev-log digests; proposes process
    improvements.
- **`memory-consolidator` agent** (Sonnet, new) — quarterly memory
  hygiene: archives historical RESUME HERE blocks, dedupes
  pointer indexes, surfaces a diff for operator approval before
  writing. Solves the MEMORY.md-bloat-to-30KB+ class.
- **`/memory-consolidate` command** — convenience wrapper that
  invokes the agent.
- **`stacking-rule-check` pre-push hook** — detects pushes that
  bundle ≥2 distinct slot IDs with foundational file changes (RLS,
  auth, OIDC, `core/database*.py`, `Role.ALL_MODULES`, schema
  ALTERs) and blocks. Implements Process v2's foundational-changes-
  always-per-slot rule structurally.
- **GitHub Actions CI gate template** (`templates/ci/engine-gate.yml.template`)
  — soft mirror of the local trailer hooks for contributors who
  haven't installed pre-commit. Gates PRs on Code-reviewed +
  Docs-updated trailers.

### Engine inventory after v0.7

- **13 agents** (was 9): the 9 prior + build-error-resolver,
  data-model-auditor, e2e-runner, memory-consolidator,
  retrospective-agent
- **5 commands** (was 4): the 4 prior + /memory-consolidate
- **6 hooks** (was 5): the 5 prior + stacking-rule-check
- Scheduler templates: macOS launchd + Linux systemd + Linux cron +
  Windows Task Scheduler
- CI gate template

### Deferred (rationale unchanged from v0.6)

- Multi-project portfolio mode — blocked on ≥2 multi-project
  adopters.
- Adopter telemetry opt-in — blocked on real adopters.

---

## [0.6.0] — 2026-06-17

### Added

- **`hooks/` directory** — five generalized pre-commit + commit-msg
  hooks extracted from 8CStudio:
  - `code-review-trailer` (commit-msg, blocks ≥5-file commits without
    `Code-reviewed:` or `Code-skip-reason:` trailer)
  - `docs-updated-trailer` (commit-msg, blocks structural-file commits
    without `Docs-updated:` trailer)
  - `design-review-trailer` (commit-msg, blocks UI-file commits without
    `Design-reviewed:` trailer)
  - `claude-md-size` (pre-commit, warns when CLAUDE.md > 40 KB)
  - `research-index-rebuild` (pre-commit, re-embeds the semantic index
    when `docs/research/*.md` is staged)
  - All hooks read tuning env vars (`ENGINE_REVIEW_THRESHOLD`,
    `ENGINE_STRUCTURAL_FILES`, `ENGINE_UI_FILES`,
    `ENGINE_CLAUDE_MD_LIMIT`).
  - Starter `.pre-commit-config.yaml.template` + `hooks/README.md`
    documenting install / tuning / bypass.
- **`pe eject <project>`** — removes engine-managed symlinks from a
  project. Lists what will be removed (project-local), what will be
  kept (.process-engine.yaml, templates), what you remove manually
  (system-level skills + launchd / systemd / Task Scheduler jobs).
  Asks confirmation. Reversible via `pe install`.
- **Linux systemd templates** (`templates/systemd/`) — user-level
  `.service` + `.timer` units for the weekly CEO retro. Friday 17:00
  via `OnCalendar=Fri *-*-* 17:00:00`. notify-send heartbeat. Same
  wrapper shell shape as macOS launchd.
- **Cron alternative** (`templates/cron/`) — plain crontab entries
  for adopters who prefer cron over systemd (Alpine, WSL2, older
  distros without lingering).
- **Windows Task Scheduler templates** (`templates/windows-task-scheduler/`)
  — PowerShell `Run-Weekly.ps1`, `Check-Heartbeat.ps1`, and
  `Install-Task.ps1` to register Weekly + Daily-every-3-days
  scheduled tasks. Runs as current user, no admin required.

### Changed

- Roadmap bumps: v0.6 (this) ships hooks + eject + cross-platform
  schedulers earlier than the original v0.6 target (domain agents),
  which moves to v0.7.

### Deferred (with rationale)

- **Multi-project portfolio mode** — speculative without ≥2 real
  multi-project adopters; would build the wrong abstraction.
- **Adopter telemetry opt-in** — needs real adopters first; without
  signal we'd be guessing at what to measure.

Both stay on the roadmap but blocked-on-adoption.

---

## [0.5.0] — 2026-06-17

### Added

- **Multi-provider RAG embeddings.** `scripts/research_index.py`
  refactored with an `Embedder` ABC and 4 concrete providers:
  `fastembed` (default), `voyage`, `gemini`, `openai`.
- **`fastembed` as the default provider** — fully local, zero API
  keys, BAAI/bge-small-en-v1.5 (384 dims). Adopters get a working
  RAG with `pip install fastembed` and nothing else. Validated on
  the 8CStudio Wave 1M.3 corpus: Workbox brief surfaces at cosine
  0.73 in ≤10s of CPU.
- **Provider resolution chain:** CLI `--provider` flag →
  `.process-engine.yaml` `rag.provider` → env detection (any of
  `VOYAGE_API_KEY` / `GEMINI_API_KEY` / `OPENAI_API_KEY` set) →
  fastembed default.
- **Dim-mismatch detection.** The script tracks
  `embedding_model` + `embedding_dim` in the SQLite `meta` table
  and force-rebuilds if the configured provider doesn't match the
  indexed one. No silent garbage scores.
- **Query-time check.** `query` subcommand verifies the current
  embedder's dim matches the indexed dim before running; errors
  with a clear remediation hint if not.
- **Key-safety section in `docs/RAG.md`.** Documents that keys are
  read only from env vars, never written to config files or logs,
  and that adopters should never paste keys into
  `.process-engine.yaml`.

### Changed

- `docs/RAG.md` rewritten: provider matrix, cost comparison per
  provider on the 8CStudio scale, when to upgrade off fastembed,
  resolution-order documentation.
- `templates/process-engine.yaml.template` gains a `rag:` block with
  `provider` + `model` keys + provider-comparison docstring.
- README: RAG section gains the 4-provider matrix; "adopt
  incrementally" RAG row no longer requires a Gemini key.

### Rationale

Adopter feedback (raised by Sanish 2026-06-17) — most adopters
already have an Anthropic relationship via Claude Code. Forcing a
second API signup (Google AI Studio) just to use the RAG is
friction. Anthropic doesn't ship embedding models directly, but
fastembed runs fully local with competitive quality on the corpus
sizes the engine targets. Voyage/Gemini/OpenAI stay as easy
upgrades for larger corpora or higher recall.

### Migration

`v0.4 → v0.5` for **existing installs**:

```bash
pe upgrade
pip install fastembed
# Optional: edit .process-engine.yaml to set rag.provider explicitly
python3 scripts/research_index.py rebuild --force
```

The `--force` is required because v0.4 indexes (Gemini, 768 dims)
aren't compatible with v0.5's default fastembed (384 dims). The
script will print a clear "model changed" message and force the
rebuild even without the flag.

If you want to **keep using Gemini**, add to
`.process-engine.yaml`:

```yaml
rag:
  provider: gemini
```

No re-index required.

---

## [0.4.0] — 2026-06-17

### Added

- **`pe` unified CLI** (`scripts/pe`) — single entry point replacing
  direct invocation of `install.sh` and `install_launchd.sh`.
  Subcommands: `install`, `launchd`, `upgrade`, `status`, `doctor`,
  `version`, `help`. Self-locates the engine via its own symlink path.
- **`pe doctor`** — diagnose engine self-check + per-project install
  health. Detects broken symlinks, missing deps (numpy,
  google-generativeai), missing `GEMINI_API_KEY` env var, unloaded
  launchd plists.
- **CHANGELOG.md** — formal version history.
- **CONTRIBUTING.md** — short adoption / extension guide.
- **Public-launch README** — opening hook, before/after example,
  60-second install, value prop, platform support matrix, "adopting
  incrementally" guide for piece-by-piece adoption.

### Changed

- README rewritten from a functional reference into a
  marketing-grade public-facing doc.

### Migration

`v0.3 → v0.4` is non-breaking. Existing projects don't need re-install;
`pe upgrade` propagates everything. You can optionally:

```bash
ln -s <engine-dir>/scripts/pe ~/.local/bin/pe
```

…and then use `pe install`, `pe upgrade`, `pe doctor` instead of the
two old script names.

---

## [0.3.0] — 2026-06-17

### Added

- **RAG over `docs/research/`** — local SQLite + Gemini
  text-embedding-004 index (`scripts/research_index.py`). Solves the
  "Workbox-miss class" surfaced in the 2026-05-28 Wave 1M.3 Phase 1
  root-cause audit where planner-only reads at slot pickup miss the
  OSS contract locked earlier in the brief.
- **`/research-search [query]`** slash command.
- **`docs/RAG.md`** — full doctrine: problem statement, architecture
  decisions, rejected alternatives (pgvector, Chroma, Anthropic
  Files, sentence-transformers, MCP server, TF-IDF), setup, cost,
  failure modes.
- **Step 0 in brief-writer + architect** — both agents now run the
  semantic search before drafting and cite top matches with cosine
  ≥0.55 under a `## Related prior work` heading.

### Changed

- `scripts/install.sh` now symlinks `scripts/research_index.py` into
  the target project's `scripts/` and appends
  `*.research-index.sqlite` + `.process-engine.local.yaml` to the
  project's `.gitignore` if absent.

### Architecture decisions

See `docs/RAG.md` for the full table. Highlights:

- **SQLite over pgvector** — zero infra; the project's DB shouldn't be
  a hard dep of the dev tool.
- **Gemini text-embedding-004 over OpenAI / Voyage / sentence-
  transformers** — `google-generativeai` is already a common project
  dep, the free tier covers RAG, and asymmetric task_types
  (`RETRIEVAL_DOCUMENT` vs `RETRIEVAL_QUERY`) improve recall.
- **Cosine in numpy over sqlite-vec extension** — <100k chunks
  doesn't need the extension; in-memory scan is sub-second.
- **Agents-run-bash over MCP server** — simpler install, no
  `.mcp.json` config, no extra process.

---

## [0.2.0] — 2026-06-17

### Added

- **6 new agents:** `architect` (Opus), `code-reviewer` (Haiku),
  `doc-updater` (Haiku), `planner` (Opus), `security-reviewer`
  (Sonnet), `tdd-guide` (Sonnet).
- **2 session skills:** `/start-session` (orient at session start,
  read CLAUDE.md, MEMORY, weekly plan, quality calendar, recommend
  first task), `/end-session` (close-out: git status, sync check,
  MEMORY banner update, deliverables ledger, next-session pickup).
  Both project-agnostic; tweak via `.claude/session.yaml` per project.
- **launchd template bundle** (`templates/launchd/`) — macOS plist +
  wrapper templates for the CEO weekly retro. TCC-safe wrappers live
  in `~/.local/bin/<org>-ceo/`. Rendered from `.process-engine.yaml`.
- **`.process-engine.yaml` schema** — project-level config consumed
  by `install_launchd.sh`. Schema documented in
  `templates/process-engine.yaml.template`.
- **`scripts/install_launchd.sh`** — render launchd templates,
  validate with `plutil -lint`, print bootstrap commands.

### Changed

- `agents/ceo.md` now enforces W-prefix on weekly-plan filenames
  (`weekly-plan-2026-W25.md`, not `weekly-plan-2026-25.md`) after a
  dry-run produced the missing-W form.
- `scripts/install.sh` symlinks skills to `~/.claude/skills/` and
  copies `.process-engine.yaml` template into target.

---

## [0.1.0] — 2026-05-22

### Added

- **3 agents:** `brief-writer` (Sonnet), `researcher` (Haiku), `ceo`
  (Opus).
- **3 commands:** `/brainstorm`, `/lock-backlog`, `/weekly-retro`.
- **Doctrine docs:** `OSS_SEARCH_ORDER.md` (5 rules of OSS-first),
  `RHYTHM.md` (weekly cadence), `AGENT_INVOCATION_RULES.md` (slot-
  type → agent-chain matrix).
- **Templates:** `brief.md`, `eval.md`, `retro.md`, `weekly-plan.md`.
- **`scripts/install.sh`** — symlink agents + commands into target
  project's `.claude/`.

---

[Unreleased]: https://github.com/sanishsk/8colors-process-engine/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/sanishsk/8colors-process-engine/releases/tag/v0.4.0
[0.3.0]: https://github.com/sanishsk/8colors-process-engine/releases/tag/v0.3.0
[0.2.0]: https://github.com/sanishsk/8colors-process-engine/releases/tag/v0.2.0
[0.1.0]: https://github.com/sanishsk/8colors-process-engine/releases/tag/v0.1.0
