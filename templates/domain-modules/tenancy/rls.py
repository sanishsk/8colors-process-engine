"""RLS policy helpers — the DB layer of the two-layer defense.

The pattern (per operator's rules/common/security.md § tenant
isolation):
    1. Enable RLS on the table.
    2. FORCE it (blocks superuser bypass — `BYPASSRLS` role
       attribute is ignored). This is what distinguishes the
       tenant-isolation-auditor's SHIPS-SAFE bar from CVE-worthy
       silent leaks.
    3. Create a policy that reads `current_setting('app.current_org_id')`
       (issued by context.py's SET LOCAL) and matches against the
       row's `org_id` column.

Every tenant-scoped table gets this treatment via
`apply_rls_to_table('name', session)`. The migration helper is
idempotent — safe to re-run on production.

Non-negotiables:
    * Never grant BYPASSRLS to any role that runs application
      queries. Migration runners can be an exception (they need
      to build indexes across all tenants) — but if they SELECT
      from tenant tables, they leak.
    * Never DROP POLICY without a REPLACEMENT. A DROP-then-
      CREATE-in-different-transaction leaves the window during
      which the table has RLS enabled but no policy → all rows
      are visible to all sessions.
"""

from __future__ import annotations

from sqlalchemy import text


def apply_rls_to_table(table: str, session) -> None:
    """Enable + FORCE + policy on `<table>`. Idempotent.

    Requires the table to have an `org_id` bigint column.

    Uses `DO $$ ... END $$` blocks so re-running against a table
    that already has RLS + policy doesn't error — PostgreSQL doesn't
    have `CREATE POLICY IF NOT EXISTS`, so we synthesize it.
    """
    if not table.replace("_", "").isalnum():
        # Defensive — the caller should never pass user input here,
        # but reject anything that could break out of the identifier
        # context.
        raise ValueError(f"invalid table name: {table!r}")

    session.execute(text(f"ALTER TABLE {table} ENABLE ROW LEVEL SECURITY;"))
    session.execute(text(f"ALTER TABLE {table} FORCE ROW LEVEL SECURITY;"))

    # Idempotent policy creation.
    session.execute(text(f"""
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_policies
                WHERE tablename = '{table}'
                  AND policyname = 'tenant_isolation'
            ) THEN
                CREATE POLICY tenant_isolation ON {table}
                    USING (org_id = current_setting('app.current_org_id')::bigint);
            END IF;
        END $$;
    """))
    session.commit()


def rls_is_enabled(table: str, session) -> bool:
    """Diagnostic — returns True iff RLS is enabled AND forced on
    `<table>` AND the tenant_isolation policy exists."""
    row = session.execute(text("""
        SELECT
            relrowsecurity AS enabled,
            relforcerowsecurity AS forced,
            EXISTS (
                SELECT 1 FROM pg_policies
                WHERE tablename = :t AND policyname = 'tenant_isolation'
            ) AS policy_exists
        FROM pg_class
        WHERE relname = :t;
    """), {"t": table}).one_or_none()
    if row is None:
        return False
    return bool(row.enabled) and bool(row.forced) and bool(row.policy_exists)


def drop_rls_from_table(table: str, session) -> None:
    """DANGEROUS — drops the policy and disables RLS.

    Use only when de-tenanting a table (e.g. moving it to shared
    global scope). NEVER during routine schema changes — a live
    ALTER TABLE that briefly disables RLS is a leak window.
    """
    if not table.replace("_", "").isalnum():
        raise ValueError(f"invalid table name: {table!r}")
    session.execute(text(f"DROP POLICY IF EXISTS tenant_isolation ON {table};"))
    session.execute(text(f"ALTER TABLE {table} DISABLE ROW LEVEL SECURITY;"))
    session.commit()
