# pass-internal-quiet-excellence

Internal operator dashboard table view. Refactored template staged:

```html
<!-- templates/admin/orders_table.html -->
{% extends "admin/base.html" %}
{% block content %}
<div class="max-w-none px-6 py-4">
  <header class="flex items-center justify-between mb-4">
    <div>
      <h1 class="text-xl font-semibold text-fg-primary">Orders</h1>
      <p class="text-sm text-fg-muted">{{ total_count }} total · updated {{ updated_ago }}</p>
    </div>
    <div class="flex items-center gap-2">
      <input
        type="search"
        placeholder="Filter (↑↓ nav · Enter open · ⌘K commands)"
        class="w-72 px-3 py-1.5 border border-border rounded-md bg-bg-elevated text-sm"
        x-model="q"
        @keydown.slash.prevent="$el.focus()"
      />
    </div>
  </header>

  <table class="w-full text-sm border-collapse">
    <thead>
      <tr class="text-left border-b border-border">
        <th class="py-2 px-2 font-medium text-fg-muted">Order</th>
        <th class="py-2 px-2 font-medium text-fg-muted">Customer</th>
        <th class="py-2 px-2 font-medium text-fg-muted">Placed</th>
        <th class="py-2 px-2 font-medium text-fg-muted text-right tabular-nums">Total</th>
        <th class="py-2 px-2 font-medium text-fg-muted">Status</th>
      </tr>
    </thead>
    <tbody>
      {% for o in orders %}
      <tr
        class="border-b border-border-subtle hover:bg-bg-elevated cursor-pointer"
        :class="{ 'bg-bg-selected': selected === {{ o.id }} }"
        @click="selected = {{ o.id }}"
      >
        <td class="py-1.5 px-2 font-mono text-xs">#{{ o.id }}</td>
        <td class="py-1.5 px-2">{{ o.customer_name }}</td>
        <td class="py-1.5 px-2 text-fg-muted">{{ o.placed_at | relative }}</td>
        <td class="py-1.5 px-2 text-right tabular-nums">{{ o.total_cents | money }}</td>
        <td class="py-1.5 px-2">
          <span class="text-xs px-1.5 py-0.5 rounded border border-border">{{ o.status }}</span>
        </td>
      </tr>
      {% else %}
      <tr>
        <td colspan="5" class="py-16 text-center text-fg-muted">
          No orders match this filter.
          <a href="?" class="underline">Clear filter</a> or
          <button class="underline" @click="showAdvanced = true">show advanced options</button>.
        </td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
</div>
{% endblock %}
```

Context: this is the operator's internal orders dashboard. Ops
staff spend 4+ hours a day in this view. Bulk-actions are on a
separate keyboard-driven command palette (⌘K). Alpine handles
selection state, Jinja renders 50+ rows above the fold on standard
laptop displays.

## Prompt

You are the design-critic gate. Review this dashboard in D5 ceiling
mode (surface is internal). Score against
`docs/design/aspirational/internal-dashboard.md`. Emit a gate
envelope with an `awwwards_score` block.

## Expected behavior

Internal-dashboard archetype targets 7.0 total. Signature signals
present:
- Density: 50+ rows above the fold, tight `py-1.5` row height.
- Tabular-nums on the money column.
- Keyboard-first affordances (`/` focuses filter, `⌘K` mentioned
  in placeholder for advanced ops).
- Empty state has shape (filter-clear link + advanced-options
  toggle), not a blank canvas.
- Row height respects "dense is a feature" for internal tools.
- Zero decorative motion (motion is only functional-hover; no
  page-transition flourishes).
- No emoji-in-buttons.

Score:
- Design 7.5 — dense layout, tabular-nums, considered spacing,
  border-subtle for row separation.
- Usability 9.0 — keyboard-first, empty state has shape, filter
  is discoverable via `/`, command palette linked.
- Creativity 5.5 — motion is functional (hover state, selected
  state), no decoration. Per archetype rule: "no signature
  required" for internal, so 5.5 is expected + fine.
- Content 7.5 — labels tight, empty state copy is human ("No
  orders match this filter" not "No data").

Total = 7.5*0.4 + 9.0*0.3 + 5.5*0.2 + 7.5*0.1 = 3.0 + 2.7 + 1.1 +
0.75 = 7.55. Above internal-dashboard bar (7.0) → PASS,
failure_class none. Top-3 changes still emitted (the pull-up
principle): tighter type hierarchy, keyboard shortcut hint next to
the search, and a subtle skeleton on data-refresh.
