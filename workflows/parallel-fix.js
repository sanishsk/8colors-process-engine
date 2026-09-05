export const meta = {
  name: 'parallel-fix',
  description: 'Fix N independent issues concurrently, each in its own git worktree, on its own branch. Detects branches that touched the same files, refuses to call anything landable that did not verify a test RED and finish the suite green — and merges nothing.',
  phases: [
    { title: 'Fix', detail: 'one agent per issue, isolated in its own worktree' },
    { title: 'Verify', detail: 'an independent agent re-checks each branch' },
  ],
}

// ─────────────────────────────────────────────────────────────────────────
// The engine had one parallel mechanism: /gate-review, which reviews ONE
// diff with three agents. There was nothing for the opposite shape — many
// issues, one repo — and that is the shape a backlog actually has.
//
// Doing it by hand is what goes wrong. Two agents editing one working tree
// interleave their edits; the second one's `git add -A` sweeps up the
// first's half-finished work; a suite run by one is invalidated by the
// other mid-run. So each fix gets its own git worktree — a separate
// checkout sharing the object database — and can neither see nor clobber
// its siblings' files.
//
// Isolation stops them corrupting each other's WORK. It does not stop them
// producing two fixes that conflict, because each is correct alone and
// wrong together: two branches that both edit hooks/size-budget.sh will
// merge cleanly and still break, or will collide at merge time and leave
// someone reconciling two agents' reasoning after the fact. That is a
// property of the SET of results, which no single agent can see, so the
// script computes it: overlapping files are reported as a sequencing
// requirement before anyone merges anything.
//
// Three floors, all applied by the script because an agent reporting on
// its own work is the thing being guarded against:
//
//   1. A null result is an UNFIXED issue, never a dropped one. The
//      .filter(Boolean) idiom would report "3 of 5 fixed" as a clean run.
//   2. Landable requires the agent to have watched its test FAIL before
//      the fix, and the suite to be green after. A test written after the
//      fix demonstrates nothing; the engine's own standard is RED first.
//   3. NOTHING IS MERGED. This returns branches and a merge order. A
//      workflow cannot pause for a human, and merging N agents' work into
//      a shared branch unattended is precisely where "we messed something
//      up" comes from. The operator merges, in the order given.
// ─────────────────────────────────────────────────────────────────────────

// Accepts a bare list of task strings, a list of {id?, title?, task}
// objects, or {issues: [...]} — whichever the caller found natural.
function normalise(input) {
  const raw = Array.isArray(input) ? input : (input && input.issues) || []
  return raw.map((item, i) => {
    const o = typeof item === 'string' ? { task: item } : item || {}
    const n = i + 1
    // Falls through to the task text so a bare list of strings still yields
    // branch names an operator can read. `fix/issue-1-1` names nothing.
    const slug = (o.id || o.title || o.task || `issue-${n}`)
      .toString()
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 40) || `issue-${n}`
    return {
      n,
      title: o.title || o.task || `issue ${n}`,
      task: o.task || o.title || '',
      // The script names the branch. Left to the agents, two would pick the
      // same one and the second push would fail or, worse, land on the first.
      branch: `fix/${slug}-${n}`,
    }
  })
}

const issues = normalise(args)

if (issues.length === 0) {
  log('No issues passed. Call with args: ["fix X", "fix Y"] or [{title, task}, ...].')
  // Same shape as the main return. An early exit with its own field names is
  // a second contract for the caller to get right.
  return {
    merged: false,
    landable: [],
    blocked: [],
    collisions: [],
    merge_order: [],
    next_step: 'Nothing to do — pass the issues as args.',
  }
}

// Each of these is a full agent doing real work in its own checkout; the
// runtime caps concurrency on its own, so the list length is the operator's
// call, not something to silently truncate here.
log(`${issues.length} issue(s), one worktree each. Nothing will be merged.`)

const FIX_SCHEMA = {
  type: 'object',
  required: ['issue', 'committed', 'red_verified', 'suite_passed', 'files_touched', 'summary'],
  properties: {
    issue: { type: 'string' },
    committed: { type: 'boolean', description: 'true only if a commit exists on the branch' },
    red_verified: { type: 'boolean', description: 'true only if you SAW the new test fail before the fix' },
    red_evidence: { type: 'string', maxLength: 600, description: 'the failing assertion line, verbatim' },
    suite_passed: { type: 'boolean' },
    suite_output: { type: 'string', maxLength: 600, description: 'the final summary line of the run, verbatim' },
    files_touched: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string', maxLength: 1000 },
    blocked_reason: { type: 'string', maxLength: 600, description: 'set when the fix could not be completed' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object',
  required: ['fixes_the_issue', 'scope_is_clean', 'test_would_catch_regression', 'verdict', 'reasoning'],
  properties: {
    fixes_the_issue: { type: 'boolean' },
    scope_is_clean: { type: 'boolean', description: 'no unrelated edits rode along' },
    test_would_catch_regression: { type: 'boolean', description: 'revert the fix, keep the test — does it fail?' },
    verdict: { type: 'string', enum: ['LANDABLE', 'NEEDS_WORK'] },
    reasoning: { type: 'string', maxLength: 1000 },
  },
}

// pipeline, not parallel: a fix is verified the moment it is done, rather
// than every verifier waiting for the slowest fix. The collision check is
// the only thing that needs the whole set, and it runs after, in the script.
const results = await pipeline(
  issues,

  issue =>
    agent(
      `Fix ONE issue in this repository, alone, on your own branch.\n\n` +
      `Issue: ${issue.title}\n\n${issue.task}\n\n` +
      `You are in a git worktree of your own. Other agents are fixing other ` +
      `issues in their own worktrees at the same time. Touch nothing outside ` +
      `what this issue requires — you cannot see their work and they cannot ` +
      `see yours, so an unrelated "while I'm here" edit becomes a merge ` +
      `conflict nobody can attribute.\n\n` +
      `Steps, in order:\n` +
      `1. \`git checkout -b ${issue.branch}\`\n` +
      `2. Read the code the issue names before changing any of it.\n` +
      `3. Write a test that fails FOR THIS ISSUE. Run it. Watch it fail, and ` +
      `keep the failing assertion line — a test written after the fix proves ` +
      `only that the fix is self-consistent. If you cannot make it fail, say ` +
      `so in blocked_reason and set red_verified false. Do not invent ` +
      `evidence.\n` +
      `4. Make the smallest change that turns it green.\n` +
      `5. Run the full suite: \`tests/run-all.sh\`. Report its final summary ` +
      `line verbatim.\n` +
      `6. Commit to ${issue.branch}. Do not merge, do not rebase onto the ` +
      `base branch, do not touch any other branch.\n` +
      `7. Report every file you changed, including the test.\n\n` +
      `If the suite is red at the end, report suite_passed false with the ` +
      `real output. A truthful blocked report is worth more than a green ` +
      `claim that does not survive review — the next phase re-runs this ` +
      `against your branch.`,
      {
        label: `fix: ${issue.title}`.slice(0, 60),
        phase: 'Fix',
        isolation: 'worktree',
        schema: FIX_SCHEMA,
      },
    ).then(r => ({ issue, fix: r })),

  ({ issue, fix }) => {
    // Nothing to verify if the fixer never landed a commit. Skipping the
    // verifier here is not a shortcut — it is the difference between "we
    // checked and it is not landable" and "we never checked".
    if (!fix || !fix.committed) return { issue, fix, verify: null }
    return agent(
      `Review one branch adversarially. Assume it is wrong until the diff ` +
      `shows otherwise.\n\n` +
      `Branch: ${issue.branch}\n` +
      `Issue it claims to fix: ${issue.title}\n\n${issue.task}\n\n` +
      `The author reported: ${fix.summary}\n\n` +
      `Read the diff with \`git diff HEAD...${issue.branch}\` and the log ` +
      `with \`git log --oneline HEAD..${issue.branch}\`. Then answer:\n` +
      `1. Does the change actually fix the issue as stated, or does it fix a ` +
      `symptom and leave the cause? Check the other callers of anything it ` +
      `touched.\n` +
      `2. Is the scope clean — is there an edit in this diff that the issue ` +
      `did not require?\n` +
      `3. The decisive one: would the new test CATCH this regression? Read ` +
      `the test against the pre-fix code and say whether it fails there. A ` +
      `test that passes either way is not a test.\n\n` +
      `Do not edit anything and do not merge. NEEDS_WORK unless all three ` +
      `hold.`,
      {
        label: `verify: ${issue.title}`.slice(0, 60),
        phase: 'Verify',
        schema: VERIFY_SCHEMA,
      },
    ).then(v => ({ issue, fix, verify: v }))
  },
)

// ─── the floor ───────────────────────────────────────────────────────────
// A pipeline stage that throws drops its item to null, and a fix agent that
// died returns null from the first stage. Either way the issue is UNFIXED,
// and it says so by name.
const landable = []
const blocked = []

for (let i = 0; i < issues.length; i++) {
  const issue = issues[i]
  const r = results[i]

  if (!r || !r.fix) {
    blocked.push({ issue: issue.title, branch: null, reason: 'the fix agent did not return — skipped, or it died' })
    continue
  }

  const { fix, verify } = r
  const why = []
  if (!fix.committed) why.push(fix.blocked_reason || 'nothing was committed')
  if (!fix.red_verified) why.push('the test was never seen to fail before the fix')
  if (!fix.suite_passed) why.push(`the suite did not pass: ${fix.suite_output || 'no output reported'}`)
  if (fix.committed && !verify) why.push('the verifier did not return — this branch is unreviewed')
  if (verify && verify.verdict !== 'LANDABLE') why.push(verify.reasoning)

  const entry = {
    issue: issue.title,
    branch: issue.branch,
    files: fix.files_touched || [],
    summary: fix.summary,
    verify: verify || null,
  }

  if (why.length === 0) landable.push(entry)
  else blocked.push({ ...entry, reason: why.join('; ') })
}

// ─── collisions ──────────────────────────────────────────────────────────
// The one thing no individual agent could have known. Two branches that
// edit the same file are each correct alone; merged in either order the
// second one rebases onto a file it never saw.
const owners = new Map()
for (const e of landable) {
  for (const f of e.files) {
    if (!owners.has(f)) owners.set(f, [])
    owners.get(f).push(e.branch)
  }
}
const collisions = [...owners.entries()]
  .filter(([, branches]) => branches.length > 1)
  .map(([file, branches]) => ({ file, branches }))

if (collisions.length > 0) {
  log(`${collisions.length} file(s) edited by more than one branch — these must be merged one at a time, re-running the suite between.`)
  for (const c of collisions) log(`  ${c.file}: ${c.branches.join(', ')}`)
}

// Branches that collide go last, so the independent ones land first and a
// conflict is reconciled against a tree that already has them.
const colliding = new Set(collisions.flatMap(c => c.branches))
const mergeOrder = [
  ...landable.filter(e => !colliding.has(e.branch)).map(e => e.branch),
  ...landable.filter(e => colliding.has(e.branch)).map(e => e.branch),
]

log(`${landable.length} landable, ${blocked.length} blocked, ${collisions.length} collision(s). Nothing merged — that is yours.`)

return {
  merged: false,
  landable,
  blocked,
  collisions,
  merge_order: mergeOrder,
  next_step: collisions.length
    ? 'Merge in merge_order, running tests/run-all.sh between each. The last branches share files — expect to reconcile.'
    : 'These branches touch disjoint files. Merge in any order; still run tests/run-all.sh after the last one.',
}
