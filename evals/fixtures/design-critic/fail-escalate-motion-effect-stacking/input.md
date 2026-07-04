# fail-escalate-motion-effect-stacking

Hero section for a client-facing marketing page. New file added:

```html
<!-- templates/marketing/hero_with_motion.html -->
{% extends "base.html" %}
{% block content %}
<section class="hero relative min-h-screen">
  <!-- Full-viewport background scroll parallax -->
  <div
    class="absolute inset-0 bg-slate-900 animate-pulse"
    x-data
    x-init="gsap.to($el, { backgroundPositionY: '50%', ease: 'none', scrollTrigger: { trigger: $el, scrub: true } })"
  ></div>

  <!-- Fade + slide in on load -->
  <div
    class="relative z-10 flex flex-col items-center pt-32 opacity-0 translate-y-8 transition-all duration-1000 ease-out animate-fade-in"
    x-init="gsap.timeline().from($el, { opacity: 0, y: 40, duration: 1.2 }).from('.hero-h1', { scale: 0.9, duration: 0.8 }, '-=0.4')"
  >
    <h1 class="hero-h1 text-7xl font-bold text-white transition-transform hover:scale-105 animate-pulse">
      Imagine your studio.
    </h1>
    <p class="mt-6 text-lg text-slate-300 animate-fade-in-up transition-opacity duration-700">
      Unleash boundless creativity.
    </p>
    <button
      class="mt-10 bg-cyan-500 text-white px-8 py-4 rounded-full shadow-lg shadow-cyan-500/50 animate-bounce transition-all duration-300 hover:scale-110 hover:shadow-2xl motion-blur-md"
      x-init="motion(this).transform({ y: [0, -10, 0] }, { duration: 2, repeat: Infinity })"
    >
      Get Started
    </button>

    <!-- Decorative floating orbs -->
    <div class="absolute top-20 left-1/4 w-32 h-32 rounded-full bg-cyan-500/20 blur-3xl animate-ping"></div>
    <div class="absolute bottom-40 right-1/4 w-40 h-40 rounded-full bg-purple-500/20 blur-3xl animate-pulse"></div>
    <div class="absolute top-1/2 right-1/3 w-24 h-24 rounded-full bg-pink-500/20 blur-2xl animate-bounce"></div>
  </div>
</section>

<script src="https://cdn.jsdelivr.net/npm/gsap@3.12.0/dist/gsap.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/gsap@3.12.0/dist/ScrollTrigger.min.js"></script>
{% endblock %}
```

Context: marketing landing hero. No `prefers-reduced-motion` guard
anywhere in the file. The previous Lighthouse CI run against this
route showed LCP 1.4s; the change is expected to regress to ≥ 2.5s
(operator's expectation, verified by lighthouse-ci artifact attached
inline: LCP 2.61s, CLS 0.14, TBT 340ms).

## Prompt

You are the design-critic gate. Review this hero in D5 ceiling mode
(surface is client-facing marketing) with the D6 motion-craft rubric.
Score against `docs/design/aspirational/marketing-site.md`. Emit a
gate envelope with an `awwwards_score` block.

## Expected behavior

`motion-lint.sh` would BLOCK this commit upstream: 10+ motion signals
(animate-pulse ×3, animate-bounce ×2, animate-ping, animate-fade-in,
transition-* × 6, gsap.to, gsap.timeline, motion component, motion-blur)
+ ZERO `prefers-reduced-motion` guards + no `motion_gate.global_guard_file`.

The design-critic judgment layer on TOP of that:

- Effect stacking on the hero — parallax + fade + slide + hover
  scale + orb pulses + orb ping + orb bounce + motion-blur + gsap
  timeline + framer-motion component. 10+ effects to make ONE hero
  feel "premium" — the #1 amateur tell.
- Motion communicates NOTHING — parallax has no informational
  purpose here, the pulsing text is decorative, the floating orbs
  are pure garnish, the bounce button is confused with "call to
  action" affordance.
- CWV regression: LCP 1.4s → 2.61s. Under marketing-site archetype
  "What earns 9.0" requires perceived-instant loading; over 2s LCP
  caps Design at 7.0 AND caps Creativity at 5.0 (motion isn't
  earning its cost).
- Palette + copy also stock (dark-slate + cyan gradient + "Imagine.
  Unleash. Boundless.") — Content dimension already low.

Score (marketing-site archetype, client_facing bar 8.0):
- Design 6.0 — palette stock, type default, CWV regression caps
  ceiling.
- Usability 6.0 — reduced-motion path is missing entirely; user
  with vestibular sensitivity gets a nauseating hero.
- Creativity 4.0 — effect stacking + motion-decoration-not-
  communication + CWV regression triple-cap.
- Content 4.0 — manifesto verbs ("Imagine.", "Unleash",
  "boundless").

Total = 6.0*0.4 + 6.0*0.3 + 4.0*0.2 + 4.0*0.1 = 2.4 + 1.8 + 0.8 +
0.4 = **5.4**. Below the 8.0 client bar → FAIL,
failure_class worker_quality. Top-3 changes should target the
biggest lifts (motion-lint fix, kill effect stack, address CWV +
palette).
