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

## Trajectory metrics (L2 completion, v0.25.1)

`tests/test_gate_efficacy.sh --metrics <path>` writes a JSONL row
per fixture: `gate`, `fixture`, `corpus` (main / holdout),
`expected_exit`, `actual_exit`, `cost_cents`, `duration_ms`,
`num_turns`, `tool_calls`. Shape-mode rows carry the exit-code
data (nulls for cost / duration / turns); live-mode rows carry all
five. Feed the file into `pe telemetry summary`-style analysis to
compute per-gate p50/p95 cost and recall.

## Held-out subcorpus (L2 completion, v0.25.1)

Fixtures under `evals/fixtures/<gate>/holdout/<verdict-slug>/` are
the **unseen-during-development** measurement path — precision /
recall computed on inputs the gate author has never trained
against.

The runner walks these separately (see `--holdout-only` and
`--no-holdout` flags on `tests/test_gate_efficacy.sh`). Fixture
authors OTHER than the gate's original author add these over
time; the whole point is contamination-free measurement, so a
holdout fixture that lands in the same PR that changes the gate
is instantly stale.

Currently seeded (proof-of-shape):

- `security-reviewer/holdout/fail-escalate-hardcoded-secret` —
  Stripe live secret in source with a "TODO later" comment.

Every future gate change should be accompanied by ≥1 new holdout
fixture from someone other than the change author.

## Adding a new gate

1. Create `evals/fixtures/<gate-name>/` with at minimum:
   - 1 pass fixture
   - 1 fail-escalate OR fail-halt fixture (whichever the gate emits)
   - 1 adversarial fixture (safe lookalike of the failure it catches)
2. Run `tests/test_gate_efficacy.sh` locally.
3. Commit both directories.

## Seeded gates

- **security-reviewer** — 4 fixtures (pass, fail-escalate, fail-halt,
  adversarial). Introduced in v0.19.0.
- **code-reviewer** — 3 fixtures (pass, fail-escalate, adversarial).
  Introduced in v0.20.0.
- **database-reviewer** — 3 fixtures. Introduced in v0.20.0.
- **tdd-guide** — 3 fixtures. Introduced in v0.20.0.
- **design-critic** — 3 fixtures. Introduced in v0.20.0.

Total: 16 fixtures across 5 gates. Every gate has at minimum one
adversarial safe-lookalike — the corpus is deliberately balanced so
"catch the failures" and "don't false-positive on the lookalikes"
carry equal weight.

Additional gates (e2e-runner, merge-gate) get seeded when the
first live-mode measurement pass is scheduled.
