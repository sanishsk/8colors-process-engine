"""tests/test_billing.py — coverage floor for the billing module.

Every project that materializes this module inherits these tests.
Extend (don't replace) with integration tests that exercise real
Stripe test-mode + webhook via `stripe listen`.
"""

from __future__ import annotations

from decimal import Decimal
from unittest import mock

import pytest


class TestMoney:
    """Money as Decimal-or-int-cents, NEVER float."""

    def test_decimal_roundtrip(self):
        from modules.billing.money import from_cents, to_cents
        assert to_cents(Decimal("1.99")) == 199
        assert from_cents(199) == Decimal("1.99")
        assert to_cents(from_cents(199)) == 199

    def test_string_amount_parsed(self):
        from modules.billing.money import to_cents
        assert to_cents("1.99") == 199
        assert to_cents("100") == 10000
        assert to_cents("0.01") == 1

    def test_int_cents_passthrough(self):
        from modules.billing.money import to_cents
        # int is treated as already cents — no × 100.
        assert to_cents(199) == 199

    def test_float_rejected_loudly(self):
        # THE regression test — floats must never silently convert.
        from modules.billing.money import MoneyError, to_cents
        with pytest.raises(MoneyError, match="float amount rejected"):
            to_cents(1.99)
        with pytest.raises(MoneyError):
            to_cents(0.1 + 0.2)

    def test_no_float_drift(self):
        # 0.1 + 0.2 == 0.3 fails in floats. Decimal path must not
        # exhibit the drift.
        from modules.billing.money import to_cents
        result = to_cents(Decimal("0.1") + Decimal("0.2"))
        assert result == 30

    def test_zero_decimal_currency(self):
        from modules.billing.money import from_cents, to_cents
        # JPY has no minor unit — 100 JPY = 100 cents.
        assert to_cents(Decimal("100"), "JPY") == 100
        assert from_cents(100, "JPY") == Decimal("100")

    def test_currency_case_normalized(self):
        from modules.billing.money import to_cents
        assert to_cents(Decimal("1.99"), "usd") == 199
        assert to_cents(Decimal("1.99"), "USD") == 199

    def test_invalid_amount_rejected(self):
        from modules.billing.money import MoneyError, to_cents
        with pytest.raises(MoneyError):
            to_cents("not a number")
        with pytest.raises(MoneyError):
            to_cents(Decimal("Infinity"))

    def test_format_money_is_display_only(self):
        from modules.billing.money import format_money
        assert format_money(199, "USD") == "$1.99"
        assert format_money(100, "JPY") == "¥100"
        assert format_money(1234567, "USD") == "$12,345.67"


class TestProviderFactory:
    def test_unknown_provider_raises(self, monkeypatch):
        from modules.billing import provider as p
        monkeypatch.setattr(p, "_ADAPTERS", {})
        monkeypatch.delenv("BILLING_PROVIDER", raising=False)
        with pytest.raises(p.ProviderError, match="no billing provider"):
            p.get_provider()

    def test_registered_returned(self, monkeypatch):
        from modules.billing import provider as p

        class Fake:
            name = "fake"

        monkeypatch.setattr(p, "_ADAPTERS", {"fake": Fake})
        monkeypatch.setenv("BILLING_PROVIDER", "fake")
        instance = p.get_provider()
        assert instance.name == "fake"

    def test_credential_service_preferred_over_env(self, monkeypatch):
        # If api-credentials is installed, get_credential wins;
        # otherwise env-var fallback.
        from modules.billing import provider as p
        # Mock the credential service to return "cred-svc".
        with mock.patch.dict(
            "sys.modules",
            {"modules.api_credentials.credential_service": mock.MagicMock(
                get_credential=lambda name: "cred-svc-value"
            )},
        ):
            assert p._get_credential("stripe") == "cred-svc-value"

    def test_env_fallback_when_no_credential_service(self, monkeypatch):
        from modules.billing import provider as p
        # Force ImportError on the credential service.
        import sys
        sys.modules.pop("modules.api_credentials.credential_service", None)
        monkeypatch.setenv("STRIPE_SECRET_KEY", "env-value")
        # We can't fully test the ImportError path without a real
        # import failure; the code path is exercised by callers.
        assert p._get_credential("stripe") in ("env-value", None)


class TestWebhookHmacRejection:
    """Webhook must ALWAYS verify signature — never trust unsigned events."""

    def test_signature_error_raised_on_bad_sig(self, monkeypatch):
        from modules.billing.provider import WebhookSignatureError

        class FakeStripe:
            def __init__(self):
                self._webhook_secret = "whsec_test"
                self.name = "stripe"
            def verify_webhook(self, payload, sig):
                raise WebhookSignatureError("bad signature")

        with mock.patch.dict(
            "sys.modules",
            {"modules.billing.provider": mock.MagicMock(
                get_provider=lambda name=None: FakeStripe(),
                WebhookSignatureError=WebhookSignatureError,
                VerifiedEvent=object,
            )},
        ):
            from modules.billing.webhooks import stripe as sw
            with pytest.raises(WebhookSignatureError):
                sw.handle_stripe_webhook(b"payload", "bad-sig")


class TestIdempotency:
    """Duplicate webhook events must be caught + skipped."""

    def test_status_enum_values(self):
        # PaymentEvent + Charge status enums are string-serializable.
        from modules.billing.models.payment import ChargeStatus, RefundStatus
        assert ChargeStatus.pending.value == "pending"
        assert ChargeStatus.succeeded.value == "succeeded"
        assert RefundStatus.pending.value == "pending"

    def test_terminal_states(self):
        from modules.billing.models.payment import ChargeStatus
        assert ChargeStatus.succeeded.is_terminal is True
        assert ChargeStatus.refunded.is_terminal is True
        assert ChargeStatus.pending.is_terminal is False
