# Project Scaffolding + Domain Modules (A6)

> Shipped in v0.25.0. Complements `agents/project-kickstarter.md` —
> that agent runs interactive Q&A + reasoning; `pe new` is the
> deterministic template-drop path (zero API cost).

## Two surfaces

### 1. `pe new <name> [--stack ...]` — fresh project

Scaffolds a new project directory from `templates/scaffold/<stack>/`,
substitutes placeholders, runs `git init`, then runs `pe install` on
the result. Under 30 seconds start-to-finish.

```bash
pe new "Acme Invoices" --stack python-flask
pe new "Small Tool" --stack generic --dir ~/experiments
pe new "MyApp" --tagline "the app I've always wanted" --no-install
```

### 2. `pe module add <module>` — drop reusable module

Materializes a battle-tested SaaS module into an existing project's
`modules/` tree. Never overwrites — reports "skipped" per collision.

```bash
cd ~/code/my-project
pe module add api-credentials
```

## Available stacks

| Stack | Ships |
|---|---|
| `python-flask` | Flask 3 + SQLAlchemy 2 + pytest + ruff + mypy. `run.py`, `pyproject.toml`, `.env.example`, `modules/`, `tests/`, smoke test. |
| `generic` | Stack-agnostic minimal tree. `modules/`, `tests/`, `scripts/`, `docs/`, `.gitignore`, `CLAUDE.md`, `README.md`. |

New stacks land as a directory under `templates/scaffold/<stack>/`.
No CLI code changes needed — the scaffolder discovers stacks by
directory listing.

## Available domain modules

| Module | What it ships | Deps to add |
|---|---|---|
| `auth` (v0.26.0) | Session-based auth. User model + Role enum (owner/admin/member), bcrypt hashing (12 rounds, 2026 OWASP min), `@login_required` / `@owner_required` / `@admin_required` / `@require_password_reauth` decorators, /login /logout /reauth routes, 15-min step-up window, IP-scoped rate limit (5/15min), CSRF-protected forms, `create_owner` bootstrap script, 15+ coverage-floor tests. | `Flask-Login`, `Flask-WTF`, `bcrypt` |
| `tenancy` (v0.27.0) | Multi-tenant `org_id` scoping + PostgreSQL FORCE-mode RLS. Organization + Membership models, OrgRole enum (distinct type from `auth.Role`), session-based current-org context, `@require_membership` / `@require_org_role` decorators, `scoped_query` helper (loud-failure on missing context), `apply_rls_to_table` migration helper (superuser-bypass-proof), org switcher/create/members blueprint, 15 coverage-floor tests. | (no new deps — reuses `Flask-Login`, `Flask-WTF`, SQLAlchemy from `auth`) |
| `billing` (v0.28.0) | Payment processing. Charge / Refund / PaymentEvent models (idempotency ledger), Decimal-only money helpers (float rejection regression-tested), PaymentProvider protocol + Stripe PaymentIntent adapter, server-side amount authority (`create_charge_for_order` — client never passes amount), HMAC-verified Stripe webhook handler with idempotency-by-event_id, FORCE-mode RLS on all three tables, org-scoped receipt page, 15+ coverage-floor tests. Depends on `auth` + `tenancy` (charges org-scoped) and optionally `api-credentials` (Stripe secret via credential service). | `stripe>=8.0` |
| `api-credentials` (v0.25.0) | Encrypted API-key admin (Fernet + write-only admin UI + audit log). Placeholder decorators resolve to real `auth` module decorators when both installed. | `cryptography`, `Flask-WTF`, `Flask-Login` |

Modules land as a directory under `templates/domain-modules/<name>/`.
Each carries a `README.md` explaining: what it does, deps to add,
env vars to set, blueprint registration, migration application,
project-specific docs to add to `CLAUDE.md`.

## Recommended install pairing

The four shipped modules compose to a full multi-tenant SaaS
skeleton with payments:

```bash
cd ~/code/my-project
pe module add auth              # first — provides decorators + User FK
pe module add tenancy           # second — depends on users(id) from auth
pe module add api-credentials   # third — imports auth decorators (also
                                #         gates the Stripe secret admin)
pe module add billing           # last — depends on all three above
```

Without `auth`: `tenancy`'s memberships table can't reference
`users(id)`; `api-credentials`'s admin endpoints abort 403 by
default (safe-by-default placeholder).
Without `tenancy`: `billing`'s charges have no `org_id` FK — the
migration will fail. Billing REQUIRES tenancy.
Without `api-credentials`: `billing` still works, falling back to
the raw `STRIPE_SECRET_KEY` env var (still functional, less audited).
All four modules install side-by-side without directory conflict.

## Roadmap (next modules — deferred to follow-up releases)
- `password-reset` — email-token flow (deferred from v0.26.0 auth
  scope; needs email transport wired first).
- OAuth / JWT surfaces — separate blueprint additions per project
  need; not batched into `auth`.
- Email invitations for tenancy — same email-transport dependency
  as `password-reset`.
- Razorpay adapter for `billing` — same PaymentProvider protocol
  as the Stripe adapter; ships when the operator's Razorpay-first
  projects (India-market) call for it.
- Subscription billing — recurring charges, plan/tier management.
  Extends the billing module; ships after adopters have proven the
  one-off charge shape.

Each ships when it's genuinely reusable across ≥ 2 projects, not
speculatively. The engine's principle: extract from adopters, don't
architect in advance.

## Placeholder substitution

Three placeholders are substituted in every template file:

- `{{PROJECT_NAME}}` — the display name passed to `pe new` ("Acme Corp")
- `{{PROJECT_SLUG}}` — auto-derived, lowercase-hyphenated ("acme-corp")
- `{{PROJECT_TAGLINE}}` — from `--tagline` or a default

Everything else is copied byte-for-byte.

## `.template` suffix convention

Some files ship with a `.template` suffix so the engine repo's own
tooling (linters, tests, git-hooks) doesn't try to scan the template
content as if it were project code:

```
templates/scaffold/python-flask/pyproject.toml.template
  → materializes as: <project>/pyproject.toml
```

Two additional cases where the filename shifts at materialization:

```
gitignore.template   → .gitignore
env.example.template → .env.example
```

(Dotfiles kept out of the template dir so `ls` shows them without a
`-a` flag.)

## No overwrite policy

- `pe new` refuses to run if the target directory exists and is
  non-empty. Exit 1 with an error message; no dry-run needed —
  destructive scaffolding is not a feature.
- `pe module add` writes files that don't already exist. If EVERY
  file is a collision, exits 1 ("nothing written"). Otherwise
  reports N written / M skipped and continues.

The operator is expected to `git diff` after `pe module add` to
review the drop and either commit or `git checkout -- .` to revert.

## Complement, not replacement

`agents/project-kickstarter.md` is the Opus-tier interactive scaffold —
it asks the operator questions, picks the right stack, tunes the
generated code to the domain. Use it for green-field projects with
unclear requirements.

`pe new` is the deterministic drop — you already know the stack, you
want the standard tree in 30 seconds. Use it when the answer to
"what should this look like?" is "the same as every other one."

Both routes end with the same `pe install`, so the engine wiring is
identical either way.

## Related items

- **A6 status** — this release ships the SCAFFOLD side + ONE
  reusable module (proof-of-shape). The full library
  (`auth`, `tenancy`, `billing`) is DEFERRED to follow-up releases
  as each pattern proves itself across ≥ 2 adopters.
- **`project-kickstarter`** — the Q&A / reasoning path (interactive).
- **`project-onboarder`** — for EXISTING projects. Analyzes gaps
  against standard rules; different surface from `pe new`.
