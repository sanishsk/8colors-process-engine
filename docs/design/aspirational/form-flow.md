# form-flow

Multi-step forms, checkout, signup, onboarding, subscription
management, any surface where the user is being asked to give the
product information or money.

## Surface class

`client_facing` — pass bar ≥ 8.0/10.

## Pass bar

- **Design 40:** ≥ 7.5 required. Layout leads the eye through the
  fields in reading order; visual weight matches step importance.
- **Usability 30:** ≥ 9.0 required — this is where usability weight
  bites hardest. A form/flow that scores below 9.0 on Usability
  has a direct revenue-and-trust cost. The pass-bar override.
- **Creativity 20:** ≥ 6.5 required. Signature is optional but
  restraint is required; creativity here usually means
  micro-interactions (validation feedback, progress reveal), not
  hero moments.
- **Content 10:** ≥ 8.5 required. Error copy carries the flow.
  Manipulative defaults or "dark patterns" cap Content at 4.0.

## Real-world exemplars

- **Stripe Checkout** — the perpetual bar for "take a payment
  without breaking trust." Focus states are unmistakable, error
  copy is human, PII fields never feel like a data grab.
- **Typeform** — the bar for one-question-at-a-time flow craft.
- **Notion signup** — the bar for onboarding pacing without
  over-selling.
- **Linear signup** — the bar for zero-friction sign-in that still
  feels premium.

## What earns 9.0

- **Focus states are unmistakable.** Keyboard tab lands on
  something the user can SEE without hunting. Focus ring uses a
  color from the palette but is DEFINITELY visible (2px minimum,
  offset from the field edge).
- **Errors are human sentences.** "Please enter your email
  address" — not "email: required." "That card was declined —
  try another or use PayPal" — not "Error 402."
- **Progress is honest.** Multi-step flow shows step N of M, and
  the M doesn't grow after the user starts. Never hide the total.
- **Autofill respected.** Fields have `autocomplete="…"`
  attributes; browsers can fill them; the styling doesn't fight
  the autofill background.
- **Defaults are neutral, not manipulative.** Upsells are
  UN-checked by default. Free-trial signup doesn't auto-select
  the "add my card now" toggle. Content dimension caps at 6.0 if
  any of these fire.
- **PII fields feel proportional.** If the flow asks for a birth
  date, it explains WHY inline. If it asks for phone, it says
  "for delivery updates" not just "Phone:*".

## What earns 6.0

- Focus indicator is the browser default (1px dotted) OR is
  removed entirely (`outline: none` without a replacement).
- Error copy is "field required" / "invalid" / "error" — a machine
  message shown to a human.
- Progress is shown but the total silently changes (2-of-3
  becomes 4-of-5 after the user commits to the first two).
- Autofill breaks the styling (yellow background clash).
- Manipulative defaults visible — pre-checked upsells, hidden
  add-ons, "unsubscribe" is a 3-click path but subscribe is
  1-click.
- Payment field asks for full name / billing address without
  saying WHY on a $9/mo product.

## Signature signals unique to this archetype

1. **The 10-second panic test.** Show a first-time user the flow
   for 10 seconds. Can they identify: what step they're on, what
   step comes next, and what happens when they finish? Any "no" =
   Usability caps at 7.5.
2. **Payment fields must never look decorative.** A payment field
   with a gradient, a glow, or a hero-image behind it fails a
   trust test that Content and Usability both score. The convention
   is quiet: white background, clear focus, real Stripe/Braintree
   iframe, canonical field order.
3. **Recovery paths visible.** Every flow needs "back," "save for
   later," or "cancel" reachable without hunting. Missing this
   caps Usability at 8.0 regardless of the happy path's polish.
