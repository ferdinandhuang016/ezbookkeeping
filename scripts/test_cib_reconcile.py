"""Business checks for CIB statement conversion and one-to-one matching."""

import tempfile
import unittest
from dataclasses import replace
from datetime import datetime, timedelta
from pathlib import Path

from cib_reconcile import (
    ZONE, BankRow, LedgerRow, ReconcileError, cents, read_excel,
    reconcile, report, validate, write_excel,
)


class CibReconcileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.time = datetime(2026, 6, 1, 12, 0, tzinfo=ZONE)
        self.first = BankRow(self.time, "20260601", "快捷支付", "支", -190, 810,
                             "兴业银行", 1, 1)

    def test_invalid_money_is_rejected(self) -> None:
        with self.assertRaises(ReconcileError):
            cents("1.234", "amount")

    def test_balance_gap_is_rejected(self) -> None:
        second = replace(self.first, amount=-100, balance=711, row=2)
        with self.assertRaisesRegex(ReconcileError, "balance should be"):
            validate([self.first, second])

    def test_excel_round_trip_preserves_cents_and_location(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.pdf"
            output = Path(directory) / "statement.xlsx"
            source.write_bytes(b"source marker")
            write_excel([self.first], source, output)
            self.assertEqual(read_excel(output), [self.first])

    def test_duplicate_amount_consumes_one_online_row(self) -> None:
        second = replace(self.first, balance=620, row=2)
        online = LedgerRow(self.time, -190, 3, "", "one")
        pairs, bank_only, online_only = reconcile([self.first, second], [online])
        self.assertEqual(len(pairs), 1)
        self.assertEqual(len(bank_only), 1)
        self.assertEqual(online_only, [])

    def test_internal_transaction_stays_in_balance_but_not_matching(self) -> None:
        internal = replace(self.first, time=self.time + timedelta(minutes=1),
                           summary="购汇", amount=-1000, balance=-190, row=2)
        online = LedgerRow(self.time, -190, 3, "", "one")
        text = report([self.first, internal], [online], "兴业银行储蓄卡", Path("snapshot.json"))
        self.assertIn("卡内理财排除：1 笔", text)
        self.assertIn("仅银行 0、仅线上 0", text)
        self.assertIn("| p1/r2 | 2026-06-01 12:01:00 | -10.00 | 购汇 |", text)


if __name__ == "__main__":
    unittest.main()
