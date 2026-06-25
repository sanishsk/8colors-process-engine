#!/usr/bin/env python3
"""
baseline.py — Phase 0 baseline harness.

E2, 2026-06-24. Stdlib only. Invoked via `pe baseline capture`.

Records the speed / size / quality profile of a shipped slot from
git history, so Phase 3's escalation ladder has a "didn't get worse"
success criterion to measure against.

What is measured (retrospectively):
  - speed.wall_clock_hours      first slot commit → merge commit
  - speed.iterations            count of commits on the slot branch
  - size.files_changed/lines_*  git diff --stat on the merge
  - quality.rework_72h          fix-prefix or slot-ID commits in 72h
                                after merge, on master, touching files
                                the slot touched (file-overlap rule).

What is recorded as null with a documented reason:
  - quality.sentry_incidents_7d  unless --sentry-count provided by hand
  - quality.gate_pass_rate       NULL for any pre-E1 slot — the gate
                                 envelope (E1) is the prerequisite for
                                 this metric. Forward-going only.
  - cost.{input,output,cache_read}_tokens
                                 NULL retrospectively — Claude Code did
                                 not emit per-slot token telemetry. The
                                 next slot (E2.1) wires this for
                                 forward-going records.

The honest measurable_notes[] field is the receipt: every field reports
either measured / null_retrospective / null_unavailable, with a reason.

USAGE
    pe baseline capture \\
        --project /path/to/8CStudio \\
        --slot-id 1M.5 \\
        --slot-kind feature_incremental \\
        --branch phase1/1m.5-offline-auth-refresh \\
        --merge-commit 776b435 \\
        [--sentry-count 0]              # optional, from MCP query
        [--output docs/baselines/1m.5.json]   # default: stdout

The script does not call Sentry directly — pass --sentry-count from the
MCP query result. This keeps the harness offline-first and easy to
reproduce.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path

SCHEMA_VERSION = "1.0.0"

REWORK_WINDOW_SECONDS = 72 * 3600
SENTRY_WINDOW_SECONDS = 7 * 24 * 3600  # for docs only — script doesn't call Sentry
FIX_PREFIX_RE = re.compile(r"^(?:fix|hotfix|patch|chore\(fix\)|revert)\b", re.IGNORECASE)
# Subjects matching this pattern are housekeeping (docs, tests-only, chore,
# style) that follow a slot rather than rework it. Excluded from the
# slot_id_in_subject rule so the baseline isn't inflated by post-ship
# documentation commits.
HOUSEKEEPING_PREFIX_RE = re.compile(
    r"^(?:docs|doc|test|tests|style|chore|refactor|ci|build|perf)(?:\([^)]*\))?:",
    re.IGNORECASE,
)


def git(repo: Path, *args: str) -> str:
    out = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return out.stdout.strip()


def parse_iso(value: str) -> dt.datetime:
    """ISO-8601 with trailing Z tolerance."""
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def find_branch_commits(repo: Path, merge_commit: str) -> list[str]:
    """Resolve commits unique to the slot branch.

    For a merge commit M with parents [P1 (mainline), P2 (slot-tip)],
    `git log P1..P2` is the canonical "slot-only" commit list.
    For a squashed or fast-forwarded merge (single parent), the slot
    boundary is fuzzier — we fall back to "commits introduced in this
    merge", which is just M itself.
    """
    parents = git(repo, "rev-list", "--parents", "-n", "1", merge_commit).split()
    if len(parents) >= 3:
        p1, p2 = parents[1], parents[2]
        rng = git(repo, "log", f"{p1}..{p2}", "--format=%H")
        return [line for line in rng.splitlines() if line]
    # Non-merge commit — single-commit slot.
    return [parents[0]]


def commit_subject(repo: Path, sha: str) -> str:
    return git(repo, "log", "-1", "--format=%s", sha)


def commit_timestamp(repo: Path, sha: str) -> dt.datetime:
    return parse_iso(git(repo, "log", "-1", "--format=%cI", sha))


def merge_stat(repo: Path, merge_commit: str) -> tuple[int, int, int]:
    """Files changed, lines added, lines removed in the merge."""
    parents = git(repo, "rev-list", "--parents", "-n", "1", merge_commit).split()
    base = parents[1] if len(parents) >= 3 else f"{merge_commit}^"
    numstat = git(repo, "diff", "--numstat", base, merge_commit)

    files = 0
    added = 0
    removed = 0
    for line in numstat.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        a, r, _path = parts[0], parts[1], parts[2]
        files += 1
        added += int(a) if a.isdigit() else 0
        removed += int(r) if r.isdigit() else 0
    return files, added, removed


def merge_touched_files(repo: Path, merge_commit: str) -> set[str]:
    parents = git(repo, "rev-list", "--parents", "-n", "1", merge_commit).split()
    base = parents[1] if len(parents) >= 3 else f"{merge_commit}^"
    diff = git(repo, "diff", "--name-only", base, merge_commit)
    return {line for line in diff.splitlines() if line}


def rework_window(repo: Path, merge_commit: str, slot_id: str) -> dict:
    merged_at = commit_timestamp(repo, merge_commit)
    deadline = merged_at + dt.timedelta(seconds=REWORK_WINDOW_SECONDS)
    touched = merge_touched_files(repo, merge_commit)

    log = git(
        repo,
        "log",
        f"{merge_commit}..HEAD",
        "--format=%H%x00%cI%x00%s",
    )

    commits_meta = []
    for line in log.splitlines():
        sha, iso, subject = line.split("\0", 2)
        ts = parse_iso(iso)
        if ts > deadline:
            continue
        commits_meta.append((sha, ts, subject))

    if not commits_meta:
        return {"count": 0, "commits": []}

    flagged = []
    seen = set()
    for sha, _ts, subject in commits_meta:
        # Skip housekeeping prefixes — docs, tests, chores referencing a
        # slot are completion rituals, not rework.
        if HOUSEKEEPING_PREFIX_RE.match(subject):
            continue
        rule = None
        if slot_id and slot_id.lower() in subject.lower():
            rule = "slot_id_in_subject"
        else:
            files_in_commit = set(
                git(repo, "show", "--name-only", "--format=", sha).splitlines()
            )
            if FIX_PREFIX_RE.match(subject) and touched & files_in_commit:
                rule = "file_overlap"
            elif FIX_PREFIX_RE.match(subject):
                rule = "fix_prefix_in_window"
        if rule and sha not in seen:
            seen.add(sha)
            flagged.append({"sha": sha[:12], "subject": subject, "rule": rule})

    return {"count": len(flagged), "commits": flagged}


def build_record(args: argparse.Namespace) -> dict:
    repo = Path(args.project).resolve()
    if not (repo / ".git").exists():
        raise SystemExit(f"ERROR: {repo} is not a git repository (no .git)")

    branch_commits = find_branch_commits(repo, args.merge_commit)
    feature_commits = [c for c in branch_commits if c != args.merge_commit]

    if branch_commits:
        first_ts = min(commit_timestamp(repo, c) for c in branch_commits)
    else:
        first_ts = commit_timestamp(repo, args.merge_commit)
    merged_ts = commit_timestamp(repo, args.merge_commit)
    wall_clock_hours = max(
        0.0, (merged_ts - first_ts).total_seconds() / 3600.0
    )

    files_changed, lines_added, lines_removed = merge_stat(repo, args.merge_commit)
    rework = rework_window(repo, args.merge_commit, args.slot_id)

    notes: list[dict] = []

    def note(field: str, status: str, reason: str) -> None:
        notes.append({"field": field, "status": status, "reason": reason})

    note("speed.wall_clock_hours", "measured", "first slot commit → merge commit timestamps")
    note("speed.iterations", "measured", "count of commits on the slot branch")
    note("size.*", "measured", "git diff --numstat on merge commit")
    note(
        "quality.rework_72h",
        "measured",
        "fix-prefix or slot_id matches in 72h after merge, file-overlap rule applied",
    )

    sentry_value: int | None
    if args.sentry_count is not None:
        sentry_value = args.sentry_count
        note("quality.sentry_incidents_7d", "measured", "operator-supplied via --sentry-count from MCP")
    else:
        sentry_value = None
        note(
            "quality.sentry_incidents_7d",
            "null_unavailable",
            "no --sentry-count supplied; run Sentry MCP query for release:<merge_commit> 7d window and rerun",
        )

    note(
        "quality.gate_pass_rate",
        "null_retrospective",
        "pre-E1 slots — gates did not emit envelopes; first measurable on post-E1 slots",
    )
    note(
        "cost.*",
        "null_retrospective",
        "Claude Code did not emit per-slot token telemetry pre-E2.1; forward-going only",
    )

    record = {
        "schema_version": SCHEMA_VERSION,
        "slot_id": args.slot_id,
        "slot_kind": args.slot_kind,
        "project": str(repo),
        "branch": args.branch,
        "merge_commit": args.merge_commit,
        "feature_commits": [c[:12] for c in feature_commits],
        "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "speed": {
            "wall_clock_hours": round(wall_clock_hours, 2),
            "iterations": max(1, len(branch_commits)),
            "first_commit_at": first_ts.astimezone(dt.timezone.utc).isoformat(timespec="seconds"),
            "merged_at": merged_ts.astimezone(dt.timezone.utc).isoformat(timespec="seconds"),
        },
        "size": {
            "files_changed": files_changed,
            "lines_added": lines_added,
            "lines_removed": lines_removed,
        },
        "quality": {
            "rework_72h": rework,
            "sentry_incidents_7d": sentry_value,
            "gate_pass_rate": None,
        },
        "cost": {
            "input_tokens": None,
            "output_tokens": None,
            "cache_read_tokens": None,
        },
        "measurable_notes": notes,
    }

    return record


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description="Capture a Phase 0 baseline record for a shipped slot.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--project", required=True, help="Path to the project repo")
    ap.add_argument("--slot-id", required=True, help="Slot identifier, e.g. 1M.5")
    ap.add_argument(
        "--slot-kind",
        required=True,
        choices=[
            "feature_incremental",
            "feature_multi_iteration",
            "bug_fix",
            "hotfix",
            "refactor",
            "docs",
        ],
    )
    ap.add_argument("--branch", required=True, help="Slot's feature branch name")
    ap.add_argument("--merge-commit", required=True, help="Merge commit SHA")
    ap.add_argument(
        "--sentry-count",
        type=int,
        default=None,
        help="New Sentry issues count tagged release:<merge_commit> in 7d window (manual from MCP)",
    )
    ap.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output JSON path. Default: stdout.",
    )

    args = ap.parse_args(argv[1:])

    record = build_record(args)
    payload = json.dumps(record, indent=2, sort_keys=True)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload + "\n", encoding="utf-8")
        print(f"wrote {args.output}")
    else:
        print(payload)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
