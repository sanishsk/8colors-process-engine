# Changelog

All notable changes to `8colors-process-engine`.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
