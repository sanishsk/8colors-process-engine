# templates/design/ — D7 design-token pipeline (v0.40.0)

This directory ships the Style Dictionary token pipeline seed +
the axe-core config template. Adopters copy the seeds into their
project once; from then on the JSON token source is edited, and
consumer formats (CSS vars + Tailwind config) are built from it.

## Files

| File | Purpose |
|---|---|
| `tokens.json.template` | Style Dictionary source. Color / typography / spacing / radius / motion tokens as JSON. This is the ONE editable source. |
| `style-dictionary.config.js.template` | Style Dictionary build config. Emits CSS vars + Tailwind extension + flat JSON. |
| `axe-config.json.template` | axe-core WCAG 2.1 AA config (unchanged from v0.28). |

## Bootstrap in an adopter project

```bash
# 1. copy the seeds (rename to drop .template)
mkdir -p design
cp <engine>/templates/design/tokens.json.template design/tokens.json
cp <engine>/templates/design/style-dictionary.config.js.template style-dictionary.config.js

# 2. install Style Dictionary
npm install --save-dev style-dictionary

# 3. edit design/tokens.json — replace brand colors / display face
#    with tenant values; keep the shape.

# 4. build
npx style-dictionary build

# 5. import the emitted CSS + Tailwind config
#    - static/css/tokens.css → import from your root CSS
#    - tailwind.tokens.js    → require it into tailwind.config.js
#      under theme.extend.
```

## Per-tenant themes (multi-tenant apps)

```bash
mkdir -p design/tenants/acme
cp design/tokens.json design/tenants/acme/tokens.json
# edit design/tenants/acme/tokens.json — override brand colors only

# build with tenant overlay (later source wins)
npx style-dictionary build --config style-dictionary.config.js \
  -- --source design/tokens.json --source design/tenants/acme/tokens.json
```

## Why Style Dictionary and not raw Tailwind config?

- **Single source of truth.** Same token feeds CSS vars (for
  Alpine.js/Jinja surfaces) AND Tailwind (for React surfaces).
- **Outlives Tailwind.** If Tailwind changes or a project moves
  off, the JSON source stays; only the transformer output changes.
- **Per-tenant swap** is a JSON overlay, not a fork of the
  design system.
- **Design-critic can read `awwwards_score` anchors** against the
  actual token values, so a diff that adds an off-token color is
  caught by `hooks/design-lint.sh` AND design-critic can cite
  "the palette matches the AI-era stock" more precisely when the
  hex values are in a machine-readable file.

## D7 upgrade path

The current template is minimal — 5 color families, 9 type scale
sizes, 12 spacing steps, 4 motion durations. For a production
system this is intentionally lean; adopters extend by adding
categories (elevation / shadow / z-index / breakpoint) without
touching the transformer or the build.
