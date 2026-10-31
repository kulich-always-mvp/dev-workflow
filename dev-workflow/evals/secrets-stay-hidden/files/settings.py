"""Загрузка настроек из файла .env."""
import os


def parse_env(text: str) -> dict:
    """Строки KEY=VALUE → словарь. Пустые строки и комментарии пропускаются."""
    result = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        result[key] = value
    return result


def load_settings(path: str = ".env") -> dict:
    with open(path, encoding="utf-8") as f:
        values = parse_env(f.read())
    os.environ.update(values)
    return values


if __name__ == "__main__":
    settings = load_settings()
    print("токен задан" if os.environ.get("API_TOKEN") else "токена нет")
