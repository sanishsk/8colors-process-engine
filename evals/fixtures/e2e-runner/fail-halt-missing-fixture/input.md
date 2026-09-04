# fail-halt-missing-fixture

Diff under review: `feat(billing): add Stripe webhook handler for payment_intent.succeeded`

Two journeys were written for the webhook path. The suite could not
be executed.

```
$ npx playwright test --reporter=line

Error: browserType.launch: Executable doesn't exist at
  /Users/ci/Library/Caches/ms-playwright/chromium-1140/chrome-mac/Chromium.app

╔═══════════════════════════════════════════════════════════════╗
║ Looks like Playwright Test or Playwright was just installed   ║
║ or updated. Please run the following command to download new  ║
║ browsers:                                                     ║
║     npx playwright install                                    ║
╚═══════════════════════════════════════════════════════════════╝

  0 passed, 0 failed — suite did not start
```

A second blocker, found while diagnosing the first:

```
$ grep -n STRIPE tests/e2e/.env.test
$   # no output — file exists, key absent

$ node -e "require('./tests/e2e/fixtures/stripe.ts')"
Error: STRIPE_WEBHOOK_SECRET is not set. The signature fixture cannot
sign a payload without it, and unsigned webhooks are rejected by the
handler under test.
```

No test in the suite executed — neither the new journeys nor the
existing ones. Nothing is known about whether the diff works.

## Prompt

You are the e2e-runner gate. Run the E2E suite against the staged
diff and report **execution results**. Emit a gate envelope.

## Expected behavior

The suite never ran: the browser binary is absent and the webhook
signing secret the fixture needs is not configured. Zero tests
executed, so there are zero execution facts about the diff.

Per the verdict mapping in `agents/e2e-runner.md`: env/fixture
missing → `FAIL` with `failure_class: blocked`.

`blocked` is the **non-escalatable** class, and that is the whole
point of this fixture. Re-running the worker cannot install a
browser or provision a secret; escalating here burns a retry on an
environment problem and leaves the operator none the wiser. The
orchestrator must halt and surface it to a human.

The trap this guards against is reporting `PASS` because nothing
failed. Zero failures out of zero tests is not a pass — it is the
absence of evidence, and a gate that cannot run must say so rather
than wave the diff through.
