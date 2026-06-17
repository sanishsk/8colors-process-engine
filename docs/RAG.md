# RAG — Semantic search over docs/research/

> Doctrine doc for engine v0.3 RAG. Loaded into target project at
> install time as `docs/process-engine/RAG.md`.

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
→ planner in this exact order" (CLAUDE.md §9 step 1). That's a
process patch, not a structural fix.

The structural fix: make `docs/research/` semantically searchable so
the relevant prior decisions surface automatically, regardless of
which file you happen to open first.

## How it works

1. **Index** — `scripts/research_index.py rebuild` scans
   `docs/research/*.md`, chunks each file into ~800-char paragraph-
   aware windows with 120-char overlap, embeds each chunk via Gemini
   `text-embedding-004` (768 dims), stores in
   `docs/research/.research-index.sqlite`.

2. **Query** — `scripts/research_index.py query "<terms>"` embeds the
   query, computes cosine similarity against all chunks in-memory,
   returns top-K with file path + score + 500-char snippet.

3. **Wire** — brief-writer and architect agents have a "Step 0" in
   their system prompts that runs the query before drafting. If the
   top match scores ≥0.55, the agent reads the full source file and
   cites it under `## Related prior work` in the new doc.

## Architecture decisions

| Decision | Choice | Reason |
|---|---|---|
| Storage | SQLite, in-tree | Zero infra. 1.5k chunks ≈ 10 MB. Project-portable. |
| Embedding model | Gemini text-embedding-004 (768 dims) | `google-generativeai` is already a common project dep. Free tier covers RAG. Asymmetric task-types (`RETRIEVAL_DOCUMENT` for index, `RETRIEVAL_QUERY` for query) improve recall. |
| Chunking | 800 chars, paragraph-aware, 120 overlap | Captures whole sections (briefs are paragraph-heavy). Overlap preserves context across chunk boundaries. |
| Similarity | Cosine in numpy after L2-normalize | Fast enough for <100k chunks. No vector-DB extension needed. |
| Incrementality | sha256 per file in `docs` table | Re-runs only re-embed changed files. Day-to-day cost ~zero. |
| Invocation | Bash script + slash command | Slash command is documentation surface; agents call the script directly via Bash. Simpler than a custom MCP server. |
| Index location | `<corpus>/.research-index.sqlite` (gitignored) | Each clone rebuilds locally. Embeddings depend on the model — pinning embeddings to git would version-lock the model. |

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
- **sentence-transformers (local embeddings)** — adds ~1 GB of torch
  deps. Gemini's free tier is generous enough that local-only isn't
  worth the install cost. Could ship as fallback in v0.4.
- **MCP server wrapping the index** — added complexity for adopters
  (extra `.mcp.json` config). The agent-runs-bash pattern works the
  same and is simpler.
- **TF-IDF / BM25** — doesn't catch the Workbox-miss class. The whole
  point is that semantic similarity surfaces "OSS contract" when you
  search for "workbox dexie hand-rolled". Lexical search wouldn't.

## Setup (per project)

```bash
# 1. Get a free Gemini API key
open https://aistudio.google.com/apikey

# 2. Export it (add to shell rc to persist)
export GEMINI_API_KEY=AIza...

# 3. Install Python deps (one-time)
pip install numpy google-generativeai

# 4. Build the index
python3 scripts/research_index.py rebuild

# 5. Test
python3 scripts/research_index.py query "<a known topic>"
```

## Cost

Gemini's free tier (as of 2026-06) gives 1500 RPM and 1M tokens/day on
`text-embedding-004`. For 8CStudio's 70-doc corpus (~1.3 MB markdown,
~1500 chunks, ~200k tokens), a full rebuild costs **zero** on free
tier. Incremental rebuilds (after a single new doc) cost cents of API
quota at most.

If your corpus is >10k docs or you want paid tier for higher rate
limits, the model card is at
https://ai.google.dev/gemini-api/docs/models/gemini#text-embedding.

## Maintenance

Re-run `rebuild` whenever `docs/research/` changes. Options:

- **Manual** — at the start of each session that's about to draft a
  brief / architect doc.
- **Pre-commit hook** — add a hook that runs `rebuild` if any
  `docs/research/*.md` is staged. (v0.4 will ship this.)
- **launchd / cron** — nightly rebuild. Overkill for most projects;
  the sha256-incremental path makes the cost of stale-by-a-day
  basically zero.

## When to call from agents

Wired in v0.3:

- `brief-writer` agent — Step 0 of its workflow
- `architect` agent — Step 0 of its review process

Recommended to wire in your project (v0.3 doesn't ship these by default):

- `/start-session` skill — when the recommended first task is a new
  brief or architect doc, surface a top-3 of likely-relevant prior
  work in the orientation report.
- `planner` agent — same Step 0 pattern as brief-writer.

## Failure modes to know

- **API key not set** — script exits 1 with a clear message + URL to
  get the key.
- **Index empty** — `query` reports "index is empty" and exits 2. Run
  `rebuild` first.
- **Embedding model upgrade** — if Gemini deprecates `text-embedding-
  004`, the script needs an update + a full re-index. The `meta` table
  in SQLite tracks the model name so you can see the mismatch.
- **Token cap on first run** — Gemini caps each embed call at 2048
  tokens. The 800-char chunker is well under this. If you change
  CHUNK_SIZE to >6000 chars, the embed will fail.

## Comparison: this RAG vs the manual "read brief first" rule

The manual rule (CLAUDE.md §9 step 1, added 2026-05-28) says:

> MANDATORY when picking up an in-progress slot: read researcher →
> brief → architect → planner in this exact order before writing any
> code.

That works **if you know which wave you're picking up.** It fails when
the new wave overlaps with prior work in a non-obvious way. The
classic example: someone proposes a new "offline sync" feature without
realizing Wave 1M already has 6 slots of offline sync architecture.

The semantic index catches that case. The manual rule still applies
once you know which wave to read.

**Both should be in force.** The rule is the safety net for known
waves. The index is the discovery tool for non-obvious overlaps.
