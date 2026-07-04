# fail-escalate-client-below-bar

Landing page for an 8CStudio marketing site. New file added:

```html
<!-- templates/marketing/landing.html -->
{% extends "base.html" %}
{% block content %}
<section class="hero bg-gradient-to-br from-slate-900 via-cyan-900 to-slate-900 py-32">
  <div class="max-w-6xl mx-auto px-6 text-center">
    <h1 class="text-6xl font-bold text-white leading-tight">
      Imagine your studio.<br>Unleashed.
    </h1>
    <p class="text-lg text-slate-300 mt-6 max-w-2xl mx-auto">
      Empower your creative workflow with our all-in-one platform.
      Boundless possibilities await.
    </p>
    <button class="mt-10 bg-cyan-500 hover:bg-cyan-400 text-white px-8 py-4 rounded-full text-lg shadow-lg shadow-cyan-500/50">
      Get Started 🚀
    </button>
  </div>
</section>

<section class="features py-24 bg-slate-950">
  <div class="max-w-6xl mx-auto px-6">
    <div class="grid grid-cols-3 gap-8">
      <div class="feature-card bg-slate-900 p-8 rounded-2xl border border-cyan-500/20">
        <div class="text-4xl mb-4">✨</div>
        <h3 class="text-xl font-semibold text-white">Feature One</h3>
        <p class="text-slate-400 mt-2">Some description here.</p>
      </div>
      <div class="feature-card bg-slate-900 p-8 rounded-2xl border border-cyan-500/20">
        <div class="text-4xl mb-4">🚀</div>
        <h3 class="text-xl font-semibold text-white">Feature Two</h3>
        <p class="text-slate-400 mt-2">Some description here.</p>
      </div>
      <div class="feature-card bg-slate-900 p-8 rounded-2xl border border-cyan-500/20">
        <div class="text-4xl mb-4">💎</div>
        <h3 class="text-xl font-semibold text-white">Feature Three</h3>
        <p class="text-slate-400 mt-2">Some description here.</p>
      </div>
    </div>
  </div>
</section>
{% endblock %}
```

Context: this is the public marketing landing page. Font stack is
Tailwind default (system-ui). No custom typography defined.

## Prompt

You are the design-critic gate. Review this landing page in D5
ceiling mode (surface is client-facing marketing). Score against
`docs/design/aspirational/marketing-site.md`. Emit a gate envelope
with an `awwwards_score` block.

## Expected behavior

This is the AI-aesthetic template composition: stock
dark+cyan+gradient palette (tell #1), manifesto verbs
"Imagine./Unleash/Empower/Boundless" (tell #3, caught by copy-lint
too), emoji-in-hero and emoji-in-icons (tell #5), card-grid-as-menu
of three equal cards (tell #4), no signature interaction, default
type stack.

Under the marketing-site archetype:
- **Design 6.0** — palette is stock dark-cyan-gradient, type is
  default. Below "what earns 9.0" on both counts.
- **Usability 7.5** — nav is single CTA (OK), but no proof-of-value
  near the CTA (marketing-site rule caps Content path).
- **Creativity 5.0** — zero signature moment; card-grid + emoji
  icons is default AI SaaS.
- **Content 4.0** — manifesto verbs ("Imagine.", "Unleash",
  "Empower", "Boundless") + emoji-in-button + generic
  "Get Started" CTA.

Total = 6.0*0.4 + 7.5*0.3 + 5.0*0.2 + 4.0*0.1 = 2.4 + 2.25 + 1.0 +
0.4 = 6.05. Below the 8.0 client-facing bar → verdict FAIL,
failure_class worker_quality. Top-3 changes should be concrete:
kill the manifesto copy, adopt a signature type + palette, add one
signature hero interaction.
