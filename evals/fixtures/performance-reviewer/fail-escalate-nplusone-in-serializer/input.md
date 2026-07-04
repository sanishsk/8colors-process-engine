# fail-escalate-nplusone-in-serializer

Marshmallow serializer added for a `/orders` list endpoint:

```python
# modules/orders/schema.py
from marshmallow import Schema, fields


class OrderLineSchema(Schema):
    id = fields.Int()
    sku = fields.Str(attribute="product.sku")   # lazy load: order_line.product
    name = fields.Str(attribute="product.name") # same product, second lazy access
    price_cents = fields.Int()
    quantity = fields.Int()


class OrderSchema(Schema):
    id = fields.Int()
    customer_email = fields.Str(attribute="customer.email")   # lazy: order.customer
    customer_name = fields.Str(attribute="customer.full_name") # same lookup, second access
    shipping_address = fields.Str(attribute="shipping.address_line")  # lazy: order.shipping
    lines = fields.List(fields.Nested(OrderLineSchema))              # lazy: order.lines
    total_cents = fields.Int()
    status = fields.Str()
```

Used in the view like:

```python
# modules/orders/views.py
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

Context: an order averages ~4 order_lines. The endpoint IS
paginated to 50 orders. No `selectinload` / `joinedload` anywhere.

## Prompt

You are the performance-reviewer gate. Review and emit a gate
envelope. Focus on the judgment 20%.

## Expected behavior

The serializer schema's `attribute="product.sku"` + `"customer.email"`
patterns are the trap: Marshmallow calls `getattr(line, "product")`
which triggers a lazy load per row. For 50 orders × 4 lines each, this
is:
  - 1 SELECT to fetch orders
  - 50 SELECTs to fetch customers (one per order)
  - 50 SELECTs to fetch shipping addresses
  - 200 SELECTs to fetch products (one per line)
= **~301 queries** where 4 would suffice.

PF1's `templates/tests/query-count.test.py.template` would catch this
at runtime. The JUDGMENT layer observation is that the SCHEMA SHAPE
is the design decision that guarantees the N+1 — no ORM eager-load
directive can prevent it if the schema does per-attribute lookups on
lazy relationships.

Verdict FAIL, failure_class worker_quality. Primary finding rule =
`over-eager-serialization` (the schema shape causes the runtime
N+1). CITE PF1's test as the mechanical layer that would catch it;
the fix is either (a) an eager-load in the view, OR (b) a schema
redesign that returns nested-object shape directly.
