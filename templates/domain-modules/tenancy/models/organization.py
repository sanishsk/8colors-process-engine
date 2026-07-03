"""Organization + Membership models + OrgRole enum.

Design choices:
    * `Organization.slug` — URL-safe identifier, unique. Used in
      route paths `/orgs/<slug>/*` so URLs don't leak DB IDs.
    * `Membership` is the join table with a `role` — the same user
      can be an owner of org A and a member of org B; this is
      per-org role, NOT the platform-level `User.role` from auth.
    * `OrgRole` distinct from `Role` from auth — enforced at the
      naming layer so `require_org_role(Role.owner)` reads wrong.
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
    String,
    UniqueConstraint,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

try:
    from modules.db import Base  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover — isolated test scaffolding
    from sqlalchemy.orm import DeclarativeBase

    class Base(DeclarativeBase):
        pass


class OrgRole(str, enum.Enum):
    """Per-organization role. DISTINCT from `auth.User.role`.

    An org owner can invite/remove members, change org settings,
    delete the org. A member has read access to org data but no
    admin powers.
    """

    owner = "owner"
    admin = "admin"
    member = "member"

    @property
    def is_owner(self) -> bool:
        return self is OrgRole.owner

    @property
    def is_admin_or_owner(self) -> bool:
        return self in (OrgRole.owner, OrgRole.admin)


class Organization(Base):
    __tablename__ = "organizations"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    slug: Mapped[str] = mapped_column(String(64), nullable=False, unique=True, index=True)
    display_name: Mapped[str] = mapped_column(String(128), nullable=False)
    created_by: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("users.id"), nullable=False,
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
    # is_disabled preserves org data while blocking access — for
    # billing failures, ToS violations, etc. Use soft-disable, not
    # hard-delete, so audit trails stay intact.
    is_disabled: Mapped[bool] = mapped_column(
        String(1), nullable=False, default="0", server_default="0",
    )

    memberships: Mapped[list["Membership"]] = relationship(
        back_populates="organization", cascade="all, delete-orphan",
    )

    @property
    def is_active(self) -> bool:
        return self.is_disabled != "1"


class Membership(Base):
    __tablename__ = "memberships"
    __table_args__ = (
        UniqueConstraint("user_id", "org_id", name="uq_memberships_user_org"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("users.id"), nullable=False, index=True,
    )
    org_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("organizations.id"), nullable=False, index=True,
    )
    role: Mapped[OrgRole] = mapped_column(
        Enum(OrgRole, native_enum=False, length=16),
        nullable=False,
        default=OrgRole.member,
        server_default=OrgRole.member.value,
    )
    invited_by: Mapped[Optional[int]] = mapped_column(
        BigInteger, ForeignKey("users.id"), nullable=True,
    )
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False,
    )

    organization: Mapped["Organization"] = relationship(
        back_populates="memberships", foreign_keys=[org_id],
    )
