# RAG — Semantic search over docs/research/

> Doctrine doc for engine RAG. Loaded into target project at install
> time as `docs/process-engine/RAG.md`.
>
> v0.5 update: multi-provider embeddings; **fastembed (fully local, no
> API key) is the default**.

## The problem this solves

**The Workbox-miss class.** When picking up an in-progress slot, an
agent reads the latest planner doc and starts implementing. But the
planner doc doesn't always re-surface the OSS decisions locked earlier
in the brief. Result: a foundational library choice gets re-derived,
or worse, hand-rolled when the brief already adopted an OSS solution.

The origin incident: 2026-05-28 Wave 1M.3 Phase 1 root-cause audit
showed the brief locked Workbox + Dexie + hand-rolled Flask sync. The
session pickup read the planner only and missed the Workbox part. We
patched the symptom by mandating "read researcher → brief → architect
→ planner in this exact order" (CLAUDE.md §9 step 1). That's a process
patch, not a structural fix.

The structural fix: make `docs/research/` semantically searchable so
the relevant prior decisions surface automatically, regardless of
which file you happen to open first.

**Validated:** on the 8CStudio Wave 1M.3 corpus, the query
`workbox dexie offline sync OSS contract` surfaces all four 1M.3 docs
with cosine ≥0.70 — well above the agents' 0.55 threshold.

## How it works

1. **Index** — `scripts/research_index.py rebuild` scans
   `docs/research/*.md`, chunks each file into ~800-char paragraph-
   aware windows with 120-char overlap, embeds each chunk via the
   configured provider, stores in
   `docs/research/.research-index.sqlite`.

2. **Query** — `scripts/research_index.py query "<terms>"` embeds the
   query, computes cosine similarity against all chunks in-memory,
   returns top-K with file path + score + 500-char snippet.

3. **Wire** — brief-writer and architect agents have a "Step 0" in
   their system prompts that runs the query before drafting. If the
   top match scores ≥0.55, the agent reads the full source file and
   cites it under `## Related prior work` in the new doc.

## Providers (v0.5)

| Provider | Cost | Quality | Setup | Dims |
|---|---|---|---|---|
| **`fastembed`** (default) | Free, runs locally | Good for ≤10k docs | `pip install fastembed` (~150 MB + 33 MB model on first use) | 384 |
| `voyage` | Free credit + paid | Best recall (Anthropic-recommended) | `pip install voyageai` + `VOYAGE_API_KEY` | 1024 |
| `gemini` | Free tier + paid | Good, asymmetric task-types | `pip install google-generativeai` + `GEMINI_API_KEY` | 768 |
| `openai` | Paid (cheap) | Good | `pip install openai` + `OPENAI_API_KEY` | 1536 |

**Why fastembed default:** Adopters already have Claude Code (Anthropic
relationship). Forcing a second API signup (Google AI Studio / Voyage /
OpenAI) for a dev-tool is friction. Fastembed runs offline with zero
API keys — the project should "just work" after `pip install fastembed`.

**When to upgrade off fastembed:**

- Corpus >10k docs and you want higher recall → `voyage`
- You already have a `GEMINI_API_KEY` for other reasons → `gemini`
- You prefer OpenAI's billing surface → `openai`

Switching providers triggers a full rebuild (different vector spaces
aren't compatible; the script detects this via the stored `embedding_dim`
in the `meta` table and force-rebuilds).

### Provider resolution order

When `--provider` isn't set on the CLI:

1. `--provider` CLI flag
2. `.process-engine.yaml` `rag.provider`
3. Env detection (first of `VOYAGE_API_KEY` / `GEMINI_API_KEY` /
   `OPENAI_API_KEY` that's set)
4. Fastembed default

This means: an adopter with no config + no API keys gets fastembed
automatically. An adopter who already has `OPENAI_API_KEY` in env gets
OpenAI without configuring anything. Explicit config always wins.

## Architecture decisions

| Decision | Choice | Reason |
|---|---|---|
| Storage | SQLite, in-tree | Zero infra. 1.5k chunks ≈ 10 MB. Project-portable. |
| Default embedding | fastembed BAAI/bge-small-en-v1.5 (384 dims) | Fully local; no key required; adopter "just works". |
| Chunking | 800 chars, paragraph-aware, 120 overlap | Captures whole sections (briefs are paragraph-heavy). Overlap preserves context across chunk boundaries. |
| Similarity | Cosine in numpy after L2-normalize | Fast enough for <100k chunks. No vector-DB extension needed. |
| Incrementality | sha256 per file in `docs` table | Re-runs only re-embed changed files. Day-to-day cost ~zero. |
| Invocation | Bash script + slash command | Slash command is documentation surface; agents call the script directly via Bash. Simpler than a custom MCP server. |
| Index location | `<corpus>/.research-index.sqlite` (gitignored) | Each clone rebuilds locally. Embeddings depend on the model — pinning embeddings to git would version-lock the model. |
| Multi-provider | 4-provider plug-in via Embedder ABC | Adopter friction reduction. fastembed for "just works"; voyage/gemini/openai for power users. |

## What was considered and rejected

- **pgvector on the project's existing Postgres** — overkill for <100k
  docs. Adds a dependency on a running Postgres for the dev-tool
  surface, which would conflict with adopters whose projects use other
  DBs.
- **Chroma / Qdrant local** — fine, but adds a new service. SQLite +
  numpy is enough.
- **Anthropic Files API + memory tool** — limited to ~500 docs per
  workspace, beta, requires Anthropic API key (not always set up for
  dev tools).
- **sentence-transformers (full)** — adds ~1 GB of torch deps.
  Fastembed (ONNX runtime, ~150 MB) is the lean alternative we
  shipped instead.
- **MCP server wrapping the index** — added complexity for adopters
  (extra `.mcp.json` config). The agent-runs-bash pattern works the
  same and is simpler.
- **TF-IDF / BM25** — doesn't catch the Workbox-miss class. The whole
  point is that semantic similarity surfaces "OSS contract" when you
  search for "workbox dexie hand-rolled". Lexical search wouldn't.

## Setup (per project)

### Minimal (default fastembed)

```bash
# 1. Install Python deps (one-time, ~150 MB)
pip install fastembed numpy

# 2. Build the index — first call downloads the ~33 MB model to ~/.cache/fastembed/
python3 scripts/research_index.py rebuild

# 3. Test
python3 scripts/research_index.py query "<a known topic>"
```

No API key. No signup. No billing.

### Upgrading to Voyage (Anthropic-recommended)

```bash
# 1. Sign up for free credit
open https://www.voyageai.com/

# 2. Export key
export VOYAGE_API_KEY=...

# 3. Install + reconfigure
pip install voyageai
# In .process-engine.yaml:
#   rag:
#     provider: voyage

# 4. Re-index (different vector space)
python3 scripts/research_index.py --provider voyage rebuild --force
```

### Upgrading to Gemini

```bash
open https://aistudio.google.com/apikey
export GEMINI_API_KEY=AIza...
pip install google-generativeai

# In .process-engine.yaml:
#   rag:
#     provider: gemini

python3 scripts/research_index.py --provider gemini rebuild --force
```

### Upgrading to OpenAI

```bash
export OPENAI_API_KEY=sk-...
pip install openai

# In .process-engine.yaml:
#   rag:
#     provider: openai

python3 scripts/research_index.py --provider openai rebuild --force
```

## Cost

| Provider | Cost on 8CStudio 70-doc corpus full rebuild |
|---|---|
| fastembed | $0 (local CPU; ~30 s) |
| voyage-3 | $0 (free credit covers it; subsequent rebuilds ~$0.10) |
| gemini text-embedding-004 | $0 (free tier; 1M tokens/day) |
| OpenAI text-embedding-3-small | ~$0.005 (200k tokens × $0.02/1M) |

Incremental rebuilds (after a single doc change) cost cents-or-less
on any paid provider.

## Maintenance

Re-run `rebuild` whenever `docs/research/` changes. Options:

- **Manual** — at the start of each session that's about to draft a
  brief / architect doc.
- **Pre-commit hook** — add a hook that runs `rebuild` if any
  `docs/research/*.md` is staged. (v0.5 will ship this.)
- **launchd / cron** — nightly rebuild. Overkill for most projects;
  the sha256-incremental path makes the cost of stale-by-a-day
  basically zero.

## When to call from agents

Wired in v0.3:

- `brief-writer` agent — Step 0 of its workflow
- `architect` agent — Step 0 of its review process

Recommended to wire in your project (engine doesn't ship these by
default):

- `/start-session` skill — when the recommended first task is a new
  brief or architect doc, surface a top-3 of likely-relevant prior
  work in the orientation report.
- `planner` agent — same Step 0 pattern as brief-writer.

## Failure modes to know

- **No provider available, no API keys** — falls back to fastembed.
  First run pip-installs the model from HuggingFace; this requires
  network on first use only.
- **API key set but provider package not installed** — clear error
  message with the `pip install` command.
- **Index empty** — `query` reports "index is empty" and exits 2.
  Run `rebuild` first.
- **Embedding model change** — the script detects the dim mismatch in
  the `meta` table and force-rebuilds. No silent garbage scores.
- **Provider deprecates a model** — update `.process-engine.yaml`
  `rag.model` or pass `--model`. The `meta` table tracks what was
  indexed so you can see the mismatch.

## Key safety

The embedding key is read only from environment variables — never
written to any config file, log, or the SQLite index. The script
ignores `api_key`-like keys in `.process-engine.yaml` (we don't even
parse for them) to prevent foot-guns.

When sharing the engine repo or your project:

- ✅ `.process-engine.yaml` is safe to commit (no secrets).
- ✅ `.research-index.sqlite` is gitignored automatically.
- ✅ Shell env vars stay in your `~/.zshrc` (not in any repo).
- ⚠ Adopters: never paste a key into `.process-engine.yaml`. The
  default fastembed provider needs no key.

## Comparison: this RAG vs the manual "read brief first" rule

The manual rule (CLAUDE.md §9 step 1, added 2026-05-28) says:

> MANDATORY when picking up an in-progress slot: read researcher →
> brief → architect → planner in this exact order before writing any
> code.

That works **if you know which wave you're picking up.** It fails
when the new wave overlaps with prior work in a non-obvious way. The
classic example: someone proposes a new "offline sync" feature
without realizing Wave 1M already has 6 slots of offline sync
architecture.

The semantic index catches that case. The manual rule still applies
once you know which wave to read.

**Both should be in force.** The rule is the safety net for known
waves. The index is the discovery tool for non-obvious overlaps.
