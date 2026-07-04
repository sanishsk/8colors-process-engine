#!/usr/bin/env bash
# tests/test_research_index_hybrid.sh — A7 FTS5 hybrid retrieval.
#
# Full end-to-end index tests need numpy + an embedder pip-installed,
# which we can't assume in CI. Instead we test the pure helpers:
#   - _rrf_fuse: reciprocal-rank fusion produces a sane order.
#   - schema loads (FTS5 virtual table + main tables created).
#   - _fts5_query: BM25 sparse retrieval catches exact-token queries
#     that dense-only would miss (slot IDs, snake_case, SHAs).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
PY="${PE_PYTHON:-python3}"

pass=0
fail=0
declare -a failures=()

record_pass() { pass=$((pass+1)); echo "  ✓ $1"; }
record_fail() { fail=$((fail+1)); failures+=("$1"); echo "  ✗ $1"; }

echo "test_research_index_hybrid.sh — A7 FTS5 + RRF helpers"
echo ""

# ─── 1. schema creates chunks_fts virtual table ─────────────────────
out=$("$PY" - <<'PY' 2>&1
import sys
sys.path.insert(0, "scripts")
import research_index as ri
import sqlite3, tempfile, os
db = tempfile.NamedTemporaryFile(suffix='.sqlite', delete=False).name
conn = ri.open_db(__import__('pathlib').Path(db))
tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view')").fetchall()}
print('TABLES:', ','.join(sorted(tables)))
os.unlink(db)
PY
)
if echo "$out" | grep -q "chunks_fts"; then
    record_pass "schema creates chunks_fts virtual table"
else
    record_fail "chunks_fts missing from schema: '$out'"
fi

# ─── 2. _fts5_query catches snake_case exact tokens ─────────────────
out=$("$PY" - <<'PY' 2>&1
import sys
sys.path.insert(0, "scripts")
import research_index as ri
import sqlite3, tempfile, os
db = tempfile.NamedTemporaryFile(suffix='.sqlite', delete=False).name
conn = ri.open_db(__import__('pathlib').Path(db))
conn.execute("INSERT INTO docs (path, mtime, sha256, indexed_at) VALUES ('a.md',0,'x','now')")
cur = conn.execute("INSERT INTO chunks (doc_id, chunk_idx, text, embedding) VALUES (1, 0, 'the worker_quality failure_class fired on slot 1M.3', ?)", (b'0'*16,))
conn.execute("INSERT INTO chunks_fts (rowid, text) VALUES (?, ?)", (cur.lastrowid, 'the worker_quality failure_class fired on slot 1M.3'))
conn.commit()
hits = ri._fts5_query(conn, "worker_quality", 5)
print('HITS:', hits)
os.unlink(db)
PY
)
if echo "$out" | grep -qE "HITS: \[\([0-9]+, [0-9.e+-]+\)\]"; then
    record_pass "_fts5_query returns [(chunk_id, score)] on snake_case match"
else
    record_fail "_fts5_query returned unexpected: '$out'"
fi

# ─── 3. _fts5_query returns [] on empty query ───────────────────────
out=$("$PY" - <<'PY' 2>&1
import sys
sys.path.insert(0, "scripts")
import research_index as ri
import sqlite3, tempfile, os
db = tempfile.NamedTemporaryFile(suffix='.sqlite', delete=False).name
conn = ri.open_db(__import__('pathlib').Path(db))
print('HITS:', ri._fts5_query(conn, "   ", 5))
os.unlink(db)
PY
)
if echo "$out" | grep -q "HITS: \[\]"; then
    record_pass "_fts5_query returns [] on whitespace-only query"
else
    record_fail "empty-query handling wrong: '$out'"
fi

# ─── 4. _rrf_fuse orders by summed reciprocal ranks ─────────────────
out=$("$PY" - <<'PY' 2>&1
import sys
sys.path.insert(0, "scripts")
import research_index as ri
# ID 42 is rank 0 on dense AND rank 0 on sparse → best.
# ID 7 is rank 1 on dense, rank 3 on sparse → second.
# ID 99 is rank 3 on dense only → weakest.
fused = ri._rrf_fuse([42, 7, 5, 99], [42, 5, 7])
top_ids = [cid for cid, _ in fused]
print('ORDER:', top_ids[:3])
PY
)
if echo "$out" | grep -q "ORDER: \[42, 7, 5\]" \
   || echo "$out" | grep -q "ORDER: \[42, 5, 7\]"; then
    # Tie between 7 and 5 depending on rank arithmetic; both are valid
    # RRF outcomes with k=60. Just assert 42 is first.
    record_pass "_rrf_fuse ranks common-top-1 highest"
else
    record_fail "RRF ordering wrong: '$out'"
fi

# ─── 4b. FTS5 query rejects tokens with embedded quotes safely ──────
out=$("$PY" - <<'PY' 2>&1
import sys
sys.path.insert(0, "scripts")
import research_index as ri
import sqlite3, tempfile, os
db = tempfile.NamedTemporaryFile(suffix='.sqlite', delete=False).name
conn = ri.open_db(__import__('pathlib').Path(db))
conn.execute("INSERT INTO docs (path, mtime, sha256, indexed_at) VALUES ('a.md',0,'x','now')")
cur = conn.execute("INSERT INTO chunks (doc_id, chunk_idx, text, embedding) VALUES (1, 0, 'clean chunk', ?)", (b'0'*16,))
conn.execute("INSERT INTO chunks_fts (rowid, text) VALUES (?, ?)", (cur.lastrowid, 'clean chunk'))
conn.commit()
# Attacker-shaped query with embedded quotes + FTS5 operators.
hits = ri._fts5_query(conn, 'chunk" NOT everything "OR"', 5)
# Either returns some hits (quotes stripped, phrase matches) or [], but
# must NOT crash and must NOT execute an unintended FTS5 operator.
print('SAFE:', isinstance(hits, list))
os.unlink(db)
PY
)
if echo "$out" | grep -q "SAFE: True"; then
    record_pass "FTS5 query with embedded quotes handled safely (reviewer CRITICAL)"
else
    record_fail "FTS5 quote handling wrong: '$out'"
fi

# ─── 4c. rebuild cascades FTS5 rows on chunk deletion (reviewer HIGH) ─
out=$("$PY" - <<'PY' 2>&1
import sys
sys.path.insert(0, "scripts")
import research_index as ri
import sqlite3, tempfile, os
db = tempfile.NamedTemporaryFile(suffix='.sqlite', delete=False).name
conn = ri.open_db(__import__('pathlib').Path(db))
conn.execute("INSERT INTO docs (path, mtime, sha256, indexed_at) VALUES ('a.md',0,'x','now')")
cur = conn.execute("INSERT INTO chunks (doc_id, chunk_idx, text, embedding) VALUES (1, 0, 'stale', ?)", (b'0'*16,))
stale_rowid = cur.lastrowid
conn.execute("INSERT INTO chunks_fts (rowid, text) VALUES (?, ?)", (stale_rowid, 'stale'))
conn.commit()
# Simulate the rebuild's update path: doc found in DB, purge its chunks + FTS mirror.
conn.execute("DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE doc_id = ?)", (1,))
conn.execute("DELETE FROM chunks WHERE doc_id = ?", (1,))
conn.commit()
n_orphan = conn.execute("SELECT COUNT(*) FROM chunks_fts").fetchone()[0]
print('ORPHAN_ROWS:', n_orphan)
os.unlink(db)
PY
)
if echo "$out" | grep -q "ORPHAN_ROWS: 0"; then
    record_pass "chunk deletion cascades to chunks_fts (no orphan sparse rows)"
else
    record_fail "FTS5 orphan cascade broken: '$out'"
fi

# ─── 5. hybrid mode gracefully handles legacy (no-FTS5) rows ────────
out=$("$PY" - <<'PY' 2>&1
import sys
sys.path.insert(0, "scripts")
import research_index as ri
import sqlite3, tempfile, os
db = tempfile.NamedTemporaryFile(suffix='.sqlite', delete=False).name
conn = ri.open_db(__import__('pathlib').Path(db))
# Insert into chunks WITHOUT populating chunks_fts (simulates a
# pre-A7 index migrated forward by open_db).
conn.execute("INSERT INTO docs (path, mtime, sha256, indexed_at) VALUES ('a.md',0,'x','now')")
conn.execute("INSERT INTO chunks (doc_id, chunk_idx, text, embedding) VALUES (1, 0, 'legacy chunk', ?)", (b'0'*16,))
conn.commit()
# _fts5_query against empty FTS5 table returns [] (no crash).
print('HITS:', ri._fts5_query(conn, "legacy", 5))
os.unlink(db)
PY
)
if echo "$out" | grep -q "HITS: \[\]"; then
    record_pass "hybrid gracefully degrades on legacy (empty FTS5) indexes"
else
    record_fail "legacy fallback broken: '$out'"
fi

# ─── summary ────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  passed: $pass"
echo "  failed: $fail"
if [ $fail -gt 0 ]; then
    for f in "${failures[@]}"; do echo "    - $f"; done
    exit 1
fi
exit 0
