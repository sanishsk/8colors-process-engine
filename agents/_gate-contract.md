---
name: _gate-contract
description: SPEC (not a runnable agent). Canonical output contract for every gate agent — code-reviewer, security-reviewer, database-reviewer, tdd-guide, e2e-runner. Edit here; then propagate to the 5 gate agents. Long-term this file becomes the template pe install concatenates into each rendered agent (P2.3 phase 2).
---

# Gate-envelope output contract (SPEC — v1)

> **This file is the single source of truth for the E1 gate-envelope
> shape.** All five gate agents (`code-reviewer`, `security-reviewer`,
> `database-reviewer`, `tdd-guide`, `e2e-runner`) MUST emit envelopes
> conforming to this spec. When editing the contract, edit here first;
> then propagate to the 5 agent files.
>
> **Phase 2 (planned, P2.3 v0.11.0+):** `pe install` will concatenate
> this file into each gate agent's rendered artifact at install time,
> collapsing the 5-way sync problem into a single edit.
>
> **Phase 1 (shipped, P2.3 v0.11.0):** each gate agent's `# CRITICAL
> OUTPUT CONTRACT` section is a copy of Sections 1–4 below. Model-id
> exemplars have been changed from hardcoded `"claude-sonnet-4-6"` to
> `"<your-model-id>"` in all 5 agents to prevent envelopes from lying
> about their model.

---

## Section 0 — Frontmatter fields (v0.49.0 documentation)

Every agent's YAML frontmatter carries these keys. Two consumers
read the frontmatter: Claude Code proper (which resolves the agent
when the operator uses the Agent tool) and the engine's `pe agent
run` CLI (which shells out to `claude -p`).

| Key | Consumed by | Meaning |
|---|---|---|
| `name` | Claude Code + `pe agent run` | Agent identifier used in tool routing. MUST match the file basename. |
| `description` | Claude Code | Shown in agent picker; used by the model to decide when to invoke this agent. Keep first sentence a self-contained hook. |
| `tools` | Claude Code | JSON array of tool allowlist. Reviewers deliberately omit `Write`/`Edit` — gates never modify the code they judge. |
| `model` | Claude Code + `pe agent run` | Model alias (`haiku` / `sonnet` / `opus`). `pe agent run --model <alias>` overrides at invocation time. |
| `effort` | `pe agent run` | Optional metadata (`low` / `medium` / `high`). Not read by Claude Code natively; used by engine orchestration + operator scanning. Absent = engine treats as `medium`. |

**Removed in v0.49.0:** the `memory:` frontmatter key was historically
present on some agents but consumed by NOTHING — neither Claude Code
nor `pe agent run`. Removed from all 11 agents as part of the
Loose-ends cleanup. New frontmatter keys are only added when a
concrete consumer will read them. Silent-ignored keys create false
configuration surface — the operator thinks tuning `foo: bar` changes
behavior when it does nothing.

---

## Section 1 — The two non-negotiable rules

### Rule 1 — Emit ONE fenced block, EXACTLY this opening fence

The very last thing in your reply must be a fenced code block whose
opening fence is literally these characters (no variations, no
substitutions):

    ```json gate-envelope

Three tokens, in this order: three backticks, then the word `json`,
then a single space, then the word `gate-envelope`, then a newline.

**Forbidden alternatives** (the parser will fail to find your envelope
if you emit any of these):

- ` ```json `              (missing `gate-envelope` — the most common drift)
- ` ```json-gate-envelope ` (hyphen instead of space)
- ` ```gate-envelope `      (missing `json`)
- ` ```json   gate-envelope ` (multiple spaces — actually OK but avoid)
- ` ```JSON gate-envelope `  (capital JSON — actually OK but avoid)
- ` ``` `                   (no info-string at all)
- A plain JSON object outside any fence

If you have shown other JSON examples earlier in your review, that is
fine — the parser only looks at fenced blocks whose info-string is
literally `json gate-envelope`, and it picks the LAST such block.

### Rule 2 — Inside the fence, emit EXACTLY this JSON shape

The body must be valid JSON conforming to the schema below. Every
field marked **REQUIRED** must be present, with the exact spelling
and case shown. Use null only for fields documented as nullable.

```json
{
  "schema_version": "1.0.0",                       // REQUIRED, literal "1.0.0"
  "gate_name": "<code-reviewer|security-reviewer|database-reviewer|tdd-guide|e2e-runner>",  // REQUIRED
  "verdict": "PASS | WARN | FAIL",                 // REQUIRED, one of these three
  "failure_class": "none | worker_quality | task_underspecified | blocked | out_of_scope",  // REQUIRED
  "confidence": 0.0-1.0,                           // optional, recommended
  "model_used": "<your-model-id>",                 // REQUIRED — the model actually running you, e.g. "claude-sonnet-4-6". Never hardcode.
  "tier": "<haiku|sonnet|opus>",                   // optional, your tier label
  "timestamp": "<ISO 8601 UTC>",                   // REQUIRED, e.g. "2026-06-24T14:32:00Z"
  "summary": "<one sentence ≤280 chars>",          // optional, recommended
  "findings": [ /* zero or more items, shape below */ ],   // REQUIRED, may be []
  "scope": { /* optional, recommended */ }
}
```

`findings[]` items use this **exact** field set — these field names
are not negotiable:

```json
{
  "severity": "CRITICAL | HIGH | MEDIUM | LOW",    // REQUIRED
  "rule": "<short-kebab-case-id>",                 // REQUIRED, max 60 chars, must match pattern ^[a-z0-9][a-z0-9-]*$
  "message": "<sentence>",                         // REQUIRED, max 500 chars
  "file": "<path>",                                // optional
  "line": <int>,                                   // optional, 1-indexed
  "suggestion": "<fix>"                            // optional
}
```

**Do NOT invent new field names.** Earlier versions of gate prompts
allowed agents to make up field names like `category`, `title`,
`detail`, `critical_issues`. Those are now BANNED. The validator will
reject envelopes with unknown fields and the orchestrator will treat
the gate as broken.

### The `rule` field — naming convention is HARD-ENFORCED

`rule` is a **stable identifier**, not human-readable prose. The
validator rejects any value that does not match the regex
`^[a-z0-9][a-z0-9-]*$` (lowercase letters, digits, hyphens; must
start with a letter or digit; max 60 chars).

**Wrong** (will fail validation, gate is rejected):
- `"SQL Injection — f-string concatenation"` ← spaces, capitals, em-dash
- `"Mutable Default Argument"` ← spaces, capitals
- `"SQL_INJECTION"` ← underscores not allowed
- `"sql injection"` ← spaces not allowed

**Right** (passes validation):
- `"sql-injection"`
- `"mutable-default-arg"`
- `"missing-rate-limit"`
- `"timing-attack"`
- `"function-too-long"`
- `"unhandled-exception"`
- `"n-plus-one-query"`
- `"missing-csrf-token"`

Each agent MAY publish its own kebab-case rule vocabulary (see per-agent
"The `rule` field" section for domain examples). But the format
constraint is universal.

Treat `rule` like a CSS class name or a Sentry issue fingerprint:
short, kebab-case, stable across runs, suitable for grep + dedup
+ trend analysis. Put the human-readable description in `message`,
not `rule`.

---

## Section 2 — Verdict + failure_class decision table

Pick exactly one row based on what your review found:

| Findings | verdict | failure_class | Orchestrator does |
|---|---|---|---|
| 0 CRITICAL, 0 HIGH | `PASS` | `none` | Accept, proceed |
| 0 CRITICAL, ≥1 HIGH | `WARN` | `none` | Proceed, surface to human |
| ≥1 CRITICAL (real bug) | `FAIL` | `worker_quality` | Escalate to next tier |
| Cannot judge — slot goal unclear | `FAIL` | `task_underspecified` | Halt to human |
| Cannot judge — missing dep/env/fixture | `FAIL` | `blocked` | Halt to human |
| Diff reaches outside slot scope | `FAIL` | `out_of_scope` | Halt to human |

**Default bias when unsure** between `worker_quality` and
`task_underspecified`: pick `task_underspecified`. Escalating a
higher-tier worker on an ambiguous task burns three tiers of budget
on impossible work — exactly the failure mode this field exists to
prevent.

---

## Section 3 — Mandatory self-validation step (run this before emitting)

Prompt-only self-checks are unreliable — agents have been observed
asserting "all checks passed" while emitting invalid envelopes, and
**separately** observed skipping the pre-emission cross-check entirely
while still producing schema-valid envelopes. The contract therefore
requires `pe gate parse` to validate both at once, from a single
transcript draft:

```bash
# 1. Write your draft TRANSCRIPT to a tempfile. The transcript MUST
#    contain BOTH the "Envelope key values" cross-check block AND
#    the fenced envelope below it. Writing just the JSON is no
#    longer sufficient — the parser will reject it (exit 4).
cat > /tmp/gate-envelope-draft.md <<'EOF'
Envelope key values
  schema_version: 1.0.0
  gate_name:      <your-gate-name>
  verdict:        FAIL
  failure_class:  worker_quality
  model_used:     <your-model-id>
  timestamp:      2026-06-25T01:30:00Z

```json gate-envelope
{
  "schema_version": "1.0.0",
  "gate_name": "<your-gate-name>",
  "verdict": "FAIL",
  "failure_class": "worker_quality",
  "model_used": "<your-model-id>",
  "timestamp": "2026-06-25T01:30:00Z",
  ... rest of your envelope ...
}
```
EOF

# 2. Validate it.
pe gate parse /tmp/gate-envelope-draft.md

# 3. Inspect the exit code:
#    0 = PASS  (your verdict was PASS)
#    1 = FAIL worker_quality
#    2 = FAIL non-escalatable
#    3 = WARN
#    4 = parse/schema error or cross-check missing/mismatched
#        ← MUST FIX before final emission
```

If exit code is 4, the parser printed validation errors to stderr.
Common causes:
- envelope: banned field name, non-kebab-case `rule`, missing required
  field, malformed JSON.
- cross-check: missing the `Envelope key values` block entirely, or
  one of its values does not match the envelope (e.g. the cross-check
  says `verdict: PASS` but the envelope is FAIL).

Read the errors, fix, and re-run. **Do not emit until the exit code
is one of 0/1/2/3.**

Cap: maximum 3 self-validation iterations. If you cannot produce a
valid transcript after 3 attempts, emit a `verdict=FAIL,
failure_class=blocked` envelope (still inside a transcript with a
matching cross-check) and a `summary` explaining the specific
validation error you couldn't resolve. Better to halt
deterministically than to ship a broken envelope.

After validation succeeds, emit the EXACT SAME transcript — the
cross-check block followed by the fenced envelope — as the last part
of your reply. Do not edit values between validation and emission; the
draft you validated IS the artifact you emit.

---

## Section 4 — Pre-emission cross-check (values, not tick-boxes)

The "Envelope key values" block is enforced by `pe gate parse`
(E1.d, 2026-06-25). The parser requires the 6 fields below to be
present AND to literally equal the envelope's values:

```
Envelope key values
  schema_version: 1.0.0
  gate_name:      <your-gate-name>
  verdict:        FAIL
  failure_class:  worker_quality
  model_used:     <your-model-id>
  timestamp:      2026-06-25T01:30:00Z
  findings[0]:    severity=CRITICAL  rule=sql-injection
  findings[1]:    severity=HIGH      rule=mutable-default-arg
```

`findings[N]` rows are optional in the cross-check (the parser does
not enforce their format); the 6 named fields above are required.
Do not write `verdict: ✓` or `verdict: correct` — write the literal
value. Drift between the cross-check and the envelope is the exact
failure mode this block exists to catch.

---

## Section 5 — Banned extra field names (observed agent drift)

The following field names have been observed in agent output during
E1 testing. They are **forbidden**. The validator rejects unknown
fields. Do not invent these or any others:

- top-level: `review_session`, `total_findings`, `critical_issues`,
  `passed_self_check`, `rule_format_verified`, `mode`, `pass`,
  `review_date`, `coverage_checks`, `e1_contract_adherence`, `notes`
- inside `findings[]`: `category`, `title`, `detail`, `code_snippet`,
  `recommendation`, `cwe`, `severity_count`, `references`,
  `critical_count`, `block_severity`

**Rule:** if a piece of information doesn't fit one of the documented
optional fields (`confidence`, `summary`, `tier`, `scope`, `cost`),
put it in `summary` (a short sentence) or `findings[].message`. Do
NOT add a new field.

---

## Section 6 — One envelope per invocation. Always.

Emit exactly one envelope, as the last fenced block in your output.
Even if you cannot produce a verdict (no staged diff, git
unavailable, etc.), still emit an envelope with `verdict=FAIL`,
`failure_class=blocked`, empty `findings: []`, and a `summary` that
explains what blocked you. **Never** end your reply without an
envelope.

Full schema + rationale: `schemas/gate-envelope.schema.json` and
`docs/E1_GATE_ENVELOPE.md`.
