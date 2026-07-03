# pass-token-conformant

Screen under review — `templates/dashboards/invoice_list.html` (Jinja + Tailwind):

```html
<!-- new invoice list page -->
<div class="max-w-6xl mx-auto py-8">
  <header class="flex items-baseline justify-between mb-6">
    <h1 class="text-2xl font-serif text-slate-900">Invoices</h1>
    <a href="{{ url_for('invoices.new') }}"
       class="text-sm font-medium text-slate-700 border-b border-slate-400 hover:border-slate-900">
      New invoice
    </a>
  </header>

  <table class="w-full text-sm">
    <thead class="border-b border-slate-200 text-slate-500 uppercase tracking-wide text-xs">
      <tr>
        <th class="text-left py-2 font-normal">Number</th>
        <th class="text-left py-2 font-normal">Client</th>
        <th class="text-right py-2 font-normal tabular-nums">Amount</th>
        <th class="text-right py-2 font-normal">Due</th>
        <th class="text-right py-2 font-normal">Status</th>
      </tr>
    </thead>
    <tbody>
      {% for inv in invoices %}
      <tr class="border-b border-slate-100 hover:bg-slate-50">
        <td class="py-3 text-slate-900">{{ inv.number }}</td>
        <td class="py-3 text-slate-700">{{ inv.client_name }}</td>
        <td class="py-3 text-right tabular-nums text-slate-900">{{ inv.total | money }}</td>
        <td class="py-3 text-right text-slate-500">{{ inv.due_date | short_date }}</td>
        <td class="py-3 text-right">
          {% if inv.status == 'overdue' %}
            <span class="text-rose-700">Overdue</span>
          {% elif inv.status == 'pending' %}
            <span class="text-slate-500">Pending</span>
          {% else %}
            <span class="text-slate-400">Paid</span>
          {% endif %}
        </td>
      </tr>
      {% endfor %}
    </tbody>
  </table>

  {% if not invoices %}
  <p class="py-16 text-center text-slate-500 text-sm">No invoices yet. Create your first one.</p>
  {% endif %}
</div>
```

Reference lock: `docs/design/reference/invoice-list.png` (existing —
8CStudio-style: slate grays, serif headings, tabular numerals,
minimal color).

## Prompt

You are the design-critic gate. Review the screen against the 9
AI-aesthetic tells + density/hierarchy/tabular-numerals/empty-states
/responsive rubric. Emit a gate envelope.

## Expected behavior

Conforms to design system: slate palette (no purple/blue gradient),
serif for display type + sans for data, tabular-nums on Amount
column, single accent color for Overdue (rose-700), quiet empty
state, no glassmorphism, no over-padding. Verdict PASS.
