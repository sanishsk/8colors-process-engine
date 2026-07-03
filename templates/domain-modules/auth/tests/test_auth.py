"""tests/test_auth.py — coverage floor for the auth module.

Every project that materializes this module inherits these tests.
Extend (don't replace) with project-specific integration tests.
"""

from __future__ import annotations

import datetime as dt

import pytest


class TestPasswordHashing:
    def test_hash_roundtrip(self):
        from modules.auth.password_service import hash_password, verify_password
        h = hash_password("correct-horse-battery-staple")
        assert h != "correct-horse-battery-staple"
        assert h.startswith(("$2a$", "$2b$", "$2y$"))  # bcrypt formats
        assert verify_password("correct-horse-battery-staple", h) is True

    def test_wrong_password_fails(self):
        from modules.auth.password_service import hash_password, verify_password
        h = hash_password("real-password-12345")
        assert verify_password("wrong-password-1234", h) is False

    def test_empty_password_rejected(self):
        from modules.auth.password_service import hash_password
        with pytest.raises(ValueError):
            hash_password("")

    def test_none_stored_hash_returns_false(self):
        # Regression guard: verify against a None/empty hash MUST NOT
        # raise or match — always False. A caller who forgets the
        # None-check cannot silently open a hole.
        from modules.auth.password_service import verify_password
        assert verify_password("anything", None) is False
        assert verify_password("anything", "") is False

    def test_malformed_hash_returns_false(self):
        from modules.auth.password_service import verify_password
        assert verify_password("password", "not-a-bcrypt-hash") is False


class TestPasswordStrength:
    def test_short_password_rejected(self):
        from modules.auth.password_service import PasswordTooWeak, check_strength
        with pytest.raises(PasswordTooWeak, match="12 characters"):
            check_strength("short")

    def test_no_digit_rejected(self):
        from modules.auth.password_service import PasswordTooWeak, check_strength
        with pytest.raises(PasswordTooWeak, match="digit"):
            check_strength("no-digits-here-just-letters")

    def test_no_letter_rejected(self):
        from modules.auth.password_service import PasswordTooWeak, check_strength
        with pytest.raises(PasswordTooWeak, match="letter"):
            check_strength("123456789012")

    def test_ok_password_silent(self):
        from modules.auth.password_service import check_strength
        # No exception = pass.
        check_strength("valid-password-1234")


class TestRoleEnum:
    def test_owner_is_owner(self):
        from modules.auth.models.user import Role
        assert Role.owner.is_owner is True
        assert Role.admin.is_owner is False
        assert Role.member.is_owner is False

    def test_admin_or_owner(self):
        from modules.auth.models.user import Role
        assert Role.owner.is_admin_or_owner is True
        assert Role.admin.is_admin_or_owner is True
        assert Role.member.is_admin_or_owner is False

    def test_str_serializable(self):
        # Enum-as-str means JSON serialization is trivial.
        from modules.auth.models.user import Role
        assert Role.owner.value == "owner"
        assert Role.admin.value == "admin"


class TestStepUpWindow:
    """Validates the 15-min window logic in require_password_reauth."""

    def _fake_user(self, pv_at: dt.datetime | None):
        class U:
            is_authenticated = True
            password_verified_at = pv_at
        return U()

    def test_no_stamp_triggers_reauth(self, monkeypatch):
        # A user who has never stamped password_verified_at (e.g.
        # session survived a server restart but stamp got lost) must
        # be re-auth'd.
        from modules.auth import decorators as d
        u = self._fake_user(None)
        monkeypatch.setattr(d, "current_user", u)
        called = {"n": 0}
        monkeypatch.setattr(d, "_redirect_to_reauth", lambda: called.update(n=1) or "REDIRECT")

        @d.require_password_reauth
        def view():
            return "OK"
        result = view()
        assert result == "REDIRECT"
        assert called["n"] == 1

    def test_recent_stamp_allows_through(self, monkeypatch):
        from modules.auth import decorators as d
        # 5 minutes ago — well within the 15-min window.
        recent = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=5)
        u = self._fake_user(recent)
        monkeypatch.setattr(d, "current_user", u)

        @d.require_password_reauth
        def view():
            return "OK"
        assert view() == "OK"

    def test_old_stamp_triggers_reauth(self, monkeypatch):
        from modules.auth import decorators as d
        # 30 minutes ago — past the 15-min window.
        old = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=30)
        u = self._fake_user(old)
        monkeypatch.setattr(d, "current_user", u)
        monkeypatch.setattr(d, "_redirect_to_reauth", lambda: "REDIRECT")

        @d.require_password_reauth
        def view():
            return "OK"
        assert view() == "REDIRECT"

    def test_naive_stamp_normalized_to_utc(self, monkeypatch):
        # Some DBs strip tzinfo on round-trip. The decorator must
        # normalize rather than raise.
        from modules.auth import decorators as d
        recent_naive = dt.datetime.utcnow() - dt.timedelta(minutes=5)
        u = self._fake_user(recent_naive)
        monkeypatch.setattr(d, "current_user", u)

        @d.require_password_reauth
        def view():
            return "OK"
        assert view() == "OK"


class TestRateLimit:
    def test_below_threshold_not_limited(self, monkeypatch):
        from modules.auth import password_service as p
        monkeypatch.setattr(p, "failed_login_count", lambda s, ip: 3)
        assert p.is_rate_limited(None, "1.2.3.4") is False

    def test_at_threshold_is_limited(self, monkeypatch):
        from modules.auth import password_service as p
        monkeypatch.setattr(p, "failed_login_count", lambda s, ip: 5)
        assert p.is_rate_limited(None, "1.2.3.4") is True
