# evals/ — gate-efficacy corpus (A2, extended by L2)

> Seeded-defect corpus + adversarial + held-out fixtures per gate.
> Answers: **do the gates actually catch what they claim to catch?**
>
> Introduced in v0.19.0 alongside A1 (telemetry). Gate-efficacy has
> been the missing verification layer — prior to this the engine
> could ship shadow-mode decisions with `"inf"` budgets AND
> unverified agents. Telemetry (A1) closes the cost gap; this
> corpus closes the quality gap.

## Contract

Each fixture is a directory named `<verdict>-<slug>/` under
`evals/fixtures/<gate-name>/`:

```
evals/fixtures/security-reviewer/
├── pass-parameterized-orm/
│   ├── input.md                # code artifact under review + prompt
│   └── expected-envelope.json  # envelope the gate SHOULD emit
├── fail-escalate-sql-injection/
├── fail-escalate-hardcoded-secret/
├── fail-halt-underspecified/
└── adversarial-lookalike-safe/
```

- `input.md` — the artifact the gate should score. First line MUST be
  `# <slug>`. Body contains the source diff or file(s) + a `## Prompt`
  section stating what the gate is being asked to check. This is the
  input a live-mode runner would feed to the agent.

- `expected-envelope.json` — the envelope the gate MUST emit. Bare
  JSON only (no fenced markdown block). Runner validates this against
  `schemas/gate-envelope.schema.json` and asserts the exit-code class:

  | Directory prefix        | Expected `pe gate parse --bare` exit |
  |-------------------------|--------------------------------------|
  | `pass-…/`               | 0 (PASS)                             |
  | `fail-escalate-…/`      | 1 (FAIL worker_quality)              |
  | `fail-halt-…/`          | 2 (FAIL non-escalatable)             |
  | `warn-…/`               | 3 (WARN)                             |
  | `adversarial-…/`        | 0 (PASS — safe lookalike must not FP)|

## What the runner checks (shape mode — default)

`tests/test_gate_efficacy.sh` iterates every fixture and:

1. Parses `expected-envelope.json` via `pe gate parse --bare`.
2. Asserts exit code matches the directory prefix.
3. Confirms `input.md` exists and starts with `# <slug>`.

Shape mode runs in CI, has zero API cost, and catches:

- Envelopes that no longer validate against the schema (drift).
- Fixture files with wrong verdict semantics (mislabeled corpus).
- Missing input.md scaffolding.

**Shape mode does NOT invoke the live agent.** It is a corpus
integrity check — necessary but not sufficient.

## What live-mode adds (A2 full, planned)

A `--live` flag (not yet wired) will:

1. For each `input.md`, invoke the target agent (`pe agent run
   <gate-name> --input input.md`).
2. Extract the emitted envelope.
3. Compare `emitted.verdict` and `emitted.failure_class` to
   `expected-envelope.json`.
4. Aggregate: precision (verdict match on pass corpus),
   recall (verdict match on fail corpus), FP rate on adversarial.

Live mode requires `ANTHROPIC_API_KEY` and burns real tokens. Run
weekly (retro schedule) or before releases, not on every push.

## Trajectory metrics (L2 interleave)

The `tests/test_gate_efficacy.sh --live` path will also record for
each turn: step count, tool calls, retries, tokens (via A1
telemetry hook), wall-clock. Held-out (unseen-during-development)
fixtures go in `<gate>/holdout/`; adversarial-only in
`<gate>/adversarial/`.

## Adding a new gate

1. Create `evals/fixtures/<gate-name>/` with at minimum:
   - 1 pass fixture
   - 1 fail-escalate OR fail-halt fixture (whichever the gate emits)
   - 1 adversarial fixture (safe lookalike of the failure it catches)
2. Run `tests/test_gate_efficacy.sh` locally.
3. Commit both directories.

## Seed gates in this release

- **security-reviewer** — 3 fixtures. Seeds the corpus shape.

The other four gate agents (code-reviewer, database-reviewer,
tdd-guide, design-critic) will get seeded fixtures in v0.20.0.
