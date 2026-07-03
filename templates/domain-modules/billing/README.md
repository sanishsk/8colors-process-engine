# Domain module: `billing`

> Payment processing for Flask projects. Ships the Charge / Refund /
> PaymentEvent models, a provider protocol with a Stripe adapter,
> money-safe Decimal helpers, server-side amount authority, and a
> webhook handler with HMAC + idempotency.
>
> Composes with `auth` (v0.26.0), `tenancy` (v0.27.0), and
> `api-credentials` (v0.25.0). Requires `tenancy` — charges are
> org-scoped. Reads Stripe API keys via `api-credentials` when
> installed, falling back to `STRIPE_SECRET_KEY` env var otherwise.

## Purpose

Give a fresh Flask app the payment layer the operator's
security-reviewer looks for — the pattern captured in
`~/.claude/rules/common/security.md` § payments:

1. **Server-side amount authority.** The client never passes the
   amount to charge. The endpoint takes an order/cart ID; the
   server looks up `order.total_cents` and passes that to the
   provider. A malicious client cannot pay $1 for a $500 order
   by editing the request body.

2. **Money as Decimal, never float.** Every money value is a
   `Decimal` in the domain layer and `int cents` at the storage /
   provider boundary. No floats anywhere. Regression-tested.

3. **Webhook HMAC verification.** Provider webhooks are the ONLY
   trusted signal of "charge succeeded / refunded." The handler
   verifies the HMAC signature per provider spec and rejects
   anything without a valid signature.

4. **Idempotency by event_id.** The `payment_events` table stores
   every processed webhook's `event_id` (unique per provider). A
   duplicate delivery is skipped silently — providers retry
   webhooks aggressively and double-processing means double-charging
   or double-refunding.

5. **Test/live key separation.** The provider adapter reads its API
   key at initialization from the credential service, so a project
   never accidentally uses the live key in development.

6. **Tenancy scoping.** Charges + Refunds + PaymentEvents all have
   `org_id` and get FORCE-mode RLS applied via
   `apply_rls_to_table()` in the migration.

## Files that get materialized by `pe module add billing`

```
models/payment.py               Charge + Refund + PaymentEvent +
                                ChargeStatus / RefundStatus enums
money.py                        Decimal ↔ cents helpers + format_money
                                (display only). NEVER float.
provider.py                     PaymentProvider protocol +
                                get_provider() factory. Reads
                                Stripe/etc via credential service.
providers/stripe.py             Stripe adapter (create_charge,
                                verify_webhook, refund).
service.py                      create_charge_for_order — the ONLY
                                entrypoint for creating a charge.
                                Server-side amount authority
                                enforced here.
webhooks/stripe.py              Stripe webhook handler — HMAC verify
                                → idempotency dedupe → dispatch to
                                event handler → update Charge status.
blueprints/billing.py           POST /billing/checkout/<order_id>
                                (server-side amount lookup) +
                                POST /billing/webhooks/stripe
                                (public HMAC-gated endpoint) +
                                GET /billing/receipts/<charge_id>
templates_billing/*.html        checkout redirect, receipt
migrations/migrate_billing.py   CREATE charges + refunds +
                                payment_events + indexes +
                                apply_rls_to_table for each
tests/test_billing.py           money math, amount authority, HMAC
                                verify, idempotency, tenancy scoping
```

## Prerequisites (deps to add to pyproject.toml)

- `stripe>=8.0` — provider SDK
- Already installed via `auth`: `Flask-Login`, `Flask-WTF`

## Provider config

Reads Stripe secret via the credential service if `api-credentials`
is installed:

```python
from modules.api_credentials.credential_service import get_credential
STRIPE_SECRET = get_credential("stripe")
```

If the credential service is NOT installed, falls back to:

```python
STRIPE_SECRET = os.environ["STRIPE_SECRET_KEY"]
```

Set the Stripe webhook secret separately (a different string) so
`verify_webhook` can validate incoming events:

```bash
# .env
STRIPE_WEBHOOK_SECRET=whsec_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## Composition

`billing` sits on top of the other three modules. Recommended
install order:

```bash
pe module add auth
pe module add tenancy
pe module add api-credentials
pe module add billing            # last — depends on the others
```

Without `auth`: no User FK for `created_by`.
Without `tenancy`: no `org_id` scoping; charges become cross-tenant.
Without `api-credentials`: falls back to raw env vars for the
Stripe API key (still works, less audited).

## Anti-patterns rejected in review

- **Passing the amount from the client.** The endpoint MUST take an
  order/cart ID and look up the amount server-side. `POST
  /checkout` accepting `{"amount": 100}` in the body is CVE-worthy
  — the security-reviewer will block it.
- **Float arithmetic on money.** `0.1 + 0.2 == 0.3` is False in
  floats. Use `Decimal("0.1") + Decimal("0.2") == Decimal("0.3")`.
  Regression-tested in `test_money_no_float_drift`.
- **Storing money as VARCHAR or FLOAT.** Always `BIGINT` cents in
  the schema. Convert at the boundary.
- **Skipping HMAC verification "for local dev".** Fake webhook
  payloads are trivial to send. The handler must verify signature
  even in dev — use Stripe's `stripe listen` CLI which produces
  real signed payloads.
- **Silently retrying webhook processing.** If a webhook fails
  processing, log it and let the provider retry. Do NOT retry in
  a loop inside the handler — the DB transaction can deadlock.
- **Trusting client for the currency.** Currency comes from the
  order/product, never the request body.
- **Committing before the provider confirms.** Persist Charge
  status as `pending` before calling `provider.create_charge`, then
  update to `succeeded/failed` in the webhook handler. If the
  provider call raises mid-flight, the pending row surfaces the
  failure in ops.

## After materialization

1. Install the three prerequisite modules first (see Composition).
2. Add `stripe>=8.0` to `pyproject.toml` and `pip install -e .[dev]`.
3. Set `STRIPE_WEBHOOK_SECRET` in `.env`.
4. If using `api-credentials`, save the Stripe secret via the admin UI.
   Otherwise, set `STRIPE_SECRET_KEY` in `.env`.
5. Update `run.py::create_app()` with the blueprint registration:
   ```python
   from modules.billing.blueprints.billing import bp as billing_bp
   app.register_blueprint(billing_bp, url_prefix="/billing")
   ```
6. Apply the migration:
   ```bash
   python -c "from modules.billing.migrations.migrate_billing import upgrade; \
              from modules.db import session; upgrade(session)"
   ```
7. Configure the Stripe webhook endpoint in the Stripe dashboard:
   ```
   https://your-domain.com/billing/webhooks/stripe
   ```
   Enable events: `charge.succeeded`, `charge.failed`, `charge.refunded`.

## Related items

- `~/.claude/rules/common/security.md` § payments — the doctrine.
- `security-reviewer` agent — treats payment/webhook/billing paths
  as CRITICAL; runs deeper checks (S3 templates in v0.17.0).
- `tenant-isolation-auditor` agent — flags any billing query
  missing `WHERE org_id = ?` or a table missing `apply_rls_to_table`.

## Reference implementation

First shipped in 8CStudio Delivery build (2026 production). The
integration tests in that project cover real Stripe test-mode
end-to-end (webhook via `stripe listen`); the tests here are the
unit-scale coverage floor.
