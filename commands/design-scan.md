---
description: Quarterly design-scan ritual (D7, v0.40.0) — refresh the curated visual reference library. Review recent Awwwards SOTD / CSSDA / Mobbin / Land-book winners against the four archetypes and refresh anchor rows. Not a build — a *ritual*.
---

# /design-scan

Refresh the D7 curated visual reference library
(`docs/design/aspirational/*.md`) against the current award-grade
ceiling. Run once per quarter (per `docs/DESIGN_EXCELLENCE.md`
"future-proofing ritual"). This is the mechanism that keeps
design-critic's ceiling current without a rebuild — design trends
churn, and stale anchors quietly drift out from award-grade to
last-year-grade.

## When to invoke

- **Every quarter, first week of the month.** Set a calendar
  reminder or wire it into `retrospective-agent`'s quarterly
  cadence.
- **Ad-hoc** when a design ceiling verdict feels off — if
  design-critic is passing surfaces the operator would fail on
  taste, the anchors have drifted; run this to refresh them.

## Contract

Precondition: `docs/design/aspirational/*.md` exists (4 archetype
files with "Curated visual references" tables). Postcondition:
each archetype's table has at least one new-or-refreshed row and
one retired row (net-zero on stale references).

## The pass (in order)

### Step 1 — collect the ceiling

For each archetype (marketing / gallery / dashboard / form-flow),
pull the current award-grade ceiling from three sources:

1. **Awwwards Site of the Day / Site of the Month** for the last
   quarter — filter by the archetype (marketing pages, portfolios,
   apps).
2. **CSSDA (CSS Design Awards) winners** for the last quarter.
3. **Mobbin flows** for the app/dashboard archetypes; **Land-book**
   for landing pages.

For each candidate, capture:

- URL + capture date + which section (fold / anchor) matters.
- Which Awwwards dimension it exemplifies (design / usability /
  creativity / content).
- The **concrete visual anchor** — typography scale, palette hex,
  focus-ring specificity, row density, motion timing — described
  well enough that the critic can score against the description
  without re-inspecting.

### Step 2 — retire the stale

For each archetype table:

- If a reference URL 404s or has redesigned to something that no
  longer exemplifies the anchor, retire the row.
- If a reference no longer represents the current award-grade
  ceiling (a new class of surface has surpassed it), retire the
  row.
- Move retired rows to `docs/design/aspirational/RETIRED.md` with
  a note on WHY retired. This is the audit trail — future
  quarterly scans see what got promoted.

### Step 3 — add the new

For each archetype table, add rows for the collected candidates
that displaced the retired ones. The bar:

- One 9.0 exemplar row for at least one dimension per archetype.
- One 7.5 mid-tier row optional per archetype.
- One 6.0 anti-exemplar row per archetype (the anti-pattern is
  as important as the exemplar — often more actionable).

### Step 4 — file capability requirements as D-items

If a candidate exemplifies a NEW capability the engine can't
currently score for (a motion pattern the critic doesn't recognize,
a token pattern outside Style Dictionary's coverage, an
accessibility affordance beyond axe-core), file it as a new D-item
in `docs/ENHANCEMENT_PLAN_V2.md`. This is the mechanism by which
the ceiling capability grows — the scan doesn't just refresh
references, it names the gap between "we can score for this" and
"the ceiling has moved."

### Step 5 — retrospective note

Add a note to the next `retrospective-agent` run summarizing:

- How many rows refreshed per archetype.
- Whether the ceiling has moved (are the 9.0 anchors visibly
  ahead of last quarter's?).
- Whether a new D-item was filed (capability gap).

This closes the loop — the retro records whether the ritual is
working. If three consecutive quarters produce no D-items and no
retirements, the ritual is stale and the operator's taste has
plateaued; treat as a signal to seek external design review, not
skip the ritual.

## What NOT to do

- **Don't add every award winner.** The table is capped ~8 rows
  per archetype for readability. Retire before adding.
- **Don't capture only exemplars.** Anti-exemplars (the 6.0 rows)
  are what design-critic uses to CAP a dimension — they're the
  actionable half.
- **Don't invent references.** Every row cites a real URL. Fake
  references corrode the whole D5+D7 loop.
- **Don't skip the anchor description.** The URL will redesign;
  the description is the durable contract.

## Related

- `docs/design/aspirational/README.md` — the archetype file
  contract and how to add a new archetype.
- `docs/DESIGN_EXCELLENCE.md` — the doctrine behind the ritual.
- `agents/design-critic.md` — the consumer of these anchors.
