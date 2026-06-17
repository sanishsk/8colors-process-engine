---
description: Semantic search over docs/research/* — surface prior briefs, architect docs, planner artifacts, audits before drafting new ones.
---

# /research-search

Query the local semantic index of `docs/research/` to find related
prior briefs, architect docs, planner artifacts, audits, and OSS
decision logs.

**Why this exists:** the 2026-05-28 root-cause audit on Wave 1M.3 Phase
1 showed that planner-only reads at slot pickup miss the OSS contract
locked earlier in the brief. The index makes that class of miss
detectable: search for the topic, see what the engine has already
decided.

## Usage

```bash
.venv/bin/python3 scripts/research_index.py query "<your terms>"
```

Examples that should land hits:

- "workbox dexie offline sync" → Wave 1M.3 brief + planner + OSS decisions
- "btw closed period gate" → BACKLOG #190 brief + architect
- "shoot log scene grouped" → Wave 1L research + brainstorm + brief + planner
- "character sketch import" → Slot 1F.11a planner + spec

## Output

Top-K matches with:

- File path under `docs/research/`
- Chunk index (multiple high-score chunks → strong signal)
- Cosine similarity score (0–1; >0.6 = strong)
- 500-char snippet

The agent should:

1. Read the snippets to decide which full files are worth opening.
2. Open the top 1–3 files via Read.
3. Cite them at the top of the new brief / architect / planner doc
   under a `## Related prior work` heading.

## When to invoke

**Mandatory before drafting:**

- A new brief (when `brief-writer` is invoked)
- A new architect doc (when `architect` agent is invoked for a new wave)
- A new planner doc (when picking up a multi-slot wave)

**Optional but recommended:**

- When picking up an in-progress slot — surface what's already decided
- Before adding a new agent or rule — check if it's been discussed
- During code review on a new module — find prior architectural decisions

## Setup (one-time per machine)

```bash
# Get a free Gemini API key
open https://aistudio.google.com/apikey

# Export it (add to ~/.zshrc to persist)
export GEMINI_API_KEY=AIza...

# Install numpy if not present
.venv/bin/pip install numpy

# Build the index (first run ~3-4 min on the 70-doc 8CStudio corpus;
# incremental rebuilds skip unchanged files)
.venv/bin/python3 scripts/research_index.py rebuild

# Verify
.venv/bin/python3 scripts/research_index.py status
```

## Re-indexing

The index is sha256-incremental: re-running `rebuild` only re-embeds
files that changed. Run after every multi-doc research session.

A pre-commit hook can wire this automatically — see
`docs/process-engine/RAG.md` (8colors-process-engine v0.3).

## Index location

`docs/research/.research-index.sqlite` (gitignored). ~10 MB on the
8CStudio corpus.
