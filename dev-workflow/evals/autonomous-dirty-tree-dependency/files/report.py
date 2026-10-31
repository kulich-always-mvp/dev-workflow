def build_report(rows):
    """Строки отчёта [(название, сумма), ...] → список словарей."""
    return [{"name": name, "amount": amount} for name, amount in rows]
