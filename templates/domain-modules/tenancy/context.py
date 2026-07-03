"""Current-org context: session storage + RLS SET LOCAL wiring.

Contract:
    * Every authenticated request has a `flask.g.current_org_id`
      (either an int or None).
    * Every DB read/write in that request has `SET LOCAL
      app.current_org_id = <int>` already issued, so RLS policies
      resolve correctly.
    * The current org is stored in the SIGNED session (not a raw
      cookie) — the client can't set it to arbitrary values.

Usage:
    In `create_app()`:
        from modules.tenancy.context import init_tenancy_context
        init_tenancy_context(app)

    Anywhere else:
        from modules.tenancy.context import current_org_id, require_current_org

        oid = current_org_id()      # int | None
        oid = require_current_org() # aborts 400 if None
"""

from __future__ import annotations

from typing import Optional

from flask import Flask, abort, g, session
from sqlalchemy import text


SESSION_KEY = "current_org_id"


def current_org_id() -> Optional[int]:
    """Return the current org_id from Flask `g`, or None."""
    return getattr(g, SESSION_KEY, None)


def require_current_org() -> int:
    """Return the current org_id, or abort 400 if none is set.

    Use this in blueprints where a request MUST be scoped to an org
    (e.g. any resource CRUD). The 400 is honest — the client is
    trying to access an org-scoped resource without an active org.
    """
    oid = current_org_id()
    if oid is None:
        abort(400, "no active organization — visit /orgs/switch first")
    return oid


def set_current_org(org_id: Optional[int]) -> None:
    """Persist the current org selection into the session.

    Reads by later request's `_load_current_org_from_session` hook.
    Passing None clears it.
    """
    if org_id is None:
        session.pop(SESSION_KEY, None)
    else:
        session[SESSION_KEY] = int(org_id)


# ─── Flask app wiring ─────────────────────────────────────────────


def _load_current_org_from_session() -> None:
    """before_request hook — populate `g.current_org_id`."""
    oid = session.get(SESSION_KEY)
    g.current_org_id = int(oid) if oid is not None else None


def _emit_set_local_for_rls() -> None:
    """before_request hook — issue `SET LOCAL app.current_org_id`
    on the DB session so RLS policies see the right tenant.

    Emits '0' when no org is active — RLS returns zero rows,
    a safe default (no data leaks; endpoints see empty results).
    """
    try:
        from modules.db import session as db_session
    except ImportError:
        return  # isolated test — no DB
    oid = g.get(SESSION_KEY) or 0
    # `SET LOCAL` scopes the setting to the current transaction. When
    # the request commits or rolls back, the setting drops — no
    # cross-request leak.
    db_session.execute(text("SET LOCAL app.current_org_id = :v"), {"v": str(int(oid))})


def init_tenancy_context(app: Flask) -> None:
    """Wire the two before_request hooks. Idempotent."""
    if getattr(app, "_tenancy_context_wired", False):
        return
    app.before_request(_load_current_org_from_session)
    app.before_request(_emit_set_local_for_rls)
    app._tenancy_context_wired = True  # type: ignore[attr-defined]
