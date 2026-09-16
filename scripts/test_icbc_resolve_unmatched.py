import importlib.util
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import TestCase, main

SCRIPTS = Path(__file__).parent
sys.path.insert(0, str(SCRIPTS))
SCRIPT = SCRIPTS / "icbc_resolve_unmatched.py"
SPEC = importlib.util.spec_from_file_location("icbc_resolve_unmatched", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class IcbcResolveUnmatchedTest(TestCase):
    def setUp(self):
        self.when = datetime(
            2026, 3, 16, 9, 51, 37, tzinfo=timezone(timedelta(hours=8), "CST")
        )
        self.categories = {
            "income": "income-id",
            "subway": "subway-id",
            "expense": "expense-id",
        }

    def bank(self, amount, summary="摘要"):
        return MODULE.BankTransaction(self.when, amount, 1000, 1, 1, summary)

    def test_income_uses_other_income_and_preserves_summary(self):
        kind, tx_type, category, comment = MODULE.classify_bank_transaction(
            self.bank(181, "利息 "), self.categories
        )
        self.assertEqual((kind, tx_type, category), ("income", 2, "income-id"))
        self.assertEqual(comment, "利息")

    def test_subway_range_is_inclusive_and_keeps_summary(self):
        for amount in (-260, -268, -280):
            with self.subTest(amount=amount):
                kind, tx_type, category, comment = MODULE.classify_bank_transaction(
                    self.bank(amount, "无卡支付"), self.categories
                )
                self.assertEqual((kind, tx_type, category), ("subway", 3, "subway-id"))
                self.assertEqual(comment, "地铁；无卡支付")

    def test_amount_outside_subway_range_is_other_expense(self):
        for amount in (-259, -281, -330):
            with self.subTest(amount=amount):
                kind, tx_type, category, comment = MODULE.classify_bank_transaction(
                    self.bank(amount, "转账"), self.categories
                )
                self.assertEqual(
                    (kind, tx_type, category), ("expense", 3, "expense-id")
                )
                self.assertEqual(comment, "转账")


if __name__ == "__main__":
    main()
