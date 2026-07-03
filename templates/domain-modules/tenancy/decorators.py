"""Tenancy decorators — enforce membership + per-org role.

Distinct from `auth.decorators`:
    auth.owner_required     → platform-owner (rotate secrets, etc.)
    tenancy.require_org_role(OrgRole.owner)
                            → owner OF THIS ORG (invite/remove
                              members, change org settings)

Both may be needed on some endpoints. The composition rule: apply
the STRONGER gate outermost. `@auth.owner_required` on the outer
line covers cross-org platform-wide access; per-org checks go under.
"""

from __future__ import annotations

from functools import wraps

from flask import abort, redirect, request, url_for
from flask_login import current_user

from modules.tenancy.context import current_org_id


def _redirect_to_login():
    return redirect(url_for("auth.login", next=request.url))


def _redirect_to_switch():
    return redirect(url_for("tenancy.switch", next=request.url))


def require_membership(f):
    """Assert current_user is a member of current_org.

    Redirects to /auth/login if unauthenticated. Redirects to
    /orgs/switch if no current org is set. Aborts 403 if the user
    is authenticated + has an org selected but is not a member.
    """
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not current_user.is_authenticated:
            return _redirect_to_login()

        oid = current_org_id()
        if oid is None:
            return _redirect_to_switch()

        from modules.db import session
        from modules.tenancy.models.organization import Membership

        m = (
            session.query(Membership)
            .filter(Membership.user_id == current_user.id)
            .filter(Membership.org_id == oid)
            .one_or_none()
        )
        if m is None:
            abort(403, "not a member of the current organization")
        # Stash for downstream — decorators/views can read the role
        # without re-querying.
        from flask import g
        g.current_membership = m
        return f(*args, **kwargs)
    return wrapper


def require_org_role(role):
    """Assert the current membership's role is at least `role`.

    `role` is an OrgRole. Passing `OrgRole.admin` allows admin OR
    owner. Passing `OrgRole.owner` allows owner only.

    Composes ON TOP OF require_membership — a naked @require_org_role
    without @require_membership above it aborts 403 because
    g.current_membership won't be set.
    """
    from modules.tenancy.models.organization import OrgRole

    def _decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            from flask import g
            m = getattr(g, "current_membership", None)
            if m is None:
                # Not gated by require_membership — refuse to guess.
                abort(500, "require_org_role used without require_membership")
            if role is OrgRole.owner and not m.role.is_owner:
                abort(403, "org owner role required")
            if role is OrgRole.admin and not m.role.is_admin_or_owner:
                abort(403, "org admin or owner role required")
            # OrgRole.member: any authenticated membership passes.
            return f(*args, **kwargs)
        return wrapper
    return _decorator
