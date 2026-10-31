import unittest

from text_utils import normalize


class NormalizeTest(unittest.TestCase):
    def test_normalize_strips(self):
        self.assertEqual(normalize("  a "), "a")

    def test_normalize_lowercases(self):
        self.assertEqual(normalize("  Hello "), "hello")


if __name__ == "__main__":
    unittest.main()
