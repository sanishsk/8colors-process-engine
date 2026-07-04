# Changelog

All notable changes to `8colors-process-engine`.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.33.0] — 2026-07-03

> **A8 shipped — native plugin manifest + per-project version pinning.**
> Two surfaces close the "each symlink-onboarded adopter is
> migration debt" gap called out in the plan: the engine now ships
> a `.claude-plugin/plugin.json` marketplace manifest advertising
> its capabilities in Claude Code's native shape, and every
> adopter tree carries a `.claude/.engine-pin.json` written by
> `install.sh` at install time. `pe pin show|verify|bump`
> inspects and reconciles the pin so an adopter who runs
> `pe upgrade` (git pull in engine) knows whether they've drifted
> from the version they installed against — no more silent
> HEAD-riding.

### Added — `.claude-plugin/plugin.json`

- Native Claude Code marketplace manifest at the engine root.
  Points at the existing `agents/`, `commands/`, `skills/`,
  `hooks/hooks.json` entry points. Advertises the `pe` CLI, the
  Python + Bash version requirements, and the pin file location
  (`.claude/.engine-pin.json`).
- Kept in step with the legacy `plugin.json` at the repo root —
  the test suite asserts both point at the same VERSION.

### Added — `scripts/pe_pin.py` + `pe pin` subcommand

- **`pe pin show`** — prints pinned version + SHA + install
  timestamp + install mode, plus a drift verdict against the
  engine on disk. `--json` for programmatic reads.
- **`pe pin verify`** — exits 0 when pin matches engine, 1 on
  drift, 2 on missing/corrupt pin. Suitable as a CI gate: a
  downstream project's CI can fail the build when the local
  engine repo is ahead of the pinned version.
- **`pe pin bump [--to VERSION]`** — rewrites the pin to the
  engine's current VERSION + HEAD SHA. `--to VERSION` guards
  against accidental bump when the engine's checked-out version
  differs. Preserves `previous_version` + `previous_sha` in the
  new pin so the audit trail survives every reconcile.
- **Drift verdicts:**
  - `pinned` — version + SHA match exactly.
  - `engine_ahead` — engine on disk moved forward past the pin.
  - `engine_behind` — engine on disk is BEHIND the pin
    (someone reverted; usually means `git pull` in the engine
    hasn't happened yet).
  - `sha_orphan` — pinned SHA is no longer reachable
    (force-push, rewrite, or same-version untagged change).
  - `ok_no_git` — engine isn't a git tree (adopter-side copy);
    version drift can still be reported.

### Added — `scripts/install.sh` writes the pin file

- After the symlink pass, `install.sh` writes
  `<project>/.claude/.engine-pin.json` with
  `{engine_path, engine_sha, engine_version, install_mode,
   installed_at}`. Non-fatal: if the write fails (permissions,
  missing python), the install still succeeds — the pin is
  advisory, not a gate on install itself.

### Added — `tests/test_pe_pin.sh` (12 cases)

- Missing pin → verify exit 2 / show exit 0 with hint.
- Pin matching HEAD → verify exit 0 (pinned).
- Pin at older version → verify exit 1 (engine_ahead drift).
- Unreachable SHA → sha_orphan verdict surfaced by show.
- `--json` emits parseable payload with `drift_verdict` field.
- `bump` rewrites pin to engine version + preserves
  `previous_version`.
- Bump → verify roundtrip is clean.
- `bump --to VERSION` mismatch → exit 2 (safety guard against
  accidental cross-version bump).
- `install.sh` writes `.engine-pin.json` with the current
  VERSION.
- Corrupt pin file → verify exit 2 (treated as missing).
- `.claude-plugin/plugin.json` present + `name`/`version`
  aligned with the engine's VERSION file.

### Updated

- `scripts/pe` — new `cmd_pin` + dispatch entry.
- `plugin.json.description` — mentions A8 pin surface.
- `README.md` badge → 0.33.0.
- `docs/ENHANCEMENT_PLAN_V2.md` A8 marker: MISSING → SHIPPED v0.33.0.
- `docs/HANDOFF.md` — v0.33.0 header, A8 row added, resume notes.
- `MANIFEST.sha256` regenerated (surface grew by two —
  `pe_pin.py` + `.claude-plugin/plugin.json`).

### Reviewer fixes (applied pre-commit)

- **MEDIUM — pin file commit intent.** Reviewer flagged that
  `.claude/.engine-pin.json` isn't added to `.gitignore` and adopters
  might not know whether to commit it. **Fix:** added a rationale
  comment to `install.sh` — the pin file is intentionally COMMITTED
  so every teammate + CI run sees the same engine version the
  project was installed against.
- **LOW — schema URL placeholder.** `.claude-plugin/plugin.json`
  had a `$schema` field pointing at a not-yet-published Anthropic
  schema URL that offline validators would fail to resolve.
  **Fix:** removed the `$schema` line; can be re-added when the
  official schema is published.
- **LOW — pre-release version tuple.** `_version_tuple()`
  silently mapped non-numeric parts to -1 with no docstring hint
  that this yields correct semver-ish RC ordering. **Fix:**
  expanded docstring to name the invariant so future readers
  don't accidentally "fix" it into a symmetric compare.

### Alignment

- All 19 test scripts + `pe docs check` green at v0.33.0.

### Notes — deliberately out of scope

- **Copy-mode install.** The plan mentioned "Windows-friendly"
  installs. Today install.sh is symlink-only (Unix). A copy-mode
  install (`install.sh --mode copy`) would let Windows adopters
  install without symlink privileges, but isn't wired in v0.33.0
  — the pin file + native manifest are the load-bearing pieces
  for "no more silent HEAD-riding", and copy-mode is a follow-up
  when the first Windows adopter shows up.
- **Automatic upgrade prompts.** `pe upgrade` doesn't yet consult
  the pin to warn about breaking changes. A future release can
  read the pinned version, diff CHANGELOG entries since, and
  surface "MIGRATION" lines to the operator. For v0.33.0 the
  operator still runs `pe pin show` manually.
- **Enable/disable per project.** Claude Code's native
  marketplace supports enabling/disabling installed plugins.
  We ship the manifest so the shape is right; disable-flow
  wiring (which agents/commands the operator suppressed) is a
  follow-up.

### Migration

- No breaking changes. Existing adopters install cleanly at
  v0.33.0 — the pin file is written automatically the next time
  they run `pe install`. Adopters can run `pe pin show` right
  after upgrading to confirm they're pinned to the version they
  intended.

---

## [0.32.0] — 2026-07-03

> **A7 shipped — cross-session agent memory.** Three surfaces close
> the retrieval half of the A row: `pe recall <query>` reads the
> shadow-decide + reconciliation logs so an agent picking up a new
> slot can see "this is 40% similar to 1M.3; that approach passed
> in 2 iterations." The RAG index gains an FTS5 sparse side with
> reciprocal-rank fusion so exact-token queries (slot IDs, SHAs,
> snake_case, error strings) don't get buried by
> semantically-adjacent chunks. And the retrospective-agent now
> promotes ≥3-slot recurring failure patterns into
> auto-memory via `pe memory add`, capped at 3 new memories per
> retro so the system stays a living memory, not a growing swamp.

### Added — `scripts/pe_recall.py` + `pe recall` (retrieval half)

- Reads `.pe/decisions.jsonl` (+ `.pe/reconciliations.jsonl` when
  present) and returns the top-K slots whose signal tokens overlap
  the query.
- **Tokenizer:** alphanumeric + `.` / `-` / `_` runs, lowercased.
  Slot IDs (`1M.3`), SHAs (`b6c566e`), snake_case
  (`worker_quality`), dotted paths (`modules.billing.money`)
  survive intact as single tokens.
- **Similarity:** Jaccard over token multisets. Robust to query
  length, no embeddings required. Default `--min-score 0.01`
  because a 1-token query against a 30-token slot record naturally
  scores below 5%.
- **Aggregation:** multiple decisions for the same slot collapse
  into one summary — verdict trajectory (`FAIL → PASS`, `FAIL×2`),
  iteration count, gate list, router actions, reconciliation
  outcome.
- **Modes:** default human report, `--json` for programmatic reads,
  `--limit N`, `--min-score S`, `--project <path>`.
- **Exit codes:** 0 match, 1 no match, 2 corpus missing / usage.
- Read-only — never writes to the decisions log.

### Added — FTS5 sparse index + RRF hybrid in `scripts/research_index.py`

- New `chunks_fts` virtual table with `unicode61 remove_diacritics 2`
  tokenizer. Populated at rebuild time; legacy indexes migrate
  forward transparently on next rebuild.
- `_fts5_query()` runs BM25-scored sparse retrieval, sanitizing
  query tokens through phrase-quoting so `1M.3` / `worker_quality`
  don't trigger FTS5's punctuation errors.
- `_rrf_fuse()` combines dense (cosine) and sparse (BM25) rank
  lists via reciprocal-rank fusion at k=60 (the RRF-paper default).
  Score magnitudes don't need normalization — RRF only sees ranks.
- Hybrid mode is default on `pe query`; `--no-hybrid` restores
  dense-only for A/B comparison. Query header prints
  `mode: hybrid (dense + FTS5 BM25, RRF fused)` when active.
- Legacy indexes built before FTS5 was added: the schema migrates
  the virtual table forward, but existing chunks aren't
  auto-backfilled — the hybrid path silently returns [] sparse
  hits and falls back to dense-only until the operator runs
  `rebuild`.

### Added — `agents/retrospective-agent.md` §7b (synthesis half)

- New "A7 — Synthesize recurring patterns into auto-memory"
  section. Trigger: same `envelope.failure_class` (or router
  `rule_matched`) appears on ≥3 distinct `slot_id`s in the retro
  window.
- For each pattern, the agent uses `pe recall <failure_class>` to
  sanity-check + writes a `feedback` memory via `pe memory add`
  with a `Why:` line naming the ≥3 evidence slots and a
  `How to apply:` line.
- Ceiling: **3** new memories per retro run. Above that, the
  agent instead flags "auto-memory saturation" as its own
  systemic finding.
- Garbage collection: previous patterns that show 0 hits this
  window get `pe memory rm`'d.

### Added — tests

- **`tests/test_pe_recall.sh`** (11 cases): empty corpus → exit
  1 with hint; missing project → exit 2; failure_class token
  match; slot ID preserved as single token (`1M.3` hits,
  `2A.1` doesn't); trajectory collapse (`FAIL → PASS`, `FAIL×2`);
  reconciliation outcome surfaced; `--json` returns matches
  array; `--limit` caps; `--min-score 0.5` filters weak; corrupt
  jsonl line skipped silently; reconciliation-only slot still
  recallable.
- **`tests/test_research_index_hybrid.sh`** (5 cases): schema
  creates `chunks_fts` virtual table; `_fts5_query` catches
  snake_case exact tokens; whitespace-only query returns [];
  RRF ranks common-top-1 highest; hybrid degrades gracefully
  on legacy indexes.

### Updated

- `scripts/pe` — new `cmd_recall` + dispatch entry.
- `plugin.json.description` — mentions `pe recall`, FTS5 hybrid,
  retro §7b.
- `README.md` badge → 0.32.0.
- `docs/ENHANCEMENT_PLAN_V2.md` A7 marker: MISSING → SHIPPED v0.32.0.
- `docs/HANDOFF.md` — v0.32.0 header, A7 row added, resume notes.
- `MANIFEST.sha256` regenerated.

### Reviewer fixes (applied pre-commit)

- **CRITICAL — FTS5 query injection surface.** Original quote-strip
  only stripped `"`; a token with `'` or FTS5 operators inside
  could break out of phrase quotes. **Fix:** strip both `"` and
  `'` before wrapping each token in phrase quotes; a regression
  test in `test_research_index_hybrid.sh` fires the attacker-shape
  query `chunk" NOT everything "OR"` and asserts it doesn't crash
  or leak.
- **HIGH — FTS5 external-content table left orphan rows on
  rebuild.** When a doc was re-indexed, `DELETE FROM chunks WHERE
  doc_id = ?` fired, but `chunks_fts` (external content pointing
  at `chunks.id`) kept stale rowids — `_fts5_query` could return
  chunk ids that no longer existed. **Fix:** rebuild now issues
  `DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks
  WHERE doc_id = ?)` before the chunks delete. Regression test
  seeds one chunk + FTS row, runs the cascade, asserts orphan count
  is 0.
- **HIGH — silent JSONL corruption in `pe recall`.** A malformed
  decisions.jsonl line silently disappeared. **Fix:** log a
  `WARNING skipped malformed line <path>:<lineno>` to stderr while
  keeping stdout parseable. Regression test asserts the warning is
  emitted.

### Alignment

- All 18 test scripts + `pe docs check` green at v0.32.0.

### Notes — deliberately out of scope

- **Semantic memory across projects.** `pe recall` is
  project-scoped by design — a decision made in project A rarely
  applies verbatim to project B, and the false-positive rate on a
  cross-project retrieval would swamp the signal. Cross-project
  memory belongs in the human-authored global CLAUDE.md, not in
  a machine-mined index.
- **Learned reranker.** The Jaccard scorer is dep-free by design.
  A learned reranker (cross-encoder, small MLP over co-occurrence)
  would edge the top-1 score up 5–10 points but adds a model
  dependency and a training loop. Not worth it until the retro
  reports show reranking as the bottleneck.
- **Retro-agent auto-execution.** §7b tells the agent what to
  synthesize; it does NOT auto-apply the memory writes. A human
  still reviews each retro. This matches the "advisor principle"
  — memory is a suggestion, not an escalation.

### Migration

- No breaking changes. `pe install` picks up the new subcommand.
  The FTS5 virtual table is created transparently on next
  `research_index.py` open — no manual migration.
- Adopters with an existing dense index should run
  `python scripts/research_index.py rebuild` to backfill the FTS5
  side; until then, hybrid falls back to dense-only silently.

---

## [0.31.0] — 2026-07-03

> **S5 shipped — container + secrets-history + license CI gates.**
> Three advisory gates land in `engine-quality.yml.template`:
> hadolint + trivy on Dockerfile presence, weekly full-git-history
> gitleaks (schedule-only so PRs don't triple-scan), and per-stack
> license audit (pip-licenses / license-checker) that FAILS on
> AGPL / GPL-3.0 and WARNS on LGPL. All new gates are
> `continue-on-error: true` — the intent is visibility, not
> blocking every push on transient CVE catalog changes. This
> closes the last Security row in the plan; S1–S5 all shipped.

### Added — `templates/ci/engine-quality.yml.template`

- **`container-security` job** — feature-detected via
  `hashFiles('Dockerfile') != ''`. Runs `hadolint/hadolint-action@v3.1.0`
  (warning-threshold) and `aquasecurity/trivy-action@0.24.0` in
  `fs` mode (HIGH/CRITICAL only, SARIF output uploaded as artifact).
  Trivy in fs mode avoids the CI-time image build (which usually
  needs registry credentials); it still catches OS + language deps.
- **`secrets-scan-history` job** — schedule + workflow_dispatch
  only. Downloads gitleaks v8.18.4 tarball, runs
  `gitleaks detect --source . --no-git=false --redact` over the
  full git history. Uploads `gitleaks-history.json` on findings so
  the operator can act without exposing the value in the log.
- **`license-audit` job** — needs the existing `detect-stack`
  output. Python: `pip-licenses --format=json` fed into an inline
  Python evaluator that fails on any package license matching the
  `ENGINE_LICENSE_FAIL_ON` list (default:
  `AGPL-3.0;AGPL-3.0-only;GPL-3.0;GPL-3.0-only`) and warns on
  `ENGINE_LICENSE_WARN_ON` (default: `LGPL-3.0;LGPL-3.0-only;LGPL-2.1`).
  Node: `npx --yes license-checker --production --json` → same
  evaluator in JS. Go: advisory-only echo (adopter can wire
  `go-licenses check ./...` separately).
- **Schedule trigger** — new `cron: '0 8 * * 1'` (Monday 08:00
  UTC) so the weekly-only jobs fire without a manual dispatch.
  workflow_dispatch also added with an optional
  `run_tenant_audit` input that the existing S6 job already reads.
- Existing per-commit `secrets-scan` job preserved unchanged —
  it uses `gitleaks-action@v2` on the pushed diff. The new
  `secrets-scan-history` complements it by catching legacy leaks
  that never touched the current diff.

### Added — `tests/test_ci_template_s5.sh` (15 cases)

- Asserts cron + workflow_dispatch triggers present.
- Asserts `container-security` job present, Dockerfile-guarded,
  hadolint + trivy actions, continue-on-error.
- Asserts `license-audit` present with correct fail-on + warn-on
  defaults, branches on both python (pip-licenses) and node
  (license-checker).
- Asserts `secrets-scan-history` present + schedule-only.
- Asserts gitleaks full-history invocation shape.
- Asserts per-commit `secrets-scan` preserved (regression guard).
- Asserts all three new jobs are advisory (continue-on-error).

### Updated

- `plugin.json.description` — mentions S5 CI gates.
- `README.md` badge → 0.31.0.
- `docs/ENHANCEMENT_PLAN_V2.md` S5 marker: MISSING → SHIPPED v0.31.0.
- `MANIFEST.sha256` regenerated (66 entries — surface list didn't
  grow, but VERSION + plugin.json + engine-quality.yml… wait,
  templates/ci/ is NOT in the manifest surface. See notes below.).

### Reviewer fixes (applied pre-commit)

- **CRITICAL — license matcher silently passed classifier forms.**
  First-cut logic used naive substring match on the normalized
  license string. `pip-licenses` can emit any of `GPL-3.0-only`
  (SPDX), `GNU General Public License v3` (classifier), `GPLv3`
  (short), or `GNU General Public License v3 (GPLv3)` (mixed);
  the naive matcher only caught the first form. **Fix:** parse
  each fail/warn token into `(family, version)`, expand family
  to alias list (SPDX + classifier variants), try both `3`/`3.0`
  version forms, and use word-bounded regex match so `gpl` doesn't
  false-match inside `lgpl`. Long aliases relax the left-boundary
  so "GNU Affero…" (preceded by `u` from "gnu") still matches AGPL
  tokens. Applied identically to Python + Node evaluators.
- **Regression tests added:** `tests/test_ci_template_s5.sh`
  extracts the Python evaluator via awk + runs it against a
  7-package license fixture covering SPDX, classifier, short,
  mixed, AGPL forms + LGPL WARN + MIT clean. Also confirms
  LGPL doesn't false-positive on the GPL fail-on list (word
  boundary regression guard).

### Alignment

- All 16 test scripts + `pe docs check` green at v0.31.0.
- **All of S1–S5 are now SHIPPED** — the entire Security row of
  the V2 plan has closed. Twelve V2 items shipped since the fresh
  360° re-audit produced `docs/ENHANCEMENT_PLAN_V2.md`.

### Notes — deliberately out of scope

- **Templates in the manifest.** `MANIFEST.sha256` currently
  covers agents / commands / skills / hooks / scripts / plugin.json /
  VERSION. Templates (CI, tests, domain-modules) are NOT hashed
  because they're materialized-then-edited by adopters — hashing
  them would fire divergence on legitimate customization. If a
  future audit shows adopter templates being poisoned in transit,
  we can extend the manifest surface then.
- **Blocking-mode container / license gates.** All three new
  jobs are `continue-on-error: true`. Trivy's CVE catalog updates
  daily; a strict block would fail PRs whenever a new CVE lands
  in a stable dependency. Adopters who WANT blocking can drop
  the `continue-on-error` line for their tolerance.
- **SBOM generation + SLSA provenance.** Trivy can emit an SBOM
  (`--format cyclonedx` / `spdx-json`), but wiring the release
  attestation flow is a follow-up. For v0.31.0, we ship
  vulnerability visibility, not attestation.

### Migration

- No breaking changes. Adopters copy the updated template into
  `.github/workflows/engine-quality.yml`; new jobs are
  feature-detected (Dockerfile or stack) so a project without a
  Dockerfile sees no `container-security` job.
- The weekly schedule adds ONE cron trigger per repo — under
  GitHub's public-repo compute budget for all realistic team sizes.

---

## [0.30.0] — 2026-07-03

> **S4 shipped — LLM/agent threat hardening.** Three layers land
> in one release: a PostToolUse `transcript-guard.sh` that flags
> prompt-injection payloads and secret leaks in fetched / shell
> output; a `pe verify` subcommand that checksums all load-bearing
> engine surfaces against a signed manifest (catches poisoned
> agent + hook files — the real supply-chain vector now that
> agents auto-run on commit); and a hook-wiring update so the new
> guard fires on Bash / Read / WebFetch / WebSearch by default.
> These were unguarded and are the scariest class for a
> multi-tenant SaaS built BY agents.

### Added — `hooks/transcript-guard.sh` (S4 layer a + b)

- PostToolUse advisory hook. Reads the tool_response payload the
  agent is about to consume; scans for two things:
  1. **9 prompt-injection marker patterns** — "ignore N previous
     instructions", "disregard prompts", role-hijack `system:`
     prefixes, ChatGPT-style `<|im_start|>` blocks, jailbreak /
     DAN, `you are now a different assistant` re-persona attempts,
     `###system###` fake-block markers. Extend the ruleset via
     `PE_TRANSCRIPT_INJECTION_RE` env var (per-project).
  2. **11 secret-shape patterns** — Stripe live/test/restricted,
     OpenAI `sk-`, Anthropic `sk-ant-`, AWS `AKIA…`, GitHub
     `ghp_/gho_`, Slack bot tokens, Bearer tokens, JWTs. Emits
     name + last-4 preview only — the actual value is never
     re-emitted (protects the transcript itself).
- Always exit 0 (advisory — the tool already ran; the goal is to
  raise a hand to the operator). Fires only for Bash / Read /
  WebFetch / WebSearch tool_names; skipped silently on everything
  else so it never blocks a Write / Edit flow.
- Scan cap 512KB — big file dumps skip past the length limit;
  markers deep in a 5MB build log are lower risk than perf cost.

### Added — `hooks/hooks.json`

- PostToolUse matcher `Bash|Read|WebFetch|WebSearch` → runs
  `transcript-guard.sh`. Existing `Edit|Write|MultiEdit`
  PostToolUse chain (post-edit-lint, claude-md-size, design-lint,
  cache-hygiene-warn) is unchanged.

### Added — `scripts/pe_verify.py` + `pe verify` subcommand (S4 layer c)

- Checksums the load-bearing surface (agents/, commands/,
  skills/, hooks/, scripts/pe*, plugin.json, VERSION) against
  a checked-in `MANIFEST.sha256` at engine root. Divergence =
  local edit OR upstream poisoning; either way, exit 1 with the
  divergent paths listed.
- Modes:
  - default: verify + exit 0/1
  - `--update`: regenerate MANIFEST.sha256 (release-time)
  - `--json`: machine-readable output for CI
  - `--engine <path>`: explicit engine dir
- Adopter-side engine resolution: reads
  `.claude/settings.json` hook commands and auto-locates the
  engine dir from the installed hook paths — so
  `pe verify` works from any adopter tree.
- Exit codes: 0 clean, 1 divergence, 2 missing manifest / usage.

### Added — `MANIFEST.sha256` (66 entries at v0.30.0)

- SHA-256 of every load-bearing engine surface. Regenerated on
  every release via `pe verify --update` before commit + tag.
- Format: `<hex-sha256>  <relative path>` (GNU sha256sum-compatible).

### Added — tests

- **`tests/test_transcript_guard.sh`** — 12 cases:
  clean output silent, ignore-instructions marker, jailbreak/DAN,
  role-hijack `system:` prefix, Stripe-key last-4-only preview
  (never full leak), JWT-shape detection, Write tool skipped,
  empty/malformed stdin exit 0, `PE_TRANSCRIPT_INJECTION_RE`
  respected, combined injection+secret both surfaced.
- **`tests/test_pe_verify.sh`** — 8 cases: --update writes
  manifest, clean tree verifies, tampered hook detected,
  --json emits verdict, restore + rebuild works, missing manifest
  errors, new-on-disk file is advisory (not fatal), missing-from
  -disk file is fatal.

### Updated

- `plugin.json.description` — mentions transcript-guard patterns
  and `pe verify` supply-chain check.
- `README.md` badge → 0.30.0.
- `docs/ENHANCEMENT_PLAN_V2.md` S4 marker: MISSING → SHIPPED v0.30.0.

### Reviewer fixes (applied pre-commit)

- **HIGH — `pe verify --update` had no privilege gate.** A compromised
  agent could have run `pe verify --update` inside an adopter tree
  to whitewash its own poisoning. **Fix:** `--update` now requires
  `PE_VERIFY_ALLOW_UPDATE=1` in the environment AND refuses to run
  when the resolved engine dir differs from the script's own parent
  tree (an adopter tree cannot regenerate the engine's manifest).
  Two new regression tests in `test_pe_verify.sh` cover both guards.
- **MEDIUM — symlink guard in engine auto-resolve.** `pe_verify.py`
  now rejects direct-symlink paths and non-directory targets when
  auto-resolving the engine dir from an adopter's
  `.claude/settings.json` hook commands. Prevents a
  hostile-settings.json redirect to a wrong tree.

### Alignment

- All 15 test scripts + `pe docs check` green at v0.30.0.
- Manifest coverage: 66 files (all agents, commands, hooks,
  skills/*, pe + pe_*.py, plugin.json, VERSION).
- No new install step for adopters — `pe install` picks up the
  new hook via the existing hooks.json merge.

### Notes — deliberately out of scope

- **Blocking-mode transcript-guard.** The hook is ADVISORY by
  design — the plan explicitly says "WARN + human review".
  Blocking on injection markers would be trivially bypassed by
  attackers who wrap payloads in variations we don't match, and
  would produce false-positives on legitimate content that
  discusses injection (docs, security posts).
- **Automatic secret rotation.** Detection is per-session; the
  hook doesn't touch Vault / rotate keys. That coordination
  needs an incident-response path, not a PostToolUse hook.
- **Cryptographic manifest signing.** `MANIFEST.sha256` is
  checked-in unsigned. Signing (`.asc` or in-tree GPG signature)
  is a follow-up (S5-adjacent) — the current design detects
  tampering AFTER install, which is what the plan asked for.

### Migration

- No breaking changes. Adopters upgrade via `pe install` — the
  new PostToolUse matcher merges cleanly into their
  `.claude/settings.json`.
- Adopters who patch engine files locally will see `pe verify`
  fail after upgrade — either revert the patch, or upstream it,
  or set `PE_SKIP_VERIFY=1` (advisory only in v0.30.0).

---

## [0.29.0] — 2026-07-03

> **S3 shipped — auth / payment / webhook security TEST templates +
> test-evidence path-gate on the security-review-trailer.** Six new
> pytest templates cover the failure modes that keep landing in
> production: JWT alg-confusion, OAuth PKCE bypass, webhook HMAC +
> replay, session fixation, client-supplied payment amounts, and
> replayable reset tokens. The security-review-trailer now REJECTS
> commits touching money-mutating paths unless test files are
> co-staged in the same commit — closing the "code without tests"
> loophole the plan called out.

### Added — `templates/tests/` (6 new templates)

- **`session-security.test.py.template`** — session fixation
  (session id rotates on login), HttpOnly / SameSite / Secure
  cookie flags, password-rotation invalidates other sessions,
  logout clears server session, idle timeout enforcement.
- **`jwt-security.test.py.template`** — CVE-2015-9235 (`alg=none`)
  + CVE-2016-10555 (RS256 → HS256 algorithm confusion) + expired
  token + missing `exp` claim + wrong-secret sig + empty sig +
  wrong `iss`. Every case documented with the exploited CVE.
- **`oauth-security.test.py.template`** — RFC 6749 §10 threats:
  state param required (CSRF), state-mismatch rejected,
  redirect_uri exact-match (open-redirect on callback = auth-code
  theft), PKCE required for public clients (RFC 7636),
  authorization code single-use + expiration.
- **`webhook-security.test.py.template`** — HMAC verify path:
  missing sig / wrong sig / tampered payload / stale timestamp /
  duplicate event_id dedup / unknown event type → 200 (prevents
  Stripe retry loops) / constant-time compare property.
- **`payment-security.test.py.template`** — server-side amount
  authority (classic $0.01 exploit), cross-org order rejection at
  payment boundary, Decimal-not-float, test/live key separation
  (prevents `sk_live_` in dev CI), idempotency-key on retry,
  negative-amount rejected, Charge persisted BEFORE provider call.
- **`reset-token-security.test.py.template`** — OWASP Forgot
  Password cheat-sheet: identical response for real vs fake user
  (no enumeration), single-use, expiration, ≥32-char entropy,
  no cross-user collision, existing-session invalidation on
  reset, policy applies on reset path too, timing-safe compare.

### Added — `hooks/security-review-trailer.sh` (S3 test-evidence gate)

- New narrow money-path regex (`payment|billing|webhook`) is
  matched against staged files. If ANY money-path file is staged
  and NO `tests?/` files are co-staged, the hook blocks the
  commit — even when a valid `Security-reviewed:` trailer is
  present. Message points at the pytest templates above.
- New escape hatch: `Security-tests-skip-reason: <reason>`
  (revert, rename-only, docs). Existing `Security-skip-reason`
  continues to blanket-skip both trailer and test gates.
- Configurable via `ENGINE_SECURITY_TEST_PATHS` env var (mirrors
  the existing `ENGINE_SECURITY_PATHS` pattern).
- Bugfix picked up en route: the original grep-pipeline for
  `SKIP` / `TRAILER` extraction was broken under `set -euo
  pipefail` (grep returning "no match" aborted the whole hook).
  Rewrapped in `{ … || true; }` so no-match is not a script
  failure. No adopter noticed because the failure mode masked as
  "block" — which was the intended reject for no-trailer commits.

### Added — tests

- **`tests/test_security_review_trailer.sh`** — 10 tests covering
  every trailer flow: non-security paths pass silently; auth+no
  trailer blocked; legacy self-attest accepted; skip-reason
  accepted; billing+trailer+no-tests BLOCKED (the new S3 gate);
  billing+trailer+co-staged-tests accepted; webhook+
  Security-tests-skip-reason accepted; billing+Security-skip
  -reason blanket-skips both gates; auth-only path doesn't require
  tests (test gate is money-only); `ENGINE_SECURITY_TEST_PATHS`
  override respected.

### Updated

- `plugin.json.description` — mentions S3 templates + test-evidence
  path-gate.
- `README.md` badge → 0.29.0.
- `docs/ENHANCEMENT_PLAN_V2.md` S3 marker: MISSING → SHIPPED v0.29.0.

### Alignment

- All 13 test scripts + `pe docs check` green at v0.29.0.
- Templates match the plan's file list exactly:
  `session/jwt/oauth/webhook/payment/reset-token-security.test.py.template`.
- The pre-existing `auth-robustness.test.py.template` (login-path
  smoke) remains as-is — S3 templates extend, don't replace.

### Notes — what's deliberately out of scope

- **Runtime auth-bypass / injection probing** — DELEGATED to the
  ai-testing-agent (`run_security_scan`) per `TESTING_TOPOLOGY.md`.
  The engine ships templates + the path-gate; it does NOT rebuild
  a runtime prober.
- **Adopter wiring** — every template ships with
  `raise NotImplementedError` / `pytest.skip` stubs that adopters
  must connect to their app's test client + fixtures. The templates
  are opinionated on WHAT to test, not on HOW to reach the code
  under test.

### Migration

- No breaking changes. Adopters who don't copy the templates and
  don't touch money paths see no behavior change.
- Adopters who DO touch money paths after `pe install` will see the
  test-evidence gate fire — copy the relevant template + wire the
  stubs, or add `Security-tests-skip-reason:` for genuine skips
  (revert, rename).

---

## [0.28.0] — 2026-07-03

> **A6 billing module — fourth (and final planned) reusable domain
> module ships. A6 module library is now COMPLETE for the operator's
> SaaS baseline.** Payment processing for Flask projects: Charge /
> Refund / PaymentEvent models (idempotency ledger), Decimal-only
> money helpers, PaymentProvider protocol with a Stripe PaymentIntent
> adapter, server-side amount authority (client NEVER passes the
> amount), HMAC-verified Stripe webhook handler with idempotency-by-
> event_id, and FORCE-mode RLS applied to all three tables via
> tenancy's `apply_rls_to_table` helper.

### Added — `templates/domain-modules/billing/` (11 files)

- **`README.md`** — six-part contract: server-side amount authority,
  Money as Decimal (never float), webhook HMAC verification,
  idempotency by event_id, test/live key separation via credential
  service, tenancy scoping with FORCE-mode RLS.

- **`money.py`** — Decimal/int-cents helpers. `to_cents()` REJECTS
  FLOATS LOUDLY (raises `MoneyError`) — the exact bug this module
  exists to prevent. `format_money()` is DISPLAY ONLY. Zero-
  decimal currency handling (JPY, KRW, VND). Regression-tested:
  `0.1 + 0.2 == 0.3` in Decimal (fails in float).

- **`models/payment.py`** — three tables + two typed enums. `Charge`
  (org_id + user_id + amount_cents BIGINT + currency VARCHAR 3 +
  provider + `provider_charge_id` unique per provider + `ChargeStatus`).
  `Refund` (charge_id + amount_cents + reason + `RefundStatus`).
  `PaymentEvent` — the idempotency ledger, unique on
  (provider, event_id). Duplicate webhook deliveries hit the
  constraint and skip silently.

- **`provider.py`** — protocol + factory. `PaymentProvider`
  runtime-checkable Protocol. `CreateChargeResult` + `VerifiedEvent`
  frozen dataclasses. `WebhookSignatureError` (subclass — NEVER
  catch and treat as valid). `register_provider()` + `get_provider()`
  factory. `_get_credential()` reads via `api-credentials` if
  installed, falls back to legacy env var.

- **`providers/stripe.py`** — Stripe adapter using the PaymentIntent
  API. Reads secret via credential service or `STRIPE_SECRET_KEY`.
  Reads webhook secret from `STRIPE_WEBHOOK_SECRET`. `verify_webhook`
  uses `stripe.Webhook.construct_event` and reclassifies ANY
  exception as `WebhookSignatureError`. Logs ONLY payload length +
  provider name on signature failure (never raw payload / signature
  — leak to attacker probing endpoint).

- **`service.py`** — `create_charge_for_order()` — the ONE-way path
  for creating a charge. Server-side amount lookup — reads
  `order.total_cents`, NEVER accepts amount from caller. Cross-tenant
  guard: raises `OrderNotChargeable` if the order belongs to a
  different org. Persists pending Charge BEFORE calling provider —
  mid-flight provider crash still surfaces in ops.

- **`webhooks/stripe.py`** — `handle_stripe_webhook()`. HMAC verify
  first. Idempotency via INSERT + `IntegrityError` catch on duplicate.
  Dispatch to per-event handlers (`payment_intent.succeeded`,
  `payment_intent.payment_failed`, `charge.refunded`). Unknown types
  ignored (never 500 — Stripe retries 5xx forever). All downstream
  failures logged + rolled back; NEVER propagate to Stripe.

- **`blueprints/billing.py`** — `POST /checkout/<order_id>`
  (@require_membership → server-side amount), `POST /webhooks/stripe`
  (public, HMAC-gated, CSRF-exempted), `GET /receipts/<charge_id>`
  (@require_membership + explicit org_id match check).

- **`templates_billing/receipt.html`** — Flask + Tailwind, slate
  palette, tabular-nums. Status badges by state.

- **`migrations/migrate_billing.py`** — CREATE charges + refunds +
  payment_events + indexes. Idempotent. Calls `apply_rls_to_table`
  on each — hard-depends on tenancy (import fails if tenancy not
  installed; correct behavior — billing without tenancy is a
  cross-tenant leak).

- **`tests/test_billing.py`** — 15 coverage-floor tests:
    * Money: Decimal roundtrip, string parse, int passthrough,
      float rejected loudly, no-float-drift regression, zero-
      decimal currency (JPY), currency case, invalid amounts,
      display-only `format_money`.
    * Provider factory: unknown raises, registered returned,
      credential service preferred over env, env-var fallback.
    * Webhook: signature error raised on bad sig.
    * Enums: status values + terminal states.

### Added — tests

- **`tests/test_pe_new.sh`** grew 53 → 65 tests. New coverage:
  billing module materializes all 11 files, quad-composite install
  (`auth + tenancy + api-credentials + billing`) leaves all four
  directories intact.

### Updated

- `docs/SCAFFOLD.md` — billing row added, 4-module install pairing
  documented, roadmap updated (Razorpay adapter + subscription
  billing deferred, email flows still queued).
- `plugin.json.description` — mentions billing's payment surfaces.
- `README.md` badge → 0.28.0.
- `docs/ENHANCEMENT_PLAN_V2.md` A6 marker: A6 module library is
  now COMPLETE for the operator's SaaS baseline; only extensions
  (email flows, adapters, subscriptions) remain.

### Reviewer fixes (applied pre-commit)

- **CRITICAL — RLS gap on `payment_events`:** column was `org_id BIGINT
  REFERENCES organizations(id)` (nullable). Account-level Stripe events
  (`account.updated`, `balance.available`, …) have no order metadata →
  `_extract_org_id` returned `None` → row persisted with `org_id=NULL`
  → FORCE-mode RLS cannot filter NULL rows → cross-tenant visibility.
  **Fix:** `org_id BIGINT NOT NULL REFERENCES organizations(id)` +
  webhook handler now returns `{"status":"ignored","reason":"no_org_id"}`
  BEFORE persisting when metadata is absent. Account-level events are
  not persisted at all (they can be picked up from Stripe's own
  dashboard).
- **HIGH — silent `STRIPE_WEBHOOK_SECRET` misconfiguration in prod:**
  StripeAdapter previously logged a `WARNING` and deferred failure to
  the first webhook call. **Fix:** in dev the warning stays (dev
  environments legitimately don't need webhooks), but if
  `STRIPE_LIVE_MODE=1` is set the adapter now raises `ProviderError`
  at startup — a misconfigured production deploy fails loudly instead
  of silently 400-ing every webhook.

### Alignment

- All 12 test scripts + `pe docs check` green at v0.28.0.
- Total module inventory: **4** — `auth`, `tenancy`,
  `api-credentials`, `billing`. Full multi-tenant SaaS baseline with
  payments in one install.

### Notes — what's deliberately deferred from billing's scope

- **Razorpay adapter** — same PaymentProvider protocol as Stripe;
  ships when the operator's Razorpay-first projects call for it.
- **Subscription billing** — recurring charges, plan/tier
  management. Ships after adopters prove the one-off charge shape.
- **Refund UI** — the schema + `refund()` method are ready; the
  admin UI for initiating refunds is per-project.
- **Invoice PDF** — receipt.html is HTML; PDF generation per
  project need (WeasyPrint / ReportLab).

### Migration

- No breaking changes. `pe module add billing` is a new drop-in.
  REQUIRES `auth` + `tenancy`; recommended with `api-credentials`.
- Adopters: `pe upgrade` picks up the new module.

---

## [0.27.0] — 2026-07-03

> **A6 tenancy module — third reusable domain module ships.**
> Multi-tenant `org_id` scoping + PostgreSQL RLS setup for Flask
> projects. Adds Organization + Membership models, session-based
> current-org context, decorators, `scoped_query` helper,
> `apply_rls_to_table` migration helper (with FORCE mode — blocks
> superuser bypass), and a basic org-switcher blueprint. Composes
> with `auth` (v0.26.0) and `api-credentials` (v0.25.0) — the three
> modules install side-by-side without conflict.

### Added — `templates/domain-modules/tenancy/` (13 files)

- **`README.md`** — post-materialization steps, two-layer defense
  doctrine (application `scoped_query` + database RLS), composition
  with `auth`, OrgRole-vs-User.role distinction.

- **`models/organization.py`** — `Organization` (slug-keyed URL-safe
  identifier + display_name + created_by + is_disabled soft-lock)
  + `Membership` (user↔org join with `role`, unique per pair) +
  `OrgRole` enum (owner/admin/member — deliberately distinct type
  from `auth.Role` so `require_org_role(Role.owner)` reads wrong at
  the type level).

- **`context.py`** — session-based current-org context:
    * `current_org_id()` / `require_current_org()` / `set_current_org()`
    * `init_tenancy_context(app)` — wires two `before_request` hooks:
      populate `g.current_org_id` from signed session, and emit
      `SET LOCAL app.current_org_id = <int>` on the DB session so
      RLS policies resolve correctly. Idempotent — safe to call
      multiple times. Emits `'0'` when no org active → RLS returns
      zero rows (safe default, no data leaks).

- **`decorators.py`** — `require_membership` (member of current org
  or 403; redirects to /orgs/switch when no org set) +
  `require_org_role(OrgRole)` (factory decorator; enforces
  per-org role; aborts 500 if used without `require_membership`
  above it — explicit engineering error, no silent-pass).

- **`scoping.py`** — `scoped_query(cls)` — the ONE-way path for
  tenant-safe queries. Auto-adds `WHERE org_id = <current>`.
  Raises `TenancyMisuse` when: (a) the model has no `org_id` column,
  or (b) no current org context is set. Loud failure beats silent
  empty-result. Plus `with_current_org(org_id)` context manager
  for job runners / batch scripts without an HTTP request.

- **`rls.py`** — `apply_rls_to_table(name, session)` migration
  helper. Idempotent. Does three things:
    1. `ALTER TABLE ... ENABLE ROW LEVEL SECURITY;`
    2. `ALTER TABLE ... FORCE ROW LEVEL SECURITY;` — blocks even
       superuser `BYPASSRLS` role attribute. This is the difference
       between a shipping-safe deploy and a CVE-worthy silent leak.
    3. `CREATE POLICY tenant_isolation ... USING (org_id =
       current_setting('app.current_org_id')::bigint);` — synthesized
       via `DO $$ ... IF NOT EXISTS ... $$` block since PostgreSQL
       lacks `CREATE POLICY IF NOT EXISTS`.
    * Rejects table names outside `[a-z0-9_]+` — defensive against
      SQL identifier smuggling if a caller ever mistakenly passes
      user input.
    * `rls_is_enabled(name)` diagnostic + `drop_rls_from_table(name)`
      for de-tenanting migrations (documented as dangerous).

- **`blueprints/tenancy.py`** — `/orgs`, `/orgs/switch`, `/orgs/new`,
  `/orgs/<slug>/members`, `/orgs/<slug>/members/<id>/remove`.
    * POST /orgs/switch — CSRF-protected (POST-only to prevent
      CSRF-via-img-src).
    * POST /orgs/new — creates org + auto-adds creator as
      OrgRole.owner. Slugifies with -2/-3/... on collision.
    * POST /orgs/<slug>/members/<id>/remove — @require_org_role(OrgRole.owner)
      gated. Refuses to remove the last owner.

- **`templates_tenancy/*.html`** — 4 templates. Flask + Tailwind,
  slate palette + tabular-nums, extends `base.html`.

- **`migrations/migrate_tenancy.py`** — CREATE TABLE organizations
  + memberships + indexes. Idempotent. `organizations` and
  `memberships` themselves do NOT get RLS (they're read BEFORE
  `SET LOCAL` fires — chicken-and-egg). New tenant-scoped tables
  call `apply_rls_to_table` in their own migration.

- **`tests/test_tenancy.py`** — 12 coverage-floor tests:
    * OrgRole enum: owner/admin_or_owner + type-distinctness from
      `auth.Role` (regression guard against import-the-wrong-Role
      silent-pass)
    * scoped_query: rejects missing org_id column, rejects
      no-current-org
    * require_membership: unauthenticated redirects to login,
      no-org redirects to switch
    * require_org_role: owner-admits-owner, owner-rejects-admin,
      admin-admits-{admin,owner}, admin-rejects-member,
      missing-membership-context-is-500
    * rls.apply_rls_to_table: rejects SQL identifier smuggling,
      accepts snake_case + alnum
    * context: set/get round-trip through session, init is
      idempotent (double-init doesn't double-register
      before_request hooks)

### Added — tests

- **`tests/test_pe_new.sh`** grew 39 → 53 tests. New coverage:
  tenancy module materializes all 13 files, tri-composite install
  (`auth + tenancy + api-credentials`) leaves all three module
  directories intact.

### Updated

- `docs/SCAFFOLD.md` — tenancy row added to the modules table.
- `plugin.json.description` — mentions tenancy's decorators + RLS
  helper.
- `README.md` badge → 0.27.0.
- `docs/ENHANCEMENT_PLAN_V2.md` A6 marker: adds "SHIPPED v0.27.0
  for tenancy — billing remains queued".

### Alignment

- All 12 test scripts + `pe docs check` green after the release.
- Total module inventory: **3** — `auth` (v0.26.0), `tenancy`
  (v0.27.0), `api-credentials` (v0.25.0). Cross-references between
  them (auth decorators ← api-credentials placeholder resolution;
  tenancy depends on users table from auth) all work.

### Notes — what's deliberately deferred from tenancy's scope

- **Email invitations** — needs email transport wired first (same
  reason password-reset is deferred from auth).
- **Cross-org resource sharing** — no doctrine yet on how a project
  or invoice can appear in two orgs. Ship when the operator's
  8CStudio Delivery build proves a shape.
- **Org-level API keys** — worth a future extension of the
  api-credentials module.
- **Advanced RLS policies** — the module ships the standard
  `org_id = current` policy. Row-level ACLs, time-based visibility,
  role-based row filtering all get added per project need.

### Migration

- No breaking changes. `pe module add tenancy` is a new drop-in.
  Requires `auth` module for the `users(id)` FK reference.
- Adopters: `pe upgrade` picks up the new module. `pe module add
  tenancy` in the target project when ready.

---

## [0.26.0] — 2026-07-03

> **A6 auth module — closes the placeholder decorators in
> `api-credentials`.** The second reusable domain module ships:
> session-based auth with bcrypt-12 password hashing, role-based
> decorators (owner / admin / member), a 15-minute step-up re-auth
> window, IP-scoped rate limiting, CSRF-protected forms, and a
> `create_owner` bootstrap script. When installed alongside
> `api-credentials` (v0.25.0), the credential admin's placeholder
> decorators resolve to the real thing — the credential admin is
> now fully gated with zero placeholder fallback.

### Added — `templates/domain-modules/auth/` (10 files)

- **`README.md`** — post-materialization steps: deps to add, session
  config in `create_app`, migration, `create_owner` bootstrap,
  composition with `api-credentials`.

- **`models/user.py`** — User (Flask-Login `UserMixin`) with:
    * `email` (unique index), `password_hash` (bcrypt), `role`
      (typed `Role` enum — never magic strings)
    * `password_verified_at` (drives the step-up window)
    * `is_disabled` (soft-lock without deleting)
    * `display_name`, `created_at`, `updated_at`
  Plus `FailedLogin` table (append-only) with an index on
  `(ip_address, created_at)` for the rate limiter.

- **`password_service.py`** — bcrypt hash + verify + strength check
  + IP-scoped rate limit:
    * `hash_password()` uses `BCRYPT_ROUNDS = 12` (2026 OWASP min)
    * `verify_password()` returns False on None/malformed hash —
      the None-check regression that unit tests lock in
    * `check_strength()` raises `PasswordTooWeak` on <12 chars, no
      letter, or no digit. Length-first per modern guidance
    * `failed_login_count()` / `is_rate_limited()` /
      `record_failed_login()` — 5 fails / 15-minute window / IP
    * NEVER stores plaintext; NEVER logs plaintext

- **`decorators.py`** — the primitives every gated endpoint uses:
    * `login_required` (re-exported from Flask-Login for
      one-import convenience)
    * `owner_required` — role gate, 403 for non-owner
    * `admin_required` — role gate for owner OR admin
    * `require_password_reauth` — 15-min step-up window. Reads
      `current_user.password_verified_at`, redirects to /reauth
      when None or stale. Normalizes naive datetimes to UTC.

- **`blueprints/auth.py`** — /login, /logout, /reauth routes:
    * POST /login — CSRF-protected, IP rate-limited, dummy-hash
      compare on missing user (no timing leak of email existence),
      stamps `password_verified_at` on success, records
      `FailedLogin` row on failure
    * GET /logout — ends session
    * POST /reauth — step-up. Re-confirms current_user's password
      without new session. Same rate-limit protection.

- **`templates_auth/{login,reauth}.html`** — Flask + Tailwind, slate
  palette, tabular-nums friendly. Reuse the `base.html` layout the
  scaffolded project provides.

- **`migrations/migrate_auth.py`** — CREATE TABLE users +
  failed_logins with the index. Idempotent (IF NOT EXISTS).

- **`scripts/create_owner.py`** — interactive bootstrap for the
  first owner. Refuses to run if an owner already exists
  (subsequent owners must be promoted by an existing owner via the
  admin UI, which is per-project scope).

- **`tests/test_auth.py`** — 15 coverage-floor tests:
    * Password hash roundtrip + wrong password fails + empty
      rejected + None returns False + malformed returns False
    * Strength check: short / no digit / no letter / ok
    * Role enum: owner / admin_or_owner / str-serialization
    * Step-up window: no stamp triggers reauth / recent allows
      through / old triggers reauth / naive datetime normalized
    * Rate limit: below threshold / at threshold

### Changed — `api-credentials`

- **`README.md`** updated: recommends installing `auth` first
  (`pe module add auth` → `pe module add api-credentials`) so the
  credential admin's decorators resolve to real implementations.
  Without `auth` the placeholder still aborts 403 (safe-by-default).
- No code changes to `credential_service.py` or
  `admin_credentials.py` — the placeholder import path was already
  correct in v0.25.0; auth just fills in the target.

### Added — tests

- **`tests/test_pe_new.sh`** grew from 28 → 39 tests. New coverage:
  auth module materializes all 10 files, combined install
  (`auth + api-credentials`) leaves both directories intact and
  non-conflicting.

### Updated

- `docs/SCAFFOLD.md` — auth module row added, "Recommended install
  pairing" section documents the composition, roadmap updated
  (tenancy + billing still queued, `password-reset` explicitly
  deferred from auth's scope).
- `plugin.json.description` — mentions the auth module.
- `README.md` badge → 0.26.0.

### Alignment

- All 12 test scripts + `pe docs check` green after the release.
- Adopters (8CStudio + Origyn) re-installed at v0.26.0.
- ENHANCEMENT_PLAN_V2 A6 marker updated to reflect: scaffold +
  api-credentials + auth SHIPPED; tenancy + billing on queue per
  "extract when stable in ≥ 2 adopters" doctrine.

### Notes — what's still deferred inside auth's scope

- **OAuth / SSO** — separate blueprint per provider (Google,
  GitHub, Microsoft) added per project need. Not batched into the
  core auth module.
- **JWT bearer surfaces** — session-cookie only in this release.
  Add a separate blueprint if an API surface needs bearer tokens.
- **Password reset flow** — email-token flow (token generation is
  ready in `password_service.py`-adjacent code; delivery layer is
  not shipped since it depends on the project's email transport
  choice: SendGrid / SES / Mailgun / etc.).
- **2FA / WebAuthn** — future addition; the step-up window covers
  the highest-value case (credential admin access) already.

### Migration

- No breaking changes. `pe module add auth` is a new drop-in
  materialization. Existing projects unaffected.
- Adopters: `pe upgrade` picks up the new module. `pe module add
  auth` in the target project when ready to use it.

---

## [0.25.1] — 2026-07-03

> **PARTIAL cleanup — everything shippable now shipped.** Operator
> feedback: partials silently accumulate and rot. This release
> closes SEVEN items that were previously marked PARTIAL, and
> re-classifies TWO items to their honest status (GATED vs
> NEXT-RELEASE) instead of pretending they're partial. From here on
> every plan item is either SHIPPED, GATED with named prerequisite,
> or on a named release queue — no floating in-between state.

### Closed — L1 nested tool-call span tree

- **`scripts/telemetry.py`** — `_emit_tool_use_child_spans()` walks
  the assistant record's `content` array, extracts `tool_use`
  items (id + name + input), and emits one OTel child span per tool
  invocation, parented at the assistant turn's span. Follows GenAI
  conventions (`gen_ai.tool.name`, `gen_ai.tool.call_id`,
  `8colors.parent_model`). No cost attribute on children — Anthropic
  bills per-turn, not per-tool.
- `.pe/traces/<session>.jsonl` now carries a real parent→child span
  tree, answering "where did this slot spend its time".
- **`tests/test_telemetry.py`** — 5 new tests: no-tools emits no
  children, missing content emits no children, one tool emits one
  child, multiple tools emit multiple children, all children share
  parent turn ID. 19/19 pass (was 14).

### Closed — L2 held-out subcorpus + trajectory metrics

- **`evals/fixtures/<gate>/holdout/`** — new subdirectory contract.
  Fixtures under here are the unseen-during-development recall path;
  they're walked separately from the main corpus. Runner has
  `--holdout-only` and `--no-holdout` filters. Seeded with
  `security-reviewer/holdout/fail-escalate-hardcoded-secret`
  (Stripe live secret in source with "TODO later" comment).
- **`tests/test_gate_efficacy.sh --metrics <path>`** — new flag
  writes JSONL per fixture with `gate`, `fixture`, `corpus`,
  `expected_exit`, `actual_exit`, `cost_cents`, `duration_ms`,
  `num_turns`, `tool_calls`. Shape mode fills only exit codes;
  `--live` fills all five. Feed into `pe telemetry summary`-style
  analysis for per-gate p50/p95 cost + recall.
- Output labels: `[main]` and `[holdout]` prefixes on every pass /
  fail line so the corpus split is visible per-run.
- Total shape-mode fixture count: 17 (was 16).

### Closed — L4 cost surfacing in retro-agent

- **`agents/retrospective-agent.md`** — Step 0 rewritten to run
  `pe telemetry collect` + `pe telemetry summary` alongside
  `pe collect`. Doctrine: the retro report's Cost section MUST cite
  top-3-cost sessions + per-model breakdown with dollar amounts, so
  the model-routing discipline in OPERATOR_WORKFLOW_V3 becomes
  measurable instead of faith.

### Closed — S6 tenant-isolation-auditor scheduling

- **`templates/launchd/com.ORG_TAG.tenant-isolation.weekly.plist.template`**
  — Monday 09:00 launchd plist. Bootstrap:
  `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/...plist`.
- **`templates/launchd/run_tenant_isolation.sh.template`** — wrapper
  that invokes `claude -p '/audit-tenants --window 7' --agent
  tenant-isolation-auditor` and writes the report under
  `docs/security/tenant-isolation-audit-<week>.md`. `PE_FORCE=1`
  bypasses the Monday gate.
- **`templates/ci/engine-quality.yml.template`** — new
  `tenant-isolation-audit` job, `if: github.event_name ==
  'schedule'`, `continue-on-error: true` (advisory; launchd is the
  primary path). Catches contributors who don't have launchd wired.

### Closed — D4 spacing/radius/shadow tokens

- **`hooks/design-lint.sh`** — new `_check_token_class` helper
  enforces `spacing_tokens`, `radius_tokens`, `shadow_tokens`
  allowlists per theme. Matches on Tailwind-style class prefixes:
    * `spacing_tokens`: p / px / py / pt / pb / pl / pr / m / mx /
      my / mt / mb / ml / mr / gap / space-x / space-y
    * `radius_tokens`: rounded-*
    * `shadow_tokens`: shadow-*
  WARN by default, FAIL under `design_lint.strict=true`. Empty
  allowlist = check disabled.
- **`templates/design-lint.config.template`** — documented shape
  with example values (`["1","2","4","6","8","12"]` for spacing,
  `["lg","xl"]` for radius, `["sm","md"]` for shadow).

### Closed — TOK1 prompt-cache hygiene

- **`hooks/cache-hygiene-warn.sh`** — new PostToolUse advisory hook
  fires when Write/Edit/MultiEdit touches CLAUDE.md,
  `.claude/agents/*.md`, or `rules/*.md` mid-session. Warns that
  every subsequent turn re-bills the prefix at full input rates
  (~10× the cache-hit rate). Dedupes per prefix file per session
  (state at `.pe/cache-hygiene-seen.state`). Advisory only —
  exits 0 always.
- **`hooks/hooks.json`** — new entry under PostToolUse
  `Edit|Write|MultiEdit` matcher.
- **`docs/OPERATOR_WORKFLOW_V3.md`** — new § Cache hygiene under §2
  Context diet. Four rules: batch prefix edits to session end,
  keep tool set stable, don't rewrite early history, hook watches
  for you.

### Closed — TOK2 read hygiene

- **`docs/OPERATOR_WORKFLOW_V3.md`** — new § Read hygiene under §2.
  Preference order for retrieving context: RAG query → grep+`Read
  offset/limit` → subagent for multi-file sweep → whole-file
  `Read` (last resort). Subagent pattern is the strongest native
  lever — burns its own context, returns a summary.

### Reclassified — A4 auto-escalation loop → GATED

- Previous marker: `PARTIAL v0.21.0 — execution primitive shipped;
  orchestrator auto-escalation wiring deferred`.
- New marker: `SHIPPED v0.21.0 for the primitive; auto-escalation
  loop GATED on enforce-mode first-fire evidence per §9 watchpoint`.
- Rationale: the primitive IS shipped (per-turn accounting fixed in
  v0.23.1 with 5 regression tests + live smoke). The auto-escalation
  loop is safety-gated — it needs first-fire evidence on
  enforce-mode (currently `tested = false` per policy §9). Calling
  this "partial" for months would be dishonest — it's a legitimate
  release-gate, not slop.

### Reclassified — A6 auth/tenancy/billing → NEXT-RELEASE

- Previous marker: `PARTIAL SHIPPED v0.25.0 — scaffold + 1 module;
  remaining modules deferred`.
- New marker: `SHIPPED v0.25.0 for scaffold + api-credentials;
  auth/tenancy/billing on next-release queue per "extract when
  stable in ≥ 2 adopters" doctrine`.
- Rationale: same principle — the scaffold + first module IS
  shipped and complete. Auth is v0.26.0's scope. Tenancy + billing
  land when the pattern stabilises across ≥ 2 adopters. Not
  partial; queued.

### Notes

- Total ENHANCEMENT_PLAN_V2 PARTIAL markers before v0.25.1: **9**.
  After v0.25.1: **0**. Every item is now SHIPPED, GATED with a
  named prerequisite, MISSING (not yet started), or on a specific
  release queue.
- All 12 test scripts + `pe docs check` green. Test count grew from
  ~180 → ~185 with the L1 span-tree regression tests.

### Migration

- No breaking changes. Adopters: `pe upgrade` picks up the new
  hook + updated design-lint. `pe install <project>` on next run
  materializes the new `cache-hygiene-warn.sh` hook wiring into
  `.claude/settings.json` via the existing idempotent merge.

---

## [0.25.0] — 2026-07-03

> **A6 (partial) — `pe new` project scaffolder + first reusable domain
> module (`api-credentials`).** The plan called this the "biggest
> structural gap" and marked it Effort: L. Full A6 = scaffold + a
> whole library of reusable SaaS modules (auth, tenancy, billing,
> credentials, ...). This release ships the SCAFFOLD half and ONE
> module as a proof-of-shape. The remaining modules land as each
> pattern proves itself across ≥ 2 adopters — the engine principle
> is "extract, don't architect in advance."

### Added — `pe new` scaffold

- **`scripts/pe_new.py`** — deterministic template-drop scaffolder.
  Zero API cost. Substitutes `{{PROJECT_NAME}}` / `{{PROJECT_SLUG}}`
  / `{{PROJECT_TAGLINE}}` placeholders, runs `git init -b main`,
  then chains into `pe install` on the new directory (unless
  `--no-install`).

- **`pe new <name> [--stack python-flask|generic] [--dir <parent>]
  [--tagline "..."] [--no-install]`** — 30-second fresh-project path.
  Slugifies the display name for the directory (`"Acme Invoices"` →
  `acme-invoices`). Refuses to run if the target directory exists and
  is non-empty (exit 1). Rejects unknown stacks with exit 3.

- **`templates/scaffold/python-flask/`** — Flask 3 + SQLAlchemy 2 +
  pytest + ruff + mypy stack. Ships `run.py` (app factory + /health
  endpoint), `pyproject.toml` (deps + tool config), `.env.example`
  (SECRET_KEY, DATABASE_URL, PORT), `.gitignore` (Python + engine),
  `CLAUDE.md` (project rules), `README.md`, `modules/__init__.py`,
  `tests/__init__.py`, `tests/test_smoke.py` (proves boot).

- **`templates/scaffold/generic/`** — stack-agnostic minimal tree.
  `modules/`, `tests/`, `scripts/`, `docs/`, `.gitignore`,
  `CLAUDE.md`, `README.md`. Extends any language / framework.

- **Complementary to `agents/project-kickstarter.md`** — that agent
  does interactive Q&A + Opus reasoning; `pe new` is the
  deterministic drop when the operator already knows the stack.
  Both paths end with the same `pe install`.

### Added — `pe module add` domain-module dropper

- **`pe module add <module> [--project <path>]`** — materializes a
  reusable module into `<project>/modules/<name>/`. Never overwrites
  existing files (reports "skipped" per collision). Exits 1 if EVERY
  file is a collision ("nothing written"). Exits 3 on unknown module.

- **`templates/domain-modules/api-credentials/`** — first reusable
  module. Extracted from the operator's global doctrine
  (`~/.claude/rules/common/api-credentials.md`) — this is the
  CODE side of the same pattern. Ships 8 files:
    * `README.md` — post-materialization steps (deps, env-var,
      blueprint registration, migration)
    * `models/api_credential.py` — encrypted row + audit table
      SQLAlchemy models
    * `credential_service.py` — 3-layer fallback (cache → encrypted
      DB → legacy env var), Fernet encryption, 60-second in-process
      cache, `invalidate_cache()`, `encrypt_for_storage()`
    * `blueprints/admin_credentials.py` — owner-only + step-up
      auth + audit-log blueprint. Write-only responses (last-4
      preview only). CSRF + rate-limit as doctrine.
    * `templates_admin/api_credentials.html` — write-only admin form
    * `templates_admin/reauth.html` — step-up password page
    * `migrations/migrate_api_credentials.py` — CREATE TABLE
      migration (idempotent via IF NOT EXISTS)
    * `tests/test_api_credentials.py` — coverage floor:
      encrypt/decrypt roundtrip, master-key-required-for-writes,
      env-var fallback, cache invalidation, plaintext-never-in-logs

### Added — tests

- **`tests/test_pe_new.sh`** — 27 smoke tests:
    * python-flask scaffold creates slugified dir, ships all 9
      expected files (README, run.py, pyproject.toml, CLAUDE.md,
      .gitignore, .env.example, 2× __init__.py, test_smoke.py)
    * placeholder substitution (name, slug, tagline in the right
      files)
    * git init runs
    * generic scaffold ships baseline files + excludes
      python-specific ones
    * refuses to overwrite non-empty target (exit 1)
    * unknown --stack rejected (exit 3)
    * pe module add materializes all 7 files
    * second pe module add reports "skipped" (idempotency)
    * unknown module rejected (exit 3)

- All 12 test scripts + `pe docs check` green (11 pre-existing +
  1 new). Total unit-test count across the suite continues to grow
  monotonically as new surfaces ship.

### Added — `docs/SCAFFOLD.md`

Doctrine doc: two-surface architecture (`pe new` for fresh, `pe
module add` for existing), available stacks + modules table,
placeholder substitution rules, `.template` suffix convention, the
no-overwrite policy, roadmap for next modules (auth, tenancy,
billing — deferred to follow-up releases per "extract, don't
architect in advance" principle), and how `pe new` complements
`project-kickstarter` and `project-onboarder`.

### Alignment sweep

- `docs/ENHANCEMENT_PLAN_V2.md` A6 marker: `MISSING` →
  `PARTIAL SHIPPED (scaffold + 1 module; module library deferred)`.
- `plugin.json.description` grew a summary of the two new surfaces.
- `README.md` badge → 0.25.0.
- `CHANGELOG` (this entry) documents scope + deferrals honestly.

### Notes

- **What's deferred to follow-ups** (not this release):
    * `auth` module (session + JWT + OAuth + password reset) —
      closes the last placeholder in `api-credentials` (which
      currently placeholder-decorates its blueprint with
      `owner_required` / `require_password_reauth` stubs).
    * `tenancy` module (multi-tenant `org_id` scoping + RLS setup).
    * `billing` module (Stripe / Razorpay integration with webhook
      HMAC verification + idempotency).
    * Each ships when it's genuinely reusable across ≥ 2 projects.
- The `api-credentials` module's blueprint currently has PLACEHOLDER
  decorators — this is intentional and documented in the module's
  README. Materialization on a project that doesn't yet have an
  auth module surfaces the gap immediately (the placeholder aborts
  with 403). Adopters that want to use `api-credentials` today
  must either bring their own auth or wait for the `auth` module.
- Total scaffolded project boot time end-to-end (fresh dir → `pe
  new` → `.venv` → `pytest -q`): ~90 seconds on a typical machine.

### Migration

- No breaking changes. `pe new` + `pe module add` are new
  subcommands; existing workflow untouched.
- Adopters: `pe upgrade` picks up the new subcommands. No
  re-install required — existing projects are already scaffolded.

---

## [0.24.0] — 2026-07-03

> **L3 — auto-memory governance (inspect / verify / delete /
> staleness).** The 2026 memory literature is emphatic that the hard
> part of agent memory isn't *learning* — it's **governance**:
> inspect / correct / delete tooling, retention + deletion policy,
> staleness handling. Deferring these is "an expensive architectural
> retrofit." Every project directory has a companion
> `~/.claude/projects/<slug>/memory/` where Claude Code writes
> long-lived facts; before v0.24.0 the engine had zero tooling for
> auditing or pruning that state. This release ships the missing
> inspection side.
>
> **Deliberately out of scope:** auto-writes stay with Claude Code
> (governed by the operator's global memory rules), and access
> control is not enforced yet. Enforcement waits for Claude Code
> to expose a write hook — the `scope` schema field ships now so
> future access-control work has a stable data model.

### Added — `pe memory <sub>` CLI

- **`scripts/pe_memory.py`** — new module, stdlib-only. Reads
  `~/.claude/projects/<slug>/memory/*.md` entries with YAML
  frontmatter (nested two levels: top-level `name` + `description`,
  nested `metadata:` dict with `node_type` / `type` /
  `originSessionId` and new L3 fields).

- **`pe memory ls [--project <path>] [--type <t>] [--stale]`** —
  list entries with type, age-in-days, staleness flag,
  description. Warns via stderr when `MEMORY.md` and on-disk files
  have drifted (files without index lines, or index lines pointing
  at missing files).

- **`pe memory show <name> [--project <path>]`** — full
  frontmatter + body dump, with computed `effective_freshness_days`
  and current staleness state at the top.

- **`pe memory rm <name> [--project <path>] [--yes]`** — deletes
  the file AND removes its line from `MEMORY.md` index. Prompts
  interactively unless `--yes`.

- **`pe memory verify <name> [--project <path>]`** — stamps
  `metadata.last_verified = today` (ISO date) on an entry the
  operator has re-checked. Resets the staleness clock without
  editing the body. This is the *endorse* path — cheaper than
  rewriting, honest about the fact that the fact still applies.
  Preserves all other metadata + body prose.

- **`pe memory stale [--project <path>] [--older-than-days N]`** —
  the pruning workflow. Lists entries past their per-type
  freshness window (or past N days if `--older-than-days` is
  set). Each row includes the two next actions:
  `pe memory verify <name>` (still true) or `pe memory rm <name>`
  (obsolete).

### Added — schema (all optional, backward-compatible)

Existing entries keep working unchanged. Three new optional fields
under `metadata:`:

- **`freshness_days: <int>`** — TTL override. Defaults per type:
  `user` = 90d, `feedback` = 60d, `project` = 14d,
  `reference` = 180d, (unknown) = 30d.
- **`last_verified: <YYYY-MM-DD>`** — auto-stamped by
  `pe memory verify`. When present, staleness measured from this
  date rather than mtime.
- **`scope: user | agent | session | org`** — advisory tag for
  multi-scope memory. Not read/write-enforced today; shipping the
  schema now so future access-control work has a stable data model.

### Staleness rule

An entry is stale iff:

    now - max(mtime, last_verified) >= (freshness_days or default_by_type)

Last-touched-date is the file's mtime OR the `last_verified` stamp,
whichever is later. Adding prose bumps mtime and counts as
touching; `pe memory verify` counts as touching without changing
content.

### Added — `docs/MEMORY_GOVERNANCE.md`

Doctrine doc explaining: why the L3 layer exists, the pruning
workflow, what the schema does and doesn't do, migration notes for
existing entries. Reads as an extension to the operator's global
`~/.claude/CLAUDE.md` memory rules, not a replacement.

### Added — tests

- **`tests/test_pe_memory.py`** — 25 unit tests:
    * Frontmatter parser: flat fields, nested metadata dict, quoted
      strings, malformed input raises.
    * Entry loader: all fields extracted, missing optionals default
      to `None`, bad `last_verified` date leaves it `None`.
    * Staleness: per-type defaults (all 4 types + unknown fallback),
      explicit `freshness_days` overrides default, `last_verified`
      resets the clock past even a 100-day-old mtime.
    * List entries: excludes `MEMORY.md` itself, missing dir returns
      empty list, malformed entries surfaced (not silently dropped).
    * MEMORY.md index I/O: bullet-line parser, ignores non-matching
      lines, remove-by-filename, missing-name returns False.
    * Desync detection: file-not-in-index reported, index-references-
      missing-file reported, clean state = zero problems.
    * `stamp_verified` mutation: adds when missing, replaces when
      present, preserves body, preserves other metadata (scope,
      freshness_days).
- **`tests/test_pe_memory.sh`** — shell wrapper for the standard
  test-suite loop. All 11 test scripts + `pe docs check` green.

### Notes

- Total agent count unchanged: 20.
- The engine's own memory directory has 6 entries (all `project`
  type, all created this week). Real-project smoke on the engine
  directory confirmed `ls / show / stale / verify` work end-to-end
  and edited a real entry (project-workflow-v3) with a
  `last_verified` stamp.
- Test file count: 11 scripts (was 10 — pe_memory added).

### Migration

- No breaking changes. Existing entries — every entry currently in
  `~/.claude/projects/*/memory/` — have no L3 metadata fields.
  Loaders return `None` for missing fields; staleness falls back to
  per-type defaults. Operators who want tighter control can add
  fields when convenient.
- Adopters: `pe upgrade` + `pe install <project>` picks up the new
  subcommand.

---

## [0.23.1] — 2026-07-03

> **Patch — model/cost accounting in `pe agent run` (found by real
> live-mode validation).** Before shipping L3, we ran one live
> gate-efficacy fixture end-to-end (~$0.14) to prove the whole
> A4 pipe worked against the real Anthropic API. It did — the
> security-reviewer agent emitted a correct PASS envelope and
> `pe gate parse` extracted exit 0. But the persisted run record
> showed `model_used: "sonnet"` (the alias, not the full ID) and
> `cost_cents: 0.0` (despite Claude billing $0.138). Unit tests
> couldn't have caught this — I'd guessed the wrong JSON shape.
> Fixed at the source, added 5 regression tests, verified with a
> second live invocation.

### Fixed

- **`scripts/agent_runner.py::parse_result`** — real `claude -p
  --output-format json` has NO top-level `model` key; instead
  `modelUsage` holds a per-model breakdown with real IDs like
  `claude-sonnet-4-6` and `claude-haiku-4-5-20251001`. New
  `_primary_model_from_modelusage()` helper picks the model with
  the most output tokens (Claude Code routes short tool calls to
  haiku while the main run stays on sonnet — the response emitter
  is whichever has the most output). Falls back to legacy `model`
  key → requested alias.
- **`scripts/agent_runner.py::parse_result`** — real output includes
  `total_cost_usd` as the authoritative cost from Claude itself.
  Now prefers this (× 100 → cents) over the derived price-table
  cost. Derived path stays as fallback when `total_cost_usd` is
  absent. The derived path was silently returning zero cents
  because the model alias `"sonnet"` never matched the
  `claude-sonnet-*` prefix in the price table.

### Added — regression tests

- `test_model_extracted_from_modelusage` — real JSON shape (no
  top-level `model`) → correct model ID extracted from `modelUsage`.
- `test_prefers_total_cost_usd_over_derived` — when both are present,
  authoritative cost wins (13.77 cents matches Claude's report).
- `test_falls_back_to_derived_cost_when_total_missing` — pre-1.x
  compatibility.
- `test_primary_model_picks_highest_output_tokens` — mixed haiku +
  sonnet responses correctly pick the primary emitter.
- `test_missing_modelusage_falls_back_to_alias` — persisted record
  stays populated when neither field is present.

31/31 agent_runner tests pass. All 10 test scripts + `pe docs check`
green. Verified with second live invocation:
`model=claude-sonnet-4-6 cost_cents=15.04` (was `model=sonnet cost_cents=0.00`).

### Notes

- Total live-mode validation cost so far: ~$0.28 (two invocations
  of security-reviewer/pass-parameterized-orm at ~$0.14 each).
- The A1 telemetry parser (`scripts/telemetry.py`) is UNCHANGED —
  it reads from `~/.claude/projects/<slug>/*.jsonl` which is
  Claude Code's own transcript log, a stable format. This bug was
  specific to `-p --output-format json` output, which is a
  DIFFERENT surface with different keys.

---

## [0.23.0] — 2026-07-03

> **A5 — Ponytail as universal prerequisite.** The published Ponytail
> evals report ~54% LOC reduction with 100% safety-held; that makes
> the decision-ladder cheaper than any other quality lever in the
> engine. This release closes the "PARTIAL" state by making it a
> default-on install, wiring an advisory PreToolUse hook that surfaces
> the ladder before every Write/Edit/MultiEdit, and adding the
> Ponytail preamble to the five code-writing agents that didn't have
> it yet.

### Changed — install default flipped

- **`scripts/install.sh`** — `WITH_PONYTAIL` defaults to `1`. A new
  `--no-ponytail` flag opts out (idempotent — safe to re-run). The
  original `--with-ponytail` flag is retained as a no-op for
  backward compatibility with older wrapper scripts.
- Usage line + help now list `--no-ponytail` and drop `--with-ponytail`
  from the primary shape.

### Added — PreToolUse advisory hook

- **`hooks/ponytail-preflight.sh`** — fires on Write / Edit /
  MultiEdit before disk. Reads the tool-event JSON from stdin,
  extracts the pending content (Write `content`, Edit `new_string`,
  or MultiEdit `edits[].new_string` summed), and emits the ladder:
    * Small pending content (< 50 lines): one-line reminder.
    * Large pending content (≥ 50 lines): verbose block with the
      full ladder + "any new dep requires an explicit `Ponytail:
      allow <reason>` in your envelope" reminder.
- Dedup: back-to-back small writes within a 10-minute TTL surface
  the reminder only once (state in
  `.pe/ponytail-preflight-seen.state`). Large writes ALWAYS surface —
  they're the highest-value reminder moment.
- **Advisory, never blocking.** Exits 0 on every path including
  malformed JSON, missing python3, or stdin probes. Bash tool
  (non-writing) suppressed silently.
- **`hooks/hooks.json`** — new PreToolUse entry for
  `Edit|Write|MultiEdit` pointing at the new hook, alongside the
  existing `Bash → pre-commit-envelope-check.sh` entry.

### Added — Ponytail preamble in code-writing agents

- Added to **5 agents** that were missing the reference:
    * `architect.md` — "architecture proposals compound: a service
      you introduce today becomes what every future feature bolts
      onto"
    * `data-model-auditor.md` — "extracted constant → config file →
      table; don't propose CRUD when a module constant is enough"
    * `e2e-runner.md` — "40 test files each importing their own
      login_helper is worse than 40 tests inlining three page.fill
      calls"
    * `project-kickstarter.md` — "kickstart is the highest-leverage
      moment for bloat"
    * `project-onboarder.md` — "don't replace working ad-hoc
      solutions with the 'correct' framework unless the operator
      asked"
- Already had it: `build-error-resolver.md`, `tdd-guide.md`.
- **7 of 7 code-writing agents** now reference the ladder in their
  preamble.

### Added — tests

- **`tests/test_ponytail_preflight.sh`** — 7 smoke tests:
    * small Write → short reminder
    * large Write (≥50 lines) → verbose block
    * non-writing tool (Bash) → suppressed
    * empty stdin → silent (probe safety)
    * dedup on back-to-back small writes within TTL
    * malformed JSON → silent exit 0 (never leaks stderr)
    * hook always returns exit 0 (never blocks a Write)
- All 10 test scripts + `pe docs check` green.

### Notes

- The hook is DELIBERATELY advisory. Blocking Write/Edit on a "walk
  the ladder" gate would create a UX cliff the operator can't
  diagnose from inside Claude Code. The ladder is a discipline, not
  a checklist gate — surfacing it at the moment of use is what makes
  it stick.
- Non-code-writing agents (brief-writer, planner, doc-updater,
  memory-consolidator, retrospective-agent, ceo, researcher,
  incident-synthesizer + all gate agents) were deliberately left
  alone. Applying the ladder to a gate agent muddles its role.
- The hook's dedup state lives in `.pe/ponytail-preflight-seen.state`
  which is covered by the existing `.pe/` gitignore rule.

### Migration

- No breaking changes. Existing installs pick up the default-on
  Ponytail install on next `pe upgrade` + `pe install`; operators
  who want to disable can pass `--no-ponytail`.
- Existing `.claude/settings.json` merges pick up the new PreToolUse
  hook via `pe install` (same idempotent merge that shipped in
  v0.10.0).

---

## [0.22.0] — 2026-07-03

> **A3 — incident → gate synthesizer (the self-improvement loop).**
> Closes §0's meta-principle: *incidents become gates automatically
> instead of waiting for a human to notice the pattern.* Ships as one
> new specialist agent (`agents/incident-synthesizer.md`) with a hard
> anti-abuse contract, one CLI wrapper (`pe incident propose`), one
> JSON schema (`schemas/proposal-envelope.schema.json`), and 19 unit
> tests covering the extractor + validator + materializer.
>
> **The anti-abuse contract is non-negotiable:** the synthesizer agent
> has NO Write/Edit tool. Its only output is a Proposal Envelope. The
> CLI materializes proposed files under `.pe/incident-proposals/<slug>/
> files/` in the OPERATOR'S project — never the engine repo. Human
> reviews the materialized files and opens a PR manually. No
> `--auto-apply` mode exists. Ever.

### Added — `agents/incident-synthesizer.md`

- New Opus-tier specialist. Reads ONE incident (retro digest, decisions
  FAIL row, `.claude/gates/*.json` FAIL envelope, operator note, or
  commit-history slice) and proposes ONE gate.
- Classification taxonomy: `sast_rule` (favoured; deterministic and
  cheap) → `hook` → `test_fixture` → `policy_toml` → `agent_revision`
  (last resort — persona edits are the least verifiable layer).
- Tools deliberately restricted to `["Read", "Grep", "Glob", "Bash"]`.
  NO `Write` or `Edit` — enforced at the Claude Code plugin layer,
  not just doctrine.
- Confidence discipline codified: 0.85+ needs a mechanical rule that
  fires on every recurrence; <0.4 shouldn't emit unless the operator
  asked for it explicitly.
- Every proposal MUST cite a corpus fixture (`validation_plan.
  corpus_fixture` = `{gate, slug, expected_verdict}`) — the fixture
  is A2's proof that the proposal actually catches the incident class.
- Total agent count: **20** (was 19). `_gate-contract.md` still isn't
  counted; the +1 is incident-synthesizer.

### Added — `schemas/proposal-envelope.schema.json`

- Draft-07 JSON schema for the Proposal Envelope, distinct from
  gate-envelope. Required fields: `schema_version`, `proposal_type`
  (const `"gate-synthesis"`), `incident_summary`, `incident_source =
  {kind, ref}`, `failure_class` (short slug regex), `proposed_gate_kind`
  (5-value enum), `confidence` (0–1), `proposed_files[]` (each with
  `path` regex rejecting absolute + `..`, `action` ∈ `{create, modify}`,
  `content`, `rationale`), `validation_plan = {corpus_fixture,
  regression_check}`.
- The `proposed_files[].path` regex is the FIRST layer of the
  anti-escape guarantee. The CLI's `materialize()` re-verifies via
  `Path.resolve()` + prefix check as defence-in-depth (a corpus fixture
  in `tests/test_incident_synth.py::test_rejects_escaping_path_defence_in_depth`
  proves it).

### Added — `scripts/incident_synth.py` + `pe incident` CLI

- `assemble_brief()` — normalizes the incident source into a
  brief with cited `incident_source.kind` + `ref`. Sources:
  file path (kind inferred from name — `retro_digest` /
  `decisions_jsonl` / `gates_json` / else `operator_note`),
  inline `--note` (kind `operator_note`), or
  `--decisions-fail` (samples the LATEST worker_quality row from
  `.pe/decisions.jsonl`).
- `extract_proposal()` — extracts the LAST fenced `\`\`\`json
  proposal-envelope` block. Distinct fence from gate-envelope so the
  two parsers never conflict.
- `_validate_shallow()` — stdlib-only draft-07-style validation.
  Catches missing required fields, enum drift, out-of-band confidence,
  and — critically — absolute or `..`-containing paths in
  `proposed_files`.
- `materialize()` — writes `.pe/incident-proposals/<UTC-timestamp>-
  <failure_class>-<hex>/proposal.json` + `files/<relative-path>` for
  every proposed file. Defence-in-depth path check ensures nothing
  escapes the `files/` subtree.
- **`pe incident propose --incident <file>|--note "<text>"|--decisions-fail
  [--out-dir <path>] [--model <alias>] [--timeout <s>] [--dry-run]`**
- **`pe incident list [--out-dir <path>]`** — enumerate past proposals
  with their `failure_class`, `proposed_gate_kind`, and confidence.

### Added — tests

- **`tests/test_incident_synth.py`** — 19 unit tests:
    * Envelope extraction (well-formed fence, last-fence-wins,
      missing fence, malformed JSON)
    * Shallow schema validation (valid envelope, missing required,
      wrong enum, out-of-band confidence, absolute path rejection,
      `..`-in-path rejection, wrong `action` value)
    * Materialization (files land at correct paths, proposal.json
      roundtrips, slug lands under `.pe/incident-proposals/`,
      escaping paths REJECTED even if schema missed them)
    * Brief assembly (note vs file kind inference, jsonl kind,
      decisions-fail sampling, decisions-fail with no matches raises)
- **`tests/test_incident_synth.sh`** — shell wrapper for the standard
  suite. All 9 test scripts + `pe docs check` green.

### Notes

- The eval corpus (`evals/fixtures/`) is UNCHANGED — the
  incident-synthesizer is a meta-agent (proposes gates; doesn't
  emit gate verdicts on code). Its output validates against
  `proposal-envelope.schema.json`, not `gate-envelope.schema.json`.
  Live-mode `tests/test_gate_efficacy.sh --live` still runs against
  the 5 seeded gates only.
- The synthesizer runs at Opus for the same reason `retrospective-
  agent` does: this agent's output steers future engine structure, so
  its reasoning depth bounds the ceiling of the whole self-
  improvement loop.
- Cost: Opus. Typical brief ~5–20k tokens; output ~5–15k tokens
  (envelope + file contents). Expect \$1–\$5 per proposal.

### Migration

- No breaking changes. `pe incident` is a new subcommand; existing
  workflow untouched.
- Adopters: `pe upgrade` + `pe install <project>` picks up the new
  agent + subcommand + schema.
- `.pe/incident-proposals/` is covered by the existing `.pe/` gitignore
  rule.

---

## [0.21.0] — 2026-07-03

> **A4 (partial) — headless agent invocation primitive + live-mode
> gate-efficacy.** Adds `pe agent run <name>` — a `claude -p` wrapper
> that invokes any engine agent by name with a brief on stdin, using
> the agent's YAML frontmatter (model, tools) and body (system prompt)
> from `agents/<name>.md`. Persists a structured run record to
> `.pe/runs/<slug>/{brief.md,run.json,output.txt}`. Then wires
> `tests/test_gate_efficacy.sh --live` on top: the eval harness can
> now actually invoke each gate against every fixture and compare
> the emitted envelope's verdict + failure_class to the expected.
>
> **What's still open in A4:** the orchestrator's auto-escalation
> loop (on `worker_quality` FAIL, invoke next tier headlessly, re-run
> the gate) — that's the caller of this primitive. Deferred to a
> follow-up release. The execution mechanism is ready; wiring it
> into `pe_orchestrator.py`'s decision loop with human checkpoints
> is a separate scope.

### Added — `pe agent run`

- **`scripts/agent_runner.py`** — headless agent invocation
    * `load_agent_spec()` parses `agents/<name>.md` frontmatter (name,
      model, tools, effort) + body (system prompt).
    * `build_argv()` assembles `claude -p --output-format json
      --model <alias> --append-system-prompt <body> --allowedTools <list>`.
      Uses `--append-system-prompt`, not `--system-prompt`, so Claude
      Code's own safety guardrails stay active on top of the persona.
    * `parse_result()` best-effort extracts `result / session_id /
      model / usage / duration_ms` from the JSON blob. Missing keys
      default to zero; raw JSON is retained so schema drift is
      inspectable.
    * `run_agent()` executes the subprocess with a 600s timeout;
      raises `ClaudeNotOnPathError` if `claude` is missing so callers
      can feature-detect a clean SKIP.
    * `persist_run()` writes `.pe/runs/<UTC-timestamp>-<agent>-<hex>/`
      with `brief.md`, `run.json` (structured, joinable against
      `.pe/telemetry.jsonl`), and `output.txt` (raw agent response).
    * Cost is computed via `scripts/telemetry.py::_cost_cents` so
      A1's price table is the single source of truth.

- **`pe agent run <name>` CLI**
    * `--brief <file>|-` — brief file path or stdin
    * `--out <path>` — write output to file (else stdout)
    * `--model <alias>` — override agent's default model
    * `--timeout <s>` — subprocess timeout (default 600)
    * `--dry-run` — print the assembled invocation without executing
      (redacts the system prompt body for readability)

- **Exit codes:** 0 success · 1 agent exited non-zero · 2 invalid args ·
  3 `claude` CLI not on PATH (feature-detected skip) · 4 agent .md
  file missing / unparseable

### Added — live-mode gate-efficacy

- **`tests/test_gate_efficacy.sh --live`** — for each fixture,
  invokes `pe agent run <gate> --brief input.md`, extracts the
  emitted envelope via `pe gate parse`, and asserts the exit code
  matches the directory-prefix contract. Also supports `--gate
  <name>` and `--fixture <slug>` filters + `--model <alias>` +
  `--timeout <s>`. Preflight-checks for `claude` on PATH and
  `ANTHROPIC_API_KEY` in the environment; skips cleanly (exit 0)
  if either is missing. Shape mode (default) unchanged: 16/16 pass.

### Added — tests

- **`tests/test_agent_runner.py`** — 22 unit tests covering:
  frontmatter parser (JSON-array tools, comma-list tools, missing
  frontmatter), agent-spec loader (real security-reviewer.md, missing
  agent, default model fallback), argv assembly (model override,
  append-system-prompt, empty tools, tool joining), JSON result
  parsing (well-formed, non-JSON fallback, missing usage, stderr
  capture), subprocess wrapper (FileNotFoundError → typed
  ClaudeNotOnPathError, canned success, non-zero exit forwarding),
  and run persistence (brief.md + run.json + output.txt written).
- **`tests/test_agent_runner.sh`** — shell wrapper for the standard
  test-suite loop.

### Notes

- `pe agent run` is the PRIMITIVE. It does not read `.claude/gates/`,
  it does not auto-trigger review trailers, it does not escalate. It
  runs one agent, once, with one brief, and hands you the output.
  Composing that primitive into an auto-escalation loop is the
  remaining half of A4 (deferred).
- The run record shape (`.pe/runs/<slug>/run.json`) is designed to be
  joined against A1's `.pe/telemetry.jsonl` via `session_id` — future
  releases can walk the runs directory to compute per-agent p50/p95
  cost and success rate for the retro.

### Migration

- No breaking changes. `pe agent run` is a new subcommand; existing
  workflow untouched.
- Adopters: `pe upgrade` + `pe install <project>` picks up the new
  subcommand + agent_runner.py.
- `.pe/runs/` is gitignored via the existing `.pe/` rule.

---

## [0.20.0] — 2026-07-03

> **A2 fill-out — gate-efficacy corpus complete across all 5 gate
> agents.** v0.19.0 seeded security-reviewer only; this release adds
> 12 more fixtures covering code-reviewer, database-reviewer,
> tdd-guide, and design-critic. Each gate now has a pass fixture, a
> fail-escalate fixture, and an adversarial safe-lookalike. As a
> side effect the corpus caught a real bug: `design-critic` (shipped
> in v0.18.0) was never added to the `gate_name` enum in
> `schemas/gate-envelope.schema.json` — a shape-mode failure fixed
> this release. This is exactly the class of drift the corpus was
> built to catch.

### Added — 12 new fixtures

**`evals/fixtures/code-reviewer/`**

- `pass-small-cohesive-refactor/` — clean extraction with type hints
  + test updated via public API.
- `fail-escalate-god-function/` — 60-line checkout doing 8 things,
  no transaction, no tests. Multiple HIGH findings expected.
- `adversarial-long-but-cohesive/` — 50-line P&L aggregator that IS
  single-responsibility (one input, one output, tested via return
  struct). Guards against blind "any function >30 lines is a god
  function."

**`evals/fixtures/database-reviewer/`**

- `pass-parameterized-migration/` — CREATE INDEX CONCURRENTLY +
  partial predicate matching the query.
- `fail-escalate-missing-tenant-filter/` — multi-tenant SELECT
  without `WHERE org_id = ...` — the exact silent-leak pattern
  tenant-isolation-auditor targets.
- `adversarial-covered-by-composite-index/` — ORDER BY that LOOKS
  unindexed but is fully covered by an existing
  `(org_id, total_billed DESC)` composite. Guards against
  index-recommendation without schema context.

**`evals/fixtures/tdd-guide/`**

- `pass-red-then-green/` — textbook two-commit sequence, real
  RED (import error) then GREEN.
- `fail-escalate-no-tests-added/` — new payment-flow module with
  0% coverage, no red-first.
- `adversarial-pure-refactor/` — refactor with no new test needed
  (public API unchanged, existing tests cover every branch of the
  extracted helper). Guards against "any commit without a new test
  file is FAIL."

**`evals/fixtures/design-critic/`**

- `pass-token-conformant/` — slate palette, serif+sans hierarchy,
  tabular-nums, quiet empty state.
- `fail-escalate-ai-aesthetic-drift/` — 8 tells on one screen:
  purple/blue gradient, glassmorphism, chip-pill filters,
  hover:scale-105, emoji decoration, centered oversized display
  type, missing tabular-nums, flat hierarchy.
- `adversarial-minimal-not-unfinished/` — deliberately spare
  utility page (API-credentials form) that COULD read as
  "unfinished." Guards against "polish = more UI" bias.

### Fixed

- **`schemas/gate-envelope.schema.json`** — `design-critic` added to
  the `gate_name` enum. The design-critic agent shipped in v0.18.0
  emitting `"gate_name": "design-critic"` in every envelope, but the
  JSON Schema enum still only listed the original 6 gates. Any
  design-critic envelope validated with `pe gate parse` since v0.18.0
  would have failed with `not in enum`. Discovered by the v0.20.0
  corpus expansion — first real bug the eval harness caught.

### Notes

- Corpus totals: **16 fixtures across 5 gates** (4 security-reviewer +
  3 each for code-reviewer / database-reviewer / tdd-guide /
  design-critic).
- Still shape-mode only. Live-mode (`--live`) that actually invokes
  each agent and scores emitted vs expected envelopes is scoped as
  part of A4 (orchestrator invokes workers headlessly) — a larger
  release. This one is corpus + regression coverage.

### Migration

- No breaking changes. `schemas/gate-envelope.schema.json` gained an
  enum value; older envelopes still validate.
- `pe upgrade` → `pe install <project>` picks up the new fixtures.

---

## [0.19.0] — 2026-07-02

> **A1 + A2 + L1 + L4 — telemetry + gate-efficacy corpus.** The
> engine can finally measure what it costs and check what its gates
> catch. Circuit-breaker budgets were "inf" placeholders because
> agent-emitted `envelope.cost` is self-reported and unreliable; the
> gates shipped with zero test coverage of their verdict shape.
> This release closes both gaps at the source of truth: Claude Code's
> own session transcripts (real usage dicts, real model names), and
> a seeded fixture corpus with a schema-validating runner.

### Added — A1 telemetry (transcript parser + OTel spans + cost)

- **`scripts/telemetry.py`** — parses `~/.claude/projects/<slug>/*.jsonl`,
  extracts every assistant turn (input / output / cache-read /
  cache-creation token counts + model + git branch + cwd), dedupes
  by `uuid`, writes structured records to `<project>/.pe/telemetry.jsonl`.

- **OTel-shaped spans (L1)** emitted to `<project>/.pe/traces/<session>.jsonl`.
  Follows OTel GenAI conventions (`gen_ai.system=anthropic`,
  `gen_ai.request.model`, `gen_ai.usage.*`) plus 8colors-specific
  attributes (`8colors.cost_cents`, `8colors.git_branch`, `8colors.cwd`).
  Local-first — no external observability service required; operators
  who want Langfuse / Arize / Grafana just tail the file.

- **Cost attribution (L4)** — `CENTS_PER_MTOKEN` table with 2026-07
  Anthropic pricing per model prefix (opus / sonnet / haiku, with
  cache-read ~10% of input). Unknown model → 0 cost, surfaces the
  miss instead of silently over-billing.

- **`pe telemetry collect / summary`** subcommands wired into the CLI.
  Zero API cost — parses local transcripts only. Feature-detected:
  no transcripts → exit 0.

- **`tests/test_telemetry.py`** — 13 unit tests covering the parser,
  pricing table invariants (cache_read < input for every model), and
  OTel span shape. Runs standalone via unittest, zero external deps.

### Added — A2 gate-efficacy corpus (seeded)

- **`evals/README.md`** — corpus contract: per-gate
  `evals/fixtures/<gate>/<verdict-prefix>-<slug>/{input.md,
  expected-envelope.json}`. Directory prefix carries the expected
  verdict class (`pass-`, `fail-escalate-`, `fail-halt-`, `warn-`,
  `adversarial-`), enforced by the runner.

- **`evals/fixtures/security-reviewer/`** — 4 seed fixtures:
    * `pass-parameterized-orm` — clean SQLAlchemy `select()`.
    * `fail-escalate-sql-injection` — f-string SQL, CRITICAL.
    * `fail-halt-underspecified` — empty diff, `task_underspecified`.
    * `adversarial-safe-string-format` — log-line f-string that
      **looks** like SQL injection but isn't — guards against
      "any f-string with user data is CRITICAL" false-positive.

- **`tests/test_gate_efficacy.sh`** — shape-mode runner. Iterates
  every fixture, validates the expected envelope against
  `schemas/gate-envelope.schema.json` via `pe gate parse --bare`, and
  asserts the exit code class matches the directory prefix. Zero
  API cost. Live-mode (`--live`, planned v0.20.0) will actually
  invoke each gate and check whether the emitted verdict matches
  the expected envelope.

### Changed — circuit breaker guidance

- **`policy/circuit_breaker.toml`** — token budgets still `"inf"`
  (shadow-mode unchanged), BUT the comment block now cites the
  empirical baseline: this engine's own 2948 assistant turns
  ($1846 grand-total, opus-4-8 dominant) yield starting guesses of
  `worker_tokens_budget = 4_000_000` / `gate_tokens_budget = 2_000_000`
  for the eventual enforce-mode graduation. Numbers derived from
  measurement, not selected from a hat.

### Notes

- A2 seed covers **security-reviewer only**. The other four gate
  agents (code-reviewer, database-reviewer, tdd-guide, design-critic)
  get their seed fixtures in v0.20.0.
- Live-mode gate-efficacy (`--live` flag on
  `tests/test_gate_efficacy.sh`) is scaffolded in the README but not
  wired yet — requires a per-gate `pe agent run` interface first.
- L2 (adversarial / held-out split + trajectory metrics) partially
  landed: `adversarial-*` prefix is honored by the runner; held-out
  subdirs + step-count / retry metrics ride on the same `--live` path.

### Migration

- No breaking changes. `pe telemetry` is new subcommand; existing
  workflow untouched.
- Adopters: `pe upgrade` then `pe install <project>` picks up the
  new subcommand and eval corpus.

---

## [0.18.1] — 2026-07-03

> **PF2 — static perf gate.** Custom semgrep rule pack catching the
> "instant on 100 rows, OOM on 1M rows" class (unbounded queries) +
> missing-index candidates + blocking work in the request path.
> Small package: rides on top of the S1 SAST hook with a config-
> driven rule file. Extends `database-reviewer` with the runtime
> partner (`EXPLAIN ANALYZE`, `auto_explain` guidance).

### Added

- **`templates/perf/semgrep-perf-rules.yml.template`** (PF2) —
  custom semgrep rules, Python-focused. Rule IDs prefixed `pf2.*`
  for allowlisting:
    * `pf2.sqlalchemy.list-query-without-limit` — `.query.all()`
      / `session.query(...).all()` / `execute(select(...)).scalars().all()`
      without `.limit()` / `.paginate()` — WARNING.
    * `pf2.django.list-query-without-limit` — `list(Model.objects.all())`
      / `Model.objects.all().values()` without slice or filter — WARNING.
    * `pf2.raw-sql-select-star-no-limit` — raw `SELECT *` on any
      table without a `LIMIT` or `WHERE` — INFO.
    * `pf2.sqlalchemy.order-by-without-visible-index` — `.order_by()`
      on a column with no `db.Index(...)` in the same model file —
      INFO (advisory; semgrep can't verify indexes exist in
      migrations, only nearby model definitions).
    * `pf2.blocking-http-in-view` — `requests.get`/`post` /
      `urllib.request.urlopen` inside a `@app.route(...)` handler —
      WARNING (task queue / async framework instead).
    * `pf2.time-sleep-in-view` — `time.sleep()` inside a route
      handler — ERROR (pins worker).
- **`.process-engine.yaml.template`** — new `perf_gate.semgrep_rules`
  key. Empty by default; adopter sets to `.semgrep-perf-rules.yml`
  after copying the template into place. Feature-detected (missing
  path or missing semgrep → advisory skip).

### Changed

- **`hooks/sast-scan.sh`** — reads
  `perf_gate.semgrep_rules` and adds it as an extra `--config`
  when set. Uses WARNING severity by default (INFO under
  `sast_gate.strict=true`), so a fresh install doesn't drown the
  adopter. Only fires on staged `.py` files.
- **`agents/database-reviewer.md`** — three additions:
    * **§Query safety** — "Missing `LIMIT`" upgraded MEDIUM → HIGH
      with explicit reference to the PF2 rule pack + noqa escape
      hatch.
    * **§Index quality** — new "PF2 checks" bullet block: every
      column referenced by `.filter`/`.order_by`/`.group_by` must
      be indexed; `EXPLAIN ANALYZE` seq-scan / sort-materialisation
      interpretation rules.
    * **New §`EXPLAIN ANALYZE` — when to require it** — attaches
      to every new query in an endpoint called >10× per session.
      Documents `auto_explain` + `pg_stat_statements` setup for
      Postgres in prod; PF6 (performance-reviewer agent, future)
      will consume these.

### Rationale

Static grep is not perfect — this pack biases toward false negatives
(prefers to miss a bug than shout at every line). Combined with the
PF1 runtime query-count template (adopter test suite) + the future
PF6 performance-reviewer agent, the perf story stops being "there's
a static line in the checklist" and becomes a three-layer defence:

| Layer | What catches |
|---|---|
| **PF2 (this release)** | Static — obvious unbounded queries, blocking-in-view, missing-index candidates |
| **PF1** (v0.17.2) | Runtime — in-process query count doesn't scale with N |
| **PF3** (v0.18.0) | Backend p95 latency + Lighthouse frontend budgets |
| **PF6** (future) | Agent judgment — cache invalidation, algorithmic complexity, EXPLAIN plan interpretation |

### Verification

- 86/86 tests pass.
- `pe docs check` clean at v0.18.1.
- 8CStudio + Origyn re-installed; perf rule template lands at
  `docs/templates/perf/semgrep-perf-rules.yml.template`.

### Session pickup (v0.19.0 next)

- **A1 telemetry** — parse Claude Code transcripts / OTEL usage
  into `.pe/decisions.jsonl`. Budgets are still `"inf"` so the
  circuit breaker is decorative; A1 makes it real.
- **A2 gate-efficacy eval harness** — seeded-defect corpus per
  gate + held-out/adversarial fixtures per L2 + trajectory
  metrics. Proves every gate above (security, design, perf)
  actually works.

---

## [0.18.0] — 2026-07-03

> **V2 wave 2 — design parity + accessibility + performance budgets.**
> Ships D1 (design-critic agent + evidence-verified envelope) + D2
> (axe-core WCAG 2.1 AA gate) + PF3 (Lighthouse perf budgets + backend
> p95 latency), sharing Lighthouse wiring between D2 and PF3 (one CI
> job, two verticals). Closes the code-vs-design asymmetry that was
> the operator's stated #2 priority: **design is now evidence-verified,
> not self-attested.**

### Added

- **`agents/design-critic.md`** (D1) — new gate agent. Emits standard
  E1 envelope (`gate_name = "design-critic"`); rubric covers:
    * **9 AI-aesthetic tells** — stock-token palette, glow/neon,
      manifesto copy, card-grid-as-menu, emoji-as-icon, over-padding,
      default font pairing, word-chip UI, no signature element. ≥3
      tells on a new/reworked screen → FAIL rule
      `d1.ai_aesthetic_rubric.tells_exceeded` with "match locked
      reference" instruction.
    * **5 quality dimensions** — density, hierarchy, tabular
      numerals, empty states, responsive. Two "bad" dimensions =
      FAIL.
    * **Reference lock** — if `docs/design/reference/<page>.png`
      exists, judged against it; drift = `d1.reference_drift`.
  Agent count 18 → 19. The P5.9 rubric moves here from
  `code-reviewer.md` (code-reviewer now points to design-critic and
  keeps the tells as a reference list only).
- **`hooks/design-review-trailer.sh`** rewritten (D1 — was: bare
  self-attest accepted). Now mirrors `code-review-trailer.sh`:
    * Multi-file UI commits (≥`ENGINE_UI_THRESHOLD`, default 2)
      REQUIRE `Design-reviewed: <envelope-sha>` that resolves to a
      PASS/WARN record in `.claude/gates/`.
    * Legacy `Design-reviewed: design-critic|self|ui-ux-design-agent`
      accepted only on single-file UI diffs (bug fix, copy tweak).
    * `Design-skip-reason: <one-line>` accepted with mandatory
      reason.
    * `PE_SKIP_DESIGN_TRAILER=1` bypass (logged).
    * FAIL verdicts in the envelope block the commit (was: no
      verdict check).
- **`templates/e2e/a11y-audit.spec.ts.template`** (D2) — Playwright
  spec using `@axe-core/playwright`. Iterates nav paths (reuses
  smoke.spec.ts's discovery helper); asserts zero WCAG 2.1 AA
  violations per path; reports "incomplete" findings (need human
  review) but doesn't fail on them. Loads `.axe-config.json` for
  project-specific rule tuning + per-page overrides.
- **`templates/design/axe-config.json.template`** (D2) — starter
  axe config with commented `disableRules` guidance ("every
  disabled rule is a11y debt") and per-page override structure.
- **`templates/ci/lighthouse-ci.yml.template`** (D2 + PF3) —
  GitHub Actions workflow. **One workflow, two gates.** Runs
  `lhci autorun` on PRs touching UI/frontend paths. Uses adopter's
  `.lighthouserc.json` for URL list + assertions. Chrome + npm
  cached; upload target defaults to `temporary-public-storage`
  (free, ephemeral).
- **`templates/perf/lhci.json.template`** (D2 + PF3) — Lighthouse
  CI budget config with per-category floors (`accessibility ≥ 90`
  D2; `performance ≥ 0.75` PF3; `best-practices ≥ 0.85`) + hard
  metric budgets (LCP ≤ 2500ms, TBT ≤ 300ms, CLS ≤ 0.1, total ≤
  1500KB, images ≤ 600KB, JS ≤ 500KB). Adopter-tunable per
  vertical.
- **`templates/tests/latency-budget.test.py.template`** (PF3) —
  pytest template for backend p95 latency budgets. Two-phase per
  endpoint: N warm-up + M measured requests; sort, take p95,
  assert `<= budget_ms`. Adopter wires `_call()` to their test
  client and populates `ENDPOINTS = [(method, path, budget_ms), ...]`.

### Changed

- **`agents/code-reviewer.md`** — UI review § softened. The P5.9
  9-tells rubric MOVED to `agents/design-critic.md` (which owns the
  gate now). code-reviewer's section is now a reference note
  pointing at design-critic — you no longer emit both a code-review
  and design-review verdict on the same diff.
- **`templates/process-engine.yaml.template`** — 3 new opt-in
  sections: `design_gate` (enabled/ui_threshold), `a11y_gate`
  (enabled/wcag_level/axe_config/lighthouse_a11y_min), `perf_budget`
  (enabled/lighthouse_perf_min/lhci_config).
- **`scripts/install.sh`** — copies `templates/design/*`,
  `templates/perf/*`, and `templates/ci/lighthouse-ci.yml.template`
  into adopters at `docs/templates/{design,perf,ci}/`. Idempotent.
- **`plugin.json`** description updated to reflect 19 agents +
  3 CI templates + the design/a11y/perf additions.
- **`README.md`** badge → 0.18.0; agent count 18 → 19; Agents
  table gained the `design-critic` row.

### Fixed

- Design was self-attested while code was evidence-verified — the
  asymmetry that made design drift ship. v0.18.0 D1 closes this:
  the design-review-trailer now requires an envelope-sha on
  multi-file UI commits, just like code-review has since v0.10.0.

### Verification

- 86/86 tests pass (9 sync + 10 install-reconcile + 12 hooks +
  33 orchestrator + 22 P2.11 unittest).
- `pe docs check` at v0.18.0: **19 agents on disk**, docs
  consistent.
- 8CStudio + Origyn re-installed against v0.18.0:
    * 8CStudio preserves its project-local `database-reviewer.md`
      fork (as expected — P2.1 pattern).
    * Both report clean symlinks; new templates land at
      `docs/templates/{design,perf,ci}/`.

### Session pickup (v0.18.x + v0.19.0)

- **v0.18.x** — PF1 optional wrapper `hooks/perf-gate.sh` + PF2
  unbounded-query + missing-index static gate (semgrep rule pack +
  database-reviewer § extension).
- **v0.19.0** — A1 telemetry (budgets are still `"inf"` — breaker
  decorative) + A2 gate-efficacy eval harness (seeded-defect
  corpus + adversarial + trajectory metrics per L2).

---

## [0.17.2] — 2026-07-03

> Sync patch — closes three floaters from the parallel-session PF1 +
> A9.2 work + fixes the stale README badge from v0.17.1. No new
> functional gate; wires the PF1 template into `database-reviewer`
> so the two halves reference each other correctly.

### Added

- **`templates/tests/query-count.test.py.template`** (PF1) — in-process
  N+1 detector. Two variants ship in the same template: SQLAlchemy
  (`before_cursor_execute` counter) + Django (`CaptureQueriesContext`).
  Two invariants per endpoint: (1) `assert_max_queries(N)` bounded
  ceiling, (2) query count MUST NOT scale with row count (the actual
  N+1 assertion). Adopter wires the fixture into their session and
  picks the framework variant.
- **`agents/database-reviewer.md`** — Query safety §N+1 row extended
  to reference the PF1 template as the definitive runtime gate.
  Static grep misses indirect N+1 (template touching `.related` per
  row, serializer lazy-loading per item); the reviewer now requires
  a query-count assertion on any endpoint flagged for suspected N+1
  before merge.

### Changed

- **`docs/ENHANCEMENT_PLAN_V2.md` PF1 section** — coverage note
  corrected. The earlier "delegate to the agent" note was
  architecturally wrong: a **black-box** agent can only sample
  latency (list-vs-detail ×5), which the agent already ships in
  `generators/performance_tests.py::generate_n_plus_one_journeys`.
  Real query-count N+1 detection is **inherently in-process**, so it
  lives as an engine pytest template the adopter runs in its own
  suite. Correct split: **engine = the real detector (in-process
  query count); agent = complementary black-box latency smoke.**
  Neither replaces the other. PF1 STATUS marked template-shipped;
  optional `hooks/perf-gate.sh` wrapper stays open.
- **`docs/AI_TESTING_AGENT_VALIDATION.md`** — DOGFOOD 2026-07-03
  banner added. The engine's S1 SAST gate (semgrep
  `p/security-audit + p/owasp-top-ten`) was run against the
  ai-testing-agent codebase and found **13 findings** the agent's
  own security testing missed on itself: 8× `avoid-sqlalchemy-text`
  (raw `text()` — triage each for binding), 1× XXE (FP —
  allowlisted), 1× unescaped-HTML XSS (**real; fixed** with
  `autoescape=True`), 3× MD5 (2 legit perceptual-hash FPs to
  allowlist; 1 in the deprecated licensing subsystem). All 679
  tests still pass after the two fixes. **This is A2 eval-proof-
  in-miniature: the engine gate works on a codebase it wasn't
  built for.**
- **`README.md`** badge synced 0.17.0 → 0.17.2 (v0.17.1 shipped
  from a parallel session without the badge update).

### Verification

- 86/86 tests pass (9 sync + 10 install-reconcile + 12 hooks +
  33 orchestrator + 22 P2.11 unittest).
- `pe docs check` clean at v0.17.2.

### Wave pickup

Next real wave (**v0.18.0**) — D1 design-critic agent + verified
envelope + D2 axe-core Playwright + Lighthouse CI + PF3 Lighthouse
perf budgets + backend p95 latency. Shares Lighthouse wiring
between D2 and PF3 (one setup, two verticals).

---

## [0.17.1] — 2026-07-03

> Security wave, part 2 — **A9.2 API breaking-change gate**. Reuses the
> ai-testing-agent's differ (via the new `ai-test api-diff` CLI) instead of
> building an oasdiff gate from scratch. Catches the silent class of prod
> break: the tests pass but the response *shape* changed.

### Added

- **`hooks/api-contract-check.sh`** (A9.2) — pre-commit gate. When a committed
  OpenAPI/Swagger spec changes, it diffs `HEAD` vs the staged version via
  `ai-test api-diff` and **blocks the commit on a breaking change** (removed/
  renamed endpoint, param, or field; type change; new required field).
  Additions are advisory. Registered in `.pre-commit-config.yaml.template`;
  configured via `api_contract_gate.{enabled,spec_globs}` in
  `.process-engine.yaml`. Optional by design: advisory skip if `ai-test`
  isn't installed (mirrors `sast-scan`). Bypass: `PE_SKIP_API_CONTRACT=1`.
- **`agents/code-reviewer.md`** — new **API contract (HIGH)** checklist
  section: judge the semver impact of a flagged break (MAJOR bump or
  deprecation window), and catch breaks when there's no committed spec to diff.

### Changed

- **ai-testing-agent** gains an `ai-test api-diff` CLI wrapping the same
  `APIDiffer` the `compare_api_specs` MCP tool uses — one source of truth,
  callable deterministically from the hook. (See `AI_TESTING_AGENT_VALIDATION.md`.)

---

## [0.17.0] — 2026-07-03

> First V2 wave — security core (S1 + S2). Turns the security-reviewer
> from a Node-centric prompt-checklist into an evidence-based
> Python-first gate wired to real SAST tools. Operator's #1 priority.

### Added

- **`hooks/sast-scan.sh`** (S1) — Static Application Security Testing
  pre-commit hook that feature-detects and runs, per language:
    * Python: `semgrep --config=p/security-audit --config=p/owasp-top-ten` + `bandit -rq`
    * Go: `gosec` + `semgrep p/security-audit`
    * JS/TS: `semgrep p/javascript --config=p/owasp-top-ten` + `eslint --plugin security`
  Missing tool = advisory skip with a fix-it hint (`pipx install
  semgrep bandit`, `go install github.com/securego/gosec/v2/cmd/
  gosec@latest`). Blocks the commit only when a tool ran AND found
  HIGH+ severity issues. `--strict` mode drops the threshold to
  MEDIUM+. FP allowlist via `.semgrep-allowlist.txt` per project.
  Extra semgrep rule packs via
  `sast_gate.semgrep_configs` yaml value (e.g. `"p/flask,p/django"`).
  Bypass one commit: `PE_SKIP_SAST=1`.
- **`templates/security/`** — new template dir:
    * `.semgrep-allowlist.txt.template` — starter allowlist file with
      comment guidance ("every entry deserves a comment explaining
      why").
    * `README.md` — installation ladder + toggling + escalation.
- **`.process-engine.yaml.template`** — new `sast_gate` section:
  `enabled` (default true) / `strict` (default false) /
  `semgrep_configs` / `allowlist`.

### Changed

- **`agents/security-reviewer.md`** (S2) — substantial rewrite:
  * **De-Node-ified** — Python-first pattern table (SQLAlchemy string
    interpolation, `subprocess shell=True`, `pickle.loads`,
    `yaml.load` on untrusted, `flask.render_template_string(user)`,
    MD5/SHA1 for passwords, `secrets` vs `random`, `verify=False` in
    `requests`). JS/TS + Go tables preserved as secondary references.
  * **Analysis Commands** section rewritten around real tools per
    stack — semgrep/bandit/pip-audit for Python primary; gosec +
    govulncheck for Go; npm audit + semgrep p/javascript for
    JS/TS. Points at the pre-commit `hooks/sast-scan.sh` so the
    agent doesn't duplicate.
  * **Step 3 Auth depth** — new full section covering session
    security (HttpOnly/Secure/SameSite/CSRF/fixation-rotation on
    login), JWT (reject `alg:none`, require `exp`/`aud`/`iss`,
    `verify_signature=False` = CRITICAL, symmetric key strength),
    OAuth 2.0/OIDC (exact-match `redirect_uri`, `javascript:`/
    `data:` block, `state` param, PKCE for public clients, no
    tokens in URLs), password-reset tokens (≥128-bit entropy, TTL
    ≤1h, single-use, rate-limited, timing-safe compare, no user-
    existence leak).
  * **Step 4 Payment + webhook** — new section covering server-side
    amount authority (`Decimal` not `float` = CRITICAL), webhook
    signature verification (constant-time compare), idempotency
    keys, test/live key separation, atomic refund state machines.
    Fires on paths matching `payment|webhook|billing|checkout|
    invoice`.
  * **Confidence scoring** — new §, findings emit a confidence
    score 0.0–1.0. `verdict=WARN` for confidence <0.5 (surfaces
    without blocking); `verdict=FAIL` only when confidence ≥0.5
    AND severity HIGH+. This is the "critical without drowning"
    routing the operator asked for.
  * **OWASP Top 10 (2021)** — updated numbering (A01–A10) and
    per-category questions rewritten for Python/Flask/Django
    context.
- **`hooks/.pre-commit-config.yaml.template`** — wires `sast-scan`
  as a pre-commit stage. Env-var comment table gains `PE_SKIP_SAST`.
- **`scripts/install.sh`** — copies `templates/security/*` and the
  dotfile `.semgrep-allowlist.txt.template` into
  `<project>/docs/templates/security/` on install.
- **`plugin.json`** version + **`README.md`** badge → 0.17.0.

### Session pickup (v0.18.0 next)

- **D1** — Design-critic agent + evidence-verified envelope (closes
  the code-vs-design asymmetry).
- **D2** — axe-core + Lighthouse CI (the strongest OSS design gates —
  a11y + perf). Shared wiring with PF3.
- **PF3** — Lighthouse perf budgets + backend p95 latency assertions.

Then v0.18.x for PF1 (runtime N+1 gate) + PF2 (unbounded-query /
missing-index static gate). Both share tooling with S1's semgrep +
the database-reviewer agent.

---

## [0.16.0] — 2026-07-03

> P7.4 skills stocktake tooling + P7.5 execution-patterns docs.
> Closes the operator-workflow chapter of the plan honestly — every
> P7 item is now shipped or explicitly documented as out-of-engine-
> scope. Engine work against the full plan (excluding P3.x
> strategic and P4 parked) is complete.

### Added

- **`scripts/skills_audit.py`** + **`pe skills-audit`** subcommand
  (P7.4). Zero-mutation inventory + classification of the operator's
  `~/.claude/skills/` and `~/.claude/commands/`:
  - Flags name collisions across skills and commands.
  - Classifies skills as engine-shipped / core-recommended /
    engine-command-shadowed / external.
  - With `--project <path>`, flags project-local duplicates.
  - Exits 1 on collisions or command-shadowed skills so it can slot
    into pre-commit or CI.
- **`docs/SKILLS.md`** (P7.4). The engine's opinionated **core-20**
  skill list with rationale per row. Pairs with `pe skills-audit`.
  Documents the "prune everything else" principle without touching
  the operator's machine.
- **`docs/EXECUTION_PATTERNS.md`** (P7.5). Concrete recipes for the
  four execution patterns referenced in `OPERATOR_WORKFLOW_V3.md`
  §4:
  1. Interactive judgment session
  2. Worktree fleet for parallel slots
  3. Headless `claude -p` batches
  4. Background agents (launchd / cron / ad-hoc)
  Includes decision tree for lane classification, failure modes to
  avoid, and cross-refs to hooks/agents that make each pattern safe.

### Changed

- **`docs/RHYTHM.md`** gained an "Execution patterns" section
  cross-referencing the new `EXECUTION_PATTERNS.md` recipes. The
  three-lane classification (Judgment / Standard slot / Mechanical
  batch) is now visible in the weekly-rhythm doc.
- **`scripts/install.sh`** doc-allowlist gained `SKILLS.md` and
  `EXECUTION_PATTERNS.md` so adopters receive both on `pe install`.
- **`plugin.json`** version → 0.16.0. **`README.md`** badge → 0.16.0.

### Engine work complete against the audit + hygiene backlog

Every P0/P1/P2/P5/P6/P7 item on `docs/IMPROVEMENT_PLAN.md` is now
either **✅ SHIPPED** or explicitly documented as **out-of-engine-
scope** (P7.2 global-rules half — operator's `~/.claude/rules/`,
not engine repo).

**Deliberately parked (per plan):**
- **P3.1–P3.12** — L-effort strategic (`pe new`, SaaS module
  extraction, native plugin migration, telemetry, eval harness,
  execution loop, doc consolidation, SaaS review coverage, Python
  test suite parity, hybrid RAG, fleet ops). Sequence after
  8CStudio settles post-#227.
- **P4** — "Deliberately NOT now" (Phase 4 DAG, auto-tier-routing,
  engine self-mod, vector DB, pe_core pkg).

Next: switch to 8CStudio for **#227 dev-env repair** — the true
critical-path blocker. Engine returns for P3.x after #227 lands.

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
