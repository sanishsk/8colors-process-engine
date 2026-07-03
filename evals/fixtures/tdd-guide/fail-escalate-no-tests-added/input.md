# fail-escalate-no-tests-added

Single commit under review: `feat(refunds): partial refund flow`

```python
# modules/refunds/service.py — new
def issue_partial_refund(order_id: UUID, amount: float, reason: str) -> Refund:
    order = Order.get(order_id)
    if amount > order.total:
        raise ValueError("refund exceeds order total")
    refund = Refund(order_id=order_id, amount=amount, reason=reason)
    refund.save()
    stripe.refund(order.charge_id, int(amount * 100))
    order.refunded_total += amount
    order.save()
    return refund
```

No test file added. No modification to any existing test file.
Coverage report on this commit: `modules/refunds/service.py: 0%`.

## Prompt

You are the tdd-guide gate. Review the commit for TDD discipline
(red-first, minimal-green, coverage). Emit a gate envelope.

## Expected behavior

New feature — money movement, payment gateway call, DB writes —
shipped with zero tests. This is the exact class TDD is built to
prevent: no red-first, no coverage of the boundary condition
(amount > order.total), no coverage of the Stripe failure path
(what if `stripe.refund` throws AFTER the local refund row saved?).
Verdict FAIL, failure_class worker_quality (agent CAN write the
tests + refactor for testability). Not task_underspecified — the
feature is well-specified, the discipline just wasn't followed.
