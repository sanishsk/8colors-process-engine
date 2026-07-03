# pass-small-cohesive-refactor

Diff under review:

```python
# modules/invoices/totals.py — before
def compute_totals(invoice):
    subtotal = 0
    for line in invoice.lines:
        subtotal += line.qty * line.unit_price
    tax = subtotal * invoice.tax_rate
    return {"subtotal": subtotal, "tax": tax, "total": subtotal + tax}

# modules/invoices/totals.py — after
def _subtotal(lines) -> float:
    return sum(line.qty * line.unit_price for line in lines)


def compute_totals(invoice) -> dict[str, float]:
    subtotal = _subtotal(invoice.lines)
    tax = subtotal * invoice.tax_rate
    return {"subtotal": subtotal, "tax": tax, "total": subtotal + tax}
```

Tests updated:

```python
# tests/test_totals.py
def test_subtotal_multiple_lines():
    inv = _fixture_invoice(lines=[(2, 100), (1, 50)])
    assert compute_totals(inv)["subtotal"] == 250
```

## Prompt

You are the code-reviewer gate. Review the diff for quality, security,
and maintainability. Emit a gate envelope.

## Expected behavior

Small, cohesive extraction. Type hints added. Test updated to cover
the extracted helper's behavior via the public API. Verdict PASS,
0 CRITICAL / 0 HIGH.
