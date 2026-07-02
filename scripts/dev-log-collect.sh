#!/usr/bin/env bash
# dev-log-collect — portable git-derived daily digest collector.
#
# Runs against the project you invoke it in (or --project <path>).
# Writes docs/dev-log/daily/<YYYY-MM-DD>.json with metrics that the
# retrospective-agent consumes — commit velocity, churn, gate-verdict
# distribution, top files. Zero Claude tokens.
#
# This is the P7.3 collector: portable, git-only, wired by every adopter
# via cron/launchd/systemd so the Friday retro always has a week of
# real data. Replaces the 8CStudio-specific collector that was ambient
# and went stale after 2026-W21.
#
# USAGE
#   dev-log-collect.sh [--project <path>] [--date YYYY-MM-DD] [--window <days>]
#   dev-log-collect.sh                            # today, cwd, 1-day window
#   dev-log-collect.sh --date 2026-07-01          # backfill one day
#   dev-log-collect.sh --window 7                 # 7-day rollup (weekly)
#
# OUTPUTS
#   docs/dev-log/daily/<YYYY-MM-DD>.json   — machine-readable digest
#   docs/dev-log/daily/<YYYY-MM-DD>.md      — pre-formatted text digest
#
# EXIT CODES
#   0 — digest written
#   2 — not a git repo / invalid args
#   3 — git command failed

set -euo pipefail

PROJECT=""
DATE=""
WINDOW=1

while [ $# -gt 0 ]; do
    case "$1" in
        --project) PROJECT="$2"; shift 2 ;;
        --date)    DATE="$2"; shift 2 ;;
        --window)  WINDOW="$2"; shift 2 ;;
        -h|--help)
            sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$PROJECT" ]; then
    PROJECT="$(pwd)"
fi

if [ ! -d "$PROJECT/.git" ]; then
    echo "ERROR: $PROJECT is not a git repository (no .git/)" >&2
    exit 2
fi

if [ -z "$DATE" ]; then
    DATE="$(date +%Y-%m-%d)"
fi

# Validate DATE format
if ! echo "$DATE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    echo "ERROR: --date must be YYYY-MM-DD (got: $DATE)" >&2
    exit 2
fi

# Validate WINDOW is a positive integer
if ! echo "$WINDOW" | grep -qE '^[1-9][0-9]*$'; then
    echo "ERROR: --window must be a positive integer (got: $WINDOW)" >&2
    exit 2
fi

cd "$PROJECT"

# Compute the since-date: DATE minus WINDOW-1 days at 00:00; until end of DATE.
if date -v-1d '+%Y-%m-%d' >/dev/null 2>&1; then
    # BSD date (macOS)
    OFFSET=$((WINDOW - 1))
    SINCE_DATE="$(date -j -v-"${OFFSET}"d -f %Y-%m-%d "$DATE" +%Y-%m-%d)"
else
    # GNU date (Linux)
    SINCE_DATE="$(date -d "$DATE -$((WINDOW - 1)) days" +%Y-%m-%d)"
fi
SINCE="${SINCE_DATE}T00:00:00"
UNTIL="${DATE}T23:59:59"

OUT_DIR="docs/dev-log/daily"
mkdir -p "$OUT_DIR"
JSON_OUT="$OUT_DIR/${DATE}.json"
MD_OUT="$OUT_DIR/${DATE}.md"

# ─── gather ─────────────────────────────────────────────────────────
# 1. commit count + basic list
COMMITS_RAW="$(git log --since="$SINCE" --until="$UNTIL" \
    --pretty=format:'%H%x09%an%x09%s' 2>/dev/null || true)"
COMMIT_COUNT="$(printf '%s\n' "$COMMITS_RAW" | grep -c . || true)"

# 2. numstat for the window
NUMSTAT_RAW="$(git log --since="$SINCE" --until="$UNTIL" --numstat --pretty=format:'---%H' 2>/dev/null || true)"

# 3. gate verdicts (v0.10.0+) — .claude/gates/*.json
GATES_DIR=".claude/gates"

# 4. authors
AUTHORS_RAW="$(git log --since="$SINCE" --until="$UNTIL" --pretty=format:'%an' 2>/dev/null || true)"

# ─── format via python ─────────────────────────────────────────────
"${PE_PYTHON:-python3}" - "$JSON_OUT" "$MD_OUT" "$DATE" "$WINDOW" "$SINCE_DATE" "$COMMITS_RAW" "$NUMSTAT_RAW" "$AUTHORS_RAW" "$GATES_DIR" <<'PY'
import sys, json, os, glob, datetime as dt
from collections import Counter, defaultdict

json_out, md_out, date, window, since_date, commits_raw, numstat_raw, authors_raw, gates_dir = sys.argv[1:10]
window = int(window)

commits = []
for line in commits_raw.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t", 2)
    if len(parts) == 3:
        sha, author, subject = parts
        commits.append({"sha": sha[:12], "author": author, "subject": subject})

# Parse numstat: blocks separated by ---<sha>
churn = defaultdict(lambda: {"insertions": 0, "deletions": 0, "edits": 0})
current_sha = None
total_ins = 0
total_del = 0
for line in numstat_raw.splitlines():
    if line.startswith("---"):
        current_sha = line[3:]
        continue
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) < 3:
        continue
    ins_s, del_s, path = parts[0], parts[1], parts[2]
    try:
        ins = int(ins_s)
        dels = int(del_s)
    except ValueError:
        ins = 0
        dels = 0
    churn[path]["insertions"] += ins
    churn[path]["deletions"] += dels
    churn[path]["edits"] += 1
    total_ins += ins
    total_del += dels

top_churn = sorted(
    ({"path": p, **d} for p, d in churn.items()),
    key=lambda x: x["edits"], reverse=True,
)[:15]

authors = Counter(a for a in authors_raw.splitlines() if a.strip())

# Gate verdicts
gate_verdicts = Counter()
gate_files_scanned = 0
if os.path.isdir(gates_dir):
    for path in glob.glob(os.path.join(gates_dir, "*.json")):
        try:
            mtime = dt.datetime.fromtimestamp(os.path.getmtime(path)).date().isoformat()
        except OSError:
            continue
        if mtime < since_date or mtime > date:
            continue
        gate_files_scanned += 1
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception:
            continue
        v = (data.get("verdict") or data.get("status") or "").upper()
        if v:
            gate_verdicts[v] += 1

digest = {
    "date": date,
    "window_days": window,
    "since_date": since_date,
    "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
    "generator": "pe dev-log-collect (git-derived)",
    "commit_count": len(commits),
    "insertions_total": total_ins,
    "deletions_total": total_del,
    "net_lines": total_ins - total_del,
    "authors": dict(authors),
    "top_churn": top_churn,
    "commits": commits,
    "gate_verdicts": dict(gate_verdicts),
    "gate_files_scanned": gate_files_scanned,
}

with open(json_out, "w") as f:
    json.dump(digest, f, indent=2, ensure_ascii=False)

# Human-readable markdown digest
lines = []
lines.append(f"# Dev-log digest — {date} (window: {window} day{'s' if window > 1 else ''})")
lines.append("")
lines.append(f"_Generated: {digest['generated_at']} by `pe dev-log-collect` (git-derived, zero Claude tokens)_")
lines.append("")
lines.append("## Summary")
lines.append("")
lines.append(f"- **Commits:** {digest['commit_count']}")
lines.append(f"- **Lines:** +{total_ins} / -{total_del} (net {total_ins - total_del:+d})")
lines.append(f"- **Authors:** {', '.join(f'{a} ({n})' for a, n in authors.most_common()) or '_(none)_'}")
if gate_verdicts:
    lines.append(f"- **Gate verdicts:** {', '.join(f'{v}={n}' for v, n in gate_verdicts.most_common())} ({gate_files_scanned} files scanned)")
else:
    lines.append(f"- **Gate verdicts:** _(none in window — {gate_files_scanned} files scanned in `{gates_dir}/`)_")
lines.append("")
if top_churn:
    lines.append("## Top churn (files edited most often)")
    lines.append("")
    lines.append("| Path | Edits | +Ins | -Del |")
    lines.append("|---|---:|---:|---:|")
    for row in top_churn:
        lines.append(f"| `{row['path']}` | {row['edits']} | +{row['insertions']} | -{row['deletions']} |")
    lines.append("")
if commits:
    lines.append("## Commits")
    lines.append("")
    for c in commits:
        lines.append(f"- `{c['sha']}` {c['author']} — {c['subject']}")

with open(md_out, "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"✓ {json_out}")
print(f"✓ {md_out}")
print(f"  commits={digest['commit_count']} churn_files={len(top_churn)} gates={gate_files_scanned}")
PY
