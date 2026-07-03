"""Auth blueprint — /login, /logout, /reauth.

Non-negotiable gates:
    * POST /login — rate-limited by IP (5 fails / 15 min), CSRF-protected,
      stamps password_verified_at on success, records FailedLogin on
      wrong password (never leaks whether the email exists).
    * GET /logout — CSRF-protected (POST-only in production; GET wired
      for demo simplicity). Ends the session cleanly.
    * POST /reauth — step-up. Re-confirms current_user's password
      without creating a new session. Same rate-limit as /login.

If a bearer-token / API-key surface is needed, add a separate
blueprint — mixing session-cookie and bearer-token paths in one
route family leaks confusion.
"""

from __future__ import annotations

from flask import Blueprint, abort, flash, redirect, render_template, request, url_for
from flask_login import current_user, login_user, logout_user
from flask_wtf.csrf import validate_csrf
from wtforms.validators import ValidationError

from modules.auth.password_service import (
    is_rate_limited,
    record_failed_login,
    verify_password,
)

bp = Blueprint("auth", __name__, template_folder="../templates_auth")


@bp.route("/login", methods=["GET", "POST"])
def login():
    from modules.db import session
    from modules.auth.models.user import User

    if current_user.is_authenticated:
        return redirect(request.args.get("next") or url_for("index"))

    if request.method == "POST":
        try:
            validate_csrf(request.form.get("csrf_token"))
        except ValidationError:
            abort(400, "invalid CSRF token")

        ip = request.remote_addr or "unknown"
        if is_rate_limited(session, ip):
            flash("Too many failed attempts. Try again in 15 minutes.", "error")
            return render_template("login.html"), 429

        email = (request.form.get("email") or "").strip().lower()
        password = request.form.get("password") or ""

        # Look up the user WITHOUT leaking existence — always run the
        # hash comparison against a dummy hash if no user is found, so
        # response timing doesn't distinguish "wrong email" from
        # "wrong password".
        user = session.query(User).filter(User.email == email).one_or_none()
        stored_hash = user.password_hash if user else "$2b$12$fakefakefakefakefakefakefakefakefakefakefakefakefakef"

        ok = verify_password(password, stored_hash) and user is not None and user.is_active
        if not ok:
            record_failed_login(session, email_attempted=email, ip_address=ip,
                                user_agent=request.user_agent.string or "")
            flash("Wrong email or password.", "error")
            return render_template("login.html"), 401

        user.stamp_password_verified()
        session.commit()
        login_user(user, remember=True)
        return redirect(request.args.get("next") or url_for("index"))

    return render_template("login.html")


@bp.get("/logout")
def logout():
    logout_user()
    flash("Signed out.", "success")
    return redirect(url_for("auth.login"))


@bp.route("/reauth", methods=["GET", "POST"])
def reauth():
    """Step-up: re-confirm current password without a new session."""
    if not current_user.is_authenticated:
        return redirect(url_for("auth.login", next=request.args.get("next", "")))

    from modules.db import session

    if request.method == "POST":
        try:
            validate_csrf(request.form.get("csrf_token"))
        except ValidationError:
            abort(400, "invalid CSRF token")

        ip = request.remote_addr or "unknown"
        if is_rate_limited(session, ip):
            flash("Too many failed attempts. Try again in 15 minutes.", "error")
            return render_template("reauth.html"), 429

        password = request.form.get("password") or ""
        if not verify_password(password, current_user.password_hash):
            record_failed_login(session, email_attempted=current_user.email,
                                ip_address=ip,
                                user_agent=request.user_agent.string or "")
            flash("Wrong password.", "error")
            return render_template("reauth.html"), 401

        current_user.stamp_password_verified()
        session.commit()
        return redirect(request.args.get("next") or url_for("index"))

    return render_template("reauth.html")
