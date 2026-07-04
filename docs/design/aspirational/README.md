# docs/design/aspirational/ — the D5 scoring anchor

This directory is the **aspirational reference library** the
`design-critic` scores against when running in D5 ceiling mode.
Each archetype file describes what "award-grade / quiet-excellence"
looks like for one surface class, so the critic can produce a
concrete Awwwards-shaped score (Design 40 / Usability 30 /
Creativity 20 / Content 10) rather than a "not-bad?" verdict.

## v0.38.0 status — STUBS

The archetype files that ship in v0.38.0 are **narrative stubs**,
not visual references. They name:

- The target aesthetic (typography, palette, motion posture,
  signature moment).
- 1–2 real-world references (Awwwards / Mobbin / operator taste).
- Scoring anchors for each Awwwards dimension — "what earns 9.0"
  vs "what earns 6.0" on THIS archetype.
- The pass bar (client-facing ≥ 8.0, internal ≥ 7.0 per
  `docs/DESIGN_EXCELLENCE.md` §5).

D5 lands the scoring shape + the aspirational-target loop.
**D7** (the curated reference library) upgrades these stubs to
real visuals (screenshot swatches, motion clips, token
snapshots) sourced from the operator's own gallery + selected
Awwwards / CSSDA / Mobbin winners. Until D7, the stubs are
sufficient for the critic to reason about the direction — the
adopter's judgment is the final anchor when scoring is close.

## The archetypes

| File | Surface class | Pass bar | Real-world exemplars named |
|---|---|---|---|
| `marketing-site.md` | client_facing | ≥ 8.0 | Linear.app landing, Vercel.com |
| `client-gallery.md` | client_facing | ≥ 8.0 | Pixieset (baseline to beat), Squarespace showcase |
| `internal-dashboard.md` | internal | ≥ 7.0 | Linear app, Stripe dashboard |
| `form-flow.md` | client_facing | ≥ 8.0 | Stripe Checkout, Typeform |

## How the critic reads these

At scoring time, the critic:

1. Classifies the surface as `client_facing` or `internal`.
2. Opens the matching archetype file and reads:
   - "What earns 9.0" — the target ceiling.
   - "What earns 6.0" — the current floor threshold to clear.
   - The three signature signals unique to this archetype.
3. Scores each dimension (0–10) with reference to those anchors.
4. Reports the anchor file in `awwwards_score.reference_used`.

## Adding a new archetype

Every archetype file MUST include these sections in this order (the
critic reads them by heading match):

```markdown
# <archetype-name>
## Surface class
## Pass bar
## Real-world exemplars
## What earns 9.0
## What earns 6.0
## Signature signals unique to this archetype
```

New archetypes belong in this dir with a `<slug>.md` filename. The
critic auto-discovers via `Glob("docs/design/aspirational/*.md")`,
excluding this README.
