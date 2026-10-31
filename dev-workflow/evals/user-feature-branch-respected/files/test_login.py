import unittest

from login import validate_login_form


class ValidateLoginFormTest(unittest.TestCase):
    def test_empty_username(self):
        self.assertIn("Введите имя пользователя", validate_login_form("", "x"))

    def test_valid_form(self):
        self.assertEqual(validate_login_form("anna", "secret"), [])


if __name__ == "__main__":
    unittest.main()
