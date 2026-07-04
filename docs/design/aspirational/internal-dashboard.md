# internal-dashboard

Admin views, operator dashboards, ops tools — surfaces users spend
hours in and where information density + speed matter more than
signature. The Linear/Stripe "quiet excellence" archetype.

## Surface class

`internal` — pass bar ≥ 7.0/10 per `DESIGN_EXCELLENCE.md` §5. Internal
targets Linear/Stripe-grade quiet excellence, not Awwwards flash — a
different, equally-high bar.

## Pass bar

- **Design 40:** ≥ 7.0 required. Density is a feature; typography +
  spacing scale to information volume, not the reverse.
- **Usability 30:** ≥ 8.5 required — internal users interact
  hundreds of times a day; every friction compounds. This is the
  highest-weighted dimension for this archetype.
- **Creativity 20:** ≥ 5.5 required. Restraint is the value. Motion
  is functional (state change, sort transition), never decorative.
- **Content 10:** ≥ 7.5 required. Copy is tight — labels not
  sentences, numbers not manifesto.

## Real-world exemplars

- **Linear.app** — the current bar for internal-tool quiet
  excellence. Keyboard-driven, information-dense, motion is
  functional (list reorder, state change).
- **Stripe dashboard** — the bar for "premium-feel dashboard for
  developer users." Type hierarchy carries.
- **Notion desktop** (post-2024 refresh) — the bar for dense-info
  surfaces without visual fatigue.
- **Superhuman** — the bar for keyboard-first internal tool where
  every millisecond visible.

## Curated visual references (D7, v0.40.0)

Concrete visual anchors per dimension. Internal-dashboard anchors
lean on density, keyboard, and information-hierarchy rather than
signature. Operators inspect the live surface.

| Reference | Fold / anchor | Dimension | Bar | Concrete visual anchor |
|---|---|---|---|---|
| `linear.app` (issues view) | Table above the fold | Design | 9.0 | 30+ rows visible on 1080p viewport, row height 32px, `font-variant-numeric: tabular-nums` on all count columns, single accent color for status pills, zero table chrome (no zebra, no heavy borders). |
| `linear.app` (issues view) | Keyboard flow | Usability | 9.5 | Every action reachable in ≤ 2 keystrokes. `?` opens a categorized shortcut cheat sheet. `j`/`k` navigation between rows. `⌘K` command palette covers every action. Shortcut hint visible near the affordance on hover. |
| Stripe dashboard (payments list) | Row optimistic UI | Usability | 9.0 | Refund action shows the new row state within 100ms; server round-trip happens in background; a failure reverts + surfaces the error inline. Skeleton row on initial fetch, NOT a spinner. |
| Notion (post-2024 refresh) | Empty state | Design | 9.0 | Empty database shows the columns as headers + one instructive "Add your first row" line + a keyboard hint (`⌘N`). Not a blank canvas, not a marketing illustration. |
| Superhuman (inbox) | Motion posture | Creativity | 8.0 | Motion is FUNCTIONAL only — the archived message slides out to communicate the archive; tab-switch is instant, no fade. No spring-in cards on load. This scores at the internal-dashboard Creativity ceiling; going higher would be a distraction. |
| Classic Bootstrap admin theme | Table above the fold | Design | 6.0 | Row height 56px "comfortable" default, ≤10 rows above the fold on 1080p. Proportional figures — the 9 column doesn't line up with the 1 column. Heavy zebra + borders decorate the density that isn't there. |
| Any dashboard with staggered-fade page-load | Load | Creativity | 5.0 | Every row springs in with a staggered animation. Every card fades from bottom. Page-transition flourishes on tab switch. The operator waits for decoration to finish before they can act. |
| Any dashboard with mouse-required primary action | Common flow | Usability | 6.0 | The most-used action (approve, archive, mark-paid) has no keyboard shortcut. `?` opens nothing or opens help docs, not shortcuts. Screen still requires 3+ clicks + a mouse to reach the primary action from cold-load. |

**How to use these when scoring:**

- Row-count (30+ vs ≤10) is measurable — inspect the demo screen
  at 1080p and count.
- Keyboard shortcut count is measurable — count discoverable
  shortcuts vs actions on the page.
- Cite the anchor row in `awwwards_score.reference_used`.

## What earns 9.0

- **Keyboard-first, mouse-optional.** Every action has a shortcut;
  the shortcut hint appears near the action on hover. `?` opens a
  cheat sheet. A dashboard that requires a mouse for common
  operations cannot score above 7.0.
- **Information density is a feature.** Tables show 30+ rows
  above the fold. Numeric columns use tabular figures
  (`font-variant-numeric: tabular-nums`) so numbers align. Copy
  wraps to two lines only when necessary.
- **State changes are instant.** Optimistic UI on writes;
  loading is a skeleton, not a spinner. Perceived latency < 100ms
  on the common case.
- **Empty states have shape.** An empty table shows the columns
  and a "no rows yet, here's how" line; a first-time-user view
  has a considered onboarding rather than a blank canvas.
- **Motion is functional only.** List reorders animate to show
  the change; tab switches DON'T animate (would slow the operator).

## What earns 6.0

- Mouse-required for common operations — no keyboard shortcuts,
  or shortcuts that don't match the surface.
- Table shows ≤ 10 rows above the fold; row height inflated
  ("comfortable" default that wastes screen real estate on a tool
  meant for hours of use).
- Numbers use proportional figures (default `font-variant`) — the
  9 column doesn't line up with the 1 column.
- Writes show a spinner + navigate away; user waits for round-trip
  before seeing the result.
- Empty state is a blank canvas or a single "No data" line.
- Decorative motion — spring-in cards on load, staggered fade of
  every row, page-transition flourishes. These are amateur tells
  on internal tools.

## Signature signals unique to this archetype

1. **The 100-row test.** Does the surface still work well with 100
   rows of realistic data, not just the 3-row demo? If cropped
   images / dropped columns / unusable scrollbars appear at
   volume, caps Design at 7.0 no matter how nice the demo looks.
2. **The 3am operator test.** If someone gets paged at 3am, can
   they perform the common actions without reading the docs? Any
   action buried > 2 clicks deep on a tool surface caps Usability
   at 7.5.
3. **No signature required.** Unlike client-facing surfaces, an
   internal dashboard is NOT penalized for the absence of a
   signature interaction. It IS penalized for adding one — a
   decorative signature moment on an internal tool reads as
   distraction, and caps Creativity at 6.0.
