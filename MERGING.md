# Merging a stacked-PR batch into master

> Captured 2026-06-25 from the gate-layer merge (8 PRs, #1–#8). Several
> avoidable lifecycle traps cost a long recovery. This runbook is the
> beta-tester version of "don't repeat what we just learned."

The engine ships agents whose work often lands as **stacked PRs** —
a chain like `master ← #1 ← #5 ← #6 ← #8`. Squash-merging that chain
without discipline triggers two classes of GitHub-side trap that don't
exist for a single PR. This doc is the playbook.

---

## TL;DR (the rules, in priority order)

1. **No `--delete-branch` until the ENTIRE batch is merged.** Final
   cleanup is one explicit `git push origin --delete <branch>` per
   merged PR at the very end.
2. **Before each merge:** `gh pr list --state open --base <this-PR-branch>`
   — if any open PR uses it as a base, **retarget those to master
   FIRST**, then merge.
3. **Squash-merging changes commit SHAs.** Every stacked child carries
   the pre-squash SHAs in its history → GitHub shows them as `CONFLICTING`
   against master even though the content is identical. **Recovery:
   rebase --onto master `<old-base-SHA>` `<child-branch>`**, force-push
   with lease.
4. **Verify before destructive.** `--ff-only`, `--force-with-lease`,
   per-branch deletes (not batched). Same discipline as the merges
   themselves.
5. **`pe doctor` against a consuming project after every merge that
   touches `agents/`.** Doctor-green on the last merge proves the
   assembled agent set installs as a unit.

---

## The two GitHub-side lifecycle traps

### Trap 1 — `--delete-branch` cascades closures

When you squash-merge `#1` with `--delete-branch`, GitHub deletes
`#1`'s branch. **Every open PR that targeted that branch as its base
is auto-closed** — not merged, not orphaned, just CLOSED with
`mergedAt: null`. In our run, deleting `feat/e1-gate-envelope` on `#1`'s
merge silently closed both `#3` and `#5` because they shared that base.

**Why it's a trap:** the merge looks successful. The cascade closures
surface 5–10 minutes later when you try to look at `#3`/`#5`.

**The rule:** no `--delete-branch` mid-batch. Defer cleanup to the end,
when every PR in the batch is in master. **3 separate auto-close
incidents in our gate-layer merge** — every one of them caused by an
early `--delete-branch`. This is the single highest-value rule in this
file.

### Trap 2 — closed-PR-with-deleted-base can't be reopened

If trap 1 fires and a PR is closed because its base disappeared, you
**cannot `gh pr reopen` it**:

```
GraphQL: Could not open the pull request. (reopenPullRequest)
```

GitHub requires the base ref to exist before reopen. And you can't
retarget a closed PR either:

```
GraphQL: Cannot change the base branch of a closed pull request.
```

**Recovery — "temp-resurrect":** push the master HEAD up as a branch
with the deleted name. The PR can now be reopened and retargeted.
Delete the temp ref once all dependents are retargeted.

```bash
MASTER_SHA=$(git rev-parse origin/master)
git push origin "${MASTER_SHA}:refs/heads/<deleted-base-branch>"
gh pr reopen <N>
gh pr edit <N> --base master
# repeat for each affected PR
git push origin --delete <deleted-base-branch>
```

The temp ref's "wrong history" is irrelevant — nothing reads it.
`mergeable` is computed against master once retargeted. The temp's
only job is to satisfy GitHub's "base ref must exist to reopen" rule.

**Better:** don't trigger this in the first place. Rule 1.

---

## The squash-SHA divergence problem (real conflict, not a trap)

After squash-merging `#1`, master has one new commit (the squash)
whose **content is identical** to `#1`'s original commit chain but
whose **SHA is different**. Every PR stacked on `#1` still carries
the pre-squash commits in its history. When GitHub re-evaluates
`#3` against master, it sees two parallel SHA chains touching the
same files → `mergeable: CONFLICTING / mergeStateStatus: DIRTY`.

This is a **real conflict at the SHA level, not a stale flag**.
Sleep-and-repoll won't help. The fix is to rewrite `#3`'s history
to drop the now-duplicate commits.

### Recovery — `rebase --onto`

For each stacked descendant, identify the **last commit that's now in
master via squash** (call it `<old-base-SHA>`). Replay only the new
commits onto current master:

```bash
git fetch origin
git checkout -B <child-branch> origin/<child-branch>
git rebase --onto origin/master <old-base-SHA>
# Successfully rebased and updated ...   ← clean replay = safe to push
git push --force-with-lease origin <child-branch>
```

Then wait ~20 seconds (GitHub takes time to recompute mergeability
after a force-push) and verify all four fields are green:

```bash
gh pr view <N> --json state,baseRefName,mergeable,mergeStateStatus,isDraft
# Expect: OPEN / master / MERGEABLE / CLEAN
```

**Force-push safety:** `--force-with-lease` (not plain `--force`) refuses
the push if the remote has moved since your last fetch. Safe for draft
PRs without active review. If anyone has commented or reviewed, force-
push will orphan those threads — pause and surface first.

### Nested-stack divergence

If you have `#1 ← #5 ← #6 ← #8` and you've already squashed `#1` and
`#5` into master, `#6`'s history contains the original `#1` commits
**and** the original `#5` commits — both now squash-duplicated.

The rebase cut-point is **the last commit that's now in master via any
squash**. Drop everything up to and including that SHA, replay only
the genuinely-new commits.

```bash
# #6's history:  fd83 → 9d28 (#1) → 04a3 (#1) → bb5d (#5) → 5515 (#5) → 3bd6 (#5) → 8ac3 (#6)
#                                                                       ^^^^^
#                                                              last-squashed SHA
git rebase --onto origin/master 3bd6a0c
# Replays only 8ac3 (#6's actual work) on top of master.
```

For `#8` in our run, this dropped **7 squash-duplicated commits** and
replayed **1 new commit** — the narrowest possible change against the
final master state.

---

## The full sequence (template)

For each PR `N` in the batch, in dependency order (root first):

```bash
# 1. Pre-flight: dependents check
gh pr list --state open --base <N's-branch>
# If any open PR targets N's branch: retarget them to master first
# (gh pr edit M --base master) — this is the trap-1 prevention.

# 2. Ensure N is mergeable against current master
gh pr view N --json state,baseRefName,mergeable,mergeStateStatus
# If CONFLICTING and N was stacked on a now-squashed PR:
#   git fetch origin
#   git checkout -B <N-branch> origin/<N-branch>
#   git rebase --onto origin/master <old-base-SHA>
#   git push --force-with-lease origin <N-branch>
#   sleep 20  # let GitHub recompute
#   gh pr view N --json mergeable,mergeStateStatus  # must be CLEAN

# 3. Mark ready + merge
gh pr ready N
gh pr merge N --squash    # NO --delete-branch

# 4. Local sync
git checkout master
git pull --ff-only        # fail-loud if not a fast-forward

# 5. Consumer verification (after agents/ or scripts/pe changes)
pe install /path/to/consuming-project
pe doctor  /path/to/consuming-project
# Must report "No broken symlinks. Project install is healthy."
```

After the **last** PR in the batch lands and doctor is clean:

```bash
# Audit before destructive
git ls-remote origin 'refs/heads/feat/*'
gh pr list --state merged --limit 20

# Confirm each remaining feat/* branch matches a merged PR
# Then delete one-at-a-time (sequential, not batched — legible failures)
git push origin --delete feat/<branch-1>
git push origin --delete feat/<branch-2>
# ...
```

---

## Why the discipline pays off

The recovery for a single auto-close cascade — temp-resurrect, reopen,
retarget, rebase, force-push, settle, verify, merge — takes **roughly 10
minutes per affected PR**, and risks more mistakes during the unwind.
Skipping `--delete-branch` mid-batch costs nothing and prevents every
trap in this document.

The verification habit (`--ff-only`, `--force-with-lease`, per-branch
deletes, four-field gate check, `pe doctor` after each agent merge,
audit-before-destructive at cleanup) is what kept master clean
throughout the recovery in our gate-layer merge. The same discipline
applies to the cleanup itself — don't shortcut the audit just because
the merge work is done.

---

## When you've drifted (recovery checklist)

If you find yourself mid-batch with auto-closed PRs and confused state:

1. **Don't keep merging.** Stop and enumerate actual state:
   `gh pr list --state all --limit 30`,
   `git ls-remote origin 'refs/heads/*'`.
2. **Identify what closed and why.** `gh pr view <N> --json state,mergedAt,closedAt` — `mergedAt: null` + recent `closedAt` = auto-close, not human-close.
3. **Verify head branches still exist.** `git ls-remote origin refs/heads/<head>` — if yes, recovery is possible.
4. **Temp-resurrect each deleted base** (one at a time, not all at
   once — keeps the dependency graph legible).
5. **Reopen + retarget each affected PR to master** (one at a time).
6. **Rebase + force-push** each retargeted PR onto current master,
   dropping the squashed commits.
7. **Verify the four-field gate** before each subsequent merge.
8. **Audit before final cleanup.**

This is exactly the recovery sequence used in the gate-layer merge.
It works; it's just slower than not making the mistake in the first
place.
