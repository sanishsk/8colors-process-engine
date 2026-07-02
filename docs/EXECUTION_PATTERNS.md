# Execution patterns — worktrees, headless, background (v0.16.0 / P7.5)

> Concrete recipes for the three lanes in `OPERATOR_WORKFLOW_V3.md`
> §4. The V3 doc defines the *when*; this doc supplies the *how*.

## The three lanes (recap)

| Lane | When | Pattern |
|---|---|---|
| **Judgment** | New territory, taste, real risk | Interactive session, plan mode first, Fable/Opus, operator engaged the whole time |
| **Standard slot** | Known shape, brief exists | Interactive OR background; engine pipeline `brainstorm → brief → architect → plan → tdd → impl → simplify → review` |
| **Mechanical batch** | Deterministic verifier exists; N similar items | **Headless** `claude -p` per item OR one session driving a worktree fleet; gates decide; operator reviews the diff summary once |

Classify first. The lane picks the pattern; the pattern picks the model.

---

## Pattern 1 — Interactive judgment session

Nothing fancy. Open Claude Code in the project, enter Plan Mode
(Shift+Tab), let the model draft the plan, argue with it, then
execute. Applies to design direction, foundational refactors, RLS
policy flips, pricing, anything where being wrong hurts.

**When to force this lane:**
- The diff touches an auth boundary, a money path, or a tenancy fence.
- No brief exists AND the shape isn't obvious.
- You'll change your mind mid-turn and want to steer.

**Don't fall into this lane by default.** Interactive is expensive
per unit of work; reserve it for real judgment.

---

## Pattern 2 — Worktree fleet for parallel slots

`git worktree` gives you cheap parallel checkouts of the same repo.
The engine's install pattern (symlinks under `.claude/` + `.claude/
settings.json`) works identically in a worktree — no extra setup.

**When to use:**
- Two or more independent slots that can be worked in parallel
  without touching each other's files.
- Mechanical batch work you want to fan out (see Pattern 3).
- A refactor that you want to attempt AND keep the mainline session
  available for questions.

**Recipe:**

```bash
# Create worktree at /tmp/repo-slot-1M6 pointing at branch feature/1M6
git worktree add /tmp/repo-slot-1M6 -b feature/1M6

# Open Claude Code in the worktree (same repo config, isolated files)
cd /tmp/repo-slot-1M6
claude   # or /start-session

# When done:
cd -                                 # back to mainline
git worktree remove /tmp/repo-slot-1M6
```

**Practical notes:**
- Each worktree carries its own `.claude/settings.json` if you copy
  it in; or leave it and inherit `~/.claude/settings.json`.
- `pe doctor` and `pe install` work per-worktree — treat the
  worktree path as a project path.
- Do NOT run `pe install` from two worktrees against the same
  target simultaneously (races on the symlink writes).

---

## Pattern 3 — Headless batch (`claude -p`)

For N similar items where a deterministic gate settles correctness.

**Contract per item:**
1. Tight brief (≤10 lines, DoD included).
2. Reference the locked reference (e.g. `docs/reference/nav.png`,
   `docs/tokens.md`, or an already-migrated example).
3. Verifier: `pytest -x`, `pe gate parse`, `hooks/*` — whatever
   emits a PASS/FAIL envelope.
4. Failure policy: 1 retry, then queue for the interactive session.

**Recipe (shell wrapper):**

```bash
# One line per work-item (path + short brief tag)
cat > /tmp/batch.txt <<'EOF'
app/templates/nav/dashboard.html    tokens-v2
app/templates/nav/gallery.html      tokens-v2
app/templates/nav/settings.html     tokens-v2
EOF

# Fan out
while read -r path tag; do
  echo "=== $path ($tag) ==="
  claude -p \
    "Migrate $path to tokens v2 (see docs/reference/tokens-v2.md).
     Rules: no inline style=; only tokens from allowlist; keep semantics.
     DoD: hooks/design-lint.sh returns 0 on this file." \
    --allowedTools Read,Edit,Bash \
    --permission-mode acceptEdits
  hooks/design-lint.sh || echo "  ✗ failed — queue for interactive"
done < /tmp/batch.txt
```

**Operator engagement per batch:**
- Write the brief once.
- Review the batch report once (all diffs + gate verdicts).
- Interactive session handles ONLY the queued failures.

**Model choice for headless batches:**
- Prefer the cheapest tier that passes the verifier.
- Haiku for mechanical text-transforms with a strong gate.
- Sonnet for anything that needs the tiniest bit of judgment.
- Opus/Fable never enters the headless lane — that's the interactive
  budget.

---

## Pattern 4 — Background agents

When the pipeline includes async work that shouldn't block the
operator (research, market scan, retro, weekly-plan generation).

**When to use:**
- The `researcher` agent for weekly OSS/MCP scans (already wired via
  RHYTHM.md Monday cadence).
- The `ceo` agent for the Friday retro (already wired via launchd).
- Long-running `pe collect --window 7` before a heavy retro session
  (already the retro-agent Step 0).

**Recipe (launchd — macOS):**

Use the engine's `pe launchd <project>` for the standard weekly
retro — it installs both the runner and a heartbeat watchdog. For a
custom background agent, model the plist on
`templates/launchd/com.ORG_TAG.ceo.weekly.plist.template`.

**Recipe (cron — Linux):**

```
# Monday 07:55 — refresh dev-log digest before the interactive slot
55 7 * * 1 cd /path/to/project && $HOME/.local/bin/pe collect
```

**Recipe (ad-hoc — any platform):**

```bash
# In one shell, kick off an async researcher pass
nohup claude -p "/research-search 'auth-boundary hardening 2026'" > /tmp/research.log 2>&1 &

# Meanwhile, continue your interactive session in another window
```

---

## Choosing the pattern (decision tree)

```
Does the task have a deterministic verifier (test, hook, gate)?
├── NO  → Interactive judgment session (Pattern 1)
└── YES ─┬── Is it >1 similar item?
         ├── NO  → Standard slot (interactive OR one background agent)
         └── YES ─┬── Do the items touch each other?
                  ├── YES → Serial worktree fleet (Pattern 2 + 3)
                  └── NO  → Parallel worktree fleet OR headless batch (Pattern 3)
```

---

## Cross-refs

- **`docs/OPERATOR_WORKFLOW_V3.md` §4** — the spec these recipes implement.
- **`docs/RHYTHM.md`** — the weekly cadence + wiring points.
- **`agents/researcher.md`** — the async pass template.
- **`hooks/*.sh`** — the deterministic verifiers that make headless
  batches safe.
- **`commands/new-feature.md`** — the standard-slot chain with the
  `/simplify` stage inserted.

## Common failure modes to avoid

- **Interactive-by-default for mechanical work** — burns operator
  attention on things a gate could settle. If the verifier exists,
  use it.
- **Headless without a verifier** — you don't know if it worked.
  Either build the verifier first or run interactive.
- **One giant worktree for a batch** — batching in one worktree
  is fine but you lose parallelism. Fan out for real speedup.
- **Background agents without a heartbeat** — silent failure is
  worse than no automation. `pe launchd` ships a heartbeat
  watchdog; roll your own if you skip that.
