"""SQLAlchemy models for the api-credentials domain module.

Two tables:
    api_credentials         — one encrypted row per provider
    api_credential_audit    — access log (set / read / delete events)

Design choices:
    * `encrypted_value` is BLOB (Fernet-encoded bytes; base64 URL-safe
      inside the token but stored as raw bytes for byte-integrity).
    * `last_four` is stored in plaintext so the admin UI can render a
      preview without decrypting. Anyone with DB read can see it —
      that's the point.
    * `created_by` / `updated_by` are FKs to the users table (assumed
      to exist; adjust the ForeignKey target to match your project).
    * Audit rows NEVER contain the plaintext. Only who / when / IP /
      user-agent + the action.
"""

from __future__ import annotations

import datetime as dt
from typing import Optional

from sqlalchemy import (
    BigInteger,
    Column,
    DateTime,
    ForeignKey,
    Index,
    LargeBinary,
    String,
    UniqueConstraint,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

# Import the project's declarative base — adjust the path to match
# where your app defines it. Common shape: `from modules.db import Base`.
try:
    from modules.db import Base  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover — during isolated tests
    from sqlalchemy.orm import DeclarativeBase

    class Base(DeclarativeBase):
        pass


class ApiCredential(Base):
    """Encrypted API key row, one per provider."""

    __tablename__ = "api_credentials"
    __table_args__ = (
        UniqueConstraint("provider", name="uq_api_credentials_provider"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    provider: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    encrypted_value: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    last_four: Mapped[str] = mapped_column(String(4), nullable=False)
    created_by: Mapped[Optional[int]] = mapped_column(
        BigInteger, ForeignKey("users.id"), nullable=True
    )
    updated_by: Mapped[Optional[int]] = mapped_column(
        BigInteger, ForeignKey("users.id"), nullable=True
    )
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False
    )
    updated_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=text("now()"),
        onupdate=dt.datetime.utcnow,
        nullable=False,
    )

    def preview(self) -> str:
        return f"…{self.last_four}"


class ApiCredentialAudit(Base):
    """One row per read/write/delete access. NEVER contains plaintext."""

    __tablename__ = "api_credential_audit"
    __table_args__ = (
        Index("ix_api_credential_audit_provider_ts", "provider", "created_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    provider: Mapped[str] = mapped_column(String(64), nullable=False)
    action: Mapped[str] = mapped_column(String(16), nullable=False)  # set | read | delete
    actor_user_id: Mapped[Optional[int]] = mapped_column(
        BigInteger, ForeignKey("users.id"), nullable=True
    )
    ip_address: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    user_agent: Mapped[Optional[str]] = mapped_column(String(512), nullable=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False
    )
