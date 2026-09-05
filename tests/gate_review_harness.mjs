// tests/gate_review_harness.mjs — execute workflows/gate-review.js for real,
// with the runtime's four hooks stubbed, and assert what it decides.
//
// The alternative was declarative fixtures listing gate outcomes and expected
// verdicts. That tests a description of the script. This tests the script:
// it loads the actual file, injects fake agent()/parallel()/phase()/log(),
// and drives the real control flow.
//
// The scenario that matters is `gate-dies`. agent() returns null when an
// agent is skipped or dies, and the documented .filter(Boolean) idiom FAILS
// OPEN here — drop a dead security-reviewer, see two clean envelopes, report
// PASS, and a payment-path change is committed having never been
// security-reviewed.
//
// There were two more, `aggregator-lies` and `aggregator-dies`, covering an
// aggregating agent that ignored the floor or never answered. Both are gone
// because the agent is: aggregation is deterministic and now runs in the
// script, so there is nothing left to lie or die. What replaced them is
// `duplicate-findings`, which tests the merge logic that inherited the job —
// the failure mode moved from "an agent dropped a finding" to "the dedupe
// key is too coarse and dropped one", and that needs its own scenario.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = readFileSync(join(ROOT, 'workflows', 'gate-review.js'), 'utf8')

// The script is written for a runtime that supplies hooks as globals, allows
// top-level await, and treats a top-level `return` as the workflow's result.
// Wrapping the body in an async function reproduces all three. `export` is
// the only token that cannot survive the wrap.
const BODY = SRC.replace(/^export const meta/m, 'const meta')

function envelope(gate, findings = [], verdict = 'PASS') {
  return {
    schema_version: '1.0.0',
    gate_name: gate,
    verdict,
    failure_class: verdict === 'FAIL' ? 'worker_quality' : 'none',
    findings,
    model_used: 'test-model',
    timestamp: '2026-09-04T12:00:00Z',
  }
}

// Run the real script against a scripted set of agent responses.
// `respond(label, prompt)` returns what that agent call should resolve to;
// returning null models a skipped or dead agent.
async function runWorkflow(respond) {
  const calls = []
  const phases = []
  const logs = []

  const agent = async (prompt, opts = {}) => {
    const label = opts.label || '(unlabelled)'
    calls.push({ label, phase: opts.phase, hasSchema: Boolean(opts.schema), prompt })
    return respond(label, prompt)
  }
  const parallel = thunks => Promise.all(thunks.map(t => t()))
  const pipeline = async () => { throw new Error('pipeline() not stubbed') }
  const phase = title => phases.push(title)
  const log = message => logs.push(message)
  const args = undefined

  const fn = new Function(
    'agent', 'parallel', 'pipeline', 'phase', 'log', 'args',
    `return (async () => {\n${BODY}\n})()`,
  )
  const result = await fn(agent, parallel, pipeline, phase, log, args)
  return { result, calls, phases, logs }
}

// ─── scenarios ───────────────────────────────────────────────────────────

const DIFF_SHA = '1111111111111111111111111111111111111111'
const STAGED = {
  files: ['modules/billing/charges.py', 'models/charge.py'],
  diff_sha: DIFF_SHA,
}
const RECORD_OK = {
  recorded: true,
  exit_code: 0,
  recorder_output: 'gate: recorded .claude/gates/last-gate.json (verdict=PASS, diff_sha=abc)',
}

const HIGH = { severity: 'HIGH', rule: 'missing-tenant-filter', message: 'query is not tenant-scoped' }
const CRITICAL = { severity: 'CRITICAL', rule: 'fstring-sql', message: 'f-string interpolated into execute()' }

const scenarios = {
  'nothing-staged': label =>
    label === 'staged diff' ? { files: [] } : null,

  'all-clean': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'record') return RECORD_OK
    return envelope(label)
  },

  'one-high': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'database-reviewer') return envelope(label, [HIGH], 'WARN')
    if (label === 'record') return RECORD_OK
    return envelope(label)
  },

  'one-critical': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'security-reviewer') return envelope(label, [CRITICAL], 'FAIL')
    if (label === 'record') return RECORD_OK
    return envelope(label)
  },

  // THE ONE. security-reviewer dies; the other two are clean.
  'gate-dies': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'security-reviewer') return null
    if (label === 'record') return RECORD_OK
    return envelope(label)
  },

  'all-gates-die': label =>
    label === 'staged diff' ? STAGED : null,

  // Aggregation used to be an agent asked to "deduplicate findings that
  // describe the same problem at the same file and line ... do not drop a
  // finding just because it resembles another at a different location".
  // That instruction is now a dedupe key, and a key is exactly the kind of
  // thing that is one field too coarse and silently eats a real finding.
  //
  // Three gates, deliberately overlapping:
  //   * security and database both flag missing-tenant-filter at
  //     charges.py:42 — one problem, seen twice, and database rates it
  //     CRITICAL where security says HIGH. One finding must survive, at
  //     CRITICAL: dedupe must not be able to downgrade.
  //   * security also flags the SAME RULE at charges.py:88. Different line,
  //     different problem, must survive on its own.
  //   * code-reviewer flags a different rule at the same file and line as
  //     the first. Same location, different problem, must also survive.
  'duplicate-findings': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'record') return RECORD_OK
    const dup = s => ({ severity: s, rule: 'missing-tenant-filter', message: `seen by a gate as ${s}`, file: 'charges.py', line: 42 })
    if (label === 'security-reviewer') {
      return envelope(label, [
        dup('HIGH'),
        { severity: 'HIGH', rule: 'missing-tenant-filter', message: 'a second, distinct occurrence', file: 'charges.py', line: 88 },
      ], 'WARN')
    }
    if (label === 'database-reviewer') return envelope(label, [dup('CRITICAL')], 'FAIL')
    if (label === 'code-reviewer') {
      return envelope(label, [
        { severity: 'LOW', rule: 'unused-import', message: 'different rule, same line', file: 'charges.py', line: 42 },
      ], 'WARN')
    }
    return envelope(label)
  },

  // What actually happened on the first live run against a real repo:
  // three gates answered, twelve genuine findings, a correct WARN — and
  // `pe gate parse` refused the whole envelope because four messages ran
  // past the canonical schema's 500-char cap, so nothing was recorded and
  // the commit gate saw no verdict at all.
  'overlong-message': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'record') return RECORD_OK
    if (label === 'code-reviewer') {
      return envelope(label, [
        { severity: 'HIGH', rule: 'long-message', message: 'x'.repeat(578) },
        { severity: 'LOW', rule: 'long-suggestion', message: 'short', suggestion: 'y'.repeat(1400) },
      ], 'WARN')
    }
    return envelope(label)
  },

  'record-fails': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'record') return {
      recorded: false,
      exit_code: 4,
      recorder_output: 'gate: NOT recorded — .claude/gates/last-gate.json left unchanged.',
    }
    return envelope(label)
  },
}

// ─── assertions ──────────────────────────────────────────────────────────

let pass = 0, fail = 0
const ok = m => { console.log(`  ✓ ${m}`); pass++ }
const bad = m => { console.log(`  ✗ ${m}`); fail++ }
const has = (r, rule) => (r.findings || []).some(f => f.rule === rule)

const run = name => runWorkflow(scenarios[name])

console.log('gate_review_harness')

{
  const { result, calls } = await run('nothing-staged')
  result.verdict === 'PASS' && result.recorded === false
    ? ok('nothing staged → PASS, nothing recorded')
    : bad(`nothing staged → ${JSON.stringify(result)}`)
  calls.length === 1
    ? ok('nothing staged → no gate agents spawned')
    : bad(`nothing staged spawned ${calls.length} agents`)
}

{
  const { result, calls } = await run('all-clean')
  result.verdict === 'PASS'
    ? ok('three clean envelopes → PASS')
    : bad(`three clean envelopes → ${result.verdict}`)
  result.recorded === true
    ? ok('PASS is recorded where the commit hook reads it')
    : bad('PASS was not recorded')
  const gates = calls.filter(c => c.phase === 'Review').map(c => c.label).sort()
  JSON.stringify(gates) === JSON.stringify(['code-reviewer', 'database-reviewer', 'security-reviewer'])
    ? ok('all three gates ran, every time')
    : bad(`gates that ran: ${gates.join(', ')}`)
  calls.filter(c => c.phase === 'Review').every(c => c.hasSchema)
    ? ok('every gate call is schema-bound at the call site')
    : bad('a gate call was made without a schema')
}

{
  const { result } = await run('one-high')
  result.verdict === 'WARN'
    ? ok('one HIGH finding → WARN')
    : bad(`one HIGH finding → ${result.verdict}`)
}

{
  const { result } = await run('one-critical')
  result.verdict === 'FAIL' && result.envelope.failure_class === 'worker_quality'
    ? ok('one CRITICAL finding → FAIL with failure_class=worker_quality')
    : bad(`one CRITICAL → ${result.verdict}/${result.envelope.failure_class}`)
}

{
  const { result } = await run('gate-dies')
  result.verdict !== 'PASS'
    ? ok(`a dead gate cannot yield PASS (got ${result.verdict})`)
    : bad('FAIL-OPEN: a dead security-reviewer still produced PASS')
  has(result.envelope, 'gate-did-not-run')
    ? ok('the dead gate is named in the findings')
    : bad('the dead gate left no trace in the envelope')
  result.gates_missing.includes('security-reviewer')
    ? ok('gates_missing names security-reviewer')
    : bad(`gates_missing = ${JSON.stringify(result.gates_missing)}`)
  result.gates_ran.length === 2
    ? ok('gates_ran reports the two that answered')
    : bad(`gates_ran = ${JSON.stringify(result.gates_ran)}`)
}

{
  const { result } = await run('all-gates-die')
  result.verdict === 'FAIL' && result.recorded === false
    ? ok('every gate dead → FAIL, nothing recorded')
    : bad(`every gate dead → ${JSON.stringify(result.verdict)}`)
}

// ── aggregation is the script's job now; prove it does it, and does it alone ──
{
  const { result, calls } = await run('duplicate-findings')
  const f = result.envelope.findings

  calls.every(c => c.phase !== 'Aggregate')
    ? ok('no agent is spawned to aggregate — the script merges')
    : bad('an agent ran in the Aggregate phase; the round-trip is back')

  const at42 = f.filter(x => x.rule === 'missing-tenant-filter' && x.line === 42)
  at42.length === 1
    ? ok('the same rule at the same line from two gates collapses to one finding')
    : bad(`same rule+line survived ${at42.length} times`)
  at42[0] && at42[0].severity === 'CRITICAL'
    ? ok('the surviving duplicate keeps the HIGHER severity, not the first seen')
    : bad(`dedupe downgraded a CRITICAL to ${at42[0] && at42[0].severity}`)

  f.some(x => x.rule === 'missing-tenant-filter' && x.line === 88)
    ? ok('the same rule at a DIFFERENT line survives — not a duplicate')
    : bad('dedupe swallowed a second, genuine occurrence of the same rule')
  f.some(x => x.rule === 'unused-import' && x.line === 42)
    ? ok('a different rule at the same line survives')
    : bad('dedupe keyed on location alone and ate an unrelated finding')

  f.length === 3
    ? ok('four gate findings, one true duplicate → three survive')
    : bad(`expected 3 findings after dedupe, got ${f.length}`)
  result.verdict === 'FAIL'
    ? ok('the verdict follows the merged findings (CRITICAL → FAIL)')
    : bad(`merged CRITICAL did not produce FAIL: ${result.verdict}`)

  f.map(x => x.severity).join() === 'CRITICAL,HIGH,LOW'
    ? ok('findings are ordered by severity')
    : bad(`findings out of order: ${f.map(x => x.severity).join()}`)

  // The clock. The script has no Date; the envelope must still be dated.
  result.envelope.timestamp === '2026-09-04T12:00:00Z'
    ? ok('the merged envelope is dated from the gates, not from a clock the script lacks')
    : bad(`merged timestamp = ${result.envelope.timestamp}`)
}

// The diff the gates reviewed must be the diff the record points at.
{
  const { calls } = await run('all-clean')
  const record = calls.find(c => c.label === 'record')
  record && record.prompt.includes(`--diff-sha ${DIFF_SHA}`)
    ? ok('Record is told the sha sampled before the review, not asked to recompute one')
    : bad('the Record prompt does not carry the sha collected up front')
  const recomputes = /git hash-object/.test(record ? record.prompt : '')
  recomputes
    ? bad('Record still recomputes the sha — it can drift from what was reviewed')
    : ok('Record does not recompute the sha')
}

{
  const { result } = await run('overlong-message')
  const msgs = result.envelope.findings.map(f => f.message)
  msgs.every(m => m.length <= 500)
    ? ok('an over-long finding message is clamped to the schema cap')
    : bad(`a message survived at ${Math.max(...msgs.map(m => m.length))} chars — pe gate parse will refuse the envelope`)
  const sugg = result.envelope.findings.map(f => f.suggestion).filter(Boolean)
  sugg.every(s => s.length <= 1000)
    ? ok('an over-long suggestion is clamped too')
    : bad(`a suggestion survived at ${Math.max(...sugg.map(s => s.length))} chars`)
  msgs.some(m => m.endsWith('…[truncated]'))
    ? ok('truncation is marked in the text, not silent')
    : bad('a message was shortened with nothing to say so')
  result.verdict === 'WARN' && result.envelope.findings.length === 2
    ? ok('clamping changes the text and nothing else — verdict and findings survive')
    : bad(`clamping altered the verdict or dropped findings: ${result.verdict}, ${result.envelope.findings.length}`)
}

{
  const { result } = await run('record-fails')
  result.recorded === false
    ? ok('a failed record is reported as unrecorded, not as a pass')
    : bad('the workflow claimed to record a verdict it did not record')
  // Bound to a name rather than starting a line with `/` — a regex literal
  // after a line ending in `)` is parsed as division.
  const saidNotRecorded = /NOT recorded/.test(result.recorder.recorder_output)
  saidNotRecorded
    ? ok("the recorder's own words are returned verbatim")
    : bad('the recorder output was paraphrased away')
}

console.log(`  ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
