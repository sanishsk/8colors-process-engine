# fail-escalate-regression

Diff under review: `refactor(auth): move session lookup behind a cache`

```python
# modules/auth/session.py — after
def current_company_id(request):
    sess = _session_cache.get(request.cookies.get("sid"))
    if sess is None:
        sess = _load_session(request.cookies.get("sid"))
        _session_cache[request.cookies.get("sid")] = sess
    return sess.company_id
```

No test files were changed. The existing suite was re-run.

```
$ npx playwright test --reporter=line

  ✓ auth/login.spec.ts:8 · logs in with valid credentials (2.2s)
  ✓ auth/login.spec.ts:19 · rejects a wrong password (1.5s)
  ✗ auth/logout.spec.ts:6 · logs out and clears the session (6.1s)
      Error: expect(page).toHaveURL(/\/login/)
      Received: "http://localhost:5000/invoices"
      ...retry 1 failed (6.0s)
      ...retry 2 failed (6.1s)
  ✗ auth/switch-company.spec.ts:11 · switches to the second company (6.4s)
      Error: expect(rows).toHaveCount(3)
      Received: 7   // rows from the PREVIOUS company are still listed
      ...retry 1 failed (6.2s)
      ...retry 2 failed (6.3s)
  ✓ invoices/list.spec.ts:9 · lists invoices for the current company (2.9s)
  ... 10 other tests, all passed

  12 passed, 2 failed (1m 09s)
```

Both failures reproduce on every attempt. Both tests passed on the
parent commit. Artefacts: `trace.zip`, `video.webm` and
`test-failed-{1,2,3}.png` captured for each failure.

## Prompt

You are the e2e-runner gate. Run the E2E suite against the staged
diff and report **execution results**. Emit a gate envelope.

## Expected behavior

Two tests that passed on the parent commit now fail deterministically
— 3 of 3 attempts each. The cache is keyed by session id and never
invalidated, so logout leaves a live session and a company switch
serves the previous company's rows. This is the diff breaking
existing behaviour.

Per the verdict mapping in `agents/e2e-runner.md`: existing tests
broken by the diff → `FAIL` with `failure_class: worker_quality`
and rule `test-execution-regression`.

`worker_quality` is the escalatable class — the worker wrote code
that broke a verified journey, and re-running the worker with the
failure attached is the correct next move. Contrast with
`fail-halt-missing-fixture`, where re-running the worker cannot
help.

Note the second failure is a **tenant-isolation** regression:
company B's user sees company A's rows. Execution facts still, but
the severity is CRITICAL rather than HIGH.
