# Changelog

All notable changes to `8colors-process-engine`.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
