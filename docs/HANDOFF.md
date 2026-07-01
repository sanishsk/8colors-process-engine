# Session Handoff

> **Rolling doc — rewritten at each session end.** Read this at the top
> of your next session (after `/start-session`) to orient in <2 minutes.
>
> **Last updated:** 2026-06-30 (engine v0.8.0 shipped + P2 Stage A complete
> + both adopters synced + BETA_TESTER_BRIEF refreshed)

---

## One-line state

Engine v0.8.0 is on `origin/master`. Both adopters (8CStudio, Origyn)
are synced and validated. Everything pushed. No dangling state.

## Where to start

```
/start-session
```

in the engine repo — it'll orient from CLAUDE.md + memory + recent git.
Then read this doc.

## The only queued task

**Task #8 — P3 auto-update suggestion surfacer.** **DO NOT BUILD YET.**
Waits on ≥1 concrete recurring "we keep noticing X across sessions"
pattern from operator/adopter feedback. If a candidate pattern surfaces
(e.g. in beta tester feedback on GitHub issues, or in your own retros),
that's the signal to promote it.

## Signals that promote parked work back to active

| Signal | Promotes | Where to check |
|---|---|---|
| Recurring "we keep noticing X" pattern | Task #8 (P3) | Session feedback / beta tester GitHub issues |
| Any of 4 triggers in `docs/COUPLING_MAP.md` §7 fires | Phase 4 / Stage B | Re-run the coupling survey first, then decide |
| Beta severity-calibration feedback arrives | Gate agent rubric tuning | `BETA_TESTER_BRIEF.md` explicitly asks about this — watch GitHub issues + DMs |
| 3rd product adopts the engine | Re-run coupling survey for it; possibly formalize L0 knowledge-pack | `docs/CAPABILITY_CATALOG.md` §3 |

## What is explicitly OFF the runway (do NOT propose building these)

- **Phase 4 dependency-aware DAG scheduler** — parked; both apps cluster
  cleanly per `docs/COUPLING_MAP.md` §5. Re-open only if §7 triggers.
- **Engine self-modification / auto-commit** — never, by design. One bad
  auto-change would propagate to every adopter via `pe sync`.
- **Auto-tier-routing** — deferred until cost telemetry (E2.1) exists.

## Docs to read first (in priority order)

1. `docs/BACKLOG.md` — Priority overview + P1-adjacent items
2. `docs/COUPLING_MAP.md` §5 (session-split guide) + §7 (re-eval triggers)
3. `CHANGELOG.md` — what shipped in v0.8.0
4. `docs/CAPABILITY_CATALOG.md` §3 — "If you need X" pointers (avoid
   re-investigating tools already evaluated)
5. `docs/launch/BETA_TESTER_BRIEF.md` — what's being shared with adopters

## Gotchas / things to remember

- **Origyn's real path** is `/Users/sanishsasikumar/Documents/Origyn`
  (NOT under `8Colors/`). This mistake was made twice this session — do
  not repeat.
- **8CStudio's `org_tag` is `8colors`** (matches its
  `com.8colors.ceo.*.plist` LaunchAgents already installed).
- **8CStudio-side coupling rule:** work in ONE cluster at a time — pick
  from Production Pipeline / Money / Reporting per COUPLING_MAP §5.
- **Origyn-side coupling rule:** Client + Trainer MUST share a session.
  The STRONG border edge `trainer → Lead` cannot be split without
  reproducing exactly the tangle we've seen.
- **Never commit `.process-engine.yaml.template` placeholders**
  (`acme` / `Acme Corp` / `/Users/you/code/acme`) — replace with real
  project values BEFORE the commit whenever `pe install` writes a new
  yaml in a fresh project.
- **`pe sync --dry-run` is the safe default** for investigating an
  adopter's state — never run non-dry-run without checking dry-run first.

## Common operations

### Onboarding a new project

```bash
pe install [--subset gate-only|core|full] /path/to/new/project
# edit .process-engine.yaml (org_tag + display_name + root)
# then, for macOS weekly retro:
pe launchd /path/to/new/project
```

### Adopter reports a sync issue

```bash
pe sync --dry-run /path/to/their/project   # always dry-run first
pe doctor /path/to/their/project           # get freshness summary + shadowed count
```

### Pulling engine updates into all known adopters

```bash
cd /path/to/8colors-process-engine && git pull
pe sync /Users/sanishsasikumar/Documents/8Colors/8CStudio    # 8CStudio
pe sync /Users/sanishsasikumar/Documents/Origyn              # Origyn
```

## What shipped in the last session (2026-06-30)

7 commits on the engine + 2 commits on 8CStudio:

| Commit | Repo | What |
|---|---|---|
| `07465e3` | engine | BACKLOG reorganized into P1/P2/P3 priorities |
| `3c15b3d` | engine | 0.8.0 — VERSION bump + shadow string fix + `pe doctor` extension |
| `ea3ab63` | engine | 0.8.0 — INSTALL.md PATH check |
| `5e40316` | engine | Finding #6 backlog note |
| `2367e56` | engine | 0.8.0 — `pe install --subset` preset |
| `9ce0fc3` | engine | 0.8.0 — `pe sync` diff-before-clobber + smoke test |
| `8352265` | engine | 0.8.0 release date sealed |
| `a3f7765` | engine | P2 Stage A — coupling map + Phase 4 parked |
| `9ec6cb5` | engine | Finding #6 fix — research_index.py SIM102 |
| `de16dd5` | engine | BETA_TESTER_BRIEF refreshed for v0.8.0 |
| `245a5e9` | 8CStudio | track `scripts/research_index.py` engine symlink |
| `c617a81` | 8CStudio | add engine `.process-engine.yaml` + `.gitignore` updates |

## Session close pattern

At the end of each session, update this doc before ending. Specifically:
- Bump the "Last updated" date
- Update "One-line state"
- Move any newly-shipped items into "What shipped in the last session"
- Add any new gotchas discovered
- If the queued task changed, update "The only queued task" section

This doc is the memory the next session needs. Keep it lean and current.
