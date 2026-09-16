import importlib.util
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import TestCase, main

SCRIPT = Path(__file__).with_name("icbc_reconcile.py")
SPEC = importlib.util.spec_from_file_location("icbc_reconcile", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class IcbcReconcileTest(TestCase):
    def setUp(self):
        self.when = datetime(
            2026, 3, 16, 9, 51, 37, tzinfo=timezone(timedelta(hours=8), "CST")
        )

    def test_parse_money_uses_minor_units(self):
        self.assertEqual(MODULE.parse_money("+2,000.00", location="test"), 200000)
        self.assertEqual(MODULE.parse_money("-2.40", location="test"), -240)

    def test_parse_money_rejects_watermark_noise(self):
        with self.assertRaises(MODULE.ReconcileError):
            MODULE.parse_money("D-10.00", location="test")

    def test_excel_money_rejects_fractional_cents(self):
        with self.assertRaises(MODULE.ReconcileError):
            MODULE.excel_money_to_minor(1.001, location="test")

    def test_running_balance_validation_rejects_inconsistent_row(self):
        rows = [
            MODULE.BankTransaction(self.when, -20000, 294853, 1, 1),
            MODULE.BankTransaction(
                self.when + timedelta(seconds=1), -5000, 290000, 1, 2
            ),
        ]
        with self.assertRaises(MODULE.ReconcileError):
            MODULE.validate_statement(rows)

    def test_reconcile_honors_duplicate_multiplicity(self):
        bank = [
            MODULE.BankTransaction(self.when, -240, 1000, 1, 1),
            MODULE.BankTransaction(self.when, -240, 760, 1, 2),
        ]
        online = [MODULE.OnlineTransaction(self.when, -240, "1", 3, "")]
        result = MODULE.reconcile(bank, online)
        self.assertEqual(result.matched_count, 1)
        self.assertEqual(result.exact_matched_count, 1)
        self.assertEqual(len(result.bank_only), 1)
        self.assertEqual(len(result.online_only), 0)

    def test_reconcile_reports_near_match_without_calling_it_exact(self):
        bank = [MODULE.BankTransaction(self.when, -266, 1000, 1, 1)]
        online = [
            MODULE.OnlineTransaction(
                self.when - timedelta(seconds=2), -270, "near", 3, ""
            )
        ]
        result = MODULE.reconcile(bank, online)
        self.assertEqual(result.exact_matched_count, 0)
        self.assertEqual(result.matched_count, 1)
        self.assertEqual(result.near_matches[0].amount_delta_minor, 4)
        self.assertEqual(result.near_matches[0].time_delta_seconds, 2)

    def test_reconcile_rejects_negative_tolerance(self):
        with self.assertRaises(MODULE.ReconcileError):
            MODULE.reconcile([], [], amount_tolerance_minor=-1)

    def test_small_amounts_match_on_same_day_and_keep_amount_difference(self):
        bank = [MODULE.BankTransaction(self.when, -100, 1000, 1, 1)]
        online = [
            MODULE.OnlineTransaction(
                self.when + timedelta(hours=6), -800, "small", 3, ""
            )
        ]
        result = MODULE.reconcile(bank, online)
        self.assertEqual(result.matched_count, 1)
        self.assertEqual(result.near_matches[0].amount_delta_minor, 700)

    def test_same_day_exact_amount_matches_beyond_old_time_limit(self):
        bank = [MODULE.BankTransaction(self.when, 700000, 1000, 1, 1)]
        online = [
            MODULE.OnlineTransaction(
                self.when + timedelta(seconds=18), 700000, "example", 2, ""
            )
        ]
        result = MODULE.reconcile(bank, online)
        self.assertEqual(result.matched_count, 1)
        self.assertEqual(result.near_matches[0].time_delta_seconds, 18)

    def test_same_day_matching_never_crosses_midnight(self):
        before_midnight = self.when.replace(hour=23, minute=59, second=59)
        bank = [MODULE.BankTransaction(before_midnight, -270, 1000, 1, 1)]
        online = [
            MODULE.OnlineTransaction(
                before_midnight + timedelta(seconds=2), -270, "next-day", 3, ""
            )
        ]
        result = MODULE.reconcile(bank, online)
        self.assertEqual(result.matched_count, 0)

    def test_small_same_day_matching_requires_same_direction(self):
        bank = [MODULE.BankTransaction(self.when, -268, 1000, 1, 1)]
        online = [MODULE.OnlineTransaction(self.when, 181, "income", 2, "")]
        result = MODULE.reconcile(bank, online)
        self.assertEqual(result.matched_count, 0)

    def test_same_day_matching_prefers_nearest_time_before_amount(self):
        bank = [MODULE.BankTransaction(self.when, -100, 1000, 1, 1)]
        online = [
            MODULE.OnlineTransaction(
                self.when + timedelta(seconds=1), -800, "near-time", 3, ""
            ),
            MODULE.OnlineTransaction(
                self.when + timedelta(seconds=10), -100, "same-amount", 3, ""
            ),
        ]
        result = MODULE.reconcile(bank, online)
        self.assertEqual(result.near_matches[0].online.transaction_id, "near-time")
        self.assertEqual(result.near_matches[0].amount_delta_minor, 700)

    def test_large_amounts_still_require_normal_amount_tolerance(self):
        bank = [MODULE.BankTransaction(self.when, -10000, 1000, 1, 1)]
        online = [
            MODULE.OnlineTransaction(
                self.when + timedelta(seconds=1), -10100, "large", 3, ""
            )
        ]
        result = MODULE.reconcile(bank, online)
        self.assertEqual(result.matched_count, 0)

    def test_equal_opposite_bank_only_pairs_are_suppressed_one_to_one(self):
        transactions = [
            MODULE.BankTransaction(self.when, -100000, 1000, 1, 1),
            MODULE.BankTransaction(self.when + timedelta(days=1), 100000, 2000, 1, 2),
            MODULE.BankTransaction(self.when + timedelta(days=2), 100000, 3000, 1, 3),
        ]
        remaining, pairs = MODULE.suppress_equal_opposite_bank_only(transactions)
        self.assertEqual(len(pairs), 1)
        self.assertEqual(pairs[0].outflow.amount_minor, -100000)
        self.assertEqual([item.amount_minor for item in remaining], [100000])

    def test_finance_aggregation_groups_both_statement_summaries(self):
        bank = [
            MODULE.BankTransaction(self.when, -20000, 100000, 1, 1, summary="理财"),
            MODULE.BankTransaction(
                self.when + timedelta(seconds=1),
                -5000,
                95000,
                1,
                2,
                summary="金融付款  ",
            ),
            MODULE.BankTransaction(
                self.when + timedelta(seconds=2),
                -1000,
                94000,
                1,
                3,
                summary="消费",
            ),
            MODULE.BankTransaction(
                self.when + timedelta(seconds=10),
                -10000,
                84000,
                1,
                4,
                summary="理财",
            ),
        ]
        transfer = MODULE.OnlineTransaction(
            self.when + timedelta(seconds=5),
            -25000,
            "fund",
            4,
            "基金定投",
            source_account_id="target",
            destination_account_id="fund",
        )
        result = MODULE.reconcile_finance_aggregations(
            bank, [transfer], "target", {"fund"}
        )
        self.assertEqual(len(result.aggregations), 1)
        self.assertEqual(result.aggregations[0].bank_expense_minor, 25000)
        self.assertEqual(result.aggregations[0].expense_delta_minor, 0)
        self.assertEqual(len(result.pending_bank), 1)
        self.assertEqual([item.summary for item in result.regular_bank], ["消费"])

    def test_daily_finance_and_pre_statement_residual_are_distinguished(self):
        bank = [MODULE.BankTransaction(self.when, -20000, 100000, 1, 1, summary="理财")]
        residual = MODULE.OnlineTransaction(
            self.when + timedelta(seconds=1),
            -126000,
            "residual",
            4,
            MODULE.PRE_STATEMENT_RESIDUAL_COMMENT,
            source_account_id="target",
            destination_account_id="fund",
        )
        daily = MODULE.OnlineTransaction(
            self.when + timedelta(seconds=2),
            -20000,
            "daily",
            4,
            f"{MODULE.DAILY_FINANCE_PREFIX} 2026-03-16",
            source_account_id="target",
            destination_account_id="fund",
        )
        result = MODULE.reconcile_finance_aggregations(
            bank, [residual, daily], "target", {"fund"}
        )
        self.assertEqual(len(result.aggregations), 1)
        self.assertFalse(result.aggregations[0].partial_start)
        self.assertEqual(result.aggregations[0].expense_delta_minor, 0)
        self.assertEqual(result.excluded_residual_online, [residual])
        self.assertEqual(result.regular_online, [])

    def test_online_period_filter_keeps_boundary_tolerance(self):
        transactions = [
            MODULE.OnlineTransaction(
                self.when - timedelta(seconds=11), -100, "before", 3, ""
            ),
            MODULE.OnlineTransaction(
                self.when - timedelta(seconds=10), -100, "boundary", 3, ""
            ),
            MODULE.OnlineTransaction(
                self.when + timedelta(minutes=1, seconds=11), -100, "after", 3, ""
            ),
        ]
        within, outside = MODULE.partition_online_by_period(
            transactions,
            self.when,
            self.when + timedelta(minutes=1),
            10,
        )
        self.assertEqual([item.transaction_id for item in within], ["boundary"])
        self.assertEqual([item.transaction_id for item in outside], ["before", "after"])

    def test_transfer_sign_is_from_selected_account_perspective(self):
        rows = [
            {
                "id": "out",
                "time": int(self.when.timestamp()),
                "type": 4,
                "sourceAccountId": "target",
                "destinationAccountId": "other",
                "sourceAmount": 100,
                "destinationAmount": 100,
            },
            {
                "id": "in",
                "time": int(self.when.timestamp()),
                "type": 4,
                "sourceAccountId": "other",
                "destinationAccountId": "target",
                "sourceAmount": 200,
                "destinationAmount": 200,
            },
        ]
        normalized, unsupported = MODULE.normalize_online_transactions(rows, "target")
        self.assertEqual([item.amount_minor for item in normalized], [-100, 200])
        self.assertEqual(unsupported, [])


if __name__ == "__main__":
    main()
