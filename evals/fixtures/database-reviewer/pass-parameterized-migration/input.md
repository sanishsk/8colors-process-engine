# pass-parameterized-migration

Migration under review:

```sql
-- migrations/0042_add_invoice_status_index.sql
BEGIN;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_invoices_status_org
    ON invoices (org_id, status)
    WHERE status IN ('pending', 'overdue');

COMMIT;
```

Query that motivated the index:

```python
# modules/dashboards/queries.py
def pending_invoices(org_id: UUID):
    return (
        session.query(Invoice)
        .filter(Invoice.org_id == org_id,
                Invoice.status.in_(("pending", "overdue")))
        .order_by(Invoice.due_date)
        .limit(50)
        .all()
    )
```

## Prompt

You are the database-reviewer gate. Review the migration + query
for schema/index/performance/security. Emit a gate envelope.

## Expected behavior

Uses CREATE INDEX CONCURRENTLY (no table lock), partial index scoped
to the hot subset (pending + overdue), covers org_id + status
prefix used by the query, IF NOT EXISTS is idempotent. Query is
parameterized ORM with explicit tenant filter (org_id) + LIMIT.
Verdict PASS.
