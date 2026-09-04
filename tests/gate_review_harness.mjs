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
// security-reviewed. `aggregator-lies` is its twin: it proves the floor is
// enforced by the script and not by asking the aggregating agent nicely.

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
    calls.push({ label, phase: opts.phase, hasSchema: Boolean(opts.schema) })
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

const STAGED = { files: ['modules/billing/charges.py', 'models/charge.py'] }
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
    if (label === 'aggregate') return envelope('merge-gate')
    if (label === 'record') return RECORD_OK
    return envelope(label)
  },

  'one-high': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'database-reviewer') return envelope(label, [HIGH], 'WARN')
    if (label === 'aggregate') return envelope('merge-gate', [HIGH], 'WARN')
    if (label === 'record') return RECORD_OK
    return envelope(label)
  },

  'one-critical': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'security-reviewer') return envelope(label, [CRITICAL], 'FAIL')
    if (label === 'aggregate') return envelope('merge-gate', [CRITICAL], 'FAIL')
    if (label === 'record') return RECORD_OK
    return envelope(label)
  },

  // THE ONE. security-reviewer dies; the other two are clean.
  'gate-dies': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'security-reviewer') return null
    if (label === 'aggregate') return envelope('merge-gate')
    if (label === 'record') return RECORD_OK
    return envelope(label)
  },

  // The aggregating agent ignores its instructions and reports a clean PASS
  // while a gate is missing. The script must not believe it.
  'aggregator-lies': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'database-reviewer') return null
    if (label === 'aggregate') return envelope('merge-gate', [], 'PASS')
    if (label === 'record') return RECORD_OK
    return envelope(label)
  },

  'all-gates-die': label =>
    label === 'staged diff' ? STAGED : null,

  'aggregator-dies': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'aggregate') return null
    return envelope(label)
  },

  // What actually happened on the first live run against a real repo:
  // three gates answered, twelve genuine findings, a correct WARN — and
  // `pe gate parse` refused the whole envelope because four messages ran
  // past the canonical schema's 500-char cap, so nothing was recorded and
  // the commit gate saw no verdict at all.
  'overlong-message': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'aggregate') {
      return envelope('merge-gate', [
        { severity: 'HIGH', rule: 'long-message', message: 'x'.repeat(578) },
        { severity: 'LOW', rule: 'long-suggestion', message: 'short', suggestion: 'y'.repeat(1400) },
      ], 'WARN')
    }
    if (label === 'record') return RECORD_OK
    return envelope(label)
  },

  'record-fails': label => {
    if (label === 'staged diff') return STAGED
    if (label === 'aggregate') return envelope('merge-gate')
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
  const { result } = await run('aggregator-lies')
  result.verdict !== 'PASS'
    ? ok(`the script overrides an aggregator that claims PASS (got ${result.verdict})`)
    : bad('FAIL-OPEN: the script believed an aggregator that ignored a missing gate')
  has(result.envelope, 'gate-did-not-run')
    ? ok('the missing gate is in the envelope even when the aggregator omitted it')
    : bad('the aggregator dropped the missing gate and the script let it')
}

{
  const { result } = await run('all-gates-die')
  result.verdict === 'FAIL' && result.recorded === false
    ? ok('every gate dead → FAIL, nothing recorded')
    : bad(`every gate dead → ${JSON.stringify(result.verdict)}`)
}

{
  const { result } = await run('aggregator-dies')
  result.verdict === 'FAIL' && result.recorded === false
    ? ok('a dead aggregator → FAIL, nothing recorded')
    : bad(`dead aggregator → ${result.verdict}, recorded=${result.recorded}`)
  Array.isArray(result.envelopes) && result.envelopes.length === 3
    ? ok('a dead aggregator still surfaces the raw envelopes')
    : bad('the raw envelopes were lost when aggregation failed')
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
