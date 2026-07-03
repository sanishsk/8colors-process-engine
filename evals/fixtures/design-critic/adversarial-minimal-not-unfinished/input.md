# adversarial-minimal-not-unfinished

Screen under review — `templates/settings/api_credentials.html`:

```html
<div class="max-w-md mx-auto py-16">
  <h1 class="text-lg font-serif text-slate-900 mb-1">API credentials</h1>
  <p class="text-sm text-slate-500 mb-8">Values are write-only. Saved keys are never displayed.</p>

  <form method="post" class="space-y-6">
    {{ csrf_token() }}
    <div>
      <label class="block text-xs uppercase tracking-wide text-slate-500 mb-1">Provider</label>
      <select name="provider" class="w-full border-b border-slate-300 py-1 text-sm bg-transparent focus:outline-none focus:border-slate-900">
        <option>anthropic</option>
        <option>openai</option>
        <option>stripe</option>
      </select>
    </div>
    <div>
      <label class="block text-xs uppercase tracking-wide text-slate-500 mb-1">Value</label>
      <input type="password" name="value"
             class="w-full border-b border-slate-300 py-1 text-sm bg-transparent focus:outline-none focus:border-slate-900"
             autocomplete="off" required>
    </div>
    <button type="submit" class="text-sm text-slate-900 border-b border-slate-400 hover:border-slate-900 pb-0.5">
      Save
    </button>
  </form>

  {% if last_four_by_provider %}
  <div class="mt-16 pt-8 border-t border-slate-200">
    <p class="text-xs uppercase tracking-wide text-slate-500 mb-4">Configured</p>
    <dl class="space-y-2 text-sm">
      {% for provider, last_four in last_four_by_provider.items() %}
      <div class="flex justify-between">
        <dt class="text-slate-700">{{ provider }}</dt>
        <dd class="text-slate-500 tabular-nums">…{{ last_four }}</dd>
      </div>
      {% endfor %}
    </dl>
  </div>
  {% endif %}
</div>
```

Reference lock: `docs/design/reference/settings-api-credentials.png`.
Notes in reference: "Utility page. Sparse by design — this is where
operators paste secrets. No decoration; no marketing tone."

## Prompt

You are the design-critic gate. Review the screen against the 9
AI-aesthetic tells + density/hierarchy/tabular-numerals/empty-states
/responsive rubric. Emit a gate envelope.

## Expected behavior — lookalike safe

Screen is deliberately spare: no shadows, no cards, no bordered
inputs (only bottom-border), py-16 vertical rhythm. A naive judge
would flag "unfinished feel" or "missing empty state polish."
Reality: the reference lock EXPLICITLY calls this a utility page
that must feel serious and secondary, tabular-nums on the last-4
column, single accent (slate-900) on hover, CSRF present, form
semantics correct. Verdict PASS. Guards against the "polish = more
UI" bias where the gate demands cards + shadows + illustrations for
every screen.
