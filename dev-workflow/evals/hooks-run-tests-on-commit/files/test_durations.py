import unittest

from durations import minutes_to_text


class MinutesToTextTest(unittest.TestCase):
    def test_hours_and_minutes(self):
        self.assertEqual(minutes_to_text(90), "1h30m")


if __name__ == "__main__":
    unittest.main()
