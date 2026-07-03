# fail-escalate-ai-aesthetic-drift

Screen under review — `templates/dashboards/invoice_list.html` (Jinja + Tailwind):

```html
<!-- new invoice list page -->
<div class="min-h-screen bg-gradient-to-br from-purple-600 via-blue-500 to-indigo-700 p-8">
  <div class="max-w-6xl mx-auto backdrop-blur-xl bg-white/10 rounded-3xl border border-white/20 shadow-2xl p-10">
    <div class="text-center mb-8">
      <h1 class="text-5xl font-bold bg-gradient-to-r from-white to-purple-200 bg-clip-text text-transparent">
        ✨ Your Invoices ✨
      </h1>
      <p class="text-white/70 text-lg mt-2">Manage your billing with style</p>
    </div>

    <div class="flex justify-center gap-3 mb-8">
      <span class="px-4 py-2 bg-white/20 backdrop-blur rounded-full text-white text-sm">All</span>
      <span class="px-4 py-2 bg-white/20 backdrop-blur rounded-full text-white text-sm">Paid</span>
      <span class="px-4 py-2 bg-white/20 backdrop-blur rounded-full text-white text-sm">Pending</span>
      <span class="px-4 py-2 bg-white/20 backdrop-blur rounded-full text-white text-sm">Overdue</span>
    </div>

    <div class="space-y-4">
      {% for inv in invoices %}
      <div class="bg-white/20 backdrop-blur-md rounded-2xl p-6 border border-white/20 shadow-xl hover:shadow-2xl transition-all hover:scale-105">
        <div class="flex justify-between items-center">
          <div>
            <h3 class="text-2xl font-bold text-white">{{ inv.client_name }}</h3>
            <p class="text-white/60 text-sm">Invoice #{{ inv.number }}</p>
          </div>
          <div class="text-right">
            <p class="text-3xl font-bold text-white">💰 {{ inv.total | money }}</p>
            <p class="text-white/60 text-sm">Due {{ inv.due_date | short_date }}</p>
          </div>
        </div>
      </div>
      {% endfor %}
    </div>
  </div>
</div>
```

Reference lock: `docs/design/reference/invoice-list.png` — 8CStudio
neutral slate + serif + tabular-numerals aesthetic.

## Prompt

You are the design-critic gate. Review the screen against the 9
AI-aesthetic tells + density/hierarchy/tabular-numerals/empty-states
/responsive rubric. Emit a gate envelope.

## Expected behavior

Screen exhibits ≥5 AI-aesthetic tells: (1) purple→blue gradient
background, (2) glassmorphism (backdrop-blur + bg-white/10), (3)
rounded-3xl chip pills for filters, (4) hover:scale-105
"aliveness," (5) emoji decorations (✨ 💰), (6) center-justified
oversized display type, (7) no tabular-nums on amounts, (8) no
distinct hierarchy — everything is `text-white` with size
gradations only. Verdict FAIL, failure_class worker_quality
(agent CAN rebuild against the reference lock). ≥3 tells on a
NEW screen = FAIL per D1.
