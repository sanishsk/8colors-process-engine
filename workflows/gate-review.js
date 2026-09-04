export const meta = {
  name: 'gate-review',
  description: 'Parallel gate review of the staged diff (security + database + code), schema-validated envelopes, one aggregated merge-gate verdict recorded where the commit hook reads it',
  phases: [
    { title: 'Collect', detail: 'read the staged diff' },
    { title: 'Review', detail: 'three gate agents in parallel' },
    { title: 'Aggregate', detail: 'dedupe, rank, one merge-gate envelope' },
    { title: 'Record', detail: 'persist via pe gate parse --record' },
  ],
}

// ─────────────────────────────────────────────────────────────────────────
// Replaces the prose at docs/AGENT_INVOCATION_RULES.md — "Launch 3 agents in
// parallel ... Aggregate findings" — which was six lines of instruction with
// no mechanism behind it.
//
// Design decisions and their evidence live in
// docs/research/architect-gate-review-workflow.md. The three that shape this
// file:
//
//   1. The script cannot write files, and the commit gate only reads files.
//      hooks/pre-commit-envelope-check.sh blocks `git commit` unless
//      .claude/gates/last-gate.json holds a PASS/WARN envelope whose
//      diff_sha matches the staged diff. A workflow that ends in `return`
//      produces a verdict the enforcement layer is blind to. The Record
//      phase is an agent — agents hold Bash — and it is not optional.
//
//   2. PASS is only reachable when every gate answered. agent() returns null
//      when an agent is skipped or dies, and the usual .filter(Boolean)
//      FAILS OPEN here: drop a dead security-reviewer, see two clean
//      envelopes, report PASS, and a payment-path change is committed having
//      never been security-reviewed. The script enforces the floor, not the
//      aggregating agent, because the script cannot be talked out of it.
//
//   3. No fixer. A workflow cannot pause for a human, so an agent that edits
//      files, re-reviews its own edits and reports PASS removes the operator
//      from the one place the doctrine keeps them.
// ─────────────────────────────────────────────────────────────────────────

// >>> GATE-ENVELOPE-SCHEMA-BEGIN
// A structural SUBSET of schemas/gate-envelope.schema.json, not a copy. The
// canonical schema uses draft-07 allOf/if/then conditionals whose support in
// this runtime is undocumented, and a schema silently ignored is worse than
// one absent. The conditional rule (FAIL => failure_class != none, otherwise
// == none) is enforced by `pe gate parse` in the Record phase instead.
//
// tests/test_gate_review_schema_sync.sh fails if any enum here stops
// matching the canonical file.
const ENVELOPE_SCHEMA = {
  type: 'object',
  required: ['schema_version', 'gate_name', 'verdict', 'failure_class', 'findings', 'model_used', 'timestamp'],
  properties: {
    schema_version: { type: 'string', description: 'semver, e.g. 1.0.0' },
    gate_name: {
      type: 'string',
      enum: ['code-reviewer', 'security-reviewer', 'tdd-guide', 'e2e-runner', 'database-reviewer', 'design-critic', 'performance-reviewer', 'merge-gate'],
    },
    verdict: { type: 'string', enum: ['PASS', 'WARN', 'FAIL'] },
    failure_class: {
      type: 'string',
      enum: ['worker_quality', 'task_underspecified', 'blocked', 'out_of_scope', 'none'],
    },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['severity', 'rule', 'message'],
        properties: {
          severity: { type: 'string', enum: ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'] },
          rule: { type: 'string', description: 'kebab-case, max 60 chars' },
          message: { type: 'string', description: 'max 500 chars' },
          file: { type: 'string' },
          line: { type: 'integer' },
          suggestion: { type: 'string', description: 'max 1000 chars' },
        },
      },
    },
    model_used: { type: 'string' },
    timestamp: { type: 'string', description: 'ISO-8601 UTC, e.g. 2026-09-04T12:00:00Z' },
  },
}
// >>> GATE-ENVELOPE-SCHEMA-END

// The three the prose names, for the slot types it names them for:
// RLS changes, payment, auth. design-critic and performance-reviewer also
// emit envelopes and are obvious later additions — a UI gate on an RLS
// change is noise, and choosing gates from staged paths is a second
// mechanism to get right.
const GATES = ['security-reviewer', 'database-reviewer', 'code-reviewer']

const BLOCKING = ['CRITICAL', 'HIGH']

// ─── Collect ─────────────────────────────────────────────────────────────
phase('Collect')

const staged = await agent(
  'Run `git diff --cached --name-only` in the repository root and return the ' +
  'staged file paths. Return an empty array if nothing is staged. Do not ' +
  'modify anything.',
  {
    label: 'staged diff',
    phase: 'Collect',
    schema: {
      type: 'object',
      required: ['files'],
      properties: { files: { type: 'array', items: { type: 'string' } } },
    },
  },
)

if (!staged || !staged.files || staged.files.length === 0) {
  log('Nothing staged — no review to run.')
  return {
    verdict: 'PASS',
    reason: 'no staged files',
    gates_ran: [],
    gates_missing: [],
    recorded: false,
  }
}

log(`${staged.files.length} staged file(s); running ${GATES.length} gates in parallel`)

// ─── Review ──────────────────────────────────────────────────────────────
// A genuine barrier: the aggregator needs every envelope at once, so
// parallel() is correct here rather than pipeline().
phase('Review')

const fileList = staged.files.join(', ')

const results = await parallel(
  GATES.map(gate => () =>
    agent(
      `You are the ${gate} gate agent for the 8colors-process-engine.\n\n` +
      `Read agents/${gate}.md for your rubric and agents/_gate-contract.md ` +
      `for the envelope contract, then review the STAGED diff — ` +
      `\`git diff --cached\` — of these files:\n${fileList}\n\n` +
      `Return a gate envelope with gate_name="${gate}". Set schema_version ` +
      `to "1.0.0", model_used to the model you are running as, and timestamp ` +
      `to the current UTC time in ISO-8601 (run \`date -u +%Y-%m-%dT%H:%M:%SZ\`). ` +
      `failure_class must be "none" unless verdict is FAIL. Every finding ` +
      `needs a kebab-case rule of at most 60 characters.\n\n` +
      `Review only. Do not edit any file.`,
      { label: gate, phase: 'Review', schema: ENVELOPE_SCHEMA },
    ),
  ),
)

// ── The floor. Applied here, in the script, before anything aggregates. ──
// results[i] is null when that gate was skipped or died. Filtering silently
// is the fail-open bug this whole design exists to avoid.
const envelopes = []
const gatesMissing = []
for (let i = 0; i < GATES.length; i++) {
  if (results[i]) {
    envelopes.push(results[i])
  } else {
    gatesMissing.push(GATES[i])
  }
}

const missingFindings = gatesMissing.map(gate => ({
  severity: 'HIGH',
  rule: 'gate-did-not-run',
  message:
    `${gate} did not return an envelope — it was skipped or failed. This ` +
    `review is incomplete and cannot be treated as a pass.`,
}))

if (gatesMissing.length > 0) {
  log(`INCOMPLETE: ${gatesMissing.join(', ')} did not answer. PASS is not reachable.`)
}

if (envelopes.length === 0) {
  log('No gate returned an envelope. Nothing to aggregate or record.')
  return {
    verdict: 'FAIL',
    reason: 'every gate failed to run',
    gates_ran: [],
    gates_missing: gatesMissing,
    findings: missingFindings,
    recorded: false,
  }
}

// ─── Aggregate ───────────────────────────────────────────────────────────
phase('Aggregate')

const merged = await agent(
  `Merge these ${envelopes.length} gate envelopes into ONE envelope.\n\n` +
  `${JSON.stringify(envelopes, null, 2)}\n\n` +
  `Rules:\n` +
  `- gate_name MUST be "merge-gate".\n` +
  `- Deduplicate findings that describe the same problem at the same ` +
  `file and line, keeping the highest severity and the clearest message. ` +
  `Do not drop a finding just because it resembles another at a different ` +
  `location.\n` +
  `- Order findings by severity: CRITICAL, then HIGH, then MEDIUM, then LOW.\n` +
  `- verdict is FAIL if any finding is CRITICAL, WARN if any is HIGH, ` +
  `otherwise PASS.\n` +
  `- failure_class is "worker_quality" when verdict is FAIL, else "none".\n` +
  `- schema_version "1.0.0". Set timestamp to the current UTC time in ` +
  `ISO-8601 (\`date -u +%Y-%m-%dT%H:%M:%SZ\`). model_used is the model you ` +
  `are running as.\n` +
  `- Every rule is kebab-case, at most 60 characters.\n\n` +
  `Report what the gates found. Do not soften it, and do not add findings ` +
  `of your own.`,
  { label: 'aggregate', phase: 'Aggregate', schema: ENVELOPE_SCHEMA },
)

if (!merged) {
  log('Aggregation failed. Reporting the raw envelopes without a verdict.')
  return {
    verdict: 'FAIL',
    reason: 'aggregation agent did not return an envelope',
    gates_ran: GATES.filter(g => !gatesMissing.includes(g)),
    gates_missing: gatesMissing,
    envelopes,
    recorded: false,
  }
}

// Re-apply the floor to the aggregate. The agent was told the rules; this
// is the part that does not depend on it having followed them.
const findings = missingFindings.concat(merged.findings || [])
const worst = findings.some(f => f.severity === 'CRITICAL')
  ? 'FAIL'
  : findings.some(f => BLOCKING.includes(f.severity))
    ? 'WARN'
    : 'PASS'

// A missing gate can never yield PASS, whatever the aggregator said.
const verdict = gatesMissing.length > 0 && worst === 'PASS' ? 'WARN' : worst

const envelope = {
  schema_version: '1.0.0',
  gate_name: 'merge-gate',
  verdict,
  failure_class: verdict === 'FAIL' ? 'worker_quality' : 'none',
  findings,
  model_used: merged.model_used,
  timestamp: merged.timestamp,
}

log(`Aggregate: ${verdict} — ${findings.length} finding(s) across ${envelopes.length} gate(s)`)

// ─── Record ──────────────────────────────────────────────────────────────
// The step without which none of the above reaches the commit gate.
phase('Record')

const recorded = await agent(
  `Persist this gate envelope so the engine's commit hook can read it.\n\n` +
  `Envelope:\n\`\`\`json\n${JSON.stringify(envelope, null, 2)}\n\`\`\`\n\n` +
  `Steps, in order:\n` +
  `1. Write a transcript file to .pe/gate-review-transcript.md containing ` +
  `an "Envelope key values" block listing schema_version, gate_name, ` +
  `verdict, failure_class, model_used and timestamp one per line, then the ` +
  `envelope inside a fenced \`\`\`json gate-envelope block. Both are required ` +
  `by pe gate parse in transcript mode.\n` +
  `2. Compute the staged-diff sha: ` +
  `\`git diff --cached | git hash-object --stdin\`\n` +
  `3. Run: pe gate parse --record .claude/gates/last-gate.json ` +
  `--diff-sha <sha> .pe/gate-review-transcript.md\n` +
  `4. Report its exit code and its stderr line VERBATIM. That line says ` +
  `either "gate: recorded ..." or "gate: NOT recorded ...". Do not ` +
  `paraphrase it and do not claim success if the exit code is non-zero.\n\n` +
  `Change nothing else.`,
  {
    label: 'record',
    phase: 'Record',
    schema: {
      type: 'object',
      required: ['recorded', 'exit_code', 'recorder_output'],
      properties: {
        recorded: { type: 'boolean' },
        exit_code: { type: 'integer' },
        recorder_output: { type: 'string', description: 'the stderr line, verbatim' },
        diff_sha: { type: 'string' },
      },
    },
  },
)

return {
  verdict,
  envelope,
  gates_ran: GATES.filter(g => !gatesMissing.includes(g)),
  gates_missing: gatesMissing,
  recorded: recorded ? recorded.recorded : false,
  recorder: recorded || { recorded: false, recorder_output: 'record agent did not return' },
}
