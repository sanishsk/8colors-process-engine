#!/usr/bin/env python3
"""pe_memory.py — L3 memory-governance CLI.

Auto-memory lives at `~/.claude/projects/<project-slug>/memory/`
where `<project-slug>` is Claude Code's encoding of the absolute
project path (leading `/` → `-`, every `/` → `-`). Each entry is a
`.md` file with YAML frontmatter:

    ---
    name: <slug>
    description: <one-line hook>
    metadata:
      node_type: memory
      type: user | feedback | project | reference
      originSessionId: <uuid>
      # L3 additions (all optional, backward compatible):
      freshness_days: <int>       — TTL before entry is stale
      last_verified: <ISO date>   — when operator confirmed accuracy
      scope: user | agent | session | org
    ---
    <body>

`MEMORY.md` is a one-line-per-entry index that Claude Code auto-loads
into every session. L3 doesn't change how entries are written — that
still happens via the operator's global memory rules — but it makes
the resulting state INSPECTABLE, VERIFIABLE, and DELETABLE from the
CLI.

Subcommands
-----------

    pe memory ls    [--project <path>] [--type <t>] [--stale]
                    List all memory entries with age + staleness flag.
                    --type filters by frontmatter metadata.type.
                    --stale shows only entries past their freshness window.

    pe memory show <name> [--project <path>]
                    Print the full frontmatter + body of one entry.

    pe memory rm   <name> [--project <path>] [--yes]
                    Delete an entry file AND remove its line from
                    MEMORY.md. Prompts unless --yes.

    pe memory verify <name> [--project <path>]
                    Stamp metadata.last_verified = today (ISO date).
                    Resets the staleness clock so the operator can
                    endorse an entry they've re-checked without
                    editing the body.

    pe memory stale [--project <path>] [--older-than-days N]
                    List only entries older than N days (default 30)
                    or past their per-entry freshness_days. Prints the
                    "verify or delete" recommendation for each.

Staleness rule (deliberate design)
----------------------------------

    An entry is stale iff:
        now - max(mtime, last_verified) > (freshness_days or DEFAULT_STALE_DAYS)

    Default per type (only used when metadata.freshness_days absent):
        user       — 90 days (identities change slowly)
        feedback   — 60 days (preferences drift)
        project    — 14 days (state changes fast)
        reference  — 180 days (pointers rarely rot)
        (unknown)  — 30 days

Exit codes
----------

    0  success
    1  no memory directory for this project
    2  invalid args
    3  entry not found
    4  MEMORY.md index desync (fatal — operator must fix)
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_STALE_DAYS_BY_TYPE = {
    "user": 90,
    "feedback": 60,
    "project": 14,
    "reference": 180,
}
DEFAULT_STALE_DAYS = 30


# ─── project slug ────────────────────────────────────────────────────────


def project_slug(project_path: Path) -> str:
    """Match Claude Code's directory encoding."""
    return str(project_path.resolve()).replace("/", "-")


def memory_dir(project_path: Path, claude_home: Path | None = None) -> Path:
    home = claude_home or (Path.home() / ".claude" / "projects")
    return home / project_slug(project_path) / "memory"


# ─── frontmatter parser ─────────────────────────────────────────────────


_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """Return (frontmatter_dict, body). Handles two levels of nesting
    (top-level scalars + a `metadata:` block).

    Deliberately shallow: no anchors, no multi-doc, no lists. Memory
    files are always this exact shape — if PyYAML is later added as
    an optional dep we can swap this out.
    """
    m = _FRONTMATTER_RE.match(text)
    if not m:
        raise ValueError("no YAML frontmatter block found")
    body = text[m.end():]
    fm: dict = {}
    current_nest: dict | None = None
    for raw_line in m.group(1).splitlines():
        if not raw_line.strip() or raw_line.strip().startswith("#"):
            continue
        # Top-level key: no leading whitespace before the colon.
        if raw_line[:1] not in (" ", "\t"):
            key, _, val = raw_line.partition(":")
            key = key.strip()
            val = val.strip()
            if val == "":
                # nested block starts
                fm[key] = {}
                current_nest = fm[key]
            else:
                fm[key] = _unquote(val)
                current_nest = None
        else:
            # Nested key under the most recent top-level nest.
            if current_nest is None:
                continue
            key, _, val = raw_line.partition(":")
            key = key.strip()
            val = val.strip()
            current_nest[key] = _unquote(val)
    return fm, body


def _unquote(v: str) -> str:
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
        return v[1:-1]
    return v


# ─── memory entry ───────────────────────────────────────────────────────


@dataclass
class MemoryEntry:
    path: Path
    name: str
    description: str
    node_type: str  # "memory"
    entry_type: str  # user | feedback | project | reference
    origin_session_id: str
    freshness_days: int | None  # explicit override; None → default-by-type
    last_verified: dt.date | None
    scope: str | None
    body: str
    mtime: dt.datetime

    def effective_freshness_days(self) -> int:
        if self.freshness_days is not None:
            return self.freshness_days
        return DEFAULT_STALE_DAYS_BY_TYPE.get(self.entry_type, DEFAULT_STALE_DAYS)

    def last_touched(self) -> dt.datetime:
        """max(mtime, last_verified). last_verified wins if set."""
        if self.last_verified is None:
            return self.mtime
        # Combine date with midnight UTC for comparability.
        verified_dt = dt.datetime.combine(
            self.last_verified, dt.time(), tzinfo=dt.timezone.utc
        )
        return max(self.mtime, verified_dt)

    def age_days(self) -> int:
        now = dt.datetime.now(dt.timezone.utc)
        return (now - self.last_touched()).days

    def is_stale(self) -> bool:
        return self.age_days() >= self.effective_freshness_days()


def load_entry(path: Path) -> MemoryEntry:
    text = path.read_text(encoding="utf-8")
    fm, body = parse_frontmatter(text)
    meta = fm.get("metadata") or {}
    # Freshness may be int-as-string in yaml.
    fd = meta.get("freshness_days")
    freshness_days = int(fd) if fd not in (None, "") else None
    # Parse last_verified as ISO date (YYYY-MM-DD).
    lv_raw = meta.get("last_verified")
    last_verified: dt.date | None = None
    if lv_raw:
        try:
            last_verified = dt.date.fromisoformat(str(lv_raw))
        except ValueError:
            last_verified = None
    mtime_ts = path.stat().st_mtime
    return MemoryEntry(
        path=path,
        name=fm.get("name") or path.stem,
        description=fm.get("description", ""),
        node_type=meta.get("node_type", ""),
        entry_type=meta.get("type", ""),
        origin_session_id=meta.get("originSessionId", ""),
        freshness_days=freshness_days,
        last_verified=last_verified,
        scope=meta.get("scope"),
        body=body,
        mtime=dt.datetime.fromtimestamp(mtime_ts, tz=dt.timezone.utc),
    )


def list_entries(mem_dir: Path) -> list[MemoryEntry]:
    if not mem_dir.is_dir():
        return []
    entries: list[MemoryEntry] = []
    for p in sorted(mem_dir.glob("*.md")):
        if p.name == "MEMORY.md":
            continue
        try:
            entries.append(load_entry(p))
        except ValueError:
            # Malformed entry — surface via ls but don't crash.
            entries.append(MemoryEntry(
                path=p, name=p.stem, description="(no frontmatter — malformed)",
                node_type="", entry_type="unknown", origin_session_id="",
                freshness_days=None, last_verified=None, scope=None,
                body="", mtime=dt.datetime.fromtimestamp(p.stat().st_mtime, tz=dt.timezone.utc),
            ))
    return entries


# ─── MEMORY.md index ────────────────────────────────────────────────────


_INDEX_LINE_RE = re.compile(r"^\s*-\s+\[([^\]]+)\]\(([^)]+)\)")


def read_index(mem_dir: Path) -> list[tuple[str, str]]:
    """Return [(title, filename), ...] parsed from MEMORY.md."""
    idx = mem_dir / "MEMORY.md"
    if not idx.is_file():
        return []
    out: list[tuple[str, str]] = []
    for line in idx.read_text(encoding="utf-8").splitlines():
        m = _INDEX_LINE_RE.match(line)
        if m:
            out.append((m.group(1), m.group(2)))
    return out


def remove_from_index(mem_dir: Path, filename: str) -> bool:
    """Strip the index line pointing at filename. Returns True if removed."""
    idx = mem_dir / "MEMORY.md"
    if not idx.is_file():
        return False
    lines = idx.read_text(encoding="utf-8").splitlines(keepends=True)
    kept: list[str] = []
    removed = False
    for line in lines:
        m = _INDEX_LINE_RE.match(line)
        if m and m.group(2) == filename:
            removed = True
            continue
        kept.append(line)
    if removed:
        idx.write_text("".join(kept), encoding="utf-8")
    return removed


def desync_check(mem_dir: Path) -> list[str]:
    """Files present on disk but not in MEMORY.md (or vice versa)."""
    if not mem_dir.is_dir():
        return []
    on_disk = {p.name for p in mem_dir.glob("*.md") if p.name != "MEMORY.md"}
    in_index = {fn for _, fn in read_index(mem_dir)}
    problems: list[str] = []
    for f in sorted(on_disk - in_index):
        problems.append(f"file on disk not in MEMORY.md index: {f}")
    for f in sorted(in_index - on_disk):
        problems.append(f"MEMORY.md references missing file: {f}")
    return problems


# ─── verify (stamp last_verified) ───────────────────────────────────────


def stamp_verified(entry: MemoryEntry, today: dt.date | None = None) -> Path:
    """Rewrite the entry's frontmatter to set metadata.last_verified = today."""
    today = today or dt.date.today()
    text = entry.path.read_text(encoding="utf-8")
    m = _FRONTMATTER_RE.match(text)
    if not m:
        raise ValueError("no frontmatter to update")
    fm_text = m.group(1)
    body = text[m.end():]

    # If metadata: block exists, insert / replace last_verified inside it.
    # Otherwise append a metadata block with just last_verified.
    lines = fm_text.splitlines()
    in_metadata = False
    new_lines: list[str] = []
    replaced = False
    metadata_found = False
    for ln in lines:
        stripped = ln.rstrip()
        # Enter metadata block on top-level `metadata:` line.
        if stripped.rstrip(":").strip() == "metadata" and ln[:1] not in (" ", "\t"):
            in_metadata = True
            metadata_found = True
            new_lines.append(ln)
            continue
        if in_metadata:
            if ln[:1] not in (" ", "\t") and stripped:
                # Left the metadata block — insert if not already replaced.
                if not replaced:
                    new_lines.append(f"  last_verified: {today.isoformat()}")
                    replaced = True
                in_metadata = False
                new_lines.append(ln)
                continue
            # Existing last_verified in the block — replace it.
            if ln.lstrip().startswith("last_verified:"):
                indent = ln[: len(ln) - len(ln.lstrip())]
                new_lines.append(f"{indent}last_verified: {today.isoformat()}")
                replaced = True
                continue
            new_lines.append(ln)
            continue
        new_lines.append(ln)
    # File ends while still inside metadata block: append.
    if in_metadata and not replaced:
        new_lines.append(f"  last_verified: {today.isoformat()}")
        replaced = True
    # No metadata block at all.
    if not metadata_found:
        new_lines.append("metadata:")
        new_lines.append(f"  last_verified: {today.isoformat()}")

    new_fm = "\n".join(new_lines) + "\n"
    entry.path.write_text(f"---\n{new_fm}---\n{body}", encoding="utf-8")
    return entry.path


# ─── CLI handlers ───────────────────────────────────────────────────────


def _resolve_mem_dir(args: argparse.Namespace) -> Path:
    project = Path(args.project).resolve() if args.project else Path.cwd()
    mem = memory_dir(project)
    if not mem.is_dir():
        print(
            f"ERROR: no memory directory for this project.\n"
            f"  Expected: {mem}\n"
            f"  (auto-memory is written by Claude Code — no entries yet is normal)",
            file=sys.stderr,
        )
        raise SystemExit(1)
    return mem


def cmd_ls(args: argparse.Namespace) -> int:
    mem = _resolve_mem_dir(args)
    entries = list_entries(mem)

    if args.type:
        entries = [e for e in entries if e.entry_type == args.type]
    if args.stale:
        entries = [e for e in entries if e.is_stale()]

    if not entries:
        print("(no matching entries)")
        return 0

    # Simple aligned columns; no tabulate dep.
    hdrs = ["NAME", "TYPE", "AGE (days)", "STALE?", "DESCRIPTION"]
    rows = [hdrs] + [
        [
            e.name,
            e.entry_type or "?",
            str(e.age_days()),
            "yes" if e.is_stale() else "no",
            (e.description[:60] + "…") if len(e.description) > 60 else e.description,
        ]
        for e in entries
    ]
    widths = [max(len(r[i]) for r in rows) for i in range(len(hdrs))]
    for row in rows:
        print("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)))

    # Optional desync warning.
    problems = desync_check(mem)
    if problems:
        print("", file=sys.stderr)
        print(f"MEMORY.md desync: {len(problems)} issue(s)", file=sys.stderr)
        for p in problems[:10]:
            print(f"  - {p}", file=sys.stderr)
        if len(problems) > 10:
            print(f"  ... and {len(problems) - 10} more", file=sys.stderr)
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    mem = _resolve_mem_dir(args)
    for e in list_entries(mem):
        if e.name == args.name:
            print(f"name:             {e.name}")
            print(f"path:             {e.path}")
            print(f"type:             {e.entry_type}")
            print(f"scope:            {e.scope or '(unset)'}")
            print(f"origin session:   {e.origin_session_id}")
            print(f"mtime (UTC):      {e.mtime.isoformat()}")
            print(f"last_verified:    {e.last_verified.isoformat() if e.last_verified else '(unset)'}")
            print(f"freshness_days:   {e.effective_freshness_days()} (explicit={e.freshness_days is not None})")
            print(f"age_days:         {e.age_days()}")
            print(f"stale:            {'yes' if e.is_stale() else 'no'}")
            print(f"description:      {e.description}")
            print("")
            print("─── body ────────────────────────────────────")
            print(e.body)
            return 0
    print(f"ERROR: no memory entry named {args.name!r}", file=sys.stderr)
    return 3


def cmd_rm(args: argparse.Namespace) -> int:
    mem = _resolve_mem_dir(args)
    entries = list_entries(mem)
    match = next((e for e in entries if e.name == args.name), None)
    if match is None:
        print(f"ERROR: no memory entry named {args.name!r}", file=sys.stderr)
        return 3

    print(f"Will delete:")
    print(f"  {match.path}")
    print(f"  ({match.entry_type}, age={match.age_days()}d, description={match.description[:80]!r})")

    if not args.yes:
        try:
            reply = input("Proceed? [y/N] ").strip().lower()
        except EOFError:
            reply = ""
        if reply not in ("y", "yes"):
            print("Cancelled.")
            return 0

    match.path.unlink()
    idx_removed = remove_from_index(mem, match.path.name)
    print(f"✓ deleted {match.path.name}")
    if idx_removed:
        print(f"✓ removed line from MEMORY.md")
    else:
        print(f"⚠ MEMORY.md did not reference {match.path.name} (already desync)")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    mem = _resolve_mem_dir(args)
    entries = list_entries(mem)
    match = next((e for e in entries if e.name == args.name), None)
    if match is None:
        print(f"ERROR: no memory entry named {args.name!r}", file=sys.stderr)
        return 3
    stamp_verified(match)
    print(f"✓ stamped {match.name} with last_verified = {dt.date.today().isoformat()}")
    return 0


def cmd_stale(args: argparse.Namespace) -> int:
    mem = _resolve_mem_dir(args)
    entries = list_entries(mem)
    threshold = args.older_than_days
    stale = [
        e for e in entries
        if e.is_stale() or (threshold is not None and e.age_days() >= threshold)
    ]
    if not stale:
        print("(no stale entries)")
        return 0
    print(f"{len(stale)} stale entrie(s):")
    for e in stale:
        print(f"  {e.name}  ({e.entry_type}, age={e.age_days()}d, "
              f"freshness={e.effective_freshness_days()}d)")
        print(f"    → verify (`pe memory verify {e.name}`) or delete "
              f"(`pe memory rm {e.name}`)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="pe memory",
        description="L3 memory governance — inspect / correct / delete auto-memory.",
    )
    sub = p.add_subparsers(dest="sub", required=True)

    def _project(sp):
        sp.add_argument("--project", help="Project path (default cwd)")

    l = sub.add_parser("ls", help="List memory entries with staleness")
    _project(l)
    l.add_argument("--type", help="Filter by metadata.type (user/feedback/project/reference)")
    l.add_argument("--stale", action="store_true", help="Only show stale entries")
    l.set_defaults(func=cmd_ls)

    s = sub.add_parser("show", help="Show one entry's frontmatter + body")
    _project(s)
    s.add_argument("name", help="Entry name (from frontmatter name: field)")
    s.set_defaults(func=cmd_show)

    r = sub.add_parser("rm", help="Delete an entry + remove its index line")
    _project(r)
    r.add_argument("name", help="Entry name to delete")
    r.add_argument("--yes", "-y", action="store_true", help="Skip confirmation")
    r.set_defaults(func=cmd_rm)

    v = sub.add_parser("verify", help="Stamp metadata.last_verified = today")
    _project(v)
    v.add_argument("name", help="Entry name to verify")
    v.set_defaults(func=cmd_verify)

    t = sub.add_parser("stale", help="List entries past freshness window")
    _project(t)
    t.add_argument("--older-than-days", type=int, default=None,
                   help="Additional threshold (list ALL entries older than N days)")
    t.set_defaults(func=cmd_stale)

    return p


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
