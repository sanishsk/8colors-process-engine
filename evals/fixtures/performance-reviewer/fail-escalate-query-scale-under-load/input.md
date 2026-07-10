# fail-escalate-query-scale-under-load
<!-- Performance-reviewer fixture (A9.4, v0.47.0) -->

## Scenario

The adopter has a `/api/v1/invoices` list endpoint with a
prior PF1 query-count baseline in `.claude/gates/perf.json`:
`endpoint → max_queries: 8`. The single-request test passes —
the endpoint fires 6 queries at rest. Reviewer would sign off
based on the mechanical PF1 signal alone.

The diff adds a per-tenant Redis cache layer for tenant metadata
lookups. Each tenant's metadata is cached for 60 seconds. In dev
this is invisible; a single tester never hits the cache-miss
window. Under 50VU load with 40 distinct tenants rotating
through the endpoint, each request incurs a cache-miss ~30% of
the time — and the cache-miss path fires a fresh tenant lookup
+ ACL check + audit log write, three additional queries per
miss.

`mcp__ai-testing-agent__run_resilience_tests` returns:

- `queries_per_request_p95: 22` (baseline PF1 ceiling: 8)
- `queries_per_request_scale_factor: 3.66` (scale factor
  threshold: 1.2)
- `p95_latency_ms: 620` (threshold: 500ms)
- `error_rate: 0.008` (under threshold — no error signal)
- `diff_regions: ["tenant_metadata_cache_miss_path",
  "audit_log_write_in_serializer"]`

Two of the four verdict bands FAIL: **scale factor** (3.66 vs
1.2 threshold) and **p95 latency** (620ms vs 500ms threshold).
The mechanical PF1 test passes because it never encounters the
cache-miss window. Only A9.4 catches this class.

**Reviewer emits FAIL** with two A9.4 findings pointing at the
same root cause — the tenant metadata cache-miss path fires
three additional queries per miss AND the audit log write in
the serializer is on the request path. Suggestion names the
concrete fix: hoist the tenant metadata cache warm-up to app
boot AND move the audit log write to a background queue.

## Diff summary

- `modules/invoices/views.py` — new `_get_tenant_meta(tenant_id)`
  helper wraps Redis; on miss, fires the tenant fetch + ACL
  check + audit log write inline.
- `modules/invoices/serializers.py` — the invoice serializer
  now calls `_get_tenant_meta(inv.tenant_id)` per row (fine at
  rest — cached — bad on cold cache windows).

## Envelope produced by performance-reviewer

Emits FAIL with two A9.4 findings:

- `a9-4-n-plus-one-under-load` HIGH — the 3.66 scale factor
  names the tenant-cache-miss-path amplification.
- `a9-4-latency-regression-under-load` HIGH — the 620ms p95
  vs 500ms threshold + delta named + baseline cited from
  `.claude/gates/perf.json`.

Plus a floor-level `over-eager-serialization` MEDIUM finding
(the audit log write in the serializer is a per-request
side-effect that shouldn't be there regardless of load).
