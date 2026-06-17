#!/usr/bin/env python3
"""
research_index.py — local semantic search over docs/research/*.

Indexes markdown files into a SQLite store with Gemini-computed
embeddings. Solves the "Workbox-miss class": when picking up a slot, an
agent (or human) can query the index to surface relevant prior briefs,
architect docs, planner artifacts, audits.

Origin: 2026-06-17 retrospective on the 2026-05-28 Wave 1M.3 miss where
the planner-only read at slot pickup missed the OSS contract locked in
the brief.

USAGE
-----
    # One-time setup (export the API key; free at aistudio.google.com/apikey)
    export GEMINI_API_KEY=AIza...

    # Build the index (incremental — re-runs only re-index changed files)
    python3 scripts/research_index.py rebuild

    # Query (top 8 results by default)
    python3 scripts/research_index.py query "workbox dexie offline sync"

    # Query with custom K and corpus path
    python3 scripts/research_index.py query "btw closed period" --top 5
    python3 scripts/research_index.py query "..." --corpus docs/

DESIGN
------
- Storage: SQLite at <corpus>/.research-index.sqlite (gitignored).
- Chunking: ~800 char windows + 120 char overlap, paragraph-boundary
  preferred. Each chunk gets its own embedding row.
- Embedding: Gemini text-embedding-004 (768 dims). Switchable provider
  scaffolded but only Gemini is wired (it's already in the project venv
  via google-generativeai).
- Similarity: cosine in numpy after L2 normalization. Fast enough for
  ≤100k chunks; sub-second on 8CStudio's ~1.5k chunks.
- Incremental rebuild: stores sha256 per file; skips files where the
  hash matches the last indexed value.

REQUIREMENTS
------------
- Python 3.10+
- google-generativeai (already in 8CStudio venv)
- numpy (lightweight install: pip install numpy)
- GEMINI_API_KEY env var
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
from pathlib import Path

# ─── chunking ────────────────────────────────────────────────────────────────

CHUNK_SIZE = 800
CHUNK_OVERLAP = 120
MIN_CHUNK = 100  # don't emit chunks smaller than this


def chunk_markdown(text: str) -> list[str]:
    """Paragraph-aware chunking with overlap.

    Splits on double-newline first, then greedy-packs paragraphs into
    CHUNK_SIZE windows. Adds CHUNK_OVERLAP chars of tail from the prior
    chunk to the next, preserving context across boundaries.
    """
    paras = re.split(r"\n\s*\n", text.strip())
    paras = [p.strip() for p in paras if p.strip()]
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
            # Carry the tail of the previous chunk into the next for context
            tail = current[-CHUNK_OVERLAP:] if len(current) > CHUNK_OVERLAP else current
            current = f"{tail}\n\n{para}" if tail else para
    if current and len(current) >= MIN_CHUNK:
        chunks.append(current)
    elif current and chunks:
        # Fold tiny trailing chunk into the previous
        chunks[-1] = f"{chunks[-1]}\n\n{current}"
    return chunks


# ─── embedding provider ──────────────────────────────────────────────────────


class GeminiEmbedder:
    """Wraps google-generativeai's embed_content. text-embedding-004 → 768 dims."""

    MODEL = "models/text-embedding-004"
    DIM = 768

    def __init__(self, api_key: str) -> None:
        try:
            import google.generativeai as genai  # noqa: F401
        except ImportError as exc:
            raise RuntimeError(
                "google-generativeai not installed. Run: pip install google-generativeai"
            ) from exc
        import google.generativeai as genai

        genai.configure(api_key=api_key)
        self._genai = genai

    def embed_doc(self, text: str) -> list[float]:
        """For indexing — task_type=RETRIEVAL_DOCUMENT."""
        result = self._genai.embed_content(
            model=self.MODEL,
            content=text,
            task_type="RETRIEVAL_DOCUMENT",
        )
        return result["embedding"]

    def embed_query(self, text: str) -> list[float]:
        """For query — task_type=RETRIEVAL_QUERY (asymmetric, better recall)."""
        result = self._genai.embed_content(
            model=self.MODEL,
            content=text,
            task_type="RETRIEVAL_QUERY",
        )
        return result["embedding"]


def get_embedder() -> GeminiEmbedder:
    api_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not api_key:
        print(
            "ERROR: GEMINI_API_KEY env var not set.\n"
            "       Get a free key at https://aistudio.google.com/apikey\n"
            "       Then: export GEMINI_API_KEY=AIza...",
            file=sys.stderr,
        )
        sys.exit(1)
    return GeminiEmbedder(api_key)


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


# ─── rebuild ─────────────────────────────────────────────────────────────────


def cmd_rebuild(corpus: Path, db_path: Path, force: bool) -> int:
    files = sorted(corpus.rglob("*.md"))
    if not files:
        print(f"No markdown files in {corpus}", file=sys.stderr)
        return 2

    print(f"Scanning {len(files)} markdown files in {corpus}…")
    conn = open_db(db_path)
    embedder = get_embedder()

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

        # Embed each chunk. Gemini's per-call latency is ~80-150ms.
        # For 70 docs * ~20 chunks = ~1400 calls = ~3-4 minutes on a cold rebuild.
        # Incremental rebuilds skip unchanged files so day-to-day cost is much lower.
        for idx, chunk_text in enumerate(chunks):
            try:
                vec = embedder.embed_doc(chunk_text)
            except Exception as exc:
                print(f"  ⚠ embed failed on {rel} chunk {idx}: {exc}", file=sys.stderr)
                continue
            conn.execute(
                "INSERT INTO chunks (doc_id, chunk_idx, text, embedding) VALUES (?, ?, ?, ?)",
                (doc_id, idx, chunk_text, pack_embedding(vec)),
            )
            chunks_total += 1

        conn.commit()
        action = "updated" if row else "new    "
        print(f"  {action} {rel}  ({len(chunks)} chunks)")

    conn.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
        ("last_rebuild", time.strftime("%Y-%m-%dT%H:%M:%S%z")),
    )
    conn.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
        ("embedding_model", GeminiEmbedder.MODEL),
    )
    conn.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
        ("embedding_dim", str(GeminiEmbedder.DIM)),
    )
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


def cmd_query(db_path: Path, query: str, top_k: int, snippet_chars: int) -> int:
    if not db_path.exists():
        print(
            f"ERROR: index not found at {db_path}. Run 'rebuild' first.",
            file=sys.stderr,
        )
        return 2

    try:
        import numpy as np
    except ImportError:
        print(
            "ERROR: numpy not installed. Run: pip install numpy",
            file=sys.stderr,
        )
        return 2

    conn = open_db(db_path)
    embedder = get_embedder()

    qvec = np.array(embedder.embed_query(query), dtype=np.float32)
    qvec /= np.linalg.norm(qvec) + 1e-12

    rows = conn.execute(
        "SELECT chunks.id, docs.path, chunks.chunk_idx, chunks.text, chunks.embedding "
        "FROM chunks JOIN docs ON docs.id = chunks.doc_id"
    ).fetchall()

    if not rows:
        print("ERROR: index is empty. Run 'rebuild' first.", file=sys.stderr)
        return 2

    embs = np.array(
        [unpack_embedding(r[4]) for r in rows], dtype=np.float32
    )
    # Normalize once; then dot-product = cosine similarity.
    norms = np.linalg.norm(embs, axis=1, keepdims=True) + 1e-12
    embs_n = embs / norms
    sims = embs_n @ qvec

    # Top-K
    top_idx = np.argsort(-sims)[:top_k]

    print(f"# Top {len(top_idx)} matches for: {query!r}\n")
    seen_docs: set[str] = set()
    for rank, i in enumerate(top_idx, 1):
        chunk_id, path, chunk_idx, text, _ = rows[i]
        score = float(sims[i])
        # Dedupe: skip if we've already shown 2 chunks from the same doc
        # (top-3 already gives a strong signal that the doc is relevant).
        dedupe_key = f"{path}:{chunk_idx // 3}"
        if dedupe_key in seen_docs:
            continue
        seen_docs.add(dedupe_key)
        snippet = text[:snippet_chars].rstrip()
        if len(text) > snippet_chars:
            snippet += "…"
        print(f"## [{rank}] `{path}` (chunk {chunk_idx}, score {score:.3f})\n")
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
    print(f"  model:    {meta.get('embedding_model', '?')}")
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
        Path(args.index)
        if args.index
        else corpus / ".research-index.sqlite"
    )

    if args.cmd == "rebuild":
        if not corpus.exists():
            print(f"ERROR: corpus {corpus} does not exist", file=sys.stderr)
            return 1
        return cmd_rebuild(corpus, db_path, args.force)
    if args.cmd == "query":
        return cmd_query(db_path, args.query, args.top, args.snippet)
    if args.cmd == "status":
        return cmd_status(db_path)
    return 1


if __name__ == "__main__":
    sys.exit(main())
