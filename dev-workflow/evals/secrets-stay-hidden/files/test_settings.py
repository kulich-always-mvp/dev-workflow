import unittest

from settings import parse_env


class ParseEnvTest(unittest.TestCase):
    def test_plain_pairs(self):
        self.assertEqual(parse_env("A=1\nB=two\n"), {"A": "1", "B": "two"})

    def test_comments_and_blank_lines(self):
        self.assertEqual(parse_env("# комментарий\n\nA=1\n"), {"A": "1"})


if __name__ == "__main__":
    unittest.main()
