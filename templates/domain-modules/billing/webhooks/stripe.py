"""Stripe webhook handler — HMAC verify → idempotency dedupe → dispatch.

Contract:
    1. Signature MUST verify. WebhookSignatureError → 400, event
       ignored, minimal logging (never leak payload contents on
       signature failure).
    2. Event MUST be unique per (provider, event_id). Duplicate →
       200 OK with `{"status": "duplicate"}`. Stripe retries
       aggressively; double-processing = double-charging.
    3. Event dispatched to a per-type handler. Unknown types →
       200 OK with `{"status": "ignored"}`. Never 500 — Stripe
       will retry forever on 5xx.

Threat model:
    * An attacker POSTing a fake event MUST be rejected at the HMAC
      step (not at the DB step — no leak via response timing).
    * A legitimate retry MUST be accepted-and-deduped (Stripe treats
      any 4xx / 5xx as "retry", so responding 200 on the retry
      is what stops the queue growing).
    * A stale event whose payload references data that's since been
      deleted MUST NOT crash — log and skip.
"""

from __future__ import annotations

import json
import logging

from sqlalchemy.exc import IntegrityError

from modules.billing.models.payment import (
    Charge,
    ChargeStatus,
    PaymentEvent,
    Refund,
    RefundStatus,
)
from modules.billing.provider import (
    VerifiedEvent,
    WebhookSignatureError,
    get_provider,
)

logger = logging.getLogger(__name__)


def handle_stripe_webhook(payload_bytes: bytes, signature_header: str) -> dict:
    """Handle one incoming Stripe webhook POST.

    Returns a dict the blueprint layer serializes to JSON:
        {"status": "processed" | "duplicate" | "ignored"}

    Raises `WebhookSignatureError` (blueprint should return 400).
    Never raises anything else — all downstream failures are logged
    and swallowed so Stripe doesn't retry indefinitely.
    """
    provider = get_provider("stripe")
    event = provider.verify_webhook(payload_bytes, signature_header)

    # Idempotency insert. If this event was already processed, the
    # UNIQUE constraint fires and we skip.
    from modules.db import session

    org_id = _extract_org_id(event)
    if org_id is None:
        # Account-level events (account.updated, balance.available, …)
        # and malformed tenant events land here. We do NOT persist
        # without org_id — FORCE-mode RLS can't filter NULLs and a
        # persisted row would be cross-tenant-visible.
        logger.info(
            "Stripe webhook skipped: no org_id in metadata "
            "(event_id=%s, type=%s)",
            event.event_id, event.event_type,
        )
        return {"status": "ignored", "reason": "no_org_id",
                "event_type": event.event_type}

    row = PaymentEvent(
        org_id=org_id,
        provider="stripe",
        event_id=event.event_id,
        event_type=event.event_type,
        payload_json=json.dumps(event.payload)[:1_000_000],  # cap ~1MB
    )
    try:
        session.add(row)
        session.commit()
    except IntegrityError:
        session.rollback()
        return {"status": "duplicate", "event_id": event.event_id}

    # Dispatch to a per-type handler.
    handler = _EVENT_HANDLERS.get(event.event_type)
    if handler is None:
        return {"status": "ignored", "event_type": event.event_type}

    try:
        handler(event, session)
        row.processed_at = _now_utc()
        session.commit()
    except Exception as e:  # noqa: BLE001 — never propagate to Stripe
        logger.exception("Stripe webhook handler for %s raised: %s",
                         event.event_type, e)
        session.rollback()

    return {"status": "processed", "event_type": event.event_type}


# ─── event handlers ─────────────────────────────────────────────


def _on_payment_intent_succeeded(event: VerifiedEvent, session) -> None:
    pi_id = event.payload.get("id")
    charge = (
        session.query(Charge)
        .filter(Charge.provider == "stripe")
        .filter(Charge.provider_charge_id == pi_id)
        .one_or_none()
    )
    if charge is None:
        logger.info("payment_intent.succeeded for unknown pi_id=%s (stale?)", pi_id)
        return
    charge.status = ChargeStatus.succeeded
    charge.failure_message = None


def _on_payment_intent_failed(event: VerifiedEvent, session) -> None:
    pi_id = event.payload.get("id")
    charge = (
        session.query(Charge)
        .filter(Charge.provider == "stripe")
        .filter(Charge.provider_charge_id == pi_id)
        .one_or_none()
    )
    if charge is None:
        return
    err = event.payload.get("last_payment_error") or {}
    charge.status = ChargeStatus.failed
    charge.failure_message = (err.get("message") or "unknown")[:512]


def _on_charge_refunded(event: VerifiedEvent, session) -> None:
    pi_id = event.payload.get("payment_intent")
    charge = (
        session.query(Charge)
        .filter(Charge.provider == "stripe")
        .filter(Charge.provider_charge_id == pi_id)
        .one_or_none()
    )
    if charge is None:
        return
    amount_refunded = int(event.payload.get("amount_refunded") or 0)
    if amount_refunded >= charge.amount_cents:
        charge.status = ChargeStatus.refunded
    elif amount_refunded > 0:
        charge.status = ChargeStatus.partially_refunded


_EVENT_HANDLERS = {
    "payment_intent.succeeded": _on_payment_intent_succeeded,
    "payment_intent.payment_failed": _on_payment_intent_failed,
    "charge.refunded": _on_charge_refunded,
}


# ─── helpers ────────────────────────────────────────────────────


def _extract_org_id(event: VerifiedEvent) -> int | None:
    """Pull org_id out of the event's metadata (set by
    service.create_charge_for_order). Absent for events not
    originated by this app."""
    meta = event.payload.get("metadata") or {}
    if not isinstance(meta, dict):
        return None
    v = meta.get("org_id")
    if not v:
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _now_utc():
    import datetime as dt
    return dt.datetime.now(dt.timezone.utc)
