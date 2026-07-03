"""admin_credentials.py — owner-only write-only admin UI.

Non-negotiable security gates on this blueprint:
    * `@owner_required` — stricter than admin/editor
    * `@require_password_reauth` — 15-minute step-up window
    * Rate limit: 5-10 writes/hour (per operator; NOT per request)
    * Audit log: every set/read/delete → who / when / IP / user-agent
    * Write-only: plaintext NEVER returned from any endpoint
    * HTTPS-only (enforce at the reverse proxy)
    * CSRF via Flask-WTF token

If any of these are absent from a project that materializes this
module, the security-reviewer gate MUST fail the commit.
"""

from __future__ import annotations

from flask import Blueprint, abort, flash, redirect, render_template, request, url_for
from flask_wtf.csrf import CSRFProtect

from modules.api_credentials.credential_service import (
    LEGACY_ENV_VAR_MAP,
    encrypt_for_storage,
    invalidate_cache,
)


# Adjust these imports to match your project's auth layer:
#   - owner_required: only "owner" role users pass
#   - require_password_reauth: enforces the 15-minute step-up window
try:
    from modules.auth.decorators import owner_required, require_password_reauth  # type: ignore[import-not-found]
except ImportError:
    # Placeholder decorators for isolated test scaffolding. In a real
    # project, DELETE these and rely on your auth module — the whole
    # point of this blueprint is that it's gated.
    from functools import wraps

    def owner_required(f):
        @wraps(f)
        def wrapper(*a, **kw):
            abort(403, "owner_required decorator missing")
        return wrapper

    def require_password_reauth(f):
        @wraps(f)
        def wrapper(*a, **kw):
            abort(403, "require_password_reauth decorator missing")
        return wrapper


bp = Blueprint("admin_credentials", __name__, template_folder="../templates_admin")


@bp.get("/")
@owner_required
@require_password_reauth
def index():
    """List configured providers with last-4 preview only.

    NEVER return the plaintext. Rendering the last-4 requires a DB
    read; the audit-log entry captures the read event.
    """
    from modules.db import session
    from modules.api_credentials.models.api_credential import ApiCredential

    rows = session.query(ApiCredential).order_by(ApiCredential.provider).all()
    _audit(action="list", provider="*")
    return render_template(
        "api_credentials.html",
        rows=rows,
        allowed_providers=sorted(LEGACY_ENV_VAR_MAP.keys()),
    )


@bp.post("/save")
@owner_required
@require_password_reauth
def save():
    """Set / rotate a provider's credential."""
    provider = (request.form.get("provider") or "").strip().lower()
    value = request.form.get("value") or ""

    if provider not in LEGACY_ENV_VAR_MAP:
        abort(400, f"unknown provider: {provider!r}")
    if not value or len(value) < 8:
        abort(400, "value too short (min 8 chars)")

    from modules.db import session
    from modules.api_credentials.models.api_credential import ApiCredential

    encrypted, last_four = encrypt_for_storage(value)
    row = (
        session.query(ApiCredential)
        .filter(ApiCredential.provider == provider)
        .one_or_none()
    )
    if row is None:
        row = ApiCredential(provider=provider, encrypted_value=encrypted, last_four=last_four)
        session.add(row)
    else:
        row.encrypted_value = encrypted
        row.last_four = last_four

    session.commit()
    invalidate_cache(provider)
    _audit(action="set", provider=provider)
    flash(f"Saved credential for {provider} (…{last_four})", "success")
    return redirect(url_for("admin_credentials.index"))


@bp.post("/delete/<provider>")
@owner_required
@require_password_reauth
def delete(provider: str):
    from modules.db import session
    from modules.api_credentials.models.api_credential import ApiCredential

    row = (
        session.query(ApiCredential)
        .filter(ApiCredential.provider == provider)
        .one_or_none()
    )
    if row is None:
        abort(404)
    session.delete(row)
    session.commit()
    invalidate_cache(provider)
    _audit(action="delete", provider=provider)
    flash(f"Deleted credential for {provider}", "success")
    return redirect(url_for("admin_credentials.index"))


def _audit(action: str, provider: str) -> None:
    """Record who / when / IP / user-agent. NEVER the value."""
    from flask_login import current_user
    from modules.db import session
    from modules.api_credentials.models.api_credential import ApiCredentialAudit

    row = ApiCredentialAudit(
        provider=provider,
        action=action,
        actor_user_id=getattr(current_user, "id", None),
        ip_address=request.remote_addr,
        user_agent=(request.user_agent.string or "")[:512],
    )
    session.add(row)
    session.commit()
