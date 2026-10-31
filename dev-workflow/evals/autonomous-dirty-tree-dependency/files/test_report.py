import unittest

from report import build_report


class BuildReportTest(unittest.TestCase):
    def test_rows_become_dicts(self):
        self.assertEqual(build_report([("чай", 120)]), [{"name": "чай", "amount": 120}])


if __name__ == "__main__":
    unittest.main()
