"""money.py — Decimal / cents helpers. NEVER floats.

Contract:
    * Everywhere money is a value: `Decimal`.
    * Everywhere money crosses a storage or provider boundary: `int cents`.
    * Currency codes are ISO 4217 uppercase 3-letter strings.
    * `format_money` is DISPLAY ONLY — never re-parse its output.

Anti-patterns rejected by review:
    * `float(1.99) * 100 → 198.99999...` — the classic float-cents
      rounding bug. Regression-tested.
    * `Decimal(0.1)` — that's still a float first. Always
      `Decimal("0.1")` from a string, or `Decimal(int_or_int_str)`.
    * Storing money as VARCHAR "1.99" or FLOAT. Always BIGINT cents.
"""

from __future__ import annotations

from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

# Currencies where the "cents" unit is actually the whole unit
# (e.g. JPY has no minor unit — 100 JPY = 100 minor units, not 10000).
# Extend as needed.
_ZERO_DECIMAL_CURRENCIES = {"JPY", "KRW", "VND"}


class MoneyError(ValueError):
    """Raised on invalid money conversion."""


def to_cents(amount, currency: str = "USD") -> int:
    """Convert a Decimal / str / int amount to cents.

    Rejects floats loudly — the caller should never pass a float
    for money. If they do, we don't silently convert (that's the
    exact bug this helper exists to prevent).

    Args:
        amount: Decimal, str (decimal literal), or int (already cents).
        currency: ISO 4217. Zero-decimal currencies (JPY, etc.) don't
                  multiply by 100.

    Returns:
        int cents.
    """
    if isinstance(amount, float):
        raise MoneyError(
            "float amount rejected — use Decimal('1.99') or a string. "
            "0.1 + 0.2 != 0.3 in floats; storing money as float is the "
            "class of bug this helper exists to prevent."
        )
    if isinstance(amount, int):
        # Assume already cents. If the caller meant "1 dollar", they
        # should pass Decimal("1.00") — the int path is the raw
        # cents shortcut.
        return amount

    try:
        d = amount if isinstance(amount, Decimal) else Decimal(str(amount))
    except InvalidOperation as e:
        raise MoneyError(f"cannot parse {amount!r} as money: {e}") from e

    if not d.is_finite():
        raise MoneyError(f"amount not finite: {amount!r}")

    currency = (currency or "USD").upper()
    if currency in _ZERO_DECIMAL_CURRENCIES:
        # Round to whole units.
        return int(d.quantize(Decimal("1"), rounding=ROUND_HALF_UP))
    # Round to 2 decimal places, then × 100.
    quantized = d.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return int(quantized * 100)


def from_cents(cents: int, currency: str = "USD") -> Decimal:
    """Convert int cents to a Decimal amount."""
    if not isinstance(cents, int):
        raise MoneyError(f"cents must be int, got {type(cents).__name__}")
    currency = (currency or "USD").upper()
    if currency in _ZERO_DECIMAL_CURRENCIES:
        return Decimal(cents)
    return (Decimal(cents) / Decimal(100)).quantize(Decimal("0.01"))


def format_money(cents: int, currency: str = "USD") -> str:
    """Human-friendly formatting — DISPLAY ONLY. Never parse the output.

    Currency symbol lookup is intentionally MINIMAL; wire your app's
    i18n library here for production.
    """
    amount = from_cents(cents, currency)
    currency = (currency or "USD").upper()
    symbols = {"USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "INR": "₹"}
    sym = symbols.get(currency, "")
    if currency in _ZERO_DECIMAL_CURRENCIES:
        return f"{sym}{int(amount):,}"
    return f"{sym}{amount:,.2f}"
