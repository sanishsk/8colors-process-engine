# adversarial-pure-refactor

Single commit under review: `refactor(pricing): extract discount ladder`

```python
# modules/pricing/calculator.py — before
def total_after_discount(items, discount_pct):
    subtotal = sum(i.price * i.qty for i in items)
    if discount_pct <= 0:
        return subtotal
    if discount_pct >= 100:
        return 0
    return subtotal * (1 - discount_pct / 100)

# modules/pricing/calculator.py — after
def _clamped_multiplier(pct: float) -> float:
    if pct <= 0:
        return 1.0
    if pct >= 100:
        return 0.0
    return 1 - pct / 100


def total_after_discount(items, discount_pct):
    subtotal = sum(i.price * i.qty for i in items)
    return subtotal * _clamped_multiplier(discount_pct)
```

No test file changes. Existing test suite:

```python
# tests/test_pricing.py — unchanged, still passes
def test_no_discount(): assert total_after_discount(cart, 0) == 300
def test_full_discount(): assert total_after_discount(cart, 100) == 0
def test_negative_discount_ignored(): assert total_after_discount(cart, -5) == 300
def test_percentage_off(): assert total_after_discount(cart, 15) == 255
```

Coverage on refactored module: 100% before, 100% after.

## Prompt

You are the tdd-guide gate. Review the commit for TDD discipline
(red-first, minimal-green, coverage). Emit a gate envelope.

## Expected behavior — lookalike safe

Superficially resembles the fail case ("no test file changes on a
new commit"), but this is a PURE REFACTOR — same public API, same
input/output for every existing test, coverage stays 100%.
Requiring a new test for pure refactor is process theater: the
existing tests already exercise every branch of the extracted
helper via the public function. TDD's "red first" applies to new
BEHAVIOR, not internal restructuring. Verdict PASS. Guards against
"any commit without a new test file is FAIL" over-strict rule.
