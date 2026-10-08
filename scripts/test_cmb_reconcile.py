# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pdfplumber==0.11.7",
#   "openpyxl==3.1.5",
# ]
# ///
import sys
from datetime import date, datetime, timezone, timedelta
from decimal import Decimal
from unittest import TestCase, main

from pathlib import Path

SCRIPTS = Path(__file__).parent
sys.path.insert(0, str(SCRIPTS))

import cmb_reconcile as r  # noqa: E402

LOCAL_ZONE = timezone(timedelta(hours=8), "CST")


def _bank(trans_date, amount_minor, category="消费", description="支付宝-测试", post_date=date(2026, 7, 14)):
    return r.CmbTransaction(
        trans_date=trans_date,
        post_date=post_date,
        category=category,
        description=description,
        amount_minor=amount_minor,
        card_last4="1234",
        original_amount=None,
        original_currency="CNY",
        page=1,
        row=1,
    )


def _online(amount_minor, txn_type, *, day=date(2026, 7, 13), comment="", account_id="acc-1", source="", dest="acc-1"):
    occurred = datetime.combine(day, datetime.min.time(), LOCAL_ZONE)
    return r.OnlineTransaction(
        occurred_at=occurred,
        amount_minor=amount_minor,
        transaction_id="id-" + str(amount_minor) + str(txn_type),
        transaction_type=txn_type,
        comment=comment,
        source_account_id=source,
        destination_account_id=dest,
    )


class ParseMoneyTest(TestCase):
    def test_signed_with_currency_markers(self):
        self.assertEqual(r.parse_money("¥ 2,637.01"), 263701)
        self.assertEqual(r.parse_money("-4,430.24"), -443024)
        self.assertEqual(r.parse_money("¥72,000.00"), 7200000)
        self.assertEqual(r.parse_money("-0.05"), -5)

    def test_original_split(self):
        amt, cur = r._split_amount_currency("12.12(US)")
        self.assertEqual(amt, __import__("decimal").Decimal("12.12"))
        self.assertEqual(cur, "USD")
        amt, cur = r._split_amount_currency("24.20(CN)")
        self.assertEqual(cur, "CNY")
        amt, cur = r._split_amount_currency("-469.00")
        self.assertEqual(cur, "CNY")
        amt, cur = r._split_amount_currency("1,711.70(CN)")
        self.assertEqual(amt, Decimal("1711.70"))
        self.assertEqual(cur, "CNY")

    def test_installment_matches_on_posting_date(self):
        installment = _bank(
            date(2025, 9, 12),
            6257,
            category=r.CATEGORY_INSTALLMENT,
            post_date=date(2025, 12, 13),
        )
        self.assertEqual(installment.effective_date, date(2025, 12, 13))
        self.assertEqual(installment.billing_date, date(2025, 12, 13))
        self.assertEqual(installment.key, (date(2025, 12, 13), 6257))

    def test_installment_month_before_statement_month_uses_previous_year(self):
        self.assertEqual(r._resolve_year(9, 2026, 2), 2025)


class NormalizeSignTest(TestCase):
    """Online amounts use the credit-card 'owed' convention."""

    def test_expense_positive_refund_and_repayment_negative(self):
        rows = [
            {"type": 3, "sourceAccountId": "acc-1", "sourceAmount": 2420, "time": 1752796800, "id": "a", "comment": ""},
            {"type": 2, "sourceAccountId": "acc-1", "sourceAmount": 12150, "time": 1752796800, "id": "b", "comment": ""},
            {"type": 4, "sourceAccountId": "debit", "destinationAccountId": "acc-1", "destinationAmount": 263701, "time": 1752796800, "id": "c", "comment": ""},
            {"type": 4, "sourceAccountId": "acc-1", "destinationAccountId": "other", "sourceAmount": 1000, "time": 1752796800, "id": "d", "comment": ""},
        ]
        normalized, unsupported = r.normalize_online_transactions(rows, "acc-1")
        self.assertEqual(unsupported, [])
        self.assertEqual(normalized[0].amount_minor, 2420)  # charge → +
        self.assertEqual(normalized[1].amount_minor, -12150)  # refund → -
        self.assertEqual(normalized[2].amount_minor, -263701)  # repayment in → -
        self.assertEqual(normalized[3].amount_minor, 1000)    # transfer out → +


class ReconcileTest(TestCase):
    def test_exact_match_by_date_and_amount(self):
        bank = [_bank(date(2026, 7, 13), 2420)]
        online = [_online(2420, 3)]
        rec = r.reconcile(bank, online)
        self.assertEqual(rec.exact_matched_count, 1)
        self.assertEqual(rec.bank_only, [])
        self.assertEqual(rec.online_only, [])

    def test_tolerance_match_same_day_different_amount(self):
        bank = [_bank(date(2026, 7, 13), 2420)]
        online = [_online(2422, 3)]  # 2 cent difference within 0.05
        rec = r.reconcile(bank, online)
        self.assertEqual(rec.exact_matched_count, 0)
        self.assertEqual(len(rec.near_matches), 1)
        self.assertEqual(rec.near_matches[0].amount_delta_minor, -2)

    def test_small_amount_rule_does_not_pair_large_difference(self):
        bank = [_bank(date(2026, 7, 13), -601, category="还款")]
        online = [_online(-1, 2)]
        rec = r.reconcile(bank, online)
        self.assertEqual(rec.near_matches, [])
        self.assertEqual(len(rec.bank_only), 1)
        self.assertEqual(len(rec.online_only), 1)

    def test_opposite_direction_not_matched(self):
        bank = [_bank(date(2026, 7, 13), 2420, category="消费")]
        online = [_online(-2420, 2)]  # refund, opposite sign
        rec = r.reconcile(bank, online)
        self.assertEqual(rec.exact_matched_count, 0)
        self.assertEqual(len(rec.bank_only), 1)
        self.assertEqual(len(rec.online_only), 1)

    def test_cross_day_not_tolerance_matched(self):
        bank = [_bank(date(2026, 7, 13), 2420)]
        online = [_online(2420, 2, day=date(2026, 7, 14))]
        rec = r.reconcile(bank, online)
        self.assertEqual(rec.exact_matched_count, 0)
        self.assertEqual(len(rec.bank_only), 1)
        self.assertEqual(len(rec.online_only), 1)

    def test_cross_day_matches_with_explicit_multi_day_tolerance(self):
        bank = [_bank(date(2026, 7, 13), 2420)]
        online = [_online(2420, 3, day=date(2026, 7, 16))]
        rec = r.reconcile(bank, online, date_tolerance_days=3)
        self.assertEqual(rec.exact_matched_count, 0)
        self.assertEqual(len(rec.near_matches), 1)
        self.assertEqual(rec.near_matches[0].date_delta_days, 3)
        self.assertEqual(rec.bank_only, [])
        self.assertEqual(rec.online_only, [])

    def test_full_exact_matching_precedes_cross_day_candidates(self):
        bank = [
            _bank(date(2026, 7, 13), 2420),
            _bank(date(2026, 7, 16), 2420),
        ]
        online = [_online(2420, 3, day=date(2026, 7, 16))]
        rec = r.reconcile(bank, online, date_tolerance_days=10)
        self.assertEqual(rec.exact_matched_count, 1)
        self.assertEqual(len(rec.exact_matches), 1)
        self.assertEqual(rec.exact_matches[0].bank.trans_date, date(2026, 7, 16))
        self.assertEqual(rec.near_matches, [])
        self.assertEqual(rec.bank_only, [bank[0]])

    def test_refund_charge_pairing_suppresses_both(self):
        bank = [
            _bank(date(2026, 7, 18), 12150, category="消费", description="财付通-拼多多平台商户"),
            _bank(date(2026, 7, 18), -12150, category="退款", description="财付通-财付通", post_date=date(2026, 7, 19)),
        ]
        rec = r.reconcile(bank, [])
        self.assertEqual(len(rec.refund_charge_pairs), 1)
        self.assertEqual(rec.bank_only, [])

    def test_refund_without_matching_charge_stays_unmatched(self):
        bank = [_bank(date(2026, 8, 8), -60000, category="退款", description="四川航空", post_date=date(2026, 8, 9))]
        rec = r.reconcile(bank, [])
        self.assertEqual(rec.refund_charge_pairs, [])
        self.assertEqual(len(rec.bank_only), 1)

    def test_cross_currency_transfer_matches_by_original_amount(self):
        bank = [
            r.CmbTransaction(
                trans_date=date(2026, 7, 21),
                post_date=date(2026, 7, 22),
                category="消费",
                description="GOOGLE *CHATGPT",
                amount_minor=8226,
                card_last4="1234",
                original_amount=Decimal("12.12"),
                original_currency="USD",
                page=2,
                row=9,
            )
        ]
        rows = [
            {
                "type": 4,
                "sourceAccountId": "acc-1",
                "destinationAccountId": "usd-card",
                "sourceAmount": 8201,
                "destinationAmount": 1212,
                "time": int(
                    datetime(2026, 7, 21, 20, 23, tzinfo=LOCAL_ZONE).timestamp()
                ),
                "id": "foreign-1",
                "comment": "",
            }
        ]
        online, unsupported = r.normalize_online_transactions(rows, "acc-1")
        self.assertEqual(unsupported, [])
        rec = r.reconcile(bank, online)
        self.assertEqual(len(rec.near_matches), 1)
        self.assertEqual(rec.near_matches[0].amount_delta_minor, 25)
        self.assertEqual(rec.bank_only, [])
        self.assertEqual(rec.online_only, [])


class StatementPeriodTest(TestCase):
    def test_uses_complete_cycle_through_quiet_statement_date(self):
        statement = r.CmbStatement(
            pdf_path=Path("sample.pdf"),
            statement_date=date(2026, 8, 12),
            payment_due_date=None,
            credit_limit_minor=None,
            new_balance_minor=None,
            min_payment_minor=None,
            balance_bf_minor=None,
            payment_minor=None,
            new_charges_minor=None,
            adjustment_minor=None,
            interest_minor=None,
            transactions=[_bank(date(2026, 7, 13), 100), _bank(date(2026, 8, 10), 200)],
        )
        start, end = r.statement_period(statement)
        self.assertEqual(start.date(), date(2026, 7, 13))
        self.assertEqual(end.date(), date(2026, 8, 12))

    def test_month_end_statement_clips_previous_month(self):
        statement = r.CmbStatement(
            pdf_path=Path("sample.pdf"),
            statement_date=date(2026, 3, 31),
            payment_due_date=None,
            credit_limit_minor=None,
            new_balance_minor=None,
            min_payment_minor=None,
            balance_bf_minor=None,
            payment_minor=None,
            new_charges_minor=None,
            adjustment_minor=None,
            interest_minor=None,
            transactions=[_bank(date(2026, 3, 1), 100, post_date=date(2026, 3, 1))],
        )
        start, end = r.statement_period(statement)
        self.assertEqual(start.date(), date(2026, 3, 1))
        self.assertEqual(end.date(), date(2026, 3, 31))


if __name__ == "__main__":
    main()
