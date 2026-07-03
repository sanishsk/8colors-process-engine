# adversarial-long-but-cohesive

Diff under review:

```python
# modules/reports/pnl_calculator.py
def compute_pnl_report(period_start: date, period_end: date, org_id: str) -> PNLReport:
    """Compute Profit & Loss for an organization over a period.

    Single responsibility: aggregate ledger entries into a P&L. The
    length comes from the number of GAAP line items (revenue, COGS,
    opex categories, non-op) — each is one arithmetic step against
    the same ledger query. Extracting them into helpers would spread
    the same 3-line pattern across 12 files without adding
    testability (each line is tested via the returned PNLReport).
    """
    entries = ledger_entries(org_id, period_start, period_end)

    revenue = sum(e.amount for e in entries if e.category == "revenue")
    refunds = sum(e.amount for e in entries if e.category == "refunds")
    net_revenue = revenue - refunds

    cogs_direct = sum(e.amount for e in entries if e.category == "cogs_direct")
    cogs_indirect = sum(e.amount for e in entries if e.category == "cogs_indirect")
    total_cogs = cogs_direct + cogs_indirect
    gross_profit = net_revenue - total_cogs

    salaries = sum(e.amount for e in entries if e.category == "salaries")
    rent = sum(e.amount for e in entries if e.category == "rent")
    marketing = sum(e.amount for e in entries if e.category == "marketing")
    software = sum(e.amount for e in entries if e.category == "software")
    other_opex = sum(e.amount for e in entries if e.category == "other_opex")
    total_opex = salaries + rent + marketing + software + other_opex
    operating_income = gross_profit - total_opex

    interest_income = sum(e.amount for e in entries if e.category == "interest_income")
    interest_expense = sum(e.amount for e in entries if e.category == "interest_expense")
    tax_expense = sum(e.amount for e in entries if e.category == "tax")
    net_income = operating_income + interest_income - interest_expense - tax_expense

    return PNLReport(
        period_start=period_start,
        period_end=period_end,
        revenue=revenue,
        refunds=refunds,
        net_revenue=net_revenue,
        cogs=total_cogs,
        gross_profit=gross_profit,
        opex=total_opex,
        operating_income=operating_income,
        net_income=net_income,
    )
```

Tests exercise the returned PNLReport across a fixture ledger covering
every category:

```python
def test_pnl_full_ledger():
    r = compute_pnl_report(...)
    assert r.net_income == 12_500
    assert r.gross_profit == 45_000
```

## Prompt

You are the code-reviewer gate. Review the diff for quality, security,
and maintainability. Emit a gate envelope.

## Expected behavior — lookalike safe

Long function (~50 lines) — SUPERFICIALLY resembles the god-function
failure case. Reality: single-responsibility (P&L aggregation), one
input, one output, tested via the returned struct. Extracting each
line into a helper would be 12 files of `sum(e.amount for e in
entries if e.category == "x")` — pure churn. The gate MUST NOT
blindly flag length; it must judge cohesion. Verdict PASS (or WARN
with a MEDIUM note on the docstring already explaining the choice —
NOT a HIGH function-too-long finding). Guards against the "any
function >30 lines is a god function" over-broad heuristic.
