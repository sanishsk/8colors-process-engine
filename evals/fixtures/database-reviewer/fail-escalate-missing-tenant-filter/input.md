# fail-escalate-missing-tenant-filter

Query under review (multi-tenant SaaS):

```python
# modules/reports/exports.py
def all_invoices_for_export(status: str):
    sql = "SELECT id, org_id, total, due_date FROM invoices WHERE status = %s"
    return db.execute(sql, (status,))
```

Schema context: `invoices` is a shared multi-tenant table (rows for
every org_id in the same physical table). RLS is FORCE mode + enabled.

## Prompt

You are the database-reviewer gate. Review the query for schema,
index, performance, and security concerns. Multi-tenancy is
enforced via RLS + explicit org_id predicates. Emit a gate
envelope.

## Expected behavior

Query has no `WHERE org_id = ...` predicate. RLS should catch this
at runtime, BUT: (1) an app-role connection that has RLS bypass
(superuser, migration runner) would return every org's invoices;
(2) even with RLS active, a full-table scan across all tenants is
massively over-fetching. This is the exact "silent-leak" pattern
tenant-isolation-auditor targets. Missing LIMIT is a compounding
issue. Verdict FAIL, failure_class worker_quality (agent can add
the tenant filter + LIMIT + parameterize).
