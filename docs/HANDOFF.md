# Session Handoff

> **Rolling doc — rewritten at each session end.** Read this at the top
> of your next session (after `/start-session`) to orient in <2 minutes.
>
> **Last updated:** 2026-07-02 late (P0 audit bundle committed as
> `3b43e03`; awaiting push + adopter sync; IMPROVEMENT_PLAN.md is the
> active backlog going forward)

---

## One-line state

Engine v0.9.1 committed locally (`3b43e03`), **unpushed**. Contains
all 12 P0 items from the 4-track audit + `docs/IMPROVEMENT_PLAN.md`
as the new active roadmap. 52/52 tests pass. Adopters (8CStudio,
Origyn) still on v0.9.0 until pushed + synced.

## 🔴 RESUME HERE — first action next session

1. **Push:** `git push origin master` — publishes `3b43e03` (v0.9.1)
   + this HANDOFF refresh.
2. **Propagate to adopters:**

   ```bash
   pe sync --dry-run /Users/sanishsasikumar/Documents/8Colors/8CStudio
   pe sync --dry-run /Users/sanishsasikumar/Documents/Origyn
   # then non-dry-run per HANDOFF Common operations
   ```

   Expect "0 changes" — install.sh changes propagate on the next
   `pe install` at the adopter, not via sync (documented gotcha).
   `pe doctor` should still report healthy on v0.9.1.

3. **Read `docs/IMPROVEMENT_PLAN.md`** — 4-track audit consolidated
   into ~45 items P0→P4 with file:line + severity + effort + fix.
   This is the canonical roadmap now (supersedes BACKLOG.md's
   carry-forward section).

4. **Next active work:** P1 — deterministic enforcement of headline
   promises (see three-findings section below). Do NOT start P3.x
   (domain layer, native plugin) before P1 is in.

## What the P0 bundle fixes (12 items — condensed)

| Fix | Why it matters |
|---|---|
| `pe sync` crash at `scripts/pe:414` | `diff` exit 1 under `set -euo pipefail` killed sync on every customized file; overwrite-confirm prompt was unreachable dead code. Old test passed because of the crash — test hardened to assert exit 0. |
| Router fail-safe hole | Schema-valid FAIL + `failure_class:"none"` routed to `continue` even with CRITICAL findings — **falsified the graduation signoff**. Now caught at 3 layers (schema conditional + `pe_gate` coherence check + `route()` guard) + regression test. |
| Stacking pre-push hook | Silently blocked every push with no slot IDs. Fixed. |
| `pe install` fork preservation | No longer clobbers operator-forked files. Preserves + reports + points at `pe sync` for review. |
| Interpreter hardening | Stock macOS `python3` is 3.9 (no `tomllib`). `pe` now probes for 3.11+, orchestrator exits with actionable message, subprocesses use `sys.executable`. Orchestrator test suite **couldn't run on your machine** before this — now 33/33. |
| Plus: `pe eject` bash-3.2 crash · BSD-sed doctor launchd bug · invalid-subset zero-install trap · breaker sidecar silent-corruption / non-atomic writes · gate cross-check ordering + retry bugs · brief-writer/architect missing Bash tool for MANDATORY Step 0 · version drift (0.7.0 badges vs 0.9.0, "9 agents" vs 15) |

**Test totals:** 52 pass (9 sync + 10 install-reconcile + 33 orchestrator).
All schema fixtures exit expected codes.

## Three findings that reshape priorities (from the audit)

These are P1–P3 in IMPROVEMENT_PLAN.md — do NOT start until P0 is
committed + adopters synced, but keep them in view when planning.

1. **Headline promises have no deterministic enforcement.**
   Mandatory review + TDD are prompt-hope backed by self-attested git
   trailers that aren't installed by default. There are NO Claude Code
   hooks anywhere in the engine.
   **→ P1: `hooks.json` commit gate, test-run hook, secrets scanner,
   `/new-feature` chaining skill.** This is what makes the promises real.
2. **The domain layer is missing entirely.**
   100% of the engine governs *how you work*; 0% is *what SaaS apps
   are made of*.
   **→ P3.1 / P3.2: `pe new` scaffolding + extract tenancy / billing /
   credentials modules that already exist in 8CStudio, Origyn, and
   invoice-system.** Each ships with its tests + reviewing agent.
   Highest-leverage move once P0/P1 are in.
3. **Symlink distribution should become a native Claude Code plugin
   before the beta widens.**
   Two releases fought pathologies the plugin marketplace solved;
   symlinks also have no version pinning.
   **→ P3.3: convert to native plugin.**

## Session rituals — start and end

The engine ships two skills — `/start-session` and `/end-session` — that
are THE rituals. Learn these and everything else falls into place.

### Case A — brand new project (first-time onboarding)

One-time setup per project, then it enters the daily flow (Case B).

```bash
# 1. Install the engine into the project
pe install /path/to/new/project
# — or with a leaner agent set —
pe install --subset gate-only /path/to/new/project    # 5 gate agents
pe install --subset core /path/to/new/project         # 8 agents
pe install --subset full /path/to/new/project         # 15 agents (default)

# 2. Edit the auto-created config with REAL values
#    (never commit template placeholders — acme / Acme Corp / /Users/you/…)
$EDITOR /path/to/new/project/.process-engine.yaml
# Set: project.org_tag, project.display_name, project.root

# 3. (Optional, macOS) Wire the Friday weekly retro
pe launchd /path/to/new/project

# 4. Verify install is healthy
pe doctor /path/to/new/project
```

Then continue with Case B every day. Create/grow `CLAUDE.md` +
`MEMORY.md` in the project root as work happens — the session skills
read them.

### Case B — continuing work on a project (daily flow)

**Start of session:**

1. Open Claude Code in the project directory.
2. Type `/start-session` — the skill reads CLAUDE.md, MEMORY, weekly
   plan, git state; surfaces active focus + stale plans + first-task
   recommendation and **STOPS waiting for you.** Never starts work
   autonomously.
3. If you recently pulled engine changes, run
   `pe sync --dry-run /path/to/project` to preview any updates the
   engine wants to propagate. Then `pe sync` (no `--dry-run`) if you
   want them applied. Diff-before-clobber protects your customizations.
4. Decide the task. Work.

**End of session:**

1. Type `/end-session` — the skill runs the close-out: git status, sync
   check (ahead/behind origin), MEMORY banner updates (surfaces diffs —
   **never auto-writes**), deliverables ledger (commits + hashes),
   unresolved items, next-session pickup pointer.
2. Review its output. Apply MEMORY updates it surfaces if you agree
   (you commit them manually).
3. Commit + push if you have work to ship (the skill never pushes for
   you).

Both skills are project-agnostic — they discover files via fallback
chains. Tune per-project via `.claude/session.yaml`.

### Case C — working ON the engine repo itself (this session's kind)

Same shape as Case B, plus one thing:

**Start:** `/start-session` → then read this doc (`docs/HANDOFF.md`)
for state carried over from the last engine session.

**End:** before typing `/end-session`, **update this doc**:

- Bump "Last updated" date
- Refresh "One-line state"
- Roll shipped commits into "What shipped in the last session"
- Add any new gotchas discovered

Then `/end-session` and commit the updated HANDOFF.

### Rule of thumb

| Situation | Ritual |
|---|---|
| First time on a project | `pe install` + edit yaml + `/start-session` |
| Daily start | `/start-session` |
| After engine has new upstream commits | `pe sync --dry-run` → `pe sync` |
| Daily end | `/end-session`, then commit + push if applicable |
| Engine-repo session end | Update this doc **before** `/end-session` |
| Something's off | `pe doctor /path/to/project` — engine version + freshness + shadowed count |

### Why this works

- `/start-session` does the "where was I?" work — no wasted re-orient time.
- `/end-session` prevents "wait, what did I actually do today?" via the
  ledger + surfacing what to remember.
- `pe sync --dry-run` is the safe default — see what would change before
  anything changes.
- Neither skill auto-commits, auto-edits memory, or auto-pushes. You stay
  in control of what lands.
- This doc is the engine-repo's memory anchor. Small enough to read at
  the top of every session.

Full detail on both skills lives in `skills/start-session/` and
`skills/end-session/`. The `BETA_TESTER_BRIEF.md` §"What to try first"
walks through a 30-minute first session touching all the pieces.

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
- **uvx-hosted MCPs may need an explicit `--python` pin.** As of
  2026-07-02, `semgrep-mcp` (and any MCP that transitively imports
  `google.protobuf`) crashes under Python 3.14 with
  `TypeError: Metaclasses with custom tp_new are not supported`. Fix:
  register the MCP with `uvx --python 3.12 <tool>` (see the semgrep
  entry in `~/.claude.json` for the exact shape). Symptom in the wild:
  `claude mcp list` shows `✗ Failed to connect`.
- **Install-time engine improvements do NOT propagate via `pe sync`.**
  `pe sync` re-points symlinks; it never re-runs `install.sh`. So
  changes to `scripts/install.sh` (e.g. E1.c.2 reconciling) reach an
  adopter the next time the adopter runs `pe install`, not on the next
  `pe sync`. Don't be surprised when a `pe sync` post-`install.sh`-change
  reports "0 changes" — that's correct.

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

## What shipped in the last session (2026-07-02)

3 engine commits + 2 config edits at Origyn (yaml placeholders +
Serena MCP) + 1 user-global MCP fix (Semgrep Python 3.12 pin):

| Commit / change | Repo / scope | What |
|---|---|---|
| `3b43e03` | engine | 0.9.1 — P0 audit bundle (12 fixes: sync crash, router fail-safe, install clobber guard, interpreter + bash-3.2 portability, plus 7 more) + `docs/IMPROVEMENT_PLAN.md` as new active roadmap. 52/52 tests pass. **Not pushed yet.** |
| `c229b8a` | engine | docs(HANDOFF): roll in v0.9.0 + adopter health + uvx-python-pin gotcha |
| `f689895` | engine | 0.9.0 — reconciling `pe install` (silent broken-symlink cleanup), smoke test, BACKLOG housekeeping sweep, TROUBLESHOOTING §4 refresh. Closes #10. |
| `.process-engine.yaml` | Origyn | replaced template placeholders (`acme` / `Acme Corp`) with real values (`origyn` / `Origyn` / real root) |
| `.mcp.json` | Origyn | added Serena MCP scoped to Origyn (was missing) |
| `~/.claude.json` | user-global | Semgrep MCP re-registered with `uvx --python 3.12` — fixes `✗ Failed to connect` under Python 3.14 |

## What shipped in the session before (2026-06-30)

Retained for context — 10 commits on the engine + 2 on 8CStudio:

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
