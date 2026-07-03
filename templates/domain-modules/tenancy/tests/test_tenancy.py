"""tests/test_tenancy.py — coverage floor for the tenancy module.

Every project that materializes this module inherits these tests.
Extend (don't replace) with project-specific integration tests
that exercise real DB + RLS behavior.
"""

from __future__ import annotations

from unittest import mock

import pytest


class TestOrgRoleEnum:
    def test_owner_is_owner(self):
        from modules.tenancy.models.organization import OrgRole
        assert OrgRole.owner.is_owner is True
        assert OrgRole.admin.is_owner is False
        assert OrgRole.member.is_owner is False

    def test_admin_or_owner(self):
        from modules.tenancy.models.organization import OrgRole
        assert OrgRole.owner.is_admin_or_owner is True
        assert OrgRole.admin.is_admin_or_owner is True
        assert OrgRole.member.is_admin_or_owner is False

    def test_distinct_from_auth_role(self):
        # Regression guard: OrgRole and auth.Role are DIFFERENT enums.
        # If someone imports the wrong one, `require_org_role(Role.owner)`
        # would silently pass — this test catches the naming drift.
        from modules.auth.models.user import Role as AuthRole
        from modules.tenancy.models.organization import OrgRole
        assert AuthRole is not OrgRole
        # Values happen to be the same strings — that's OK, but the
        # types must not be interchangeable.
        assert AuthRole.owner is not OrgRole.owner


class TestScopedQuery:
    """`scoped_query` is the ONE-way path for tenant-safe queries."""

    def test_missing_org_id_column_rejected(self):
        from modules.tenancy.scoping import scoped_query, TenancyMisuse

        class NoOrgId:
            __name__ = "NoOrgId"

        with pytest.raises(TenancyMisuse, match="no org_id"):
            scoped_query(NoOrgId)

    def test_no_current_org_rejected(self, monkeypatch):
        from modules.tenancy import scoping
        monkeypatch.setattr(scoping, "current_org_id", lambda: None)

        class HasOrgId:
            __name__ = "HasOrgId"
            org_id = "some-column"

        with pytest.raises(scoping.TenancyMisuse, match="no current org"):
            scoping.scoped_query(HasOrgId)


class TestWithCurrentOrg:
    """v0.27.0 reviewer regression: transaction scope for SET LOCAL."""

    def test_context_restores_previous_org_id(self, monkeypatch):
        # Round-trip: entering the context sets g.current_org_id,
        # exiting restores whatever was there before.
        from flask import Flask
        from modules.tenancy.scoping import with_current_org

        app = Flask(__name__)
        with app.test_request_context():
            from flask import g
            g.current_org_id = 99
            with with_current_org(42):
                assert g.current_org_id == 42
            # Restored.
            assert g.current_org_id == 99

    def test_context_commits_on_success(self, monkeypatch):
        # The explicit transaction must commit when no exception fires.
        from flask import Flask
        from modules.tenancy import scoping

        fake_txn = mock.Mock()
        fake_session = mock.Mock()
        fake_session.begin.return_value = fake_txn

        # Patch the deferred import point.
        import sys
        db_stub = mock.MagicMock()
        db_stub.session = fake_session
        monkeypatch.setitem(sys.modules, "modules.db", db_stub)

        app = Flask(__name__)
        with app.test_request_context():
            with scoping.with_current_org(1):
                pass
        fake_txn.commit.assert_called_once()
        fake_txn.rollback.assert_not_called()

    def test_context_rolls_back_on_exception(self, monkeypatch):
        # If the with-block raises, the transaction must rollback.
        from flask import Flask
        from modules.tenancy import scoping

        fake_txn = mock.Mock()
        fake_session = mock.Mock()
        fake_session.begin.return_value = fake_txn

        import sys
        db_stub = mock.MagicMock()
        db_stub.session = fake_session
        monkeypatch.setitem(sys.modules, "modules.db", db_stub)

        app = Flask(__name__)
        with app.test_request_context():
            with pytest.raises(RuntimeError, match="boom"):
                with scoping.with_current_org(1):
                    raise RuntimeError("boom")
        fake_txn.rollback.assert_called_once()
        fake_txn.commit.assert_not_called()


class TestRequireMembership:
    def test_unauthenticated_redirects_to_login(self, monkeypatch):
        from modules.tenancy import decorators as d
        u = mock.Mock(is_authenticated=False)
        monkeypatch.setattr(d, "current_user", u)
        monkeypatch.setattr(d, "_redirect_to_login", lambda: "LOGIN_REDIRECT")

        @d.require_membership
        def view():
            return "OK"
        assert view() == "LOGIN_REDIRECT"

    def test_no_org_redirects_to_switch(self, monkeypatch):
        from modules.tenancy import decorators as d
        u = mock.Mock(is_authenticated=True, id=1)
        monkeypatch.setattr(d, "current_user", u)
        monkeypatch.setattr(d, "current_org_id", lambda: None)
        monkeypatch.setattr(d, "_redirect_to_switch", lambda: "SWITCH_REDIRECT")

        @d.require_membership
        def view():
            return "OK"
        assert view() == "SWITCH_REDIRECT"


class TestRequireOrgRole:
    def test_owner_role_admits_owner(self, monkeypatch):
        from modules.tenancy import decorators as d
        from modules.tenancy.models.organization import OrgRole
        with monkeypatch.context() as m:
            fake_g = mock.Mock()
            fake_g.current_membership = mock.Mock(role=OrgRole.owner)
            m.setattr(d, "g", fake_g)

            @d.require_org_role(OrgRole.owner)
            def view():
                return "OK"
            assert view() == "OK"

    def test_owner_role_rejects_admin(self, monkeypatch):
        from modules.tenancy import decorators as d
        from modules.tenancy.models.organization import OrgRole
        with monkeypatch.context() as m:
            fake_g = mock.Mock()
            fake_g.current_membership = mock.Mock(role=OrgRole.admin)
            m.setattr(d, "g", fake_g)
            aborted = {"code": None}

            def _abort(code, *args, **kwargs):
                aborted["code"] = code
                raise SystemExit  # simulate abort raising
            m.setattr(d, "abort", _abort)

            @d.require_org_role(OrgRole.owner)
            def view():
                return "OK"
            with pytest.raises(SystemExit):
                view()
            assert aborted["code"] == 403

    def test_admin_role_admits_admin_and_owner(self, monkeypatch):
        from modules.tenancy import decorators as d
        from modules.tenancy.models.organization import OrgRole
        for role in (OrgRole.owner, OrgRole.admin):
            with monkeypatch.context() as m:
                fake_g = mock.Mock()
                fake_g.current_membership = mock.Mock(role=role)
                m.setattr(d, "g", fake_g)

                @d.require_org_role(OrgRole.admin)
                def view():
                    return "OK"
                assert view() == "OK", f"failed for {role}"

    def test_admin_role_rejects_member(self, monkeypatch):
        from modules.tenancy import decorators as d
        from modules.tenancy.models.organization import OrgRole
        with monkeypatch.context() as m:
            fake_g = mock.Mock()
            fake_g.current_membership = mock.Mock(role=OrgRole.member)
            m.setattr(d, "g", fake_g)
            aborted = {"code": None}

            def _abort(code, *args, **kwargs):
                aborted["code"] = code
                raise SystemExit

            m.setattr(d, "abort", _abort)

            @d.require_org_role(OrgRole.admin)
            def view():
                return "OK"
            with pytest.raises(SystemExit):
                view()
            assert aborted["code"] == 403

    def test_missing_membership_context_is_500(self, monkeypatch):
        # If require_org_role is applied WITHOUT require_membership
        # above it, g.current_membership won't be set. That's an
        # engineering bug — return 500, not silent pass.
        from modules.tenancy import decorators as d
        from modules.tenancy.models.organization import OrgRole
        with monkeypatch.context() as m:
            fake_g = mock.Mock()
            fake_g.current_membership = None
            fake_g.get = lambda k, default=None: (
                None if k == "current_membership" else default
            )
            m.setattr(d, "g", fake_g)
            aborted = {"code": None}

            def _abort(code, *args, **kwargs):
                aborted["code"] = code
                raise SystemExit
            m.setattr(d, "abort", _abort)

            @d.require_org_role(OrgRole.owner)
            def view():
                return "OK"
            with pytest.raises(SystemExit):
                view()
            assert aborted["code"] == 500


class TestRlsHelper:
    def test_rejects_invalid_table_name(self):
        from modules.tenancy.rls import apply_rls_to_table
        # SQL identifier smuggling attempt.
        with pytest.raises(ValueError, match="invalid table name"):
            apply_rls_to_table("invoices; DROP TABLE users; --", mock.Mock())

    def test_accepts_snake_case_and_alnum(self):
        from modules.tenancy.rls import apply_rls_to_table
        # These should not raise ValueError. We mock the session so
        # the DB round-trip doesn't happen.
        session = mock.Mock()
        apply_rls_to_table("invoices", session)
        apply_rls_to_table("payment_events", session)
        apply_rls_to_table("v2_reports", session)
        assert session.execute.call_count >= 3


class TestContext:
    def test_set_and_get_current_org(self, monkeypatch):
        # Round-trip: set_current_org writes to session; the
        # before_request hook reads it back into g.
        from flask import Flask
        from modules.tenancy import context

        app = Flask(__name__)
        app.config["SECRET_KEY"] = "test-secret"
        context.init_tenancy_context(app)

        # Skip the SET LOCAL DB call — we're testing context only.
        monkeypatch.setattr(context, "_emit_set_local_for_rls", lambda: None)

        @app.route("/set/<int:oid>")
        def set_route(oid):
            context.set_current_org(oid)
            return "ok"

        @app.route("/get")
        def get_route():
            oid = context.current_org_id()
            return f"oid={oid}"

        client = app.test_client()
        client.get("/set/42")
        r = client.get("/get")
        assert r.data == b"oid=42"

    def test_init_is_idempotent(self):
        from flask import Flask
        from modules.tenancy import context
        app = Flask(__name__)
        app.config["SECRET_KEY"] = "test"
        context.init_tenancy_context(app)
        # Second call must not double-register hooks.
        context.init_tenancy_context(app)
        # Count how many `_load_current_org_from_session` refs are
        # in the before_request funcs — must be exactly 1.
        funcs = app.before_request_funcs.get(None, [])
        loads = [f for f in funcs if f is context._load_current_org_from_session]
        assert len(loads) == 1
