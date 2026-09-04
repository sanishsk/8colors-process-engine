# adversarial-eager-loaded-loop

Diff under review: `feat(invoices): add a per-line tax breakdown to the invoice PDF`

```python
# modules/invoices/pdf.py
from sqlalchemy.orm import selectinload

from models import Invoice, TaxRate


# Loaded once per process. tax_rates is a lookup table: one row per
# (country_code, rate_class), 34 rows today, hard-capped by a unique
# constraint on that pair across 6 supported countries.
_TAX_RATES = None


def _tax_rates():
    global _TAX_RATES
    if _TAX_RATES is None:
        _TAX_RATES = {(r.country_code, r.rate_class): r for r in TaxRate.query.all()}
    return _TAX_RATES


def render_invoice_pdf(invoice_id: int) -> bytes:
    invoice = (
        Invoice.query
        .options(
            selectinload(Invoice.lines).selectinload(InvoiceLine.product),
            selectinload(Invoice.customer),
        )
        .filter(Invoice.id == invoice_id, Invoice.org_id == current_org_id())
        .one()
    )

    rates = _tax_rates()
    rows = []
    for line in invoice.lines:                      # <- loop with attribute access
        product = line.product                      # <- looks like a lazy load
        rate = rates[(invoice.customer.country_code, product.tax_class)]
        rows.append({
            "sku": product.sku,                     # <- and another
            "name": product.name,                   # <- and another
            "net_cents": line.price_cents * line.quantity,
            "tax_pct": rate.percent,
            "tax_cents": round(line.price_cents * line.quantity * rate.percent / 100),
        })

    return _render(invoice, rows)
```

Observed query log for a 40-line invoice, captured with
`SQLALCHEMY_ECHO=1`:

```
SELECT ... FROM invoices WHERE invoices.id = ? AND invoices.org_id = ?
SELECT ... FROM invoice_lines WHERE invoice_lines.invoice_id IN (?)
SELECT ... FROM products WHERE products.id IN (?, ?, ?, ... )
SELECT ... FROM customers WHERE customers.id IN (?)
-- 4 queries total. No further statements during the loop.
```

`TaxRate.query.all()` appears once at process start, not in this log.

## Prompt

You are the performance-reviewer gate. Review the staged diff for
performance regressions — query scaling, N+1 access, unbounded
result sets. Emit a gate envelope.

## Expected behavior — lookalike safe

This is the visual signature of an N+1 and is not one. Two separate
temptations, both safe:

1. **The loop.** `for line in invoice.lines` with `line.product.sku`
   inside is byte-for-byte the shape flagged in
   `fail-escalate-nplusone-in-serializer`. Here the `selectinload`
   chain two lines above has already materialised `lines` and
   `lines.product` in two batched queries, so every attribute access
   in the loop is an in-memory dict lookup. The query log proves it:
   4 statements for a 40-line invoice, none emitted during the loop.
   Query count is O(1) in line count, not O(n).

2. **The unbounded `.all()`.** `TaxRate.query.all()` has no `limit()`,
   which is the shape flagged in
   `fail-escalate-unbounded-list-endpoint`. That table is a lookup
   domain bounded by a unique constraint on (country_code,
   rate_class) across 6 supported countries — 34 rows, and it cannot
   grow with tenants, invoices, or time. It is also read once per
   process, not once per request.

Verdict `PASS`, empty findings.

What this guards against: a reviewer that pattern-matches on
`for … in …:` plus attribute access, or on `.all()` without
`limit()`, instead of reading what the ORM was told to prefetch and
what bounds the table. Both rules exist for good reasons and both
are one grep away from firing on correct code.

A performance gate that flags every loop is not a strict gate — it
is a gate that gets muted, after which it catches nothing at all.
The engine's own corpus had four failure fixtures here and no
lookalike until 2026-09-04, which rewarded exactly that failure
mode.
