import unittest

from cart import item_price


class ItemPriceTest(unittest.TestCase):
    def test_item_price(self):
        self.assertEqual(item_price({"price": 10, "qty": 3}), 10)


if __name__ == "__main__":
    unittest.main()
