# Domain module: `auth`

> Reusable session-based authentication for Python/Flask projects.
> Ships the User model, password hashing, session config, role-based
> decorators, step-up re-auth window, and login/logout routes.
>
> This is the module that closes the placeholder decorators in
> `api-credentials` (v0.25.0). After materializing both, the
> credential admin's `@owner_required` + `@require_password_reauth`
> decorators resolve to real behavior instead of aborting 403.

## Purpose

Give a fresh project a battle-tested auth layer in one command that:

1. **Passwords are stored as bcrypt hashes** (12 rounds, per 2026 OWASP).
2. **Sessions are signed cookies with `HttpOnly` + `Secure` + `SameSite=Lax`**.
3. **Roles are typed enums** (`owner` / `admin` / `member`) — no magic strings.
4. **Owner-only pages require step-up re-auth** — a 15-minute
   password-reconfirm window before touching credentials, deletes,
   or destructive settings.
5. **Failed-login attempts are rate-limited** — 5 fails / 15 minutes
   / IP triggers a soft lockout with 60s backoff.

## Files that get materialized by `pe module add auth`

```
models/user.py                     — User + Role enum + failed_logins
password_service.py                — bcrypt hash + verify + strength check
decorators.py                      — login_required (re-export),
                                     owner_required, admin_required,
                                     require_password_reauth
blueprints/auth.py                 — /login, /logout, /reauth routes
templates_auth/login.html          — login form
templates_auth/reauth.html         — step-up password page (replaces
                                     the placeholder in api-credentials)
migrations/migrate_auth.py         — CREATE TABLE users + failed_logins
tests/test_auth.py                 — decorator behavior, hash roundtrip,
                                     session config, rate-limit, step-up
                                     window
```

## Prerequisites (deps to add to pyproject.toml)

```toml
dependencies = [
    ...,
    "Flask-Login>=0.6",
    "Flask-WTF>=1.2",
    "bcrypt>=4.1",
]
```

## Session config setup

In `run.py::create_app()`:

```python
from datetime import timedelta

app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=True,      # requires HTTPS in prod
    SESSION_COOKIE_SAMESITE="Lax",
    PERMANENT_SESSION_LIFETIME=timedelta(days=7),
)

from flask_login import LoginManager
login_manager = LoginManager()
login_manager.login_view = "auth.login"
login_manager.init_app(app)

@login_manager.user_loader
def load_user(user_id: str):
    from modules.auth.models.user import User
    from modules.db import session
    return session.get(User, int(user_id))

# Register the auth blueprint.
from modules.auth.blueprints.auth import bp as auth_bp
app.register_blueprint(auth_bp, url_prefix="/auth")
```

## Anti-patterns rejected in review

- Storing passwords as anything other than bcrypt (or argon2) — SHA-1,
  MD5, unsalted, "we'll hash it later" all block the review.
- Session cookies missing `HttpOnly`, `Secure` (prod), or `SameSite`.
- Roles as strings scattered in code — use the `Role` enum.
- Bypassing `@owner_required` "just for this one endpoint" — that
  endpoint becomes the exploit path within a month.
- Skipping `@require_password_reauth` on credential-editing pages —
  the whole point of step-up is that a stolen session cookie can't
  read secrets without also having the password.
- Rate-limiting per-request instead of per-IP-window — attacker
  rotates User-Agents and continues.

## After materialization

1. Add the three deps to `pyproject.toml` and `pip install -e .[dev]`
2. Update `run.py::create_app()` with the session config + blueprint
   registration shown above
3. Apply the migration:
   ```bash
   python -c "from modules.auth.migrations.migrate_auth import upgrade; \
              from modules.db import session; upgrade(session)"
   ```
4. Create your first owner user (interactive):
   ```bash
   python -m modules.auth.scripts.create_owner
   ```
   (The script prompts for email + password; hashes password with
   bcrypt; sets `role=Role.owner`.)
5. Restart the app; navigate to `/auth/login`.

## Composition with `api-credentials`

If you have both `auth` and `api-credentials` installed, the
placeholder decorators in `api-credentials/blueprints/admin_credentials.py`
resolve to the real ones via:

```python
from modules.auth.decorators import owner_required, require_password_reauth
```

That import is at the top of `admin_credentials.py`; if `auth` is
not installed, the `except ImportError` fallback aborts 403 on every
credential admin endpoint. Once `auth` is installed, real gating
kicks in.

## Reference implementation

First shipped in the 8colors invoice-system (production, 2026). Copy
of the doctrine at `~/.claude/rules/common/security.md` +
`~/.claude/rules/python/security.md`.
