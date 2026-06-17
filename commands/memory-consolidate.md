---
description: Invokes the memory-consolidator agent to archive historical RESUME blocks and slim MEMORY.md. Run quarterly or when MEMORY.md exceeds 25 KB.
---

# /memory-consolidate

Triggers the `memory-consolidator` agent to:

1. Read the auto-memory file (`~/.claude/projects/<key>/memory/MEMORY.md`)
2. Identify historical RESUME HERE / PRIOR RESUME / Prior session blocks
3. Propose an archive file under `memory/archive/YYYY-Q<N>-<topic>.md`
4. Propose a slimmed MEMORY.md (target <20 KB)
5. Surface the diff for operator approval before writing

The agent NEVER writes autonomously. Every change is surfaced first.

## When to run

- **Quarterly** — first Monday of each quarter (Mar / Jun / Sep / Dec)
- **On-demand** — when MEMORY.md > 25 KB or > 250 lines (`wc -c` /
  `wc -l` on the memory file)
- **After phase boundaries** — major pivots produce dense resume blocks

## What gets kept

- ⚠ banners (verbatim — never paraphrased)
- Single most recent RESUME HERE
- Current 📦 Slot status
- 🔴 OVERDUE OBLIGATIONS
- Standard Rules feedback pointer index
- Reference pointers

## What gets archived

- "PRIOR RESUME" / "Prior session" blocks
- Slot status sections whose all rows are checked off
- Reference sections duplicating docs/ content
- Old "Project State" snapshots

Archives go to `memory/archive/`; nothing is deleted.

## Example

```bash
> /memory-consolidate
```

Agent responds with:

1. Proposed archive file path + content
2. Proposed new MEMORY.md content
3. Size delta report (e.g. "MEMORY.md: 44 KB → 11 KB, -76%")
4. Awaiting operator approval

Operator says "looks good" → agent writes both files.
