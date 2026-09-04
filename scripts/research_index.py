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

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

# Re-exported: `research_index.chunk_markdown` and friends are how the
# tests and docs address these, and the split is meant to be invisible.
from research_embed import (  # noqa: E402,F401
    CHUNK_OVERLAP,
    CHUNK_SIZE,
    Embedder,
    FastEmbedEmbedder,
    GeminiEmbedder,
    OpenAIEmbedder,
    PROVIDERS,
    VoyageEmbedder,
    chunk_markdown,
    detect_provider_from_env,
    make_embedder,
    read_yaml_field,
    resolve_provider,
)


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

-- A7 FTS5 sparse index. Pairs with the dense embedding table for
-- reciprocal-rank-fusion hybrid retrieval. Dense misses exact-token
-- queries (slot IDs like "1M.3", SHAs like "b6c566e", error strings
-- like "IntegrityError") — FTS5 catches those on the sparse side.
-- Populated at rebuild time; falls back to dense-only on old indexes
-- that were built before FTS5 was added.
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    text,
    content='chunks',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
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


def _force_on_model_change(conn, embedder: Embedder, force: bool) -> bool:
    """A changed embedding model invalidates every stored vector."""
    prev_model = get_meta(conn, "embedding_model")
    prev_dim = get_meta(conn, "embedding_dim")
    changed = (prev_dim is not None and int(prev_dim) != embedder.DIM) or (
        prev_model is not None and prev_model != embedder.MODEL
    )
    if changed and not force:
        print(
            f"  ⚠ Embedding model changed since last rebuild "
            f"({prev_model} {prev_dim}d → {embedder.MODEL} {embedder.DIM}d). "
            "Forcing full re-embed.",
            file=sys.stderr,
        )
        return True
    return force


def _embed_chunks(
    embedder: Embedder, chunks: list[str], rel: str,
) -> list[tuple[int, str, list[float]]]:
    """Embed a document's chunks, batch first, per-chunk on failure.

    Returns only what succeeded, so the caller can decline to write a doc
    row when nothing did.
    """
    try:
        vecs = embedder.embed_docs_batch(chunks)
        if len(vecs) != len(chunks):
            raise RuntimeError(
                f"embedder returned {len(vecs)} vectors for {len(chunks)} "
                "chunks — refusing partial index"
            )
        return list(zip(range(len(chunks)), chunks, vecs))
    except Exception as exc:
        print(
            f"  ⚠ batch embed failed on {rel} ({exc}); falling back to per-chunk",
            file=sys.stderr,
        )
    out: list[tuple[int, str, list[float]]] = []
    for idx, chunk_text in enumerate(chunks):
        try:
            out.append((idx, chunk_text, embedder.embed_doc(chunk_text)))
        except Exception as sub_exc:
            print(
                f"    ⚠ embed failed on {rel} chunk {idx}: {sub_exc}",
                file=sys.stderr,
            )
    return out


def _upsert_doc(conn, row, rel: str, mtime: float, sha: str) -> int:
    """Insert or refresh the doc row, clearing its old chunks. Returns doc_id."""
    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    if not row:
        cur = conn.execute(
            "INSERT INTO docs (path, mtime, sha256, indexed_at) VALUES (?, ?, ?, ?)",
            (rel, mtime, sha, now),
        )
        return cur.lastrowid
    doc_id = row[0]
    # External-content FTS5 does not cascade on DELETE, so the sparse rows
    # keyed by the chunks about to be deleted have to go explicitly —
    # otherwise a rebuilt doc keeps stale rows pointing at vanished rowids.
    conn.execute(
        "DELETE FROM chunks_fts WHERE rowid IN "
        "(SELECT id FROM chunks WHERE doc_id = ?)",
        (doc_id,),
    )
    conn.execute("DELETE FROM chunks WHERE doc_id = ?", (doc_id,))
    conn.execute(
        "UPDATE docs SET mtime = ?, sha256 = ?, indexed_at = ? WHERE id = ?",
        (mtime, sha, now, doc_id),
    )
    return doc_id


def _write_chunks(conn, doc_id: int, successful) -> int:
    for idx, chunk_text, vec in successful:
        cur = conn.execute(
            "INSERT INTO chunks (doc_id, chunk_idx, text, embedding) "
            "VALUES (?, ?, ?, ?)",
            (doc_id, idx, chunk_text, pack_embedding(vec)),
        )
        # Mirror into FTS5. content='chunks' + content_rowid='id' means the
        # FTS table does not own the text; it points at chunks.id. Written
        # here so the sparse index is populated alongside the dense one.
        conn.execute(
            "INSERT INTO chunks_fts (rowid, text) VALUES (?, ?)",
            (cur.lastrowid, chunk_text),
        )
    return len(successful)


def _index_one_file(conn, fp: Path, corpus: Path, embedder: Embedder, force: bool):
    """Index one file. Returns (outcome, chunks_written).

    outcome is "new", "updated" or "skipped".

    Embedding happens BEFORE the doc row is written. The other order left a
    doc row with the correct sha256 when every chunk failed (rate limit,
    dead network, provider bug), so every later rebuild SKIPPED it on the
    sha match — a permanent hole in the index that looked like a cache hit.
    """
    rel = str(fp.relative_to(corpus))
    sha = sha256_file(fp)
    row = conn.execute(
        "SELECT id, sha256 FROM docs WHERE path = ?", (rel,)
    ).fetchone()
    if row and row[1] == sha and not force:
        return "skipped", 0

    chunks = chunk_markdown(fp.read_text(encoding="utf-8", errors="replace"))
    if not chunks:
        return "skipped", 0

    successful = _embed_chunks(embedder, chunks, rel)
    if not successful:
        print(
            f"  ✗ SKIPPING {rel} — every chunk failed to embed (no doc row "
            "inserted; run again after fixing the embedder)",
            file=sys.stderr,
        )
        return "skipped", 0

    doc_id = _upsert_doc(conn, row, rel, fp.stat().st_mtime, sha)
    written = _write_chunks(conn, doc_id, successful)
    conn.commit()
    outcome = "updated" if row else "new"
    print(f"  {outcome:<7} {rel}  ({len(successful)}/{len(chunks)} chunks)")
    return outcome, written


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
    force = _force_on_model_change(conn, embedder, force)
    if force:
        conn.execute("DELETE FROM chunks")
        conn.execute("DELETE FROM docs")
        conn.commit()

    counts = {"new": 0, "updated": 0, "skipped": 0}
    chunks_total = 0
    t0 = time.time()
    for fp in files:
        outcome, written = _index_one_file(conn, fp, corpus, embedder, force)
        counts[outcome] += 1
        chunks_total += written

    set_meta(conn, "last_rebuild", time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    set_meta(conn, "embedding_provider", embedder.NAME)
    set_meta(conn, "embedding_model", embedder.MODEL)
    set_meta(conn, "embedding_dim", str(embedder.DIM))
    conn.commit()
    conn.close()

    print(
        f"\n✓ Done in {time.time() - t0:.1f}s — {counts['new']} new, "
        f"{counts['updated']} updated, {counts['skipped']} skipped, "
        f"{chunks_total} chunks embedded this run."
    )
    print(f"  Index: {db_path}")
    return 0


# ─── query ───────────────────────────────────────────────────────────────────


def _fts5_query(conn: sqlite3.Connection, query: str, top_k: int) -> list[tuple[int, float]]:
    """Return [(chunk_id, bm25_score), ...] top-K by FTS5 BM25.

    Returns [] gracefully if:
      - FTS5 isn't compiled in (rare on modern Python sqlite3)
      - The chunks_fts table is empty (old index built before A7)
      - The query is unparseable (only stop-words / punctuation)

    BM25 in SQLite is a distance-like score (lower = better), so we
    invert it to a similarity-shaped 1/(1+bm25) before returning.
    """
    # Sanitize: FTS5's syntax rejects `:`, `.`, `-` in unquoted terms
    # but slot IDs like "1M.3" and error names like "worker_quality"
    # are exactly the reason for hybrid. Wrap each whitespace-separated
    # token in double quotes so FTS5 treats it as a phrase.
    #
    # Strip both double AND single quotes from each token before
    # re-quoting — a token with an embedded `"` would break out of the
    # phrase-quote and let the remainder be parsed as FTS5 operators
    # (NEAR, NOT, wildcards). Same for `'`. Any residual char that
    # FTS5 doesn't like will just miss the match, which is fine —
    # advisory retrieval, not authoritative.
    raw_tokens = [t.strip() for t in query.split() if t.strip()]
    tokens: list[str] = []
    for t in raw_tokens:
        cleaned = t.replace('"', '').replace("'", '')
        if cleaned:
            tokens.append(cleaned)
    if not tokens:
        return []
    fts_query = " OR ".join(f'"{t}"' for t in tokens)
    try:
        rows = conn.execute(
            "SELECT rowid, bm25(chunks_fts) AS score "
            "FROM chunks_fts WHERE chunks_fts MATCH ? "
            "ORDER BY score LIMIT ?",
            (fts_query, top_k),
        ).fetchall()
    except sqlite3.OperationalError:
        # FTS5 unavailable or table missing on a legacy index.
        return []
    # bm25() is negative in SQLite's implementation (more negative =
    # better). Convert to a positive similarity-shaped score so RRF
    # only cares about the RANK, not the magnitude.
    return [(int(cid), -float(s)) for cid, s in rows]


def _rrf_fuse(
    dense_ranked: list[int],
    sparse_ranked: list[int],
    k: int = 60,
) -> list[tuple[int, float]]:
    """Reciprocal-rank fusion: score(id) = Σ 1/(k + rank).

    k=60 is the RRF paper default. Robust across score magnitudes —
    dense (cosine) and sparse (BM25) don't need to be normalized.
    """
    scores: dict[int, float] = {}
    for rank_i, cid in enumerate(dense_ranked):
        scores[cid] = scores.get(cid, 0.0) + 1.0 / (k + rank_i)
    for rank_i, cid in enumerate(sparse_ranked):
        scores[cid] = scores.get(cid, 0.0) + 1.0 / (k + rank_i)
    return sorted(scores.items(), key=lambda pair: -pair[1])


def _check_embedder_matches_index(conn, embedder: Embedder) -> str | None:
    """Refuse a query whose embedder differs from the one that built the index.

    This checked dim only. Two different models at the same dim (two 768d
    providers, say) silently mixed embedding spaces and returned junk with no
    error at all, so the model name is checked too.
    """
    stored_dim = get_meta(conn, "embedding_dim")
    stored_model = get_meta(conn, "embedding_model")
    if stored_dim and int(stored_dim) != embedder.DIM:
        return (
            f"query embedder dim ({embedder.DIM}) doesn't match indexed dim "
            f"({stored_dim}). The index was built with {stored_model}. Either:\n"
            "  - Use the same provider as the index, or\n"
            "  - Run 'rebuild --force' to re-embed with the new provider."
        )
    if stored_model and stored_model != embedder.MODEL:
        return (
            f"query embedder model ({embedder.MODEL}) doesn't match indexed "
            f"model ({stored_model}) — same dim, different space.\n"
            "  - Use the same model as the index, or\n"
            "  - Run 'rebuild --force' to re-embed with the new model."
        )
    return None


def _fuse_hybrid(conn, rows, sims, sorted_idx, query: str, top_k: int, np):
    """Fuse dense ranks with FTS5 BM25 ranks via RRF.

    Exact-token queries — slot IDs, SHAs, error strings — otherwise get
    buried by chunks that are semantically adjacent but share no tokens.
    Indexes built before FTS5 was added return no sparse hits, and this
    falls back to dense-only silently.

    Returns (sorted_idx, sims, mode).
    """
    row_by_id = {r[0]: i for i, r in enumerate(rows)}
    dense_ranked_ids = [rows[i][0] for i in sorted_idx]
    # A wider FTS5 slice than top_k, so fusion has candidates even for terms
    # that only appear in mid-ranked dense hits.
    sparse_ranked = _fts5_query(conn, query, max(50, top_k * 5))
    if not sparse_ranked:
        return sorted_idx, sims, "dense"

    fused = _rrf_fuse(dense_ranked_ids, [cid for cid, _ in sparse_ranked])
    fused_idx: list[int] = []
    fused_scores: dict[int, float] = {}
    for cid, s in fused:
        idx = row_by_id.get(cid)
        if idx is None:
            continue
        fused_idx.append(idx)
        fused_scores[cid] = s
    if not fused_idx:
        return sorted_idx, sims, "dense"

    sims_hybrid = np.zeros(len(rows), dtype=np.float32)
    for cid, s in fused_scores.items():
        sims_hybrid[row_by_id[cid]] = s
    return (
        np.array(fused_idx), sims_hybrid,
        "hybrid (dense + FTS5 BM25, RRF fused)",
    )


def _print_matches(rows, sims, sorted_idx, top_k: int, snippet_chars: int) -> None:
    """Walk the ranking in order, collecting distinct docs up to top_k.

    Dedupe happens BEFORE trimming. Taking top_k by similarity and deduping
    afterwards meant "top 5 all from doc X" collapsed to one visible result.
    """
    seen: set[str] = set()
    shown = 0
    for i in sorted_idx:
        if shown >= top_k:
            break
        _chunk_id, path, chunk_idx, text, _ = rows[i]
        key = f"{path}:{chunk_idx // 3}"
        if key in seen:
            continue
        seen.add(key)
        shown += 1
        snippet = text[:snippet_chars].rstrip()
        if len(text) > snippet_chars:
            snippet += "…"
        print(f"## [{shown}] `{path}` (chunk {chunk_idx}, score {float(sims[i]):.3f})\n")
        print(snippet)
        print()


def _rank_dense(rows, embedder: Embedder, query: str, np):
    """Cosine similarity of the query against every stored chunk."""
    qvec = np.array(embedder.embed_query(query), dtype=np.float32)
    qvec /= np.linalg.norm(qvec) + 1e-12
    embs = np.array([unpack_embedding(r[4]) for r in rows], dtype=np.float32)
    embs_n = embs / (np.linalg.norm(embs, axis=1, keepdims=True) + 1e-12)
    sims = embs_n @ qvec
    return sims, np.argsort(-sims)


def cmd_query(
    db_path: Path,
    embedder: Embedder,
    query: str,
    top_k: int,
    snippet_chars: int,
    hybrid: bool = True,
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
    mismatch = _check_embedder_matches_index(conn, embedder)
    if mismatch:
        print(f"ERROR: {mismatch}", file=sys.stderr)
        return 2

    rows = conn.execute(
        "SELECT chunks.id, docs.path, chunks.chunk_idx, chunks.text, chunks.embedding "
        "FROM chunks JOIN docs ON docs.id = chunks.doc_id"
    ).fetchall()
    if not rows:
        print("ERROR: index is empty. Run 'rebuild' first.", file=sys.stderr)
        return 2
    sims, sorted_idx = _rank_dense(rows, embedder, query, np)

    mode = "dense"
    if hybrid:
        sorted_idx, sims, mode = _fuse_hybrid(
            conn, rows, sims, sorted_idx, query, top_k, np
        )

    print(f"# Top matches for: {query!r}")
    print(
        f"# (provider: {embedder.NAME}, model: {embedder.MODEL}, "
        f"dim: {embedder.DIM}, mode: {mode})\n"
    )
    _print_matches(rows, sims, sorted_idx, top_k, snippet_chars)
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


def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Local semantic search over docs/research/.",
    )
    parser.add_argument("--corpus", default="docs/research",
                        help="Directory to index (default: docs/research)")
    parser.add_argument("--index", default=None,
                        help="SQLite path (default: <corpus>/.research-index.sqlite)")
    parser.add_argument(
        "--provider", choices=sorted(PROVIDERS), default=None,
        help="Override the embedding provider (default: from "
             ".process-engine.yaml or env detection or fastembed)")
    parser.add_argument(
        "--model", default=None,
        help="Override the embedding model name (provider-specific default "
             "if unset)")
    parser.add_argument(
        "--project-root", default=".",
        help="Project root for reading .process-engine.yaml (default: cwd)")

    sub = parser.add_subparsers(dest="cmd", required=True)

    p_rebuild = sub.add_parser("rebuild", help="Build / refresh the index")
    p_rebuild.add_argument("--force", action="store_true",
                           help="Re-embed all docs, ignore sha cache")

    p_query = sub.add_parser("query", help="Semantic search")
    p_query.add_argument("query", help="Search query")
    p_query.add_argument("--top", type=int, default=8,
                         help="Top-K results (default 8)")
    p_query.add_argument("--snippet", type=int, default=500,
                         help="Snippet length in chars (default 500)")
    # A7: hybrid dense + FTS5 BM25 is on by default. --no-hybrid is for A/B
    # comparison, or if the FTS5 index appears corrupted.
    p_query.add_argument("--no-hybrid", dest="hybrid", action="store_false",
                         help="Skip FTS5 sparse fusion; run dense-only "
                              "(default: hybrid)")
    p_query.set_defaults(hybrid=True)

    sub.add_parser("status", help="Show index stats")
    return parser


def main() -> int:
    args = _build_arg_parser().parse_args()

    corpus = Path(args.corpus)
    db_path = Path(args.index) if args.index else corpus / ".research-index.sqlite"

    if args.cmd == "status":
        return cmd_status(db_path)
    if args.cmd == "rebuild" and not corpus.exists():
        print(f"ERROR: corpus {corpus} does not exist", file=sys.stderr)
        return 1

    # Provider resolution: CLI → yaml → env → fastembed default
    provider_name, yaml_model = resolve_provider(
        args.provider, Path(args.project_root)
    )
    try:
        embedder = make_embedder(provider_name, args.model or yaml_model)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if args.cmd == "rebuild":
        return cmd_rebuild(corpus, db_path, embedder, args.force)
    if args.cmd == "query":
        return cmd_query(
            db_path, embedder, args.query, args.top, args.snippet,
            hybrid=args.hybrid,
        )
    return 1


if __name__ == "__main__":
    sys.exit(main())
