"""scoped_query — the ONE way to build a tenant-safe query.

Contract:
    * Every query on a tenant-scoped model MUST go through
      `scoped_query(Cls)` instead of `session.query(Cls)`.
    * The helper auto-adds `WHERE org_id = <current>` at query
      build time.
    * If no org is active, raises `TenancyMisuse` — silent
      empty-result would mask real bugs (e.g. a job runner that
      forgot to set the org context).

The `tenant-isolation-auditor` agent looks for `session.query(<any
tenant-scoped Cls>)` OUTSIDE of scoped_query and flags it as a
silent-leak risk. `scoped_query(Cls)` is the deterministic path
that satisfies the auditor.
"""

from __future__ import annotations

from sqlalchemy.orm import Query

from modules.tenancy.context import current_org_id


class TenancyMisuse(RuntimeError):
    """Raised when scoped_query is called with no org context.

    Silent empty-result would mask real bugs. Prefer loud failure.
    """


def scoped_query(cls) -> Query:
    """Return a query pre-filtered by `org_id = current`.

    Model class MUST have an `org_id` column. If it doesn't (e.g. a
    shared / global table like `plans`), don't use this helper —
    use the regular `session.query(cls)` and document why the table
    is intentionally cross-tenant.
    """
    if not hasattr(cls, "org_id"):
        raise TenancyMisuse(
            f"{cls.__name__} has no org_id — use session.query() directly "
            "and document why it's intentionally cross-tenant"
        )

    oid = current_org_id()
    if oid is None:
        raise TenancyMisuse(
            "scoped_query called with no current org — "
            "did you forget to set the org context in a job runner? "
            "Use `with_current_org(org_id):` to enter a tenant context."
        )

    from modules.db import session
    return session.query(cls).filter(cls.org_id == oid)


class with_current_org:
    """Context manager for setting the current org outside a request.

    Use in job runners / management commands / batch scripts where
    there's no HTTP request to derive the org from.

    Manages an EXPLICIT transaction so `SET LOCAL app.current_org_id`
    has a well-defined scope: on success, commits any queries done
    in the context; on exception, rolls back. Without this scope,
    `SET LOCAL` could leak into subsequent unrelated queries in the
    same session (Postgres transaction-scopes the setting; the
    transaction outlives the context manager unless explicitly ended).

    Example:
        from modules.tenancy.scoping import with_current_org

        with with_current_org(org.id):
            invoices = scoped_query(Invoice).all()
        # SET LOCAL scope ends on __exit__ (transaction committed).
    """

    def __init__(self, org_id: int):
        self.org_id = int(org_id)
        self._prev: int | None = None
        self._txn = None

    def __enter__(self):
        from flask import g
        self._prev = getattr(g, "current_org_id", None)
        g.current_org_id = self.org_id

        # Start an explicit transaction so SET LOCAL has a bounded
        # scope. Skip if SQLAlchemy is not importable (isolated test).
        try:
            from modules.db import session as db_session
            from sqlalchemy import text
            self._txn = db_session.begin()
            db_session.execute(text("SET LOCAL app.current_org_id = :v"),
                               {"v": str(self.org_id)})
        except ImportError:
            pass
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        from flask import g
        try:
            if self._txn is not None:
                if exc_type is None:
                    self._txn.commit()
                else:
                    self._txn.rollback()
        finally:
            g.current_org_id = self._prev
            self._txn = None
        # Don't swallow exceptions — bubble up so callers see them.
        return False
