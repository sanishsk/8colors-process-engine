# docs/design/reference/ — the D3 reference-lock library

This directory holds **locked visual references** for the design-
critic (D1) and the visual-baseline Playwright spec (D3). Every
shipped page has a canonical screenshot here; anything that drifts
against it is a signal for human review, not automatic failure.

## The rule

> **Match the locked reference, never make-it-professional.**

This is the mechanism that stops AI-aesthetic regeneration. A diff
that touches a button or a hero container can silently regenerate
the design with a "professional look" that violates the product's
identity. The reference lock catches that: the pre-committed
screenshot IS the source of truth, and drift against it is the
signal.

## Two consumers

### D1 — `design-critic` agent

If `docs/design/reference/<page>.png` exists for the page under
review, the critic MAY compare the diff's rendered output against
the reference. Substantial drift → FAIL with rule
`d1.reference_drift` (documented in `agents/design-critic.md`
§Reference-locking).

### D3 — Playwright visual-baseline spec

The engine ships `templates/e2e/visual-baseline.spec.ts.template`.
Adopters copy it into their test tree and populate `PAGES_TO_LOCK`.
Playwright captures screenshots at 1280×800 (desktop) and
375×812 (mobile), stores them under
`visual-baseline.spec.ts-snapshots/`, and asserts every subsequent
run matches within `maxDiffPixelRatio: 0.01`.

## The reference-lock process

### 1. Initial capture

Once the design is approved (either by a real designer or by the
operator's own judgment), capture the baseline:

```bash
E2E_BASE_URL=http://127.0.0.1:5000 \
  npx playwright test visual-baseline.spec.ts --update-snapshots
```

Commit the emitted PNGs under
`tests/e2e/visual-baseline.spec.ts-snapshots/` (or wherever your
Playwright config puts them). These are the LOCKED references.

Optionally, copy the desktop-viewport captures into
`docs/design/reference/<page>.png` so the design-critic can also
consult them. The critic reads by filename convention; keep the
name aligned with the page's slug.

### 2. On drift (designer approval loop)

Every subsequent Playwright run compares live against the locked
PNG. On drift, Playwright emits three artefacts under
`test-results/`:

- `<slug>-<viewport>-expected.png` — the locked reference
- `<slug>-<viewport>-actual.png` — the live render
- `<slug>-<viewport>-diff.png` — pixel-difference overlay

CI uploads these as artefacts. A designer (or the operator playing
the role) reviews the diff and picks ONE of two verdicts:

- **DRIFT INTENDED** — the change is what the design wanted. Re-run
  with `--update-snapshots`, commit the new PNGs. The locked
  reference has been updated with an audit trail (the CI artefacts
  + the commit that updated the snapshots).
- **DRIFT REGRESSION** — the code needs to match the locked
  reference. Fix the diff and re-run. The reference does NOT
  change.

The designer approval is the **20% human-bought** part of the
DESIGN_EXCELLENCE floor-vs-ceiling model. Automation catches the
pixel drift; humans decide whether the drift is intent or
regression.

## What to lock (and what NOT to)

**LOCK (≤5 pages initial baseline):**

- Marketing hero / landing.
- One flagship client-facing surface (delivery gallery, portfolio,
  showcase).
- One primary internal dashboard.
- One form-flow (checkout, signup, key onboarding step).
- Optional: the pricing page.

**DO NOT LOCK:**

- Every page in the app. The baseline is a signal amplifier, not
  coverage. 100 locked pages = 100 chances for a false-positive
  from a font-hinting update.
- Pages that render dynamic content (a live feed, a random
  banner). Either mask the moving region via
  `data-visual-baseline='ignore'` or exclude the page from the
  baseline entirely.
- Pages that vary by tenant. Multi-tenant surfaces need a
  tenant-scoped baseline strategy, not a single lock.

## Companion — the visual-baseline-guard hook

The engine ships a `hooks/visual-baseline-guard.sh` PostToolUse +
pre-commit hook (v0.45.0) that WARNs when a flagship page template
is edited but its reference PNG is missing. This is the mechanism
that catches "we shipped a flagship page and never captured its
baseline." Config in `.process-engine.yaml`:

```yaml
visual_baseline:
  enabled: true            # default true when this README exists
  flagship_pages:          # slugs from your PAGES_TO_LOCK
    - home
    - pricing
    - dashboard
  reference_dir: docs/design/reference  # where the PNGs live
```

The guard is advisory (WARN-only). Hard-fail semantics require
adopter opt-in — some adopters run visual-baseline only in CI, not
per commit.

## Anti-patterns

- **Locking the AI-era template** (dark cyan gradient + Space
  Grotesk + manifesto verbs). A locked reference doesn't make the
  design good; it just prevents further regression. Fix the
  design first (D1/D5), then lock.
- **Auto-approving drift.** If the designer approval loop is
  circumvented by CI auto-running `--update-snapshots` on every
  push, the lock is useless. Snapshot updates should always be a
  human commit.
- **Ignoring the diff artefact.** The three PNGs are the evidence
  bundle. CI without artefact upload = drift signal with no
  post-mortem surface.

## Related

- `templates/e2e/visual-baseline.spec.ts.template` — the Playwright
  spec adopters copy in.
- `hooks/visual-baseline-guard.sh` — the reference-must-exist
  advisory gate.
- `agents/design-critic.md` §Reference-locking — the D1 consumer.
- `docs/DESIGN_EXCELLENCE.md` — the floor/ceiling doctrine that
  motivates the reference-lock rule.
