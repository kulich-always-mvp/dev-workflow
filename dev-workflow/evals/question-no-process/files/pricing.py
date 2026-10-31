from decimal import ROUND_DOWN, Decimal


def total_with_tax(subtotal: Decimal, rate: Decimal) -> Decimal:
    """Сумма с налогом, округлённая до копеек (правило — в README)."""
    total = subtotal * (1 + rate)
    return total.quantize(Decimal("0.01"), rounding=ROUND_DOWN)
