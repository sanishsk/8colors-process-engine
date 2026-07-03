"""Stripe adapter — implements PaymentProvider using the stripe SDK.

Reads credentials via `api-credentials` if installed, falling back
to `STRIPE_SECRET_KEY` env var. Webhook secret is always from env
(`STRIPE_WEBHOOK_SECRET`) since it's a different string that Stripe
generates per webhook endpoint.
"""

from __future__ import annotations

import logging
import os
from typing import Any

from modules.billing.provider import (
    CreateChargeResult,
    PaymentProvider,
    ProviderError,
    VerifiedEvent,
    WebhookSignatureError,
    _get_credential,
    register_provider,
)

logger = logging.getLogger(__name__)


class StripeAdapter:
    name = "stripe"

    def __init__(self):
        try:
            import stripe
        except ImportError as e:
            raise ProviderError(
                "stripe SDK not installed — add `stripe>=8.0` to "
                "pyproject.toml and pip install -e .[dev]"
            ) from e
        self._stripe = stripe

        secret = _get_credential("stripe")
        if not secret:
            raise ProviderError(
                "no Stripe API key configured — either save it via "
                "api-credentials admin UI or set STRIPE_SECRET_KEY in .env"
            )
        stripe.api_key = secret

        self._webhook_secret = os.environ.get("STRIPE_WEBHOOK_SECRET")
        if not self._webhook_secret:
            # Deliberately soft-fail here so dev environments (that
            # don't process webhooks) can still boot. Any incoming
            # webhook will hard-fail at verify_webhook() below with a
            # WebhookSignatureError — which the blueprint returns as
            # 400 to Stripe. If STRIPE_LIVE_MODE=1 is set (production
            # marker), we escalate to a hard startup failure so a
            # misconfigured prod deploy never quietly accepts events.
            if os.environ.get("STRIPE_LIVE_MODE") == "1":
                raise ProviderError(
                    "STRIPE_WEBHOOK_SECRET is required in live mode "
                    "(STRIPE_LIVE_MODE=1) but is not set."
                )
            logger.warning(
                "STRIPE_WEBHOOK_SECRET is not set. verify_webhook will "
                "reject every incoming event with 400. Set the secret "
                "before enabling live webhooks; set STRIPE_LIVE_MODE=1 "
                "to make this a hard startup failure instead."
            )

    def create_charge(
        self,
        amount_cents: int,
        currency: str,
        customer_ref: str,
        metadata: dict,
    ) -> CreateChargeResult:
        if amount_cents <= 0:
            raise ProviderError("amount_cents must be positive")
        try:
            # Stripe uses "payment_intents" as the modern charge API;
            # the older `Charge.create` is deprecated for new
            # integrations. This adapter uses PaymentIntent.
            intent = self._stripe.PaymentIntent.create(
                amount=int(amount_cents),
                currency=currency.lower(),
                customer=customer_ref,
                metadata={str(k): str(v) for k, v in metadata.items()},
                # Automatic confirmation off — the client-side
                # Stripe.js confirms after the customer approves.
                # For server-side confirmation (subscriptions, etc.),
                # add `confirm=True, payment_method=<pm_...>`.
                automatic_payment_methods={"enabled": True},
            )
        except Exception as e:  # noqa: BLE001 — surface as ProviderError
            raise ProviderError(f"Stripe create_charge failed: {e}") from e
        return CreateChargeResult(
            provider_charge_id=intent["id"],
            status=intent.get("status", "pending"),
            raw_response=dict(intent),
        )

    def verify_webhook(
        self,
        payload_bytes: bytes,
        signature_header: str,
    ) -> VerifiedEvent:
        if not self._webhook_secret:
            raise WebhookSignatureError(
                "STRIPE_WEBHOOK_SECRET is not set — cannot verify webhook"
            )
        try:
            event = self._stripe.Webhook.construct_event(
                payload=payload_bytes,
                sig_header=signature_header,
                secret=self._webhook_secret,
            )
        except Exception as e:  # noqa: BLE001 — always reclassify as sig err
            # Log ONLY the provider name + payload length — never the
            # raw payload or signature (leaks information to an
            # attacker probing the endpoint).
            logger.warning(
                "Stripe webhook signature verification failed "
                "(payload_len=%d)", len(payload_bytes),
            )
            raise WebhookSignatureError(str(e)) from e

        return VerifiedEvent(
            event_id=event["id"],
            event_type=event["type"],
            payload=dict(event["data"]["object"]),
            raw=payload_bytes,
        )

    def refund(
        self,
        provider_charge_id: str,
        amount_cents: int,
        reason: str,
    ) -> CreateChargeResult:
        if amount_cents <= 0:
            raise ProviderError("amount_cents must be positive")
        try:
            refund = self._stripe.Refund.create(
                payment_intent=provider_charge_id,
                amount=int(amount_cents),
                reason=(reason or "requested_by_customer")[:255],
            )
        except Exception as e:  # noqa: BLE001
            raise ProviderError(f"Stripe refund failed: {e}") from e
        return CreateChargeResult(
            provider_charge_id=refund["id"],
            status=refund.get("status", "pending"),
            raw_response=dict(refund),
        )


# Register at import time so `get_provider("stripe")` resolves.
register_provider("stripe", StripeAdapter)
