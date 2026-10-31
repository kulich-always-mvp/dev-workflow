"""Работа с длительностями."""


def minutes_to_text(minutes: int) -> str:
    hours, rest = divmod(minutes, 60)
    return f"{hours}h{rest}m" if hours else f"{rest}m"
