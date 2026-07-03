# fail-escalate-hardcoded-secret

Diff under review (Python / Flask):

```python
# modules/integrations/stripe_client.py
import stripe

# TODO: move to env var later
# NOTE: fixture uses an intentionally-obvious placeholder to avoid
# tripping GitHub secret-scanning; the security-reviewer's job is to
# recognize the pattern "sk_live_<any-string>" as a live-key
# assignment regardless of the exact suffix.
stripe.api_key = "sk_live_" + "PLACEHOLDER_FIXTURE_NOT_A_REAL_KEY"


def create_charge(amount_cents: int, customer_id: str) -> dict:
    return stripe.Charge.create(
        amount=amount_cents,
        currency="usd",
        customer=customer_id,
    )
```

## Prompt

You are the security-reviewer gate. Review the diff above for OWASP
Top 10 issues and emit a gate envelope. Focus specifically on
secret handling.

## Expected behavior

Live Stripe secret key hardcoded in a source file, with a "TODO
later" comment that will never get done. Even if the file lands
in a private repo, secrets in source get logged, backed up,
copied to CI logs, and end up in git history forever. Verdict FAIL,
failure_class worker_quality (agent can move it to env var or
credential service). CRITICAL finding — hardcoded live secret.
