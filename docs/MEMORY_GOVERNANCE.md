# Memory Governance (L3)

> Shipped in v0.24.0. Extends the operator's global memory rules
> (`~/.claude/CLAUDE.md`) with **inspect / verify / delete tooling** —
> not a replacement for Claude Code's auto-memory system.

## Why

Auto-memory is a real feature the operator uses daily: every project
directory has a companion `~/.claude/projects/<slug>/memory/` where
Claude Code writes long-lived facts (user preferences, feedback,
project state, external references). The 2026 memory literature is
emphatic that the hard part isn't *learning* — it's **governance**:
inspect / correct / delete, retention + deletion policy, staleness
handling. Deferring these is "an expensive architectural retrofit."

Before v0.24.0 the engine had no tooling for any of this: an entry
written six months ago sat in `MEMORY.md` forever, silently getting
recalled as fact, and the operator had to `rm` files by hand and
manually re-edit the index.

## What's shipped

### CLI (`pe memory <sub>`)

- **`ls`** — list every entry with type, age-in-days, staleness flag,
  description. Optional `--type <t>` filter and `--stale` filter for
  the pruning workflow. Also warns if `MEMORY.md` and the on-disk
  files have drifted (files without index lines, or index lines
  pointing at missing files).

- **`show <name>`** — print one entry's full frontmatter + body.

- **`rm <name> [--yes]`** — delete the file AND remove its line from
  `MEMORY.md`. Prompts unless `--yes` is passed.

- **`verify <name>`** — stamp `metadata.last_verified = today` on an
  entry the operator has re-checked. Resets the staleness clock
  without touching the body. This is the *endorse* path — cheaper
  than editing, honest about the fact that the fact still applies.

- **`stale [--older-than-days N]`** — the pruning workflow. Lists
  entries past their per-type freshness window (or past N days if
  `--older-than-days` is set). Each row includes the two next
  actions: `pe memory verify <name>` (still true) or
  `pe memory rm <name>` (obsolete).

### Schema additions (all optional, backward-compatible)

Existing memory entries keep working unchanged. Three new fields can
be added to `metadata:`:

- **`freshness_days: <int>`** — TTL override. If absent, defaults per
  type:
  - `user` — 90 days (identities change slowly)
  - `feedback` — 60 days (preferences drift)
  - `project` — 14 days (state changes fast)
  - `reference` — 180 days (pointers rarely rot)
  - (unknown) — 30 days

- **`last_verified: <YYYY-MM-DD>`** — updated automatically by
  `pe memory verify`. When present, staleness is measured from this
  date rather than the file mtime.

- **`scope: user | agent | session | org`** — advisory tag for
  multi-scope memory. Not enforced at read/write today (Claude Code's
  own memory system decides who can write); shipping the schema field
  now so future access-control work has a stable data model.

### Staleness rule

An entry is stale iff:

    now - max(mtime, last_verified) >= (freshness_days or default_by_type)

That is: last-touched-date is either the file's mtime or the
`last_verified` stamp, whichever is later. Adding new prose to the
body (which bumps mtime) counts as touching; `pe memory verify`
counts as touching without changing content.

## The pruning workflow

Weekly (or before a fresh retro):

```bash
pe memory stale                    # what's past its window?
pe memory show <name>              # inspect one candidate
pe memory verify <name>            # still true → endorse
pe memory rm <name>                # obsolete → delete
```

This is designed to run in <5 minutes and produces a clean
`MEMORY.md` index — smaller context per future session.

## What this DOESN'T do

- **Access control is not enforced.** `scope: agent` is a tag, not a
  gate. Claude Code's auto-memory system decides who can write; this
  tooling only inspects the result. Enforcement waits for Claude Code
  to expose a write hook.

- **Auto-writes stay with Claude Code.** The engine's global CLAUDE.md
  memory rules describe when and how Claude Code writes entries. L3
  is not a rewrite of that; it's the missing *inspection* side.

- **No memory sync between projects.** Each project's memory is
  isolated. That's Claude Code's model; L3 respects it.

## Related items

- **A7** (cross-session memory learning) — the *learning* side. Not
  shipped yet; L3 governance ships first so A7 doesn't accumulate
  ungoverned state that becomes an "expensive retrofit."

- **S4** (LLM/agent threats) — poisoned memory is one of the threats.
  L3 makes memory auditable (list, inspect, delete); the *detection*
  side is future work.

- **A3** (incident synthesizer) — a stale-memory-caused incident is
  the kind of thing `pe incident propose` can turn into a gate. The
  loop is: L3 makes memory visible → operator catches a drift →
  A3 converts it into a permanent check.

## Migration for existing entries

Nothing to do. Every existing entry (which has no `freshness_days`,
`last_verified`, or `scope`) is treated exactly as before, with the
per-type default freshness window applied automatically. Operators
who want tighter control can add the fields when convenient.
