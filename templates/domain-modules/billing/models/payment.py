"""Charge + Refund + PaymentEvent models.

Design choices:
    * Money as BIGINT cents everywhere in the schema.
    * ChargeStatus / RefundStatus as typed enums (never magic strings).
    * PaymentEvent is the idempotency ledger — unique on
      (provider, event_id) so duplicate webhook deliveries are
      caught before double-processing.
    * All three tables carry `org_id` and get FORCE-mode RLS applied
      by the migration.
    * `provider_charge_id` is unique per provider — the same charge
      id from Stripe vs Razorpay is not a collision.
"""

from __future__ import annotations

import datetime as dt
import enum
from typing import Optional

from sqlalchemy import (
    BigInteger,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

try:
    from modules.db import Base  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover — isolated test scaffolding
    from sqlalchemy.orm import DeclarativeBase

    class Base(DeclarativeBase):
        pass


class ChargeStatus(str, enum.Enum):
    pending = "pending"                # created, not yet confirmed by provider
    succeeded = "succeeded"            # provider confirmed via webhook
    failed = "failed"                  # provider rejected
    refunded = "refunded"              # fully refunded
    partially_refunded = "partially_refunded"

    @property
    def is_terminal(self) -> bool:
        return self in (
            ChargeStatus.succeeded,
            ChargeStatus.failed,
            ChargeStatus.refunded,
        )


class RefundStatus(str, enum.Enum):
    pending = "pending"
    succeeded = "succeeded"
    failed = "failed"


class Charge(Base):
    __tablename__ = "charges"
    __table_args__ = (
        UniqueConstraint("provider", "provider_charge_id",
                         name="uq_charges_provider_charge_id"),
        Index("ix_charges_org_created", "org_id", "created_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    org_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("organizations.id"), nullable=False, index=True,
    )
    user_id: Mapped[Optional[int]] = mapped_column(
        BigInteger, ForeignKey("users.id"), nullable=True,
    )
    amount_cents: Mapped[int] = mapped_column(BigInteger, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    provider: Mapped[str] = mapped_column(String(32), nullable=False)
    provider_charge_id: Mapped[str] = mapped_column(String(255), nullable=False)
    status: Mapped[ChargeStatus] = mapped_column(
        Enum(ChargeStatus, native_enum=False, length=32),
        nullable=False,
        default=ChargeStatus.pending,
        server_default=ChargeStatus.pending.value,
    )
    order_ref: Mapped[Optional[str]] = mapped_column(String(128), nullable=True)
    failure_message: Mapped[Optional[str]] = mapped_column(String(512), nullable=True)
    metadata_json: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False,
    )
    updated_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=text("now()"),
        onupdate=dt.datetime.utcnow,
        nullable=False,
    )


class Refund(Base):
    __tablename__ = "refunds"
    __table_args__ = (
        UniqueConstraint("provider", "provider_refund_id",
                         name="uq_refunds_provider_refund_id"),
        Index("ix_refunds_charge", "charge_id"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    org_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("organizations.id"), nullable=False, index=True,
    )
    charge_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("charges.id"), nullable=False,
    )
    amount_cents: Mapped[int] = mapped_column(BigInteger, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    reason: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    provider: Mapped[str] = mapped_column(String(32), nullable=False)
    provider_refund_id: Mapped[str] = mapped_column(String(255), nullable=False)
    status: Mapped[RefundStatus] = mapped_column(
        Enum(RefundStatus, native_enum=False, length=32),
        nullable=False,
        default=RefundStatus.pending,
        server_default=RefundStatus.pending.value,
    )
    created_by: Mapped[Optional[int]] = mapped_column(
        BigInteger, ForeignKey("users.id"), nullable=True,
    )
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False,
    )
    updated_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=text("now()"),
        onupdate=dt.datetime.utcnow,
        nullable=False,
    )


class PaymentEvent(Base):
    """Idempotency ledger — every processed webhook event lands here.

    The unique constraint on (provider, event_id) is what makes
    webhook processing idempotent: a duplicate delivery hits the
    UNIQUE violation, we catch it, and skip re-processing.

    `org_id` is nullable because some events (e.g. account.updated)
    have no org context.
    """

    __tablename__ = "payment_events"
    __table_args__ = (
        UniqueConstraint("provider", "event_id",
                         name="uq_payment_events_provider_event_id"),
        Index("ix_payment_events_org_created", "org_id", "created_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    org_id: Mapped[Optional[int]] = mapped_column(
        BigInteger, ForeignKey("organizations.id"), nullable=True, index=True,
    )
    provider: Mapped[str] = mapped_column(String(32), nullable=False)
    event_id: Mapped[str] = mapped_column(String(255), nullable=False)
    event_type: Mapped[str] = mapped_column(String(64), nullable=False)
    payload_json: Mapped[str] = mapped_column(Text, nullable=False)
    processed_at: Mapped[Optional[dt.datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True,
    )
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False,
    )
