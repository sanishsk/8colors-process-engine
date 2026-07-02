---
description: Post-GREEN cleanup pass — reuse, dead-code, altitude. Tests must stay green. Runs before code-review in the /new-feature chain.
---

# /simplify

Run a focused simplicity pass on the implementation you just made pass
its tests. Not a refactor — a *cleanup*. The invariant is "tests are
still green when I'm done"; that's this stage's PASS envelope.

## When to invoke

- Manually, after `tdd-guide`'s GREEN, before `/pre-commit`.
- Automatically as Stage 6.5 of `/new-feature`.

## Contract

Precondition: tests pass (`pytest` / `npm test` / equivalent exits 0).
Postcondition: tests still pass, and the diff is smaller or the same.

If the postcondition fails, `/simplify` MUST revert its own changes
and surface the failing test output verbatim.

## The pass (in order — stop as soon as you can)

Follow the **Ponytail ladder** at every step. If the Ponytail skill
is installed (`~/.claude/skills/ponytail`), invoke it explicitly:
_"needs to exist? → stdlib? → platform-native? → installed dep? →
one line? → only then write minimum."_

### 1. Dead code

- Delete any `def`/`function`/`const`/`type` you added that no other
  file imports or references.
- Delete commented-out code.
- Delete unused imports (`ruff --select F401` or `eslint no-unused-vars`).
- Delete `TODO:` / `FIXME:` comments that are non-actionable ("cleanup
  later" — not actionable).

### 2. Reuse over rewrite

- For every new helper (util, hook, format function), grep the
  codebase for an existing one that does the same thing. If found:
  delete the new helper, use the existing one.
- If two adjacent functions share ≥5 lines: extract into one.
- If the new code duplicates a pattern from another module: extract
  the pattern to `lib/` / `shared/` and use it from both places.

### 3. Altitude (right level of abstraction)

- If a function's name is a verb + noun + adjective + qualifier
  ("compute-user-tenant-payment-total"), it's doing too much — split.
- If a class has one method other than `__init__`: it's a function.
- If a config file has one key: inline it.
- If a wrapper does nothing but call another function: remove the wrapper.

### 4. Structural size (soft cross-check)

- Any function > 50 lines: extract at least one block.
- Any file > 400 lines: consider a split; > 800 lines is a hard cap.
- Any commit > 250 net new lines: expected. Above 600, add a
  `Size-justified:` trailer.

The `size-budget` pre-commit hook will FAIL if you leave any of these
crossed. Better to catch them here than at commit time.

### 5. Re-run the tests

MANDATORY. `pytest -x` / `npm test` / `go test ./...` — whatever the
project uses. If red: revert. If green: proceed to `/pre-commit`.

## Anti-patterns

Do NOT use `/simplify` to:
- Change behavior (that's a refactor — write new tests first).
- Rename things for style (unless there's a real ambiguity).
- Move files across modules (that's a re-architecture).
- Add abstraction "for future extensibility" — see the anti-YAGNI rule.

## Envelope

Emit a gate envelope with:

```json
{
  "verdict": "PASS" | "FAIL",
  "reviewer": "simplify",
  "tests_before": { "passed": N, "failed": 0 },
  "tests_after":  { "passed": N, "failed": 0 },
  "diff_stat":    { "insertions": ..., "deletions": ... },
  "net_lines_delta": <insertions - deletions>,
  "notes": "one-line summary of what was removed"
}
```

FAIL if tests fail after the pass. FAIL if `net_lines_delta > 0`
(simplify should never grow the code).

Feed the envelope into the same `.claude/gates/last-gate.json`
location the other gates use.
