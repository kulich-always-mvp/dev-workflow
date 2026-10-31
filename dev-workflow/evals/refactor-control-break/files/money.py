def format_rub(amount):
    """Сумма в рублях: 1234.5 → '1 234,50 ₽'."""
    whole = int(abs(amount))
    frac = round((abs(amount) - whole) * 100)
    groups = []
    s = str(whole)
    while s:
        groups.insert(0, s[-3:])
        s = s[:-3]
    text = " ".join(groups) + "," + str(frac).rjust(2, "0")
    sign = "-" if amount < 0 else ""
    return sign + text + " ₽"


def format_usd(amount):
    """Сумма в долларах: 1234.5 → '$1,234.50'."""
    whole = int(abs(amount))
    frac = round((abs(amount) - whole) * 100)
    groups = []
    s = str(whole)
    while s:
        groups.insert(0, s[-3:])
        s = s[:-3]
    text = ",".join(groups) + "." + str(frac).rjust(2, "0")
    sign = "-" if amount < 0 else ""
    return "$" + sign + text
