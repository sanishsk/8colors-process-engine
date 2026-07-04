# client-gallery

Client-facing galleries where a paying customer views deliverables
(the 8CStudio Delivery gallery archetype). Also: portfolio pages,
tenant showcases, media libraries surfaced to end-consumers.

## Surface class

`client_facing` — pass bar ≥ 8.0/10.

## Pass bar

- **Design 40:** ≥ 8.0 required. Layout serves the imagery, not the
  reverse. Chrome recedes.
- **Usability 30:** ≥ 8.5 required. Loading is perceived-instant.
  Navigation between images is one gesture. Sharing / downloading
  is obvious without a tour.
- **Creativity 20:** ≥ 7.5 required. Transitions between images
  (or between gallery and detail) have a signature. This is where
  gallery apps differentiate.
- **Content 10:** ≥ 7.5 required. Titles/dates/context are present
  but never noisier than the imagery.

## Real-world exemplars

- **Pixieset** — the baseline to beat (ROADMAP C4 launch gate).
  Solid, but the transitions are template-generic; the differentiator
  is craft, not features.
- **Squarespace showcase templates (Bedford, Almar)** — the
  benchmark for chrome-recedes-imagery-leads.
- **Prophoto** — the bar for "photographer-owned typography +
  gallery integration."
- **Format** — the bar for professional portfolio delivery.

## Curated visual references (D7, v0.40.0)

Concrete visual anchors per dimension. Operators inspect the live
surface; the critic reasons about the anchor description below when
scoring a diff against this archetype.

| Reference | Fold / anchor | Dimension | Bar | Concrete visual anchor |
|---|---|---|---|---|
| Squarespace `Bedford` template gallery | Grid view | Design | 9.0 | Asymmetric masonry — cells honor image aspect (3:2, 4:5, square all coexist). Zero chrome above imagery except one small back arrow. Client name in serif title above grid; studio brand as a small footer mark. |
| Squarespace `Almar` template gallery | Detail view | Creativity | 9.0 | Image transition is a considered cross-fade with subtle Ken-Burns-style scale (1.02× over 400ms), NOT a slide. Reduced-motion path: instant cross-fade with no scale, still communicates the shift. |
| `format.com` portfolio | Load-in | Usability | 9.0 | Progressive blurhash → sharpen. LCP <1.2s on Fast 3G. Grid renders shape immediately (aspect-ratio boxes reserved) so no CLS shift when images arrive. |
| `prophoto` gallery | Client-facing header | Content | 9.0 | Client name (shoot title / wedding date) is the h1, larger than the studio brand mark. Delivery message from the studio is one line, italic serif, present but recedes. |
| Pixieset default gallery | Grid view | Design | 7.5 | Uniform-aspect grid (crops enforce 1:1 or 3:2 whether or not the image fits). Chrome bar with logo + share + download is 60px tall above the fold — takes attention off the photography. This is the baseline to beat. |
| Any gallery with template motion | Detail view | Creativity | 6.0 | Default template transition — fade-in over 300ms, no directional or spatial cue. Reduced-motion path: no transition at all, the modal just appears with no signal state changed. |
| Any gallery with 25%+ chrome | Grid view | Design | 6.0 | Top bar (nav + brand + client dropdown), breadcrumbs row, action toolbar, and footer share row together occupy >25% of viewport height on the gallery view. Photography is decoration, not lead. |
| "Powered by X" watermarked gallery | Any | Design | 6.0 | Vendor watermark visible anywhere on the client-facing surface (footer, corner of gallery frame, share-modal). Studio is renting a template, not delivering a signature product. |

**How to use these when scoring:**

- If the diff's grid resembles the Squarespace masonry row, Design
  scores toward 9.0. If it resembles the Pixieset uniform-aspect
  row, Design caps at 7.5.
- Chrome-height threshold (25%) is measurable — if the diff includes
  the template, measure it.
- Cite the anchor row in `awwwards_score.reference_used`.

## What earns 9.0

- **Chrome truly recedes.** Nav is minimal on gallery view — often
  a single "back" affordance plus a share/download control. No
  breadcrumbs above the imagery. No "Powered by X" watermark.
- **Image transitions have signature motion.** Not fade-in
  (default), not slide (Pixieset default). Something that says
  "this studio cares" — a subtle scale-and-position choreograph,
  a smart cross-fade that respects the aspect ratio, a scroll-tied
  reveal that lets the reader control the pace.
- **Perceived-instant loading.** LQIP + blurhash placeholders,
  progressive JPEG, correctly sized responsive images. LCP < 1.2s
  on Fast 3G. A gallery that loads slower than Pixieset's cannot
  score above 7.0.
- **The photo IS the design.** Cropping, ratio, and spacing choices
  serve the image. Uniform grid = 7.5 ceiling; considered
  variable-height masonry or hero-tile layouts push toward 9.0.
- **Sharing / downloading is delightful.** Copy-link feedback,
  download-all with progress, "share to client" flow — not the
  right-click-to-save baseline.

## What earns 6.0

- Fixed grid of same-size thumbnails, all cropped to 1:1 regardless
  of the photo's actual aspect.
- Default fade-in on modal open; no considered transition.
- Nav chrome (breadcrumbs, top bar, share icon row, footer) takes
  25%+ of screen height on the gallery view.
- "Powered by" watermark or the tenant's branding on someone else's
  imagery.
- Load-in is a spinner on gray boxes; no LQIP; images pop in as
  each finishes downloading.
- Sharing = "copy URL" only; downloading = per-image, no bulk.

## Signature signals unique to this archetype

1. **The client's name is more prominent than the studio's.** If
   the diff's gallery header shows the STUDIO'S brand bigger than
   the CLIENT'S wedding date or shoot title, the surface is
   confused about who it's for. Caps Design at 7.5.
2. **Print-safe layout.** If the client will print-select from
   this gallery (wedding + portrait workflow), the diff must show
   a print-preview or a proof-selection mode. Missing this on a
   Delivery gallery caps Usability at 8.0.
3. **Zero-JS fallback for the imagery itself.** The images should
   still show (even without transitions) if JS is disabled. Auth
   flow can require JS; the gallery cannot. This is a
   pixieset-parity floor.
