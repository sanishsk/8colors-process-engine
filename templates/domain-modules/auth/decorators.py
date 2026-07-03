"""Auth decorators — the primitives every gated endpoint uses.

Exports:
    login_required            — Flask-Login stock decorator, re-exported
                                for one-import convenience.
    owner_required            — enforces role == Role.owner. 403 for
                                admin/member; redirects unauthenticated
                                users to login.
    admin_required            — enforces role in {owner, admin}.
    require_password_reauth   — enforces a 15-minute step-up window
                                since last password verification. If
                                stale, redirects to /auth/reauth with
                                the current URL captured as `next`.

The @require_password_reauth decorator is the SECURITY-CRITICAL
one: it's what closes the "stolen session cookie can read all
credentials" attack. A cookie thief has a signed session but has
never re-entered the password, so `password_verified_at` is either
None or older than 15 minutes — the decorator redirects them to a
password prompt they can't pass.
"""

from __future__ import annotations

import datetime as dt
from functools import wraps

from flask import abort, redirect, request, url_for
from flask_login import current_user, login_required

# Re-export so consumers get one canonical import path.
login_required = login_required

STEP_UP_WINDOW_MINUTES = 15


def _redirect_to_login():
    return redirect(url_for("auth.login", next=request.url))


def _redirect_to_reauth():
    return redirect(url_for("auth.reauth", next=request.url))


def owner_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not current_user.is_authenticated:
            return _redirect_to_login()
        # Role enum access — never string comparisons.
        role = getattr(current_user, "role", None)
        if not (role and role.is_owner):
            abort(403, "owner role required")
        return f(*args, **kwargs)
    return wrapper


def admin_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not current_user.is_authenticated:
            return _redirect_to_login()
        role = getattr(current_user, "role", None)
        if not (role and role.is_admin_or_owner):
            abort(403, "admin or owner role required")
        return f(*args, **kwargs)
    return wrapper


def require_password_reauth(f):
    """Enforces the step-up window BEFORE the wrapped view runs.

    Reads `current_user.password_verified_at` (set by /auth/login and
    /auth/reauth). If missing or older than STEP_UP_WINDOW_MINUTES,
    redirects to /auth/reauth carrying the current URL as `next` so
    the user lands back here after re-confirming.
    """
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not current_user.is_authenticated:
            return _redirect_to_login()
        pv = getattr(current_user, "password_verified_at", None)
        if pv is None:
            return _redirect_to_reauth()
        window = dt.timedelta(minutes=STEP_UP_WINDOW_MINUTES)
        # Guard against naive-vs-aware datetime comparison — normalize
        # to UTC.
        if pv.tzinfo is None:
            pv = pv.replace(tzinfo=dt.timezone.utc)
        if dt.datetime.now(dt.timezone.utc) - pv > window:
            return _redirect_to_reauth()
        return f(*args, **kwargs)
    return wrapper
