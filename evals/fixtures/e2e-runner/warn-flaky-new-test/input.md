# warn-flaky-new-test

Diff under review: `feat(notifications): toast on successful invoice send`

One journey was added for the toast. The suite was run three times
back to back on an unchanged working tree.

```
$ npx playwright test --reporter=line --repeat-each=3

  ✓ invoices/send.spec.ts:9 · sends an invoice by email (3.2s)
  ✓ invoices/send.spec.ts:9 · sends an invoice by email (3.0s)
  ✓ invoices/send.spec.ts:9 · sends an invoice by email (3.3s)

  ✓ invoices/send.spec.ts:28 · shows a success toast (2.9s)     <- new
  ✗ invoices/send.spec.ts:28 · shows a success toast (5.0s)     <- new
      TimeoutError: locator.waitFor: Timeout 5000ms exceeded.
      waiting for getByRole('status').filter({ hasText: 'Invoice sent' })
      ...retry 1 passed (2.7s)
  ✓ invoices/send.spec.ts:28 · shows a success toast (2.8s)     <- new

  ... 36 other tests, all passed 3/3

  39 passed, 1 flaky (1m 48s)
```

Retries configured: 2. Retries consumed: 1, by
`invoices/send.spec.ts:28` only.
Artefacts: `trace.zip` + `test-failed-1.png` captured for the one
failing attempt.

No existing test failed in any of the three runs.

## Prompt

You are the e2e-runner gate. Run the E2E suite against the staged
diff and report **execution results**. Emit a gate envelope.

## Expected behavior

A newly-added test passed twice and failed once on an unchanged
tree — that is a flake, not a regression. The toast has a
dismiss timer, so the assertion races it; the run is not
trustworthy but nothing is proven broken.

Per the verdict mapping in `agents/e2e-runner.md`: new tests flake
→ `WARN` with rule `test-execution-flaky`, naming the specific
test and the retry count.

The distinction this fixture defends: **flaky is not FAIL**.
Escalating a flake to FAIL makes the escalation ladder fire on
noise, and an orchestrator that retries a worker because of a
racy assertion burns a retry budget on nothing. It is also not
PASS — a suite that only passes sometimes has not verified the
diff.
