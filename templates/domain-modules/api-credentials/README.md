# Domain module: `api-credentials`

> Reusable Managed-Secrets pattern for Python/Flask projects. Extracted
> from the operator's global doctrine (`~/.claude/rules/common/
> api-credentials.md`) — this is the CODE side of the same pattern.

## Purpose

Store third-party API keys (Anthropic, OpenAI, Stripe, Razorpay,
SendGrid, Twilio, etc.) in an **encrypted database table** with a
write-only admin UI, so owners can rotate keys without SSH access and
call sites don't drift.

Three layers:

1. **Storage** — `models/api_credential.py` — encrypted row per
   provider + audit log.
2. **Service** — `credential_service.py` — `get_credential(provider) → str | None`
   with resolution order: in-process cache → encrypted DB row → legacy
   env var fallback.
3. **Admin UI** — `blueprints/admin_credentials.py` — owner-only page
   with step-up auth. Write-only (saved values never returned; only
   the last-4-char preview is shown).

## Files that get materialized by `pe module add api-credentials`

```
models/api_credential.py           — storage + audit table
credential_service.py              — encrypt/decrypt + fallback
blueprints/admin_credentials.py    — admin UI + step-up auth
templates_admin/api_credentials.html — form template
templates_admin/reauth.html        — step-up password page
migrations/migrate_XXX_api_credentials.py — schema migration
tests/test_api_credentials.py      — coverage: encrypt/decrypt,
                                     env-var fallback, audit log,
                                     step-up gate, rate limit
```

`pe module add` writes each of these files to the caller's project
tree. It does NOT overwrite existing files — you'll see a warning per
file that already exists.

## Prerequisites (installed as deps)

- `cryptography>=41` — Fernet symmetric encryption
- `Flask-WTF>=1.2` — CSRF protection
- `Flask-Login>=0.6` — session + owner_required decorator

Add to `pyproject.toml`:

```toml
dependencies = [
    ...,
    "cryptography>=41",
    "Flask-WTF>=1.2",
    "Flask-Login>=0.6",
]
```

## Master key setup

The pattern requires ONE bootstrap secret in `.env`:

```bash
# Generate a Fernet key:
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"

# Add to .env:
CREDENTIALS_MASTER_KEY=<paste the generated key>
```

If `CREDENTIALS_MASTER_KEY` is missing, the app still boots but logs
a WARNING and falls back to reading provider keys from env vars
directly. That's the migration path — existing env-var-based code
keeps working while you gradually move keys into the encrypted table.

## Anti-patterns rejected in review

- Logging the plaintext anywhere (including the audit log itself)
- Returning the full value from any HTTP endpoint — write-only means
  write-only
- Caching plaintext for longer than ~60 seconds
- Storing the master key in the DB or in git
- Reading env vars directly instead of going through `get_credential()`
  — creates drift between paths
- Skipping step-up auth "just for this one page"
- Giving editors / admins access — owner-only, always

## After materialization

1. Add the three deps to `pyproject.toml` and `pip install -e .`
2. Set `CREDENTIALS_MASTER_KEY` in `.env`
3. Register the blueprint in `run.py::create_app()`:
   ```python
   from modules.api_credentials.blueprints.admin_credentials import bp as creds_bp
   app.register_blueprint(creds_bp, url_prefix="/admin/credentials")
   ```
4. Apply the migration
5. Update call sites — replace `os.environ["ANTHROPIC_API_KEY"]` with
   `get_credential("anthropic")`. The env var stays valid as fallback.

## Project-specific docs to add

Every project using this module should add a section to its
`CLAUDE.md` titled "API Credentials" that covers:

- The admin page URL
- The provider allowlist (names used in the `provider` column)
- The env-var fallback map (legacy names)
- Master-key rotation procedure

See `~/.claude/rules/common/api-credentials.md` for the doctrine
that governs this module in every project.

## Reference implementation

First shipped in the 8colors invoice-system (production, 2026). See
that repo for battle-tested edge cases.
