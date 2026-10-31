import unittest
from decimal import Decimal

from pricing import total_with_tax


class TotalWithTaxTest(unittest.TestCase):
    def test_rounds_to_nearest_cent(self):
        self.assertEqual(total_with_tax(Decimal("9.99"), Decimal("0.075")), Decimal("10.74"))

    def test_exact_amount(self):
        self.assertEqual(total_with_tax(Decimal("100.00"), Decimal("0.20")), Decimal("120.00"))


if __name__ == "__main__":
    unittest.main()
