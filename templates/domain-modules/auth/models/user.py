"""User model + Role enum + failed-login tracker.

Design choices:
    * Role as a typed Python enum, stored as a SQL VARCHAR — never
      raw strings scattered in code. The enum is the source of truth.
    * `password_hash` is bcrypt-format; NEVER stores plaintext.
    * `password_verified_at` timestamps the last successful password
      confirmation — read by @require_password_reauth to enforce the
      15-minute step-up window.
    * `failed_logins` is a separate table (append-only) — the
      rate-limit read counts recent rows per IP, so a legitimate user
      logging in from many devices doesn't get penalized.
"""

from __future__ import annotations

import datetime as dt
import enum
from typing import Optional

from flask_login import UserMixin
from sqlalchemy import (
    BigInteger,
    Column,
    DateTime,
    Enum,
    Index,
    String,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

try:
    from modules.db import Base  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover — isolated test scaffolding
    from sqlalchemy.orm import DeclarativeBase

    class Base(DeclarativeBase):
        pass


class Role(str, enum.Enum):
    """Typed roles — enum-as-str for easy JSON serialization."""

    owner = "owner"    # can rotate credentials, delete users, wipe data
    admin = "admin"    # can edit settings but NOT credentials or destroy
    member = "member"  # baseline authenticated user

    @property
    def is_owner(self) -> bool:
        return self is Role.owner

    @property
    def is_admin_or_owner(self) -> bool:
        return self in (Role.owner, Role.admin)


class User(Base, UserMixin):
    """One row per human. `password_hash` is bcrypt; NEVER plaintext.

    UserMixin provides `is_authenticated` / `is_active` / `get_id()`
    for Flask-Login. Override any of them to project needs (e.g.
    `is_active = False` for disabled accounts).
    """

    __tablename__ = "users"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    email: Mapped[str] = mapped_column(String(255), nullable=False, unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    role: Mapped[Role] = mapped_column(
        Enum(Role, native_enum=False, length=16),
        nullable=False,
        default=Role.member,
        server_default=Role.member.value,
    )
    display_name: Mapped[Optional[str]] = mapped_column(String(128), nullable=True)
    is_disabled: Mapped[bool] = mapped_column(
        String(1),  # portability: bool column stored as "0"/"1"
        nullable=False,
        default="0",
        server_default="0",
    )
    password_verified_at: Mapped[Optional[dt.datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True,
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

    @property
    def is_active(self) -> bool:
        return self.is_disabled != "1"

    def stamp_password_verified(self) -> None:
        """Called after successful login or /reauth. Resets step-up window."""
        self.password_verified_at = dt.datetime.now(dt.timezone.utc)


class FailedLogin(Base):
    """Append-only failed-attempt log — feeds the rate limiter."""

    __tablename__ = "failed_logins"
    __table_args__ = (
        Index("ix_failed_logins_ip_ts", "ip_address", "created_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    email_attempted: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    ip_address: Mapped[str] = mapped_column(String(64), nullable=False)
    user_agent: Mapped[Optional[str]] = mapped_column(String(512), nullable=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False,
    )
