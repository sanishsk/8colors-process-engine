"""Tenancy blueprint — /orgs, /orgs/switch, /orgs/new, /orgs/<slug>/members.

Design choices:
    * Routes are keyed on `slug`, not raw ID, so URLs don't leak
      internal PKs.
    * The switch endpoint accepts a POST (not GET) — a GET switch
      would be CSRF-vulnerable via an <img src=...> tag.
    * Creating a new org auto-adds the creator as OrgRole.owner.
"""

from __future__ import annotations

import re

from flask import (
    Blueprint,
    abort,
    flash,
    redirect,
    render_template,
    request,
    url_for,
)
from flask_login import current_user, login_required
from flask_wtf.csrf import validate_csrf
from wtforms.validators import ValidationError

from modules.tenancy.context import set_current_org
from modules.tenancy.decorators import require_membership, require_org_role
from modules.tenancy.models.organization import OrgRole

bp = Blueprint("tenancy", __name__, template_folder="../templates_tenancy")

_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$")


def _slugify(name: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "-", name).strip("-").lower()
    return s or "org"


@bp.get("/")
@login_required
def index():
    """List all orgs the current user belongs to."""
    from modules.db import session
    from modules.tenancy.models.organization import Membership, Organization

    memberships = (
        session.query(Membership, Organization)
        .join(Organization, Organization.id == Membership.org_id)
        .filter(Membership.user_id == current_user.id)
        .order_by(Organization.display_name)
        .all()
    )
    return render_template("orgs_list.html", memberships=memberships)


@bp.route("/switch", methods=["GET", "POST"])
@login_required
def switch():
    """Switch the current org.

    GET: render the switcher UI.
    POST: set the session's current_org_id (CSRF-protected).
    """
    from modules.db import session as db_session
    from modules.tenancy.models.organization import Membership, Organization

    memberships = (
        db_session.query(Membership, Organization)
        .join(Organization, Organization.id == Membership.org_id)
        .filter(Membership.user_id == current_user.id)
        .order_by(Organization.display_name)
        .all()
    )

    # Auto-select for single-org users on GET.
    if request.method == "GET" and len(memberships) == 1:
        _, org = memberships[0]
        set_current_org(org.id)
        return redirect(request.args.get("next") or url_for("index"))

    if request.method == "POST":
        try:
            validate_csrf(request.form.get("csrf_token"))
        except ValidationError:
            abort(400, "invalid CSRF token")

        target_slug = (request.form.get("slug") or "").strip().lower()
        target = next(
            (org for _, org in memberships if org.slug == target_slug),
            None,
        )
        if target is None:
            abort(403, "not a member of that organization")
        set_current_org(target.id)
        return redirect(request.args.get("next") or url_for("index"))

    return render_template("orgs_switch.html", memberships=memberships)


@bp.route("/new", methods=["GET", "POST"])
@login_required
def new():
    """Create a new organization. Creator becomes OrgRole.owner."""
    from modules.db import session
    from modules.tenancy.models.organization import (
        Membership,
        OrgRole,
        Organization,
    )

    if request.method == "POST":
        try:
            validate_csrf(request.form.get("csrf_token"))
        except ValidationError:
            abort(400, "invalid CSRF token")

        display = (request.form.get("display_name") or "").strip()
        if len(display) < 2:
            flash("Organization name must be at least 2 characters.", "error")
            return render_template("orgs_new.html"), 400

        slug = _slugify(display)
        if not _SLUG_RE.match(slug):
            flash("Could not derive a valid slug — try a different name.", "error")
            return render_template("orgs_new.html"), 400

        # Unique slug — append -2, -3, ... on collision.
        base_slug = slug
        counter = 2
        while session.query(Organization).filter(Organization.slug == slug).first():
            slug = f"{base_slug}-{counter}"
            counter += 1

        org = Organization(
            slug=slug,
            display_name=display,
            created_by=current_user.id,
        )
        session.add(org)
        session.flush()

        membership = Membership(
            user_id=current_user.id,
            org_id=org.id,
            role=OrgRole.owner,
        )
        session.add(membership)
        session.commit()

        set_current_org(org.id)
        flash(f"Created {display}. You're the owner.", "success")
        return redirect(url_for("tenancy.index"))

    return render_template("orgs_new.html")


@bp.get("/<slug>/members")
@login_required
@require_membership
def members(slug: str):
    """List members of the current org.

    Gate: caller must be a member of the CURRENT org, AND `slug`
    must match the current org (prevents cross-org URL surfing).
    """
    from modules.db import session
    from modules.tenancy.context import current_org_id
    from modules.tenancy.models.organization import Membership, Organization

    org = session.query(Organization).filter(Organization.id == current_org_id()).one()
    if org.slug != slug:
        abort(403, "URL slug does not match current org — switch first")

    rows = (
        session.query(Membership)
        .filter(Membership.org_id == org.id)
        .order_by(Membership.created_at)
        .all()
    )
    return render_template("orgs_members.html", org=org, memberships=rows)


@bp.post("/<slug>/members/<int:membership_id>/remove")
@login_required
@require_membership
@require_org_role(OrgRole.owner)
def remove_member(slug: str, membership_id: int):
    """Remove a member from the org. Owner-only.

    Refuses to remove the LAST owner — an org without an owner is
    stuck.
    """
    try:
        validate_csrf(request.form.get("csrf_token"))
    except ValidationError:
        abort(400, "invalid CSRF token")

    from modules.db import session
    from modules.tenancy.context import current_org_id
    from modules.tenancy.models.organization import Membership

    m = session.query(Membership).filter(Membership.id == membership_id).one_or_none()
    if m is None or m.org_id != current_org_id():
        abort(404)

    if m.role is OrgRole.owner:
        # Lock other-owner rows before counting — otherwise two
        # owners quitting simultaneously could both see "1 other
        # owner exists", both succeed, and leave the org with zero
        # owners. `SELECT ... FOR UPDATE` serializes the check.
        others = (
            session.query(Membership)
            .filter(Membership.org_id == m.org_id)
            .filter(Membership.role == OrgRole.owner)
            .filter(Membership.id != m.id)
            .with_for_update()
            .count()
        )
        if others == 0:
            abort(400, "cannot remove the last owner — promote someone first")

    session.delete(m)
    session.commit()
    flash("Member removed.", "success")
    return redirect(url_for("tenancy.members", slug=slug))
