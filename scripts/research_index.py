#!/usr/bin/env python3
"""
research_index.py — local semantic search over docs/research/*.

Indexes markdown files into a SQLite store. Solves the "Workbox-miss
class": when picking up a slot, an agent (or human) can query the index
to surface relevant prior briefs, architect docs, planner artifacts,
audits.

v0.5: multi-provider embeddings.

  Provider     Cost            Quality   Setup
  -----------  --------------  --------  -------------------------------
  fastembed    free, local     good      pip install fastembed
  voyage       free tier + paid better    pip install voyage + key
  gemini       free tier + paid good      pip install google-generativeai + key
  openai       paid (cheap)    good      pip install openai + key

  Default: fastembed (no API key needed; the project should "just work"
  after pip install).

USAGE
-----
    # Default — uses fastembed locally, no API key required
    pip install fastembed numpy
    python3 scripts/research_index.py rebuild
    python3 scripts/research_index.py query "workbox dexie offline"

    # Override provider via CLI
    python3 scripts/research_index.py --provider voyage rebuild

    # Or via .process-engine.yaml in project root:
    # rag:
    #   provider: voyage     # fastembed | voyage | gemini | openai
    #   model:    voyage-3   # optional, defaults per provider

DESIGN
------
- Storage: SQLite at <corpus>/.research-index.sqlite (gitignored).
- Chunking: ~800 char windows + 120 char overlap, paragraph-boundary
  preferred. Each chunk gets its own embedding row.
- Provider abstraction: see Embedder ABC + 4 concrete classes.
- Provider resolution (in order):
    1. --provider CLI flag
    2. .process-engine.yaml rag.provider
    3. Env detection (any of VOYAGE_API_KEY / GEMINI_API_KEY / OPENAI_API_KEY set)
    4. fastembed default
- Dim-mismatch detection: if the stored embedding_dim doesn't match the
  current provider's dim, rebuild is forced (would otherwise produce
  garbage scores from incompatible vectors).
- Similarity: cosine in numpy after L2 normalization. Fast enough for
  ≤100k chunks; sub-second on 8CStudio's ~1.5k chunks.
- Incremental rebuild: stores sha256 per file; skips files where the
  hash matches the last indexed value.

REQUIREMENTS
------------
- Python 3.10+
- numpy (`pip install numpy`)
- One embedding provider (default fastembed; install with
  `pip install fastembed`)
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sqlite3
import struct
import sys
import time
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Optional

# ─── chunking ────────────────────────────────────────────────────────────────

CHUNK_SIZE = 800
CHUNK_OVERLAP = 120
MIN_CHUNK = 100

# P2.11: BGE-small (fastembed default) truncates at ~512 tokens ≈
# 2000 chars. Long code blocks or wall-of-text paragraphs above this
# would be silently truncated, dropping the tail from the embedding.
# Split oversized paragraphs before chunking so every produced chunk
# fits within CHUNK_SIZE.
MAX_PARA_CHARS = CHUNK_SIZE


def _split_oversized_para(para: str, max_chars: int) -> list[str]:
    """Split a single oversized paragraph into ≤ max_chars slices at
    the nearest sentence / newline / word boundary (P2.11)."""
    out: list[str] = []
    remaining = para
    while len(remaining) > max_chars:
        # Prefer boundaries in this order: sentence, newline, space.
        window = remaining[:max_chars]
        cut = max(
            window.rfind(". "),
            window.rfind("\n"),
            window.rfind(" "),
        )
        if cut <= max_chars // 2:
            cut = max_chars  # hard split — para has no boundaries
        out.append(remaining[:cut].rstrip())
        remaining = remaining[cut:].lstrip()
    if remaining:
        out.append(remaining)
    return out


def chunk_markdown(text: str) -> list[str]:
    """Paragraph-aware chunking with overlap.

    P2.11: pre-splits paragraphs larger than MAX_PARA_CHARS so
    long code blocks aren't silently truncated by the embedder.
    """
    raw_paras = re.split(r"\n\s*\n", text.strip())
    paras: list[str] = []
    for p in raw_paras:
        p = p.strip()
        if not p:
            continue
        if len(p) > MAX_PARA_CHARS:
            paras.extend(_split_oversized_para(p, MAX_PARA_CHARS))
        else:
            paras.append(p)
    if not paras:
        return []

    chunks: list[str] = []
    current = ""
    for para in paras:
        if not current:
            current = para
        elif len(current) + len(para) + 2 <= CHUNK_SIZE:
            current = f"{current}\n\n{para}"
        else:
            chunks.append(current)
            tail = current[-CHUNK_OVERLAP:] if len(current) > CHUNK_OVERLAP else current
            current = f"{tail}\n\n{para}" if tail else para
    if current and len(current) >= MIN_CHUNK:
        chunks.append(current)
    elif current and chunks:
        chunks[-1] = f"{chunks[-1]}\n\n{current}"
    return chunks


# ─── embedder ABC + concrete providers ──────────────────────────────────────


class Embedder(ABC):
    """Provider-agnostic embedding interface."""

    NAME: str = "abstract"
    MODEL: str = "abstract"
    DIM: int = 0

    @abstractmethod
    def embed_doc(self, text: str) -> list[float]:
        """Embed a document chunk (for indexing)."""

    @abstractmethod
    def embed_query(self, text: str) -> list[float]:
        """Embed a query string. Providers with asymmetric task_types use them here."""

    def embed_docs_batch(self, texts: list[str]) -> list[list[float]]:
        """Default batching: loop over embed_doc. Providers can
        override with a real batch API (see FastEmbedEmbedder)."""
        return [self.embed_doc(t) for t in texts]


class FastEmbedEmbedder(Embedder):
    """Fully local. Default. No API key required.

    Uses BAAI/bge-small-en-v1.5 by default (384 dims, ~33 MB model).
    First call downloads the model to ~/.cache/fastembed/.
    """

    NAME = "fastembed"
    MODEL = "BAAI/bge-small-en-v1.5"
    DIM = 384

    def __init__(self, model: Optional[str] = None) -> None:
        # P2.11: catch both ImportError AND TypeError. Protobuf under
        # Python 3.14 raises TypeError from within fastembed's transit
        # deps ("Descriptors cannot not be created directly …") — the
        # old handler let that traceback through raw. The documented
        # incident under Python 3.14 was invisible from the user's POV.
        try:
            from fastembed import TextEmbedding
        except (ImportError, TypeError) as exc:
            raise RuntimeError(
                "fastembed not installed OR incompatible with this Python.\n"
                f"  Root cause: {type(exc).__name__}: {exc}\n"
                "  Fix: pip install --upgrade fastembed protobuf, or run\n"
                "       against a Python version where fastembed builds\n"
                "       cleanly (3.11–3.13 known-good as of 2026-07).\n"
                "  (fastembed adds ~150 MB of ONNX runtime + downloads a\n"
                "  ~33 MB model on first use to ~/.cache/fastembed/.)"
            ) from exc

        self.MODEL = model or self.MODEL
        self._embedding_model = TextEmbedding(model_name=self.MODEL)

    def _embed(self, text: str) -> list[float]:
        # fastembed yields a generator; take the first (only) result.
        vecs = list(self._embedding_model.embed([text]))
        return vecs[0].tolist()

    def embed_doc(self, text: str) -> list[float]:
        return self._embed(text)

    def embed_query(self, text: str) -> list[float]:
        # BGE benefits from a "query:" prefix on retrieval queries.
        return self._embed(f"query: {text}")

    def embed_docs_batch(self, texts: list[str]) -> list[list[float]]:
        """P2.11: batch embedding for the rebuild loop. Single-text
        `embed()` calls in a loop create per-chunk overhead that
        dominates rebuild time on large corpora."""
        if not texts:
            return []
        vecs = list(self._embedding_model.embed(texts))
        return [v.tolist() for v in vecs]


class GeminiEmbedder(Embedder):
    """Google Gemini text-embedding-004 (768 dims). Free tier covers RAG."""

    NAME = "gemini"
    MODEL = "models/text-embedding-004"
    DIM = 768

    def __init__(self, model: Optional[str] = None) -> None:
        api_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
        if not api_key:
            raise RuntimeError(
                "GEMINI_API_KEY not set. Get a free key at "
                "https://aistudio.google.com/apikey then "
                "`export GEMINI_API_KEY=AIza...`."
            )

        try:
            import google.generativeai as genai
        except ImportError as exc:
            raise RuntimeError(
                "google-generativeai not installed. "
                "Run: pip install google-generativeai"
            ) from exc

        self.MODEL = model or self.MODEL
        genai.configure(api_key=api_key)
        self._genai = genai

    def embed_doc(self, text: str) -> list[float]:
        result = self._genai.embed_content(
            model=self.MODEL,
            content=text,
            task_type="RETRIEVAL_DOCUMENT",
        )
        return result["embedding"]

    def embed_query(self, text: str) -> list[float]:
        result = self._genai.embed_content(
            model=self.MODEL,
            content=text,
            task_type="RETRIEVAL_QUERY",
        )
        return result["embedding"]


class VoyageEmbedder(Embedder):
    """Voyage AI voyage-3 (1024 dims). Anthropic-recommended partner."""

    NAME = "voyage"
    MODEL = "voyage-3"
    DIM = 1024

    def __init__(self, model: Optional[str] = None) -> None:
        api_key = os.environ.get("VOYAGE_API_KEY")
        if not api_key:
            raise RuntimeError(
                "VOYAGE_API_KEY not set. Sign up at https://www.voyageai.com/ "
                "(free credit available) then `export VOYAGE_API_KEY=...`."
            )

        try:
            import voyageai
        except ImportError as exc:
            raise RuntimeError(
                "voyageai not installed. Run: pip install voyageai"
            ) from exc

        self.MODEL = model or self.MODEL
        self._client = voyageai.Client(api_key=api_key)

    def embed_doc(self, text: str) -> list[float]:
        result = self._client.embed(
            [text], model=self.MODEL, input_type="document"
        )
        return result.embeddings[0]

    def embed_query(self, text: str) -> list[float]:
        result = self._client.embed(
            [text], model=self.MODEL, input_type="query"
        )
        return result.embeddings[0]


class OpenAIEmbedder(Embedder):
    """OpenAI text-embedding-3-small (1536 dims). Paid but cheap."""

    NAME = "openai"
    MODEL = "text-embedding-3-small"
    DIM = 1536

    def __init__(self, model: Optional[str] = None) -> None:
        api_key = os.environ.get("OPENAI_API_KEY")
        if not api_key:
            raise RuntimeError(
                "OPENAI_API_KEY not set. Get one at https://platform.openai.com/ "
                "then `export OPENAI_API_KEY=sk-...`."
            )

        try:
            from openai import OpenAI
        except ImportError as exc:
            raise RuntimeError(
                "openai not installed. Run: pip install openai"
            ) from exc

        self.MODEL = model or self.MODEL
        self._client = OpenAI(api_key=api_key)

    def _embed(self, text: str) -> list[float]:
        # OpenAI's embedding API has no document/query asymmetry.
        result = self._client.embeddings.create(model=self.MODEL, input=text)
        return result.data[0].embedding

    def embed_doc(self, text: str) -> list[float]:
        return self._embed(text)

    def embed_query(self, text: str) -> list[float]:
        return self._embed(text)


PROVIDERS = {
    "fastembed": FastEmbedEmbedder,
    "gemini": GeminiEmbedder,
    "voyage": VoyageEmbedder,
    "openai": OpenAIEmbedder,
}


# ─── provider resolution ────────────────────────────────────────────────────


def read_yaml_field(path: Path, *keys: str) -> Optional[str]:
    """Minimal YAML reader — scalar values under nested keys only.

    P2.11: previously would descend into sibling top-level blocks when
    the expected child was missing. Concretely, for keys=("rag",
    "provider") against:

        some_block:
          provider: A       # wrong parent, but same indent
        rag:
          model: bge-small  # no `provider:` here

    the old walker would happily match `some_block.provider` because
    it kept scanning past `some_block:` without noticing it exited the
    parent scope. Fix: bail out when a subsequent line's indent is
    < the target indent (means we've left the parent block).
    """
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    indent = 0
    i = 0
    for depth, part in enumerate(keys):
        found = False
        while i < len(lines):
            line = lines[i]
            # Skip blank / comment-only lines cheaply.
            if not line.strip() or line.lstrip().startswith("#"):
                i += 1
                continue
            stripped = line.lstrip(" ")
            line_indent = len(line) - len(stripped)

            # If we've gone SHALLOWER than the target indent while
            # searching for a child, the parent block ended — the
            # child key doesn't exist.
            if depth > 0 and line_indent < indent:
                return None

            if line_indent == indent and stripped.startswith(part + ":"):
                rest = stripped[len(part) + 1 :].strip().strip('"').strip("'")
                if rest and part == keys[-1]:
                    return rest
                indent += 2
                i += 1
                found = True
                break
            i += 1
        if not found:
            return None
    return None


def detect_provider_from_env() -> Optional[str]:
    """Return the first provider whose API key env-var is set."""
    if os.environ.get("VOYAGE_API_KEY"):
        return "voyage"
    if os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY"):
        return "gemini"
    if os.environ.get("OPENAI_API_KEY"):
        return "openai"
    return None


def resolve_provider(
    cli_provider: Optional[str], project_root: Path
) -> tuple[str, Optional[str]]:
    """Return (provider_name, model_name_or_None).

    Resolution order:
        1. --provider CLI flag
        2. .process-engine.yaml rag.provider
        3. Env detection (VOYAGE/GEMINI/OPENAI key set)
        4. fastembed default
    """
    if cli_provider:
        if cli_provider not in PROVIDERS:
            raise SystemExit(
                f"ERROR: unknown provider {cli_provider!r}. "
                f"Options: {', '.join(PROVIDERS)}"
            )
        return cli_provider, None

    config = project_root / ".process-engine.yaml"
    yaml_provider = read_yaml_field(config, "rag", "provider")
    yaml_model = read_yaml_field(config, "rag", "model")
    if yaml_provider:
        if yaml_provider not in PROVIDERS:
            raise SystemExit(
                f"ERROR: unknown rag.provider {yaml_provider!r} in "
                f"{config}. Options: {', '.join(PROVIDERS)}"
            )
        return yaml_provider, yaml_model

    env_provider = detect_provider_from_env()
    if env_provider:
        return env_provider, None

    return "fastembed", None


def make_embedder(name: str, model: Optional[str]) -> Embedder:
    cls = PROVIDERS[name]
    return cls(model=model)


# ─── storage ─────────────────────────────────────────────────────────────────


SCHEMA = """
CREATE TABLE IF NOT EXISTS docs (
    id INTEGER PRIMARY KEY,
    path TEXT UNIQUE NOT NULL,
    mtime REAL NOT NULL,
    sha256 TEXT NOT NULL,
    indexed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY,
    doc_id INTEGER NOT NULL REFERENCES docs(id) ON DELETE CASCADE,
    chunk_idx INTEGER NOT NULL,
    text TEXT NOT NULL,
    embedding BLOB NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(doc_id);

CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


def open_db(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    return conn


def pack_embedding(vec: list[float]) -> bytes:
    return struct.pack(f"{len(vec)}f", *vec)


def unpack_embedding(blob: bytes) -> list[float]:
    n = len(blob) // 4
    return list(struct.unpack(f"{n}f", blob))


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def get_meta(conn: sqlite3.Connection, key: str) -> Optional[str]:
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row[0] if row else None


def set_meta(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, value)
    )


# ─── rebuild ─────────────────────────────────────────────────────────────────


def cmd_rebuild(
    corpus: Path,
    db_path: Path,
    embedder: Embedder,
    force: bool,
) -> int:
    files = sorted(corpus.rglob("*.md"))
    if not files:
        print(f"No markdown files in {corpus}", file=sys.stderr)
        return 2

    print(
        f"Scanning {len(files)} markdown files in {corpus} "
        f"using {embedder.NAME}/{embedder.MODEL} ({embedder.DIM}d)…"
    )
    conn = open_db(db_path)

    # Force-rebuild if the embedding model / dim changed since last index
    prev_model = get_meta(conn, "embedding_model")
    prev_dim = get_meta(conn, "embedding_dim")
    dim_mismatch = prev_dim is not None and int(prev_dim) != embedder.DIM
    model_mismatch = prev_model is not None and prev_model != embedder.MODEL

    if (dim_mismatch or model_mismatch) and not force:
        print(
            f"  ⚠ Embedding model changed since last rebuild "
            f"({prev_model} {prev_dim}d → {embedder.MODEL} {embedder.DIM}d). "
            f"Forcing full re-embed.",
            file=sys.stderr,
        )
        force = True

    if force:
        conn.execute("DELETE FROM chunks")
        conn.execute("DELETE FROM docs")
        conn.commit()

    new_count = updated_count = skipped_count = 0
    chunks_total = 0
    t0 = time.time()

    for fp in files:
        rel = str(fp.relative_to(corpus))
        sha = sha256_file(fp)
        mtime = fp.stat().st_mtime

        row = conn.execute(
            "SELECT id, sha256 FROM docs WHERE path = ?", (rel,)
        ).fetchone()

        if row and row[1] == sha and not force:
            skipped_count += 1
            continue

        text = fp.read_text(encoding="utf-8", errors="replace")
        chunks = chunk_markdown(text)
        if not chunks:
            skipped_count += 1
            continue

        # P2.11: embed FIRST, then decide whether to record the doc.
        # The previous flow inserted the doc row, then embedded — if
        # every chunk failed (rate limit, dead network, provider bug),
        # a stale/empty doc row was left with the correct sha256, and
        # every subsequent rebuild would SKIP it (sha match), leaving
        # a permanent hole in the index. Now: nothing gets inserted
        # unless at least one chunk embedded successfully.
        successful: list[tuple[int, str, list[float]]] = []
        try:
            vecs = embedder.embed_docs_batch(chunks)
            if len(vecs) != len(chunks):
                raise RuntimeError(
                    f"embedder returned {len(vecs)} vectors for "
                    f"{len(chunks)} chunks — refusing partial index"
                )
            successful = list(zip(range(len(chunks)), chunks, vecs))
        except Exception as exc:
            # Fall back to per-chunk with fault isolation.
            print(
                f"  ⚠ batch embed failed on {rel} ({exc}); "
                "falling back to per-chunk",
                file=sys.stderr,
            )
            for idx, chunk_text in enumerate(chunks):
                try:
                    vec = embedder.embed_doc(chunk_text)
                    successful.append((idx, chunk_text, vec))
                except Exception as sub_exc:
                    print(
                        f"    ⚠ embed failed on {rel} chunk {idx}: {sub_exc}",
                        file=sys.stderr,
                    )

        if not successful:
            print(
                f"  ✗ SKIPPING {rel} — every chunk failed to embed "
                "(no doc row inserted; run again after fixing the embedder)",
                file=sys.stderr,
            )
            skipped_count += 1
            continue

        if row:
            doc_id = row[0]
            conn.execute("DELETE FROM chunks WHERE doc_id = ?", (doc_id,))
            conn.execute(
                "UPDATE docs SET mtime = ?, sha256 = ?, indexed_at = ? WHERE id = ?",
                (mtime, sha, time.strftime("%Y-%m-%dT%H:%M:%S"), doc_id),
            )
            updated_count += 1
        else:
            cur = conn.execute(
                "INSERT INTO docs (path, mtime, sha256, indexed_at) VALUES (?, ?, ?, ?)",
                (rel, mtime, sha, time.strftime("%Y-%m-%dT%H:%M:%S")),
            )
            doc_id = cur.lastrowid
            new_count += 1

        for idx, chunk_text, vec in successful:
            conn.execute(
                "INSERT INTO chunks (doc_id, chunk_idx, text, embedding) VALUES (?, ?, ?, ?)",
                (doc_id, idx, chunk_text, pack_embedding(vec)),
            )
            chunks_total += 1

        conn.commit()
        action = "updated" if row else "new    "
        print(f"  {action} {rel}  ({len(successful)}/{len(chunks)} chunks)")

    set_meta(conn, "last_rebuild", time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    set_meta(conn, "embedding_provider", embedder.NAME)
    set_meta(conn, "embedding_model", embedder.MODEL)
    set_meta(conn, "embedding_dim", str(embedder.DIM))
    conn.commit()
    conn.close()

    elapsed = time.time() - t0
    print(
        f"\n✓ Done in {elapsed:.1f}s — "
        f"{new_count} new, {updated_count} updated, {skipped_count} skipped, "
        f"{chunks_total} chunks embedded this run."
    )
    print(f"  Index: {db_path}")
    return 0


# ─── query ───────────────────────────────────────────────────────────────────


def cmd_query(
    db_path: Path,
    embedder: Embedder,
    query: str,
    top_k: int,
    snippet_chars: int,
) -> int:
    if not db_path.exists():
        print(
            f"ERROR: index not found at {db_path}. Run 'rebuild' first.",
            file=sys.stderr,
        )
        return 2

    try:
        import numpy as np
    except ImportError:
        print("ERROR: numpy not installed. Run: pip install numpy", file=sys.stderr)
        return 2

    conn = open_db(db_path)

    # Verify the current embedder matches the indexed one.
    # P2.11: previously only checked dim. Two different models with
    # the same dim (e.g. two 768d providers) would silently mix
    # embedding spaces — queries would return junk with no error.
    # Now: dim AND model must match.
    stored_dim = get_meta(conn, "embedding_dim")
    stored_model = get_meta(conn, "embedding_model")
    if stored_dim and int(stored_dim) != embedder.DIM:
        print(
            f"ERROR: query embedder dim ({embedder.DIM}) doesn't match "
            f"indexed dim ({stored_dim}). The index was built with "
            f"{stored_model}. Either:\n"
            f"  - Use the same provider as the index, or\n"
            f"  - Run 'rebuild --force' to re-embed with the new provider.",
            file=sys.stderr,
        )
        return 2
    if stored_model and stored_model != embedder.MODEL:
        print(
            f"ERROR: query embedder model ({embedder.MODEL}) doesn't match "
            f"indexed model ({stored_model}) — same dim, different space.\n"
            f"  - Use the same model as the index, or\n"
            f"  - Run 'rebuild --force' to re-embed with the new model.",
            file=sys.stderr,
        )
        return 2

    qvec = np.array(embedder.embed_query(query), dtype=np.float32)
    qvec /= np.linalg.norm(qvec) + 1e-12

    rows = conn.execute(
        "SELECT chunks.id, docs.path, chunks.chunk_idx, chunks.text, chunks.embedding "
        "FROM chunks JOIN docs ON docs.id = chunks.doc_id"
    ).fetchall()

    if not rows:
        print("ERROR: index is empty. Run 'rebuild' first.", file=sys.stderr)
        return 2

    embs = np.array([unpack_embedding(r[4]) for r in rows], dtype=np.float32)
    norms = np.linalg.norm(embs, axis=1, keepdims=True) + 1e-12
    embs_n = embs / norms
    sims = embs_n @ qvec

    # P2.11: dedupe BEFORE trimming to top_k. Previously took top_k
    # by similarity and then deduped, which meant "top 5 all from
    # doc X" collapsed to a single visible result. Now: sort all,
    # walk in order collecting distinct dedupe_keys, stop at top_k.
    sorted_idx = np.argsort(-sims)

    print(f"# Top matches for: {query!r}")
    print(f"# (provider: {embedder.NAME}, model: {embedder.MODEL}, dim: {embedder.DIM})\n")
    seen_docs: set[str] = set()
    shown = 0
    for i in sorted_idx:
        if shown >= top_k:
            break
        chunk_id, path, chunk_idx, text, _ = rows[i]
        dedupe_key = f"{path}:{chunk_idx // 3}"
        if dedupe_key in seen_docs:
            continue
        seen_docs.add(dedupe_key)
        shown += 1
        score = float(sims[i])
        snippet = text[:snippet_chars].rstrip()
        if len(text) > snippet_chars:
            snippet += "…"
        print(f"## [{shown}] `{path}` (chunk {chunk_idx}, score {score:.3f})\n")
        print(snippet)
        print()

    conn.close()
    return 0


# ─── status ──────────────────────────────────────────────────────────────────


def cmd_status(db_path: Path) -> int:
    if not db_path.exists():
        print(f"Index not found at {db_path}")
        return 0
    conn = open_db(db_path)
    n_docs = conn.execute("SELECT COUNT(*) FROM docs").fetchone()[0]
    n_chunks = conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    meta = dict(conn.execute("SELECT key, value FROM meta").fetchall())
    print(f"Index: {db_path}")
    print(f"  docs:     {n_docs}")
    print(f"  chunks:   {n_chunks}")
    print(f"  provider: {meta.get('embedding_provider', '?')}")
    print(f"  model:    {meta.get('embedding_model', '?')}")
    print(f"  dim:      {meta.get('embedding_dim', '?')}")
    print(f"  rebuilt:  {meta.get('last_rebuild', '?')}")
    conn.close()
    return 0


# ─── cli ─────────────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Local semantic search over docs/research/.",
    )
    parser.add_argument(
        "--corpus",
        default="docs/research",
        help="Directory to index (default: docs/research)",
    )
    parser.add_argument(
        "--index",
        default=None,
        help="SQLite path (default: <corpus>/.research-index.sqlite)",
    )
    parser.add_argument(
        "--provider",
        choices=sorted(PROVIDERS),
        default=None,
        help="Override the embedding provider (default: from .process-engine.yaml "
        "or env detection or fastembed)",
    )
    parser.add_argument(
        "--model",
        default=None,
        help="Override the embedding model name (provider-specific default if unset)",
    )
    parser.add_argument(
        "--project-root",
        default=".",
        help="Project root for reading .process-engine.yaml (default: cwd)",
    )

    sub = parser.add_subparsers(dest="cmd", required=True)

    p_rebuild = sub.add_parser("rebuild", help="Build / refresh the index")
    p_rebuild.add_argument(
        "--force", action="store_true", help="Re-embed all docs, ignore sha cache"
    )

    p_query = sub.add_parser("query", help="Semantic search")
    p_query.add_argument("query", help="Search query")
    p_query.add_argument("--top", type=int, default=8, help="Top-K results (default 8)")
    p_query.add_argument(
        "--snippet", type=int, default=500, help="Snippet length in chars (default 500)"
    )

    sub.add_parser("status", help="Show index stats")

    args = parser.parse_args()

    corpus = Path(args.corpus)
    db_path = (
        Path(args.index) if args.index else corpus / ".research-index.sqlite"
    )
    project_root = Path(args.project_root)

    if args.cmd == "status":
        return cmd_status(db_path)

    if args.cmd == "rebuild" and not corpus.exists():
        print(f"ERROR: corpus {corpus} does not exist", file=sys.stderr)
        return 1

    # Provider resolution: CLI → yaml → env → fastembed default
    provider_name, yaml_model = resolve_provider(args.provider, project_root)
    model = args.model or yaml_model
    try:
        embedder = make_embedder(provider_name, model)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if args.cmd == "rebuild":
        return cmd_rebuild(corpus, db_path, embedder, args.force)
    if args.cmd == "query":
        return cmd_query(db_path, embedder, args.query, args.top, args.snippet)
    return 1


if __name__ == "__main__":
    sys.exit(main())
