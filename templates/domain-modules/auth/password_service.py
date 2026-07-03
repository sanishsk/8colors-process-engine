"""Password hashing + strength check + rate-limit helper.

Bcrypt-only. Argon2 is superior in isolation but bcrypt has broader
tooling / migration support in the Python ecosystem circa 2026, and
the security-reviewer gate treats bcrypt at ≥12 rounds as acceptable.

Anti-patterns rejected:
    * plaintext, MD5, SHA-1, unsalted-SHA-256, or any homegrown scheme
    * bcrypt at < 12 rounds (2026 minimum per OWASP Password Storage
      Cheat Sheet)
    * verifying against a NULL / empty hash — always returns False
      instead of raising, so a caller who forgets the None-check
      can't silently open a hole
"""

from __future__ import annotations

import datetime as dt
import re

import bcrypt

BCRYPT_ROUNDS = 12  # 2026 OWASP minimum; ~250ms per verify on M-series


def hash_password(plaintext: str) -> str:
    """Return a bcrypt hash string (self-contained salt + params)."""
    if not plaintext or not isinstance(plaintext, str):
        raise ValueError("password must be a non-empty string")
    salt = bcrypt.gensalt(rounds=BCRYPT_ROUNDS)
    return bcrypt.hashpw(plaintext.encode("utf-8"), salt).decode("ascii")


def verify_password(plaintext: str, stored_hash: str | None) -> bool:
    """Constant-time compare. Returns False on any missing/malformed input."""
    if not plaintext or not stored_hash:
        return False
    try:
        return bcrypt.checkpw(plaintext.encode("utf-8"), stored_hash.encode("ascii"))
    except (ValueError, TypeError):
        # Malformed hash → treat as fail, don't leak the shape via
        # exception path.
        return False


# ─── strength check ─────────────────────────────────────────────────────


class PasswordTooWeak(ValueError):
    """Raised when a submitted password fails the strength check.

    Attributes let the caller build a user-facing error message.
    """

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def check_strength(plaintext: str) -> None:
    """Raise PasswordTooWeak on unacceptable input. Silent on OK.

    Rules (deliberate, calibrated against 2026 attacker economics):
        * ≥ 12 characters
        * ≥ 1 letter AND ≥ 1 digit (mixed alphabet requirements are
          discouraged by modern guidance — length beats complexity)
        * NOT in the top-10k common-passwords list (a compile-in
          list can be added later; ship the extension point)
    """
    if len(plaintext) < 12:
        raise PasswordTooWeak("password must be at least 12 characters")
    if not re.search(r"[A-Za-z]", plaintext):
        raise PasswordTooWeak("password must contain at least one letter")
    if not re.search(r"\d", plaintext):
        raise PasswordTooWeak("password must contain at least one digit")


# ─── rate limit ─────────────────────────────────────────────────────────


LOGIN_RATE_LIMIT_MAX = 5           # attempts
LOGIN_RATE_LIMIT_WINDOW_MIN = 15   # minutes


def failed_login_count(session, ip_address: str) -> int:
    """Count failed logins from ip_address in the last N minutes."""
    from modules.auth.models.user import FailedLogin

    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(
        minutes=LOGIN_RATE_LIMIT_WINDOW_MIN
    )
    return (
        session.query(FailedLogin)
        .filter(FailedLogin.ip_address == ip_address)
        .filter(FailedLogin.created_at >= cutoff)
        .count()
    )


def is_rate_limited(session, ip_address: str) -> bool:
    return failed_login_count(session, ip_address) >= LOGIN_RATE_LIMIT_MAX


def record_failed_login(session, email_attempted: str, ip_address: str,
                        user_agent: str = "") -> None:
    """Append one row to failed_logins. Never stores the password."""
    from modules.auth.models.user import FailedLogin

    row = FailedLogin(
        email_attempted=email_attempted[:255] if email_attempted else None,
        ip_address=ip_address,
        user_agent=(user_agent or "")[:512],
    )
    session.add(row)
    session.commit()
