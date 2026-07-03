# Domain module: `tenancy`

> Multi-tenant `org_id` scoping + PostgreSQL RLS setup for Flask
> projects. Ships the Organization + Membership models, session-based
> current-org context, decorators, `scoped_query` helper,
> `apply_rls_to_table` migration helper, and a basic org-switcher
> blueprint.
>
> Composes with `auth` (v0.26.0). Requires it: memberships link
> `User.id` (from the auth module) to `Organization.id`.

## Purpose

Give a fresh Flask app the two-layer tenant-isolation defense that
the operator's `tenant-isolation-auditor` agent looks for:

1. **Application layer** — every query goes through `scoped_query(cls)`
   which auto-adds `WHERE org_id = <current>` at query build time.
   Never string-concatenate; never trust the frontend to pass `org_id`.

2. **Database layer** — RLS policies on every tenant-scoped table.
   The `apply_rls_to_table(name)` migration helper adds:
   - `ALTER TABLE ... ENABLE ROW LEVEL SECURITY;`
   - `... FORCE ROW LEVEL SECURITY;` (blocks even superuser BYPASS)
   - `CREATE POLICY tenant_isolation ON ... USING (org_id = current_setting('app.current_org_id')::bigint);`

Two layers = defense-in-depth. An application bug that forgets the
`WHERE org_id = ?` filter is caught by RLS. An RLS bypass (superuser,
migration runner) is caught by the application filter. The
`tenant-isolation-auditor` agent's job is to catch commits that skip
BOTH.

## Files that get materialized by `pe module add tenancy`

```
models/organization.py         Organization + Membership + OrgRole enum
context.py                     current_org_id() / set_current_org() /
                               require_current_org() session helpers +
                               SET LOCAL wiring for RLS
decorators.py                  @require_membership,
                               @require_org_role(OrgRole.owner)
scoping.py                     scoped_query(cls) — auto WHERE org_id
rls.py                         apply_rls_to_table(name, session) helper
blueprints/tenancy.py          /orgs, /orgs/switch, /orgs/new,
                               /orgs/<slug>/members
templates_tenancy/*.html       switcher, members list, create form
migrations/migrate_tenancy.py  CREATE organizations + memberships,
                               ALTER tenant tables to add org_id,
                               apply RLS policies
tests/test_tenancy.py          decorator behavior, scoping, RLS smoke,
                               cross-tenant leak defense
```

## Prerequisites (deps to add to pyproject.toml)

- Already installed via `auth`: `Flask-Login`, `Flask-WTF`
- No new deps — reuses SQLAlchemy + the session infrastructure

## Session config setup

In `run.py::create_app()`:

```python
from modules.tenancy.context import init_tenancy_context

# Register the tenancy blueprint.
from modules.tenancy.blueprints.tenancy import bp as tenancy_bp
app.register_blueprint(tenancy_bp, url_prefix="/orgs")

# Init the request-lifetime context (SET LOCAL for RLS).
init_tenancy_context(app)
```

`init_tenancy_context(app)` wires two `before_request` hooks:
1. Read `session['current_org_id']` and populate `flask.g.current_org_id`.
2. Emit `SET LOCAL app.current_org_id = <int>` on the DB session so
   RLS policies read the right tenant. Emits `SET LOCAL
   app.current_org_id = '0'` when no org is active (RLS returns
   zero rows — safe default).

## Making a tenant-scoped table

When you add a new tenant-scoped model:

```python
class Invoice(Base):
    __tablename__ = "invoices"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    org_id: Mapped[int] = mapped_column(BigInteger,
                                        ForeignKey("organizations.id"),
                                        nullable=False, index=True)
    # ... other fields
```

In the migration, after CREATE TABLE, call:

```python
from modules.tenancy.rls import apply_rls_to_table
apply_rls_to_table("invoices", session)
```

That's it. The tenant-isolation-auditor will confirm on next run.

Then in the code, ALWAYS use `scoped_query`:

```python
from modules.tenancy.scoping import scoped_query

# Automatically becomes: SELECT ... FROM invoices WHERE org_id = <current>
invoices = scoped_query(Invoice).order_by(Invoice.due_date).limit(50).all()
```

## OrgRole vs User.role

These are DIFFERENT scopes. Do not confuse:

- **`User.role`** (from `auth`) — **platform role**. `owner` can
  rotate secrets, wipe data, promote other users platform-wide.
- **`Membership.role`** (from `tenancy`) — **per-org role**. A user's
  role INSIDE ONE org. `owner` of org A can invite/remove members,
  change org settings, delete org. Same user might be `member` of org B.

The `@require_org_role(OrgRole.owner)` decorator checks the
per-org role of the current_user in the current org. Cross-org
platform-owner privileges use `@owner_required` from `auth`.

## Anti-patterns rejected in review

- Adding a new tenant-scoped table without calling
  `apply_rls_to_table` in the migration.
- Adding a new query path that doesn't go through `scoped_query` —
  the `tenant-isolation-auditor` will flag it as a silent-leak risk.
- Passing `org_id` from the client — always read from
  `flask.g.current_org_id`. A malicious client can pass any org_id.
- Storing `current_org_id` in a cookie — must be in the signed
  session, so a client tamper is caught.
- Cross-tenant JOINs without an explicit `AND right.org_id =
  left.org_id`. RLS covers this at the row level but the query
  optimizer might do bad things; explicit is safer.
- Migration-runner or admin scripts that call the DB directly
  without `SET LOCAL app.current_org_id` — they'll silently
  bypass RLS if they connect as the superuser role. `FORCE ROW
  LEVEL SECURITY` (set by `apply_rls_to_table`) prevents this at
  the DB layer.

## After materialization

1. Install if not already: `auth` module (`pe module add auth`) —
   tenancy depends on `modules.auth.models.user.User`.
2. Update `run.py::create_app()` with the blueprint registration +
   `init_tenancy_context(app)` shown above.
3. Apply the migration:
   ```bash
   python -c "from modules.tenancy.migrations.migrate_tenancy import upgrade; \
              from modules.db import session; upgrade(session)"
   ```
4. Create the first org for the owner user (interactive):
   ```bash
   python -m modules.tenancy.scripts.create_first_org
   ```
5. Restart the app. Users land at `/orgs/switch` if they have
   multiple orgs, or auto-select if they have exactly one.

## Related items

- `~/.claude/rules/common/security.md` — RLS + tenant isolation
  doctrine (this module's code side).
- `tenant-isolation-auditor` agent — reads the codebase and flags
  new queries missing the `WHERE org_id` filter OR migrations that
  create tables without calling `apply_rls_to_table`.
- `hooks/sast-scan.sh` PF2 rule pack — includes checks for raw SQL
  without tenant filters (pattern `pf2.raw-sql-select-star-no-limit`).

## Reference implementation

First shipped in 8CStudio (2026 production). Copy of the doctrine
at `~/.claude/rules/common/security.md` § tenant isolation.
