// tests/parallel_fix_harness.mjs — execute workflows/parallel-fix.js for real,
// with the runtime's hooks stubbed, and assert what it decides.
//
// Same approach as gate_review_harness.mjs: load the actual file, inject fake
// agent()/pipeline()/phase()/log(), drive the real control flow. A declarative
// fixture would test a description of the script.
//
// What this workflow is FOR is the reason it needs a harness. It fans work out
// to agents that each report on their own success, in worktrees nobody else
// can see, and then decides what may be merged. Every interesting failure is
// an agent's self-report being believed:
//
//   * `agent-dies`      — a null result silently becoming "3 of 5 fixed"
//   * `no-red`          — a test written after the fix, which proves nothing
//   * `suite-red`       — a green claim contradicted by the suite output
//   * `verifier-says-no`— the fixer's word taken over the reviewer's
//   * `unreviewed`      — a commit that no verifier ever looked at
//
// and one thing no agent could report, because it is a property of the SET:
//
//   * `collision`       — two branches, each correct alone, editing one file.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = readFileSync(join(ROOT, 'workflows', 'parallel-fix.js'), 'utf8')
const BODY = SRC.replace(/^export const meta/m, 'const meta')

// A fix report that passes every floor. Scenarios below spoil one field each,
// so a test that goes red names exactly which floor stopped holding.
function goodFix(name, files = [`src/${name}.py`, `tests/test_${name}.py`]) {
  return {
    issue: name,
    committed: true,
    red_verified: true,
    red_evidence: `AssertionError: expected ${name} to be handled`,
    suite_passed: true,
    suite_output: '58 passed, 0 failed',
    files_touched: files,
    summary: `fixed ${name}`,
  }
}

const LANDABLE = {
  fixes_the_issue: true,
  scope_is_clean: true,
  test_would_catch_regression: true,
  verdict: 'LANDABLE',
  reasoning: 'diff is minimal and the test fails against the pre-fix code',
}

async function runWorkflow(issues, respond) {
  const calls = []
  const logs = []

  const agent = async (prompt, opts = {}) => {
    const label = opts.label || '(unlabelled)'
    calls.push({ label, phase: opts.phase, isolation: opts.isolation, prompt })
    return respond(opts.phase, label, prompt)
  }
  // The real pipeline runs each item through every stage independently and
  // drops an item to null if a stage throws. Reproduced, so a scenario that
  // throws is handled the way the runtime would handle it.
  const pipeline = async (items, ...stages) =>
    Promise.all(items.map(async (item, i) => {
      let v = item
      try {
        for (const s of stages) v = await s(v, item, i)
        return v
      } catch { return null }
    }))
  const parallel = thunks => Promise.all(thunks.map(t => t()))
  const phase = () => {}
  const log = m => logs.push(m)

  const fn = new Function(
    'agent', 'parallel', 'pipeline', 'phase', 'log', 'args',
    `return (async () => {\n${BODY}\n})()`,
  )
  const result = await fn(agent, parallel, pipeline, phase, log, issues)
  return { result, calls, logs }
}

let pass = 0, fail = 0
const ok = m => { console.log(`  ✓ ${m}`); pass++ }
const bad = m => { console.log(`  ✗ ${m}`); fail++ }
const blockedFor = (r, title) => r.blocked.find(b => b.issue === title)

console.log('parallel_fix_harness')

// ─── nothing to do ───────────────────────────────────────────────────────
{
  const { result, calls } = await runWorkflow([], () => null)
  result.landable.length === 0 && calls.length === 0
    ? ok('no issues → no agents spawned')
    : bad(`empty input spawned ${calls.length} agents`)
}

// ─── the happy path, and the isolation that makes it safe ────────────────
{
  const issues = ['fix the trailer hook', 'fix the size budget']
  const { result, calls } = await runWorkflow(issues, (phase, label) => {
    if (phase === 'Fix') return goodFix(label.includes('trailer') ? 'trailer' : 'budget')
    return LANDABLE
  })

  result.landable.length === 2 && result.blocked.length === 0
    ? ok('two clean fixes → both landable')
    : bad(`clean run gave ${result.landable.length} landable, ${result.blocked.length} blocked`)

  const fixCalls = calls.filter(c => c.phase === 'Fix')
  fixCalls.length === 2 && fixCalls.every(c => c.isolation === 'worktree')
    ? ok('every fix agent runs in its own worktree')
    : bad('a fix agent ran without worktree isolation — two agents can clobber one tree')

  const branches = result.landable.map(e => e.branch)
  new Set(branches).size === 2
    ? ok('branch names are distinct — the script names them, not the agents')
    : bad(`branch collision: ${branches.join(', ')}`)

  result.merged === false && result.merge_order.length === 2
    ? ok('nothing is merged; a merge order is returned instead')
    : bad('the workflow merged something, or returned no order')

  fixCalls.every(c => /do not merge|Do not merge/.test(c.prompt))
    ? ok('fix agents are told not to merge')
    : bad('a fix agent was not told to stay off other branches')
}

// ─── the five ways a self-report gets believed ───────────────────────────
{
  const issues = ['a', 'b', 'c', 'd', 'e']
  const { result } = await runWorkflow(issues, (phase, label) => {
    const which = label.slice(-1)
    if (phase === 'Fix') {
      if (which === 'a') return null                                        // died
      if (which === 'b') return { ...goodFix('b'), red_verified: false }     // test written after
      if (which === 'c') return { ...goodFix('c'), suite_passed: false, suite_output: '57 passed, 1 failed' }
      return goodFix(which)
    }
    if (which === 'd') return { ...LANDABLE, verdict: 'NEEDS_WORK', reasoning: 'patches the caller, not the cause' }
    if (which === 'e') return null                                          // verifier died
    return LANDABLE
  })

  result.landable.length === 0
    ? ok('none of the five spoiled runs is landable')
    : bad(`landable: ${result.landable.map(e => e.issue).join(', ')}`)
  result.blocked.length === 5
    ? ok('all five are reported by name, not dropped')
    : bad(`only ${result.blocked.length} of 5 issues were accounted for`)

  const a = blockedFor(result, 'a')
  a && /did not return/.test(a.reason)
    ? ok('a dead fix agent is an UNFIXED issue, not a missing one')
    : bad('a null result vanished from the report')

  const b = blockedFor(result, 'b')
  b && /never seen to fail/.test(b.reason)
    ? ok('a test never seen RED blocks the branch')
    : bad(`red_verified=false was let through: ${b && b.reason}`)

  const c = blockedFor(result, 'c')
  c && /57 passed, 1 failed/.test(c.reason)
    ? ok("a red suite blocks, and the run's own output is quoted back")
    : bad(`suite_passed=false was let through: ${c && c.reason}`)

  const d = blockedFor(result, 'd')
  d && /patches the caller/.test(d.reason)
    ? ok("the verifier's NEEDS_WORK overrides the fixer's own account")
    : bad(`a NEEDS_WORK verdict was ignored: ${d && d.reason}`)

  const e = blockedFor(result, 'e')
  e && /unreviewed/.test(e.reason)
    ? ok('a commit no verifier returned on is blocked as unreviewed')
    : bad(`an unreviewed branch was treated as landable: ${e && e.reason}`)
}

// A blocked fix must not be verified-then-forgotten: check the verifier is
// not even asked about a branch with no commit, and that this is not silent.
{
  const { result, calls } = await runWorkflow(['x'], phase =>
    phase === 'Fix'
      ? { ...goodFix('x'), committed: false, blocked_reason: 'could not reproduce the bug' }
      : LANDABLE)
  calls.filter(c => c.phase === 'Verify').length === 0
    ? ok('no verifier is spawned for a branch that has no commit')
    : bad('a verifier was paid to review a branch that does not exist')
  const x = blockedFor(result, 'x')
  x && /could not reproduce/.test(x.reason)
    ? ok("the fixer's own blocked_reason is carried through verbatim")
    : bad(`blocked_reason was dropped: ${x && x.reason}`)
}

// ─── the thing no single agent can see ───────────────────────────────────
{
  const shared = 'hooks/size-budget.sh'
  const { result, logs } = await runWorkflow(['p', 'q', 'r'], (phase, label) => {
    const which = label.slice(-1)
    if (phase === 'Fix') {
      if (which === 'r') return goodFix('r', ['docs/RHYTHM.md'])
      return goodFix(which, [shared, `tests/test_${which}.sh`])
    }
    return LANDABLE
  })

  result.landable.length === 3
    ? ok('colliding branches are still landable individually')
    : bad(`expected 3 landable, got ${result.landable.length}`)

  const c = result.collisions.find(x => x.file === shared)
  c && c.branches.length === 2
    ? ok('two branches editing one file are reported as a collision')
    : bad('the shared file was not flagged — this is the merge that breaks')

  result.collisions.length === 1
    ? ok('the file only one branch touched is not flagged')
    : bad(`flagged ${result.collisions.length} collisions; expected 1`)

  const order = result.merge_order
  order[0].startsWith('fix/r')
    ? ok('the independent branch merges first')
    : bad(`merge order leads with a colliding branch: ${order.join(', ')}`)
  order.length === 3
    ? ok('every landable branch appears in the merge order exactly once')
    : bad(`merge order has ${order.length} entries for 3 branches`)

  logs.some(l => l.includes(shared))
    ? ok('the colliding file is named in the log, not just counted')
    : bad('the operator is told a collision exists but not where')

  // Bound to a name: a regex literal opening a line after one that ends in
  // `)` is parsed as division.
  const sequenced = /one at a time|reconcile/.test(result.next_step)
  sequenced
    ? ok('next_step says to merge collisions one at a time')
    : bad(`next_step gives no sequencing guidance: ${result.next_step}`)
}

// ─── merged is false on every path, including the empty one ──────────────
{
  for (const [name, issues, respond] of [
    ['empty', [], () => null],
    ['all dead', ['z'], () => null],
    ['all clean', ['z'], p => (p === 'Fix' ? goodFix('z') : LANDABLE)],
  ]) {
    const { result } = await runWorkflow(issues, respond)
    result.merged === false
      ? ok(`merged=false on the "${name}" path`)
      : bad(`the workflow reported a merge on the "${name}" path`)
  }
}

console.log(`  ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
