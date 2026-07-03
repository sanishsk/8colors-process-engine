# Design Excellence — from "not AI-looking" to award-grade (research + engine capability spec)

> **Date:** 2026-07-03 · **Purpose:** the operator wants engine-produced design to be not merely
> clean but *award-grade and future-proof* — visually exceptional, world-class usability, always
> tracking the best in the market. This doc is the research + the capability model + the curated
> tooling + how to bake it into the engine. Implementable items land as **D5–D8** in
> `ENHANCEMENT_PLAN_V2.md`; this doc is the durable "why + how + what-tools" behind them.
> Companion to the shipped `agents/design-critic.md` (the floor) and `hooks/design-lint.sh`.

---

## 1. The core insight: FLOOR vs CEILING (this reframes everything)

The engine's current design capability is a **floor**: the design-critic catches the 9
AI-aesthetic tells (glow, gradients, manifesto copy, card-grid dashboards, no signature…),
design-lint enforces token consistency, axe-core+Lighthouse enforce accessibility+performance.
**All of that prevents BAD.** None of it produces GREAT.

Award-winning design is a **ceiling**: the *presence* of exceptional craft — originality, visual
impact, motion, a signature moment, storytelling — not the *absence* of tells. You can pass every
current gate and still be forgettable. So the whole task here is **adding a ceiling on top of the
floor you already have.**

The honest breakdown of how automatable "award-grade" is (using Awwwards' own weighting):

| Award dimension | Weight | How automatable | Engine's lever |
|---|---|---|---|
| **Usability** | 30% | HIGH — gateable | axe-core, Lighthouse, nav-budget, responsive smoke (mostly SHIPPED) |
| **Design** (typography, color, hierarchy, spacing, craft) | 40% | MEDIUM — partly gateable, partly taste | design-lint tokens + design-critic rubric + curated references |
| **Creativity** (originality, the wow) | 20% | LOW — needs human/vision-model taste + references | reference library + vision-model scoring + *know when to buy human* |
| **Content** | 10% | MEDIUM | copy-lint + editorial judgment |
| *Cross-cutting: Performance* | (gate on all) | HIGH | Core Web Vitals budgets (Lighthouse CI) |

**So the engine can systematically own ~70% (usability + performance + design-consistency +
accessibility) and *support* the 20% creativity with references and vision-model scoring — but
cannot fully automate the wow.** The mature move is to maximize the 70% deterministically and make
the 20% cheap to reach (curated references, vision scoring, and honest "buy a human for the hero
moment" triggers). Anyone selling "AI makes award-winning design end-to-end" is overclaiming.

---

## 2. What actually wins in 2026 (grounded in Awwwards/CSSDA criteria + trends)

**Awwwards scoring:** Design 40% / Usability 30% / Creativity 20% / Content 10%; needs ≥8.0/10 for
Site of the Day. The winners (Lando Norris = Site of the Year 2025, Scout Motors, Messenger) share:

1. **A signature idea, executed with restraint** — one memorable concept, not ten effects. The #1
   tell of amateur "trying to impress" is effect-stacking.
2. **Typography as the hero** — bold, confident type + a real hierarchy is the cheapest path to
   "premium." Type-driven layouts win far more than WebGL.
3. **Motion with intent** — micro-interactions, scroll-choreography, purposeful transitions.
   Motion that *communicates* (state, spatial relationship), never decoration.
4. **Extreme performance** — Core Web Vitals are now table-stakes; a slow award submission is
   rejected regardless of beauty. Fast IS part of the aesthetic.
5. **Flawless usability + accessibility** — 30% of the score; the "immersive but unusable" era is
   over ("purpose-driven UX" is the named 2026 trend).
6. **Emerging tech where it serves the story** — WebGL/3D/AI-interfaces win *when they carry the
   concept*, not as garnish.

**The critical nuance for THIS operator's stack (Flask/Jinja/Alpine/Tailwind, not React/WebGL):**
you do NOT need WebGL to win. Typography + performance + one signature moment + flawless usability
is an award-grade recipe fully achievable in Jinja/Alpine + a light GSAP layer. Reserve heavy motion
for the *client-facing* surfaces (Delivery galleries, tenant sites) where it earns its cost; the
*internal app* (finance/dashboard) should target **Linear/Stripe-grade quiet excellence**, not
Awwwards flash — a different, equally-high bar. **Surface-differentiated targets** is the key
discipline (see §5).

---

## 3. Where the existing projects stand, and what they lack

From the 2026-07 audits: **8CStudio's look-and-feel = the floor's absence, not the ceiling's.** It
reads as AI-generated (stock dark+cyan+gradient, manifesto login copy, card-grid dashboard, emoji
icons, no signature) AND inconsistent (~48% token compliance, 159 button variants, 77 modals, half
non-responsive). That's a *floor* problem — exactly what tokens v2 (PRODUCT_RESTRUCTURE_PLAN Phase
A+) + design-lint + the design-critic now fix.

**What it lacks for the ceiling (once the floor is clean):**
- **No signature element** — nothing that could only be 8CS (the film-slate/timecode/slugline
  motifs proposed in the restructure plan are exactly this — build them).
- **No motion craft** — zero purposeful interaction; the Delivery gallery especially needs
  scroll-choreography + image-transition polish to feel premium vs Pixieset.
- **No award-grade reference target** — the design-critic compares to a "locked reference," but no
  *aspirational* reference set exists; it defends the floor, doesn't pull toward a ceiling.
- **Type is default** (Space Grotesk+Inter, the AI-era pairing) — a distinctive type system is the
  cheapest premium upgrade.

**Verdict:** get the floor spotless first (in flight), then the Delivery client surfaces are the
place to invest in the ceiling — because that's where a paying customer judges the studio, and
where "beats Pixieset side-by-side" is already a launch gate (ROADMAP C4).

---

## 4. The tooling — OSS / CLI / MCP, with honest stack-fit

Grouped by the award dimension each serves. **Bold = adopt; italic = stack-dependent.**

### Motion & interaction craft (the 20% "wow", Design + Creativity)
- **GSAP** (now fully free incl. all plugins, 2025) — timeline orchestration, ScrollTrigger,
  SVG morphing, physics. **Best fit for Jinja/Alpine** (framework-agnostic, animates any DOM). The
  right pick for 8CStudio's client surfaces + Delivery galleries.
- **Motion** (`motion.dev`, ex-Framer-Motion) — the React champion (shared-layout, AnimatePresence).
  *Only if a surface goes React.* 35M weekly downloads; the ecosystem default there.
- **Lenis** (smooth-scroll) — the quiet backbone of most award scroll experiences; tiny, pairs with
  GSAP ScrollTrigger.
- **Rule:** motion serves communication, never decoration; every animation respects
  `prefers-reduced-motion` (already in the design system) and must not regress Core Web Vitals
  (gate it — §5 D6).

### Performance / Core Web Vitals (cross-cutting, table-stakes)
- **Lighthouse CI** (`@lhci/cli`) — budgets on LCP/CLS/TBT + a11y; **already shipped (D2/PF3)**.
  Extend budgets to award-grade thresholds on client surfaces.
- **unlighthouse** (CLI) — crawls the WHOLE site and Lighthouse-scores every page at once; ideal for
  a tenant-site/gallery audit in one command. **Adopt as a CLI power-up.**
- **WebPageTest** (CLI/API) — filmstrip + real-device waterfalls for the hero pages when tuning.

### Usability & accessibility (the 30%, most gateable)
- **axe-core** + **pa11y** — WCAG AA gate; **shipped via D2.** Usability is 30% of the award score
  and the most deterministic — own it fully.
- **Playwright** (MCP + CLI) — visual-regression baselines (D3) + interaction testing; **present.**

### Design system / tokens (the 40% Design, made consistent + portable)
- **Style Dictionary** (Amazon, the industry standard) — transform one token source →
  CSS-vars/Tailwind/iOS/Android. **Adopt to future-proof tokens v2** into a real pipeline (today
  tokens live as Tailwind classes; Style Dictionary makes them a single source that can theme
  per-tenant and outlive Tailwind).
- **Radix UI** (unstyled, accessible primitives) + **shadcn/ui** (the AI-standardized component
  library — "AI tools have standardised on it", 114k stars) — *React-only.* Use them for any React
  surface so creativity goes into the *signature*, not into rebuilding a dropdown. **For
  8CStudio's Jinja/Alpine:** the equivalent is DaisyUI/Tailwind UI patterns + the engine's own
  component macros (already the plan) — accept that shadcn isn't your stack, borrow its *structure*.

### Inspiration / reference sourcing (feeds the curated reference library, §5 D5)
- **Awwwards, Godly, Land-book, Refero, httpster** — award/curated site galleries; source the
  aspirational references per surface type.
- **Mobbin, UI Sources** — real-product UI/flow references (better for the *app* surfaces than the
  flashy site galleries).
- These are how you build the "locked award-grade reference" the critic scores against — the
  operator (or a vision model) curates 1 reference per surface archetype.

### Design-to-code (if a design tool enters the loop)
- **Figma MCP** (present in this environment) — pull design context/variables/screenshots into code;
  Code Connect maps components. *Adopt only if the operator designs in Figma;* otherwise the
  reference-screenshot + vision-model path (below) is lighter.

### The taste layer (the un-automatable 20%, made cheap)
- **The design-critic agent is vision-capable (Sonnet).** Its rubric today counts *tells* (floor).
  **Upgrade it (D5) to also SCORE against the Awwwards dimensions and an aspirational reference** —
  turning it from "is this not-bad?" into "how far from award-grade, and specifically why?".
- **Know when to buy a human.** The signature moments (logo/wordmark, the one hero interaction, the
  brand illustration style) are worth €500–2k of real designer time — the plan already flags this
  as the single buy-don't-build item. The engine's job is to make *everything around* the signature
  flawless so the human spend concentrates on the 20% that matters.

---

## 5. How to bake the ceiling into the engine (the D5–D8 items)

Each becomes an implementable item in `ENHANCEMENT_PLAN_V2.md`:

- **D5 — Upgrade design-critic from floor to ceiling.** Extend `agents/design-critic.md`: keep the
  9-tell floor, ADD (a) Awwwards-style scoring (Design/Usability/Creativity/Content, target ≥8.0 on
  *client-facing* surfaces, ≥7.0 "quiet excellence" on *internal* surfaces — surface-differentiated),
  (b) scoring against an *aspirational* reference (not just the locked drift reference), (c) a
  concrete "top-3 changes to reach the next point" output. Vision-model reads screenshots. FAIL
  client surfaces below their bar. **This is the highest-leverage item — it makes the critic pull up,
  not just hold the line.**
- **D6 — Motion-craft + CWV-under-motion gate.** When a diff adds animation (GSAP/Motion/CSS
  transitions), require: `prefers-reduced-motion` honored, no Core-Web-Vitals regression (Lighthouse
  budget holds *with* motion), and motion-has-purpose (critic judgment). Ships as a design-critic
  rubric dimension + a Lighthouse-with-motion check. Prevents effect-stacking (the #1 amateur tell).
- **D7 — Curated aspirational reference library + the token pipeline.** A `docs/design/aspirational/`
  set (1 award-grade reference per surface archetype: marketing site, client gallery, dashboard,
  form/flow) sourced from §4 galleries + operator taste; plus adopt **Style Dictionary** so tokens
  v2 become a real single-source pipeline. This is what D5 scores against.
- **D8 — Signature-system spec.** Codify the requirement that every product has ≥1 signature element
  (the film-slate/timecode/slugline motifs for 8CStudio) and the distinctive type system; the critic
  FAILs a "no signature" tell on flagship screens. Turns "no signature" from a soft tell into a
  product requirement.

Plus a **future-proofing ritual** (mirrors L0): a **quarterly design-scan** — the CEO/retro agent
reviews recent Awwwards/CSSDA winners + new motion/perf/token tools, refreshes the aspirational
reference library, and files any new capability as a D-item. **This is the "always best in market"
mechanism** — design trends churn; the ritual keeps the ceiling current without a rebuild.

---

## 6. How to actually get there (sequencing, honest)

1. **Floor first (in flight):** tokens v2 + design-lint + design-critic tells + axe/Lighthouse.
   Non-negotiable prerequisite — you cannot reach for a ceiling on an inconsistent base.
2. **Own the 70% deterministically:** usability (axe/nav), performance (Lighthouse/unlighthouse
   budgets), consistency (Style Dictionary tokens). This alone lifts you above most SaaS.
3. **Invest the ceiling where it pays — client-facing surfaces:** Delivery galleries + tenant sites
   get the motion craft (GSAP/Lenis), the signature system (D8), and the award-grade critic bar
   (D5). The internal app targets quiet Linear/Stripe excellence, not flash.
4. **Buy the human signature moments** (logo, hero interaction, illustration) — concentrate the
   spend on the un-automatable 20%.
5. **Run the quarterly design-scan** so the reference library and tooling never go stale.

**The realistic outcome:** the engine deterministically produces *consistently excellent, fast,
accessible, on-brand* design (top ~10% of SaaS) by default — and makes *award-grade* reachable on the
surfaces that matter by combining the upgraded critic + curated references + motion craft + targeted
human signature. That is genuinely future-proof, because the floor is enforced by code and the
ceiling is kept current by the ritual + swappable reference library — not frozen into one 2026
aesthetic.

## 7. What to skip (honest, avoids chasing hype)
- **Don't chase WebGL/3D for its own sake** — it wins only when it carries the concept; for an
  invoicing+delivery platform it's usually cost without return. Typography+motion+performance wins.
- **Don't adopt React component libraries (shadcn/Radix) for the Jinja app** — borrow their
  structure, not the dependency; wrong runtime.
- **Don't try to fully automate the 20% creativity** — score it, reference it, and buy the hero
  moments; don't pretend a gate produces originality.
- **Don't let motion regress Core Web Vitals** — a beautiful slow page loses on both the award
  rubric and the Delivery launch gate.
