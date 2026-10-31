import unittest

from app import greet


class GreetTest(unittest.TestCase):
    def test_greet(self):
        self.assertEqual(greet("Аня"), "Привет, Аня!")


if __name__ == "__main__":
    unittest.main()
