"""test_pe_memory.py — L3 memory-governance CLI unit tests.

Runs standalone: `python3 tests/test_pe_memory.py`. Zero external deps.
Every test uses a tempdir-backed memory dir; no touching of real
~/.claude/projects/ state.
"""

from __future__ import annotations

import datetime as dt
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from pe_memory import (  # noqa: E402
    DEFAULT_STALE_DAYS,
    DEFAULT_STALE_DAYS_BY_TYPE,
    MemoryEntry,
    desync_check,
    list_entries,
    load_entry,
    parse_frontmatter,
    read_index,
    remove_from_index,
    stamp_verified,
)


def _write_entry(dir_: Path, name: str, entry_type: str = "project",
                 freshness_days: int | None = None,
                 last_verified: str | None = None,
                 scope: str | None = None,
                 description: str = "test entry",
                 origin: str = "sess-1",
                 body: str = "body content") -> Path:
    p = dir_ / f"{name}.md"
    meta_lines = [
        "  node_type: memory",
        f"  type: {entry_type}",
        f"  originSessionId: {origin}",
    ]
    if freshness_days is not None:
        meta_lines.append(f"  freshness_days: {freshness_days}")
    if last_verified is not None:
        meta_lines.append(f"  last_verified: {last_verified}")
    if scope is not None:
        meta_lines.append(f"  scope: {scope}")
    text = (
        "---\n"
        f"name: {name}\n"
        f"description: {description}\n"
        "metadata:\n"
        + "\n".join(meta_lines) + "\n"
        + "---\n"
        + body + "\n"
    )
    p.write_text(text, encoding="utf-8")
    return p


def _write_index(dir_: Path, entries: list[tuple[str, str]]) -> Path:
    """entries = [(title, filename), ...]"""
    idx = dir_ / "MEMORY.md"
    lines = [f"- [{title}]({fn}) — hook" for title, fn in entries]
    idx.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return idx


class Frontmatter(unittest.TestCase):
    def test_parses_flat_fields(self):
        text = "---\nname: x\ndescription: y\n---\nbody\n"
        fm, body = parse_frontmatter(text)
        self.assertEqual(fm["name"], "x")
        self.assertEqual(fm["description"], "y")
        self.assertEqual(body.strip(), "body")

    def test_parses_nested_metadata(self):
        text = (
            "---\n"
            "name: x\n"
            "metadata:\n"
            "  node_type: memory\n"
            "  type: project\n"
            "  originSessionId: abc-123\n"
            "---\nbody\n"
        )
        fm, _ = parse_frontmatter(text)
        self.assertIn("metadata", fm)
        self.assertEqual(fm["metadata"]["type"], "project")
        self.assertEqual(fm["metadata"]["originSessionId"], "abc-123")

    def test_strips_quotes(self):
        text = "---\nname: \"x with spaces\"\n---\nbody\n"
        fm, _ = parse_frontmatter(text)
        self.assertEqual(fm["name"], "x with spaces")

    def test_missing_frontmatter_raises(self):
        with self.assertRaises(ValueError):
            parse_frontmatter("no frontmatter here")


class LoadEntry(unittest.TestCase):
    def test_reads_all_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = _write_entry(d, "e1", entry_type="project",
                             freshness_days=7, last_verified="2026-07-01",
                             scope="agent")
            e = load_entry(p)
            self.assertEqual(e.name, "e1")
            self.assertEqual(e.entry_type, "project")
            self.assertEqual(e.freshness_days, 7)
            self.assertEqual(e.last_verified, dt.date(2026, 7, 1))
            self.assertEqual(e.scope, "agent")

    def test_missing_optionals_are_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = _write_entry(d, "e2")
            e = load_entry(p)
            self.assertIsNone(e.freshness_days)
            self.assertIsNone(e.last_verified)
            self.assertIsNone(e.scope)

    def test_bad_last_verified_leaves_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = _write_entry(d, "e3", last_verified="not-a-date")
            e = load_entry(p)
            self.assertIsNone(e.last_verified)


class Staleness(unittest.TestCase):
    def test_freshness_defaults_by_type(self):
        for t, days in DEFAULT_STALE_DAYS_BY_TYPE.items():
            with tempfile.TemporaryDirectory() as tmp:
                d = Path(tmp)
                p = _write_entry(d, "e", entry_type=t)
                e = load_entry(p)
                self.assertEqual(e.effective_freshness_days(), days,
                                 f"type={t} default mismatch")

    def test_unknown_type_falls_back_to_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = _write_entry(d, "e", entry_type="mystery")
            e = load_entry(p)
            self.assertEqual(e.effective_freshness_days(), DEFAULT_STALE_DAYS)

    def test_explicit_freshness_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = _write_entry(d, "e", entry_type="project", freshness_days=1)
            e = load_entry(p)
            self.assertEqual(e.effective_freshness_days(), 1)

    def test_last_verified_resets_the_clock(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = _write_entry(d, "e", entry_type="project")
            # Make the file appear very old.
            os.utime(p, (0, 0))
            e = load_entry(p)
            # No last_verified — age should be huge, entry stale.
            self.assertTrue(e.is_stale())
            self.assertGreater(e.age_days(), 100)
            # Add today's last_verified — should not be stale.
            today = dt.date.today().isoformat()
            p.write_text(p.read_text().replace(
                "originSessionId: sess-1",
                f"originSessionId: sess-1\n  last_verified: {today}",
            ))
            e2 = load_entry(p)
            self.assertFalse(e2.is_stale())
            self.assertLessEqual(e2.age_days(), 0)


class ListEntries(unittest.TestCase):
    def test_returns_all_md_files_except_MEMORY(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_entry(d, "a")
            _write_entry(d, "b")
            _write_index(d, [("A", "a.md"), ("B", "b.md")])
            entries = list_entries(d)
            names = sorted(e.name for e in entries)
            self.assertEqual(names, ["a", "b"])

    def test_missing_dir_returns_empty(self):
        self.assertEqual(list_entries(Path("/nonexistent/path/xyz")), [])

    def test_malformed_entry_surfaced_not_dropped(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            bad = d / "malformed.md"
            bad.write_text("no frontmatter here")
            entries = list_entries(d)
            self.assertEqual(len(entries), 1)
            self.assertEqual(entries[0].entry_type, "unknown")
            self.assertIn("malformed", entries[0].description.lower())


class IndexIO(unittest.TestCase):
    def test_read_index_parses_bullet_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_index(d, [("Title 1", "one.md"), ("Title 2", "two.md")])
            self.assertEqual(
                read_index(d),
                [("Title 1", "one.md"), ("Title 2", "two.md")],
            )

    def test_read_index_ignores_non_bullet_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "MEMORY.md").write_text(
                "# heading\n"
                "prose line\n"
                "- [Title](file.md) — hook\n"
                "trailing\n"
            )
            self.assertEqual(read_index(d), [("Title", "file.md")])

    def test_remove_from_index(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_index(d, [("A", "a.md"), ("B", "b.md"), ("C", "c.md")])
            removed = remove_from_index(d, "b.md")
            self.assertTrue(removed)
            remaining = read_index(d)
            self.assertEqual([fn for _, fn in remaining], ["a.md", "c.md"])

    def test_remove_missing_returns_false(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_index(d, [("A", "a.md")])
            self.assertFalse(remove_from_index(d, "b.md"))


class Desync(unittest.TestCase):
    def test_reports_file_not_in_index(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_entry(d, "orphan")
            _write_index(d, [])  # empty index
            probs = desync_check(d)
            self.assertTrue(any("orphan.md" in p for p in probs))

    def test_reports_index_missing_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_index(d, [("Ghost", "ghost.md")])
            probs = desync_check(d)
            self.assertTrue(any("ghost.md" in p for p in probs))

    def test_clean_state_no_problems(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            _write_entry(d, "a")
            _write_entry(d, "b")
            _write_index(d, [("A", "a.md"), ("B", "b.md")])
            self.assertEqual(desync_check(d), [])


class StampVerified(unittest.TestCase):
    def test_adds_last_verified_when_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = _write_entry(d, "e")
            entry = load_entry(p)
            stamp_verified(entry, today=dt.date(2026, 7, 4))
            reloaded = load_entry(p)
            self.assertEqual(reloaded.last_verified, dt.date(2026, 7, 4))

    def test_replaces_existing_last_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = _write_entry(d, "e", last_verified="2020-01-01")
            entry = load_entry(p)
            stamp_verified(entry, today=dt.date(2026, 7, 4))
            reloaded = load_entry(p)
            self.assertEqual(reloaded.last_verified, dt.date(2026, 7, 4))

    def test_preserves_body(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = _write_entry(d, "e", body="the important prose")
            entry = load_entry(p)
            stamp_verified(entry, today=dt.date(2026, 7, 4))
            reloaded = load_entry(p)
            self.assertIn("the important prose", reloaded.body)

    def test_preserves_other_metadata_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = _write_entry(d, "e", scope="agent", freshness_days=7)
            entry = load_entry(p)
            stamp_verified(entry, today=dt.date(2026, 7, 4))
            reloaded = load_entry(p)
            self.assertEqual(reloaded.scope, "agent")
            self.assertEqual(reloaded.freshness_days, 7)


if __name__ == "__main__":
    unittest.main()
