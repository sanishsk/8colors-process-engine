# marketing-site

Landing pages, feature pages, pricing, about, docs-home. Any surface
a prospect sees before signing in.

## Surface class

`client_facing` — pass bar ≥ 8.0/10.

## Pass bar

- **Design 40:** ≥ 8.0 required. Typography hierarchy carries the
  page; layout has an obvious first-glance anchor; palette identity
  is distinct from the stock dark-cyan-gradient template.
- **Usability 30:** ≥ 8.5 required (usability is CHEAP to get right
  on marketing; anything under is neglect). Nav ≤ 5 items;
  above-the-fold CTA within one glance; no mystery-meat icons.
- **Creativity 20:** ≥ 7.5 required. One signature moment — an
  interaction, an illustration, a hero device — that couldn't be
  swapped for another SaaS's landing without noticing.
- **Content 10:** ≥ 8.0 required. Real specifics, not manifesto
  verbs ("Imagine.", "Unleash", "Empower"). No emoji-in-buttons.

## Real-world exemplars

- **Linear.app** — the current bar for "quiet excellence with one
  hero moment." Type-driven, restrained palette, one scroll
  interaction that communicates the product's plane-view metaphor.
- **Vercel.com** — the bar for "dense information with premium feel."
  Typography does the work; motion is functional, not decorative.
- **Stripe.com** — the perpetual bar for "explains complex things
  clearly with taste." Content voice + hierarchy do more than
  visual polish.

## Curated visual references (D7, v0.40.0)

Concrete visual anchors per dimension. Each row names a URL + which
fold + which score bar it exemplifies. Operators inspect the live
surface; the critic reasons about the anchor description below when
scoring a diff against this archetype. Capture the reference into
`design/references/marketing/<slug>.png` if the surface is likely to
change; the anchor description is the durable contract.

| Reference | Fold / anchor | Dimension | Bar | Concrete visual anchor |
|---|---|---|---|---|
| `linear.app` | Hero (above the fold) | Design | 9.0 | Single-weight display face (Inter Display 400) at 72px, one line, one accent color for the "Plan and build" phrase; NO gradient background; palette is neutral gray with a single blue accent (#5E6AD2) — recognizable in one glance. |
| `linear.app` | Hero motion | Creativity | 9.0 | ONE signature scroll interaction — the isometric plane rotates through 3 keyframes as the user scrolls a single section. No parallax stacking. `prefers-reduced-motion` respected: reduced path shows the third keyframe statically. |
| `vercel.com` | Feature grid | Design | 9.0 | 12-column grid with varied cell widths (asymmetric), each cell has ONE hero element + one line of proof-copy. No card-grid-as-menu. Palette: pure black + white + one product accent per feature — the polychrome is intentional, not stock. |
| `stripe.com` | Docs-home hero | Content | 9.0 | Copy voice: "The financial infrastructure for the internet." Concrete noun ("infrastructure") + concrete audience ("the internet"). No manifesto verb. Below-hero: real code snippet running, not a marketing illustration. |
| `stripe.com` | Pricing page | Content | 9.0 | Real numbers per tier ("2.9% + 30¢"), one recommended tier visually marked WITHOUT a pre-checked upsell, "Contact sales" only for the highest tier. Explicit "no hidden fees" section with the specific fees enumerated. |
| Generic "SaaS-with-Space-Grotesk-and-Inter" landing | Hero | Design | 6.0 | Type pairing is Space Grotesk display + Inter body — the AI-era smell. Hero background is a dark cyan-to-black gradient. Emoji in primary CTA. Marketing verbs: "Imagine.", "Unleash", "Empower". Card-grid-as-menu below fold. |
| Any landing with 5+ animated backgrounds | Hero motion | Creativity | 6.0 | Effect stacking — parallax + orb pulses + fade-in + typewriter + gradient shimmer + scroll-triggered slides. Nothing communicates; everything decorates. `prefers-reduced-motion` either absent or leaves the page silently-static with no signal state changed. |

**How to use these when scoring:**

- If the diff's hero visually resembles the Linear/Vercel/Stripe row
  named for its dimension, that dimension scores toward 9.0.
- If the diff visually resembles the 6.0 anti-exemplar row, the
  dimension caps at 6.5 regardless of other polish.
- Cite the anchor row in `awwwards_score.reference_used` (e.g.
  `"docs/design/aspirational/marketing-site.md#curated-visual-references linear.app hero"`).

## What earns 9.0

- **Typography is a system**, not a font choice. Multiple weights
  used with intent; a distinctive display face on hero moments;
  monospace or a numeric variant when data is shown. Space
  Grotesk + Inter default pairing (the AI-era smell) is
  disqualifying at this tier.
- **One signature interaction** on the hero — could be a scroll
  choreograph, a cursor-driven hero device, an interactive
  diagram. It must communicate the product's value, not
  decorate.
- **Palette identity beyond token compliance.** The design-lint
  ensures no off-token colors ship; the 9.0 bar requires the
  palette to be UNIQUE to this product — a color the reader would
  associate with the brand after one visit.
- **Motion that moves the reader through the story** (Lenis-style
  smooth scroll, GSAP ScrollTrigger reveal choreography) —
  respecting `prefers-reduced-motion` and not regressing LCP/CLS.
- **Copy has specific proof, not aspirational verbs.** "700 studios
  cut export time 4x" beats "Empower your creative workflow."
- **Nav is opinionated** — 4–5 primary items, each an intent, not
  a taxonomy dump.

## What earns 6.0

- Type is default (Space Grotesk + Inter, the AI-era pairing) OR
  the site uses only one weight of one font family.
- Palette is on-token but IS the stock dark-cyan-gradient — reads
  as "AI SaaS landing #3007."
- Motion is either absent OR CSS-transitions-only with no
  intentional choreograph.
- Copy uses manifesto verbs OR emoji-in-buttons OR both.
- Card-grid-as-menu below the fold with 6+ equally-sized cards and
  no primary CTA anchor.
- Above-the-fold CTA is generic ("Get started", "Learn more") with
  no proof-of-value nearby.

## Signature signals unique to this archetype

1. **The hero has a memorable object or interaction.** A perfect
   marketing site can be recognized by ONE image or motion moment
   even without the logo. If the diff's hero is generic (photo of
   people in an office, gradient rectangle, product screenshot on a
   floating device), it CANNOT score above 7.0 no matter what else
   is good.
2. **Pricing page discipline.** If the diff touches pricing, the
   page should include: real numbers (no "Contact us" as the only
   tier), a comparison the reader can act on, and NO manipulative
   defaults (pre-checked upsells, hidden add-ons). Failing here
   caps Content at 7.0.
3. **Docs-home is a first-class surface**, not an afterthought
   dumping ground. Good marketing sites make their docs entrance
   as considered as their landing.
