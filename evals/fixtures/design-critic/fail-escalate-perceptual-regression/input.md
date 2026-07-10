# fail-escalate-perceptual-regression
<!-- Design-critic fixture (A9.3, v0.46.0) -->

## Scenario

The adopter has a locked reference for the marketing landing at
`docs/design/reference/home.png` captured after a considered
design pass. The diff swaps the hero typography from a distinctive
display serif (Freight Text Pro) to Space Grotesk + Inter — the
AI-era default pairing. Palette shifts from the product's signature
warm cream + dark green to a stock dark-cyan gradient. Two hero
copy lines change from concrete proof ("700 studios cut export
time 4x") to manifesto verbs ("Empower your creative workflow").

`hooks/design-lint.sh` passes because the new colors ARE on-token —
they're just the wrong tokens. `hooks/motion-lint.sh` passes because
the new hero is static. `hooks/signature-lint.sh` passes because a
placeholder `signature_token: slate-headline` class remains on the
h1 element (phantom signature). D3's Playwright
`toHaveScreenshot()` at `maxDiffPixelRatio: 0.01` FAILs — but the
adopter's team was going to run `--update-snapshots` to accept it,
having convinced themselves the redesign was "cleaner."

**A9.3 is the last line of defense.** The `run_visual_regression`
MCP tool computes SSIM = 0.72 (well below the 0.90 FAIL floor). The
diff_regions returned name three shifts: hero-headline-typography,
palette-inversion, hero-copy-block. The critic emits FAIL with
`a9-3-perceptual-regression` HIGH severity + the diff-region names
as concrete evidence, blocks the escalation, and forces a designer
review.

Also present: `d1-reference-drift` HIGH from the composition-level
comparison the critic did in Step 4, and a floor-level 3-tell
count (stock palette + default font pairing + manifesto verbs)
that would already escalate the diff even without A9.3 — but A9.3
is the deterministic-anchored, evidence-verifiable finding that
survives the "but design-lint passes" argument.

## Diff summary

- `templates/marketing/home.html` — hero swaps display font +
  palette + copy voice. Phantom `class="slate-headline"` retained
  from the previous design to satisfy `signature-lint.sh`.
- `static/css/hero.css` — typography stack: Freight Text Pro →
  Space Grotesk + Inter default. Background: warm cream → dark
  cyan gradient (both palettes are on-token).

## Envelope produced by design-critic

Emits FAIL with the A9.3 perceptual_regression finding + the D1
reference_drift finding + three floor tells (stock palette,
default font pairing, manifesto verbs). Awwwards ceiling scoring
lands 5.8 total — below the 8.0 client-facing bar.
