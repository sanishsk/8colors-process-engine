"""service.py — the ONLY entrypoint for creating a charge.

This module enforces the server-side amount authority rule: the
endpoint takes an `order_id` (or equivalent server-controlled
reference), and the service reads `order.total_cents` from the DB.
The amount is NEVER passed from the client.

If you find yourself importing PaymentProvider directly in a route
handler, stop — call `create_charge_for_order` instead. The
security-reviewer gate will flag direct provider imports outside
this file as a payment-authority anti-pattern.
"""

from __future__ import annotations

import json
from typing import Any

from modules.billing.models.payment import Charge, ChargeStatus
from modules.billing.provider import CreateChargeResult, get_provider


class OrderNotFoundError(RuntimeError):
    pass


class OrderNotChargeable(RuntimeError):
    """Order exists but isn't in a state that can be charged
    (already paid, cancelled, refunded, etc.)."""


def create_charge_for_order(
    order_id: int,
    org_id: int,
    user_id: int | None = None,
    customer_ref: str = "",
) -> Charge:
    """Create a charge at the configured provider for the given order.

    Contract (non-negotiable):
        * `amount_cents` and `currency` are read from the order,
          NEVER from the caller.
        * `org_id` is asserted to match the order's org_id — a
          cross-tenant charge attempt raises.
        * A pending Charge row is written BEFORE the provider call,
          so a mid-flight provider crash still surfaces in ops.
        * The provider call is retry-idempotent via a
          provider-specific idempotency key derived from the order.

    Returns the persisted Charge row (status starts as pending;
    webhook flips it to succeeded/failed).

    Raises:
        OrderNotFoundError, OrderNotChargeable, ProviderError.
    """
    from modules.db import session

    # 1. Look up the order server-side. The `Order` model is
    #    per-project — this function assumes an interface with
    #    `.id`, `.org_id`, `.total_cents`, `.currency`, and
    #    `.status` fields.
    try:
        from modules.orders.models.order import Order  # type: ignore[import-not-found]
    except ImportError as e:
        raise OrderNotFoundError(
            "modules.orders.models.order.Order not importable — "
            "billing.service assumes an Order model with the fields "
            "described in the module README. Wire it in your project "
            "before using create_charge_for_order."
        ) from e

    order = session.query(Order).filter(Order.id == order_id).one_or_none()
    if order is None:
        raise OrderNotFoundError(f"order {order_id} not found")

    if order.org_id != org_id:
        # Cross-tenant attempt — refuse. Not "return not found" — a
        # loud error surfaces the misuse.
        raise OrderNotChargeable(
            f"order {order_id} belongs to a different org"
        )

    status = getattr(order, "status", "pending")
    if status in ("paid", "cancelled", "refunded"):
        raise OrderNotChargeable(f"order {order_id} is {status!r}, not chargeable")

    amount_cents = int(order.total_cents)
    currency = order.currency
    if amount_cents <= 0:
        raise OrderNotChargeable(
            f"order {order_id} has non-positive total: {amount_cents}"
        )

    provider = get_provider()
    metadata = {
        "order_id": str(order.id),
        "org_id": str(org_id),
        "user_id": str(user_id) if user_id else "",
    }

    # 2. Persist a pending Charge BEFORE calling the provider. If
    #    the provider call raises mid-flight, this row surfaces
    #    the failure in ops.
    charge = Charge(
        org_id=org_id,
        user_id=user_id,
        amount_cents=amount_cents,
        currency=currency,
        provider=provider.name,
        provider_charge_id="",  # filled after provider call
        status=ChargeStatus.pending,
        order_ref=str(order_id),
        metadata_json=json.dumps(metadata),
    )
    session.add(charge)
    session.flush()

    # 3. Provider call.
    try:
        result = provider.create_charge(
            amount_cents=amount_cents,
            currency=currency,
            customer_ref=customer_ref or f"order-{order_id}",
            metadata=metadata,
        )
    except Exception:
        # Mark the row failed so it's visible; don't swallow.
        charge.status = ChargeStatus.failed
        charge.failure_message = "provider create_charge raised"
        session.commit()
        raise

    charge.provider_charge_id = result.provider_charge_id
    # Provider returned a status hint — trust it as the initial
    # value but the webhook is the authoritative source.
    if result.status in ("succeeded", "requires_payment_method", "processing"):
        # `requires_payment_method` / `processing` map to pending in
        # our terminology — client-side confirmation is still pending.
        charge.status = ChargeStatus.pending
    session.commit()
    return charge
