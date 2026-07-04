# docs/design/aspirational/ — the D5 scoring anchor

This directory is the **aspirational reference library** the
`design-critic` scores against when running in D5 ceiling mode.
Each archetype file describes what "award-grade / quiet-excellence"
looks like for one surface class, so the critic can produce a
concrete Awwwards-shaped score (Design 40 / Usability 30 /
Creativity 20 / Content 10) rather than a "not-bad?" verdict.

## v0.40.0 status — CURATED (D7)

The archetype files ship in v0.40.0 with **curated visual references**,
not just narrative anchors. Each file now includes a "Curated visual
references" table with:

- Reference URL + fold/anchor (which section of the surface).
- Which Awwwards dimension the anchor exemplifies (design /
  usability / creativity / content).
- Score bar (9.0 exemplar / 7.5 mid / 6.0 anti-exemplar).
- **Concrete visual anchor** — measurable description (typography
  scale, palette hex, focus-ring specificity, row density, motion
  timing) that the critic can score against without requiring
  vision-model image reads. The description IS the durable contract
  when the reference site updates.

D5 landed the scoring shape + the pass-bar loop against narrative
stubs. **D7** (v0.40.0) upgrades the anchors to curated references
with measurable per-dimension descriptions — the critic no longer
has to say "the reference is a stub."

The archetype files still name:

- The target aesthetic (typography, palette, motion posture,
  signature moment).
- Real-world references (Awwwards / Mobbin / Linear / Stripe /
  Squarespace / Format / Superhuman / Notion / operator taste).
- Scoring anchors for each Awwwards dimension — "what earns 9.0"
  vs "what earns 6.0" on THIS archetype.
- The pass bar (client-facing ≥ 8.0, internal ≥ 7.0 per
  `docs/DESIGN_EXCELLENCE.md` §5).

### Optional local snapshots

For adopters who want the visuals cached alongside the anchors,
capture PNGs into `design/references/<archetype>/<slug>.png` in
their project. The engine's aspirational files carry the
descriptions — the durable, version-controlled contract that
survives when the reference URL redesigns.

### Refresh ritual

Awwwards trends churn. The `commands/design-scan.md` slash-command
runs a **quarterly design-scan** (per `docs/DESIGN_EXCELLENCE.md`)
— review recent Awwwards SOTD / CSSDA / Mobbin / Land-book winners,
refresh the curated visual reference rows in each archetype file,
file new capability requirements as D-items. This is the mechanism
that keeps the ceiling current without a rebuild.

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
   - "Curated visual references" — the measurable per-dimension
     anchors (D7, v0.40.0). The critic cites the specific row
     that most closely matches the diff.
   - "What earns 9.0" — the target ceiling.
   - "What earns 6.0" — the current floor threshold to clear.
   - The three signature signals unique to this archetype.
3. Scores each dimension (0–10) with reference to those anchors.
4. Reports the anchor file (and the specific row cited) in
   `awwwards_score.reference_used`.

## Adding a new archetype

Every archetype file MUST include these sections in this order (the
critic reads them by heading match):

```markdown
# <archetype-name>
## Surface class
## Pass bar
## Real-world exemplars
## Curated visual references (D7, v0.40.0)
## What earns 9.0
## What earns 6.0
## Signature signals unique to this archetype
```

New archetypes belong in this dir with a `<slug>.md` filename. The
critic auto-discovers via `Glob("docs/design/aspirational/*.md")`,
excluding this README.
