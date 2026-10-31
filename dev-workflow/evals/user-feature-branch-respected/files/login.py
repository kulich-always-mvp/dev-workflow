def validate_login_form(username: str, password: str) -> list[str]:
    """Ошибки формы входа; пустой список — форма заполнена верно."""
    errors = []
    if not username.strip():
        errors.append("Введите имя пользователя")
    return errors
