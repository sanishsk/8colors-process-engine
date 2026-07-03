"""PaymentProvider protocol + factory.

The protocol pins the shape every concrete adapter must implement.
The factory reads the project's default provider (from
`.process-engine.yaml` or an env var) and returns the singleton.

Adapters live under `providers/*.py`. Ship a new one by:
    1. Implement the Protocol.
    2. Register it in the `_ADAPTERS` map below.
    3. Set BILLING_PROVIDER in .env (or process-engine.yaml).

Ship-safe defaults: no adapter is registered by default until the
project explicitly opts in — this prevents `pe install` from
implicitly creating a Stripe live connection.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class CreateChargeResult:
    """What every provider must return from create_charge."""

    provider_charge_id: str      # provider's unique id for this charge
    status: str                  # "pending" / "succeeded" / "failed"
    raw_response: dict           # provider's full response, for debugging


@dataclass(frozen=True)
class VerifiedEvent:
    """What every provider must return from verify_webhook."""

    event_id: str                # provider's event id (idempotency key)
    event_type: str              # e.g. "charge.succeeded"
    payload: dict                # decoded event data
    raw: bytes                   # raw request body (for audit)


class ProviderError(RuntimeError):
    """Raised when a provider call fails in a way the caller should
    surface — configuration errors, HMAC failures, provider outages."""


class WebhookSignatureError(ProviderError):
    """Raised when webhook HMAC verification fails.

    NEVER catch this and treat the event as valid. NEVER log the raw
    payload contents at INFO level on signature failure (an attacker
    who sees the log format can craft forgeries). Log the length and
    provider name only.
    """


@runtime_checkable
class PaymentProvider(Protocol):
    """The shape every adapter implements."""

    name: str
    """Short provider name — matches Charge.provider column."""

    def create_charge(
        self,
        amount_cents: int,
        currency: str,
        customer_ref: str,
        metadata: dict,
    ) -> CreateChargeResult:
        """Create a charge at the provider.

        Args:
            amount_cents: NEVER trusted from client input — service
                          layer looks this up from order.total_cents.
            currency: ISO 4217 uppercase.
            customer_ref: provider-side customer id (created earlier
                          via provider's customer API).
            metadata: dict of key/values persisted on the charge for
                      later audit (e.g. {"order_id": "...", "user_id": ...}).
        """
        ...

    def verify_webhook(
        self,
        payload_bytes: bytes,
        signature_header: str,
    ) -> VerifiedEvent:
        """Verify a webhook signature and decode the event.

        Raises WebhookSignatureError on any verification failure.
        Never returns "unverified but decoded" — either the signature
        is valid or the event is refused.
        """
        ...

    def refund(
        self,
        provider_charge_id: str,
        amount_cents: int,
        reason: str,
    ) -> CreateChargeResult:
        """Issue a refund. `amount_cents` may be less than the
        original charge for partial refunds."""
        ...


# ─── Adapter registry ───────────────────────────────────────────

_ADAPTERS: dict[str, type] = {}


def register_provider(name: str, adapter_cls: type) -> None:
    """Register a concrete adapter under `name`.

    Idempotent — safe to call at import time.
    """
    _ADAPTERS[name] = adapter_cls


def get_provider(name: str | None = None) -> PaymentProvider:
    """Return the singleton provider instance.

    Resolution order for `name`:
        1. Explicit argument
        2. BILLING_PROVIDER env var
        3. First registered adapter (single-provider projects)
        4. Raise ProviderError

    Adapter's `__init__` reads its own config from env / credential
    service — this factory just wires the name → class mapping.
    """
    name = name or os.environ.get("BILLING_PROVIDER") or (
        next(iter(_ADAPTERS), None)
    )
    if not name:
        raise ProviderError(
            "no billing provider registered — import a provider "
            "module (e.g. `from modules.billing.providers.stripe import *`) "
            "or set BILLING_PROVIDER in .env"
        )
    adapter_cls = _ADAPTERS.get(name)
    if adapter_cls is None:
        raise ProviderError(
            f"unknown billing provider: {name!r}. "
            f"Registered: {sorted(_ADAPTERS.keys())}"
        )
    # Simple singleton — providers are cheap to construct and their
    # state is API-key-only.
    return adapter_cls()


def _get_credential(provider: str) -> str | None:
    """Resolve a provider secret via api-credentials module if
    installed, falling back to the legacy env-var name."""
    try:
        from modules.api_credentials.credential_service import get_credential
        v = get_credential(provider)
        if v:
            return v
    except ImportError:
        pass
    # Fallback: provider-specific env-var names.
    env_map = {
        "stripe": "STRIPE_SECRET_KEY",
        "razorpay": "RAZORPAY_KEY_SECRET",
    }
    env_name = env_map.get(provider)
    return os.environ.get(env_name) if env_name else None
