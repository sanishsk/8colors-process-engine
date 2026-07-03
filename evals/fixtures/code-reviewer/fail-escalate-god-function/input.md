# fail-escalate-god-function

Diff under review:

```python
# modules/orders/checkout.py
def process_checkout(cart, user, payment_method, address, coupon_code):
    # 1. validate cart
    if not cart.items:
        raise ValueError("empty cart")
    for item in cart.items:
        if item.stock < item.qty:
            raise ValueError(f"out of stock: {item.sku}")

    # 2. apply coupon
    discount = 0
    if coupon_code:
        c = Coupon.get(coupon_code)
        if c and c.valid_for(user):
            if c.type == "pct":
                discount = cart.total * (c.value / 100)
            elif c.type == "flat":
                discount = c.value
            elif c.type == "bogo":
                cheapest = min(cart.items, key=lambda i: i.unit_price)
                discount = cheapest.unit_price

    # 3. compute tax
    tax_rate = TAX_RATES.get(address.state, 0.08)
    subtotal = cart.total - discount
    tax = subtotal * tax_rate
    total = subtotal + tax

    # 4. charge payment
    if payment_method.type == "card":
        result = stripe.charge(payment_method.token, int(total * 100))
    elif payment_method.type == "wallet":
        result = wallet.debit(user.wallet_id, total)
    else:
        raise ValueError("unknown payment")
    if not result.ok:
        raise PaymentError(result.error)

    # 5. create order
    order = Order(user=user, total=total, tax=tax, discount=discount)
    for item in cart.items:
        order.lines.append(OrderLine(sku=item.sku, qty=item.qty, price=item.unit_price))
    order.save()

    # 6. reduce stock
    for item in cart.items:
        product = Product.get(item.sku)
        product.stock -= item.qty
        product.save()

    # 7. send email
    send_email(user.email, "order_confirmation", {"order_id": order.id, "total": total})

    # 8. clear cart
    cart.items = []
    cart.save()

    return order
```

No tests provided. No error handling around the stock reduction (what if it fails after payment?). No transaction boundary.

## Prompt

You are the code-reviewer gate. Review the diff for quality, security,
and maintainability. Emit a gate envelope.

## Expected behavior

God function doing 8 things. No transaction — payment succeeds but
stock reduction can fail, leaving the DB inconsistent. No tests. This
is fixable by an agent (extract 8 helpers, wrap in a transaction, add
tests), so failure_class = worker_quality, not task_underspecified.
Verdict FAIL. Multiple HIGH findings expected.
