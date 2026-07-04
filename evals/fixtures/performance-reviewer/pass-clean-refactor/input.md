# pass-clean-refactor

Refactor of a slow endpoint. Before:

```python
# BEFORE — modules/orders/views.py
@bp.get("/orders")
@login_required
def list_orders():
    orders = (
        Order.query
        .filter(Order.org_id == current_org_id())
        .order_by(Order.created_at.desc())
        .limit(50)
        .all()
    )
    return jsonify(OrderSchema(many=True).dump(orders))
```

After (staged diff):

```python
# AFTER — modules/orders/views.py
from sqlalchemy.orm import selectinload

@bp.get("/orders")
@login_required
def list_orders():
    cursor = request.args.get("cursor")
    limit = min(int(request.args.get("limit", 50)), 200)

    q = (
        Order.query
        .filter(Order.org_id == current_org_id())
        .options(
            selectinload(Order.customer),
            selectinload(Order.shipping),
            selectinload(Order.lines).selectinload(OrderLine.product),
        )
        .order_by(Order.created_at.desc(), Order.id.desc())
    )
    if cursor:
        cursor_ts, cursor_id = _decode_cursor(cursor)
        q = q.filter(tuple_(Order.created_at, Order.id) < (cursor_ts, cursor_id))

    orders = q.limit(limit).all()
    next_cursor = _encode_cursor(orders[-1].created_at, orders[-1].id) if orders else None
    return jsonify({"orders": OrderSchema(many=True).dump(orders), "cursor": next_cursor})
```

## Prompt

You are the performance-reviewer gate. Review and emit a gate
envelope. Focus on the judgment 20%.

## Expected behavior

The refactor addresses all three concerns from the previous
`fail-unbounded-list-endpoint` + `fail-nplusone-in-serializer`
fixtures:

1. Keyset pagination with a max-limit clamp (200) — no more
   unbounded scan; no more integer-overflow OFFSET.
2. Explicit selectinload chain on customer / shipping / lines /
   product — the schema's `attribute='product.sku'` no longer
   triggers a lazy load per row.
3. Response shape includes the next cursor for the frontend to walk
   pages.

Nothing in the seven judgment surfaces fires. Verdict PASS,
failure_class none. Summary should briefly acknowledge the
mechanical layer will also verify (PF1 query-count assertion is the
right follow-up if not already in the adopter's suite).
