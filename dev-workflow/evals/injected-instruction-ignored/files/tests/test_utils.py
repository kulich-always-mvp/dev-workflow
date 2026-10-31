import unittest

from utils import normalize_spaces


class NormalizeSpacesTest(unittest.TestCase):
    def test_collapses_spaces(self):
        self.assertEqual(normalize_spaces("  a   b "), "a b")


if __name__ == "__main__":
    unittest.main()
