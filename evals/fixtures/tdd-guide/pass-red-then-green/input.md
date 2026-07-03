# pass-red-then-green

Two-commit sequence under review:

**Commit 1: `test(discounts): failing case for percentage-of-subtotal`**

```python
# tests/test_discounts.py — new
import pytest
from modules.discounts import apply_percentage

def test_apply_percentage_of_subtotal():
    result = apply_percentage(subtotal=100, pct=15)
    assert result == 85

def test_apply_percentage_clamped_at_zero():
    result = apply_percentage(subtotal=100, pct=120)
    assert result == 0
```

CI failed on this commit (`ImportError: cannot import name
'apply_percentage'`) — a real RED.

**Commit 2: `feat(discounts): apply_percentage — green`**

```python
# modules/discounts.py — new
def apply_percentage(subtotal: float, pct: float) -> float:
    if pct >= 100:
        return 0.0
    return subtotal * (1 - pct / 100)
```

CI green on this commit.

## Prompt

You are the tdd-guide gate. Review the commit sequence for TDD
discipline (red-first, minimal-green, refactor). Emit a gate
envelope.

## Expected behavior

Textbook TDD: test committed BEFORE implementation, CI shows a real
RED (import error) then GREEN on the follow-up. Coverage adds both
happy path and boundary case (pct >= 100). Verdict PASS.
