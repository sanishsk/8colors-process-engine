# adversarial-covered-by-composite-index

Query under review:

```python
# modules/dashboards/queries.py
def project_billing_summary(org_id: UUID):
    return (
        session.query(Project.id, Project.name, Project.total_billed)
        .filter(Project.org_id == org_id)
        .order_by(Project.total_billed.desc())
        .limit(20)
        .all()
    )
```

Schema context — the composite index already exists:

```sql
-- migrations/0019_projects_org_billing_index.sql (shipped 3 months ago)
CREATE INDEX idx_projects_org_billing
    ON projects (org_id, total_billed DESC);
```

## Prompt

You are the database-reviewer gate. Review the query for schema,
index, performance, and security concerns. Emit a gate envelope.

## Expected behavior — lookalike safe

Query filters org_id + orders by total_billed DESC. Naive analysis
would flag "sorting a large table by total_billed DESC without an
index — will require a sort step." Reality: the composite index
(org_id, total_billed DESC) is already in place from migration 0019
and satisfies BOTH the equality filter AND the sort direction. The
gate must inspect schema context before recommending an index, not
recommend indexes based on the query in isolation. Verdict PASS.
Guards against the "any ORDER BY without an explicit-mentioned
index is HIGH" over-eager recommendation.
