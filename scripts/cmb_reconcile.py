# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pdfplumber==0.11.7",
#   "openpyxl==3.1.5",
# ]
# ///

"""Reconcile a CMB (招商银行) credit-card statement against ezBookkeeping.

Mirrors the ICBC auditable pipeline but adapts for credit-card semantics:
no per-transaction running balance (statement-level balance identity instead),
date-only granularity, inverted sign convention (消费 +, 还款/退款 −), and
refund–charge pairing instead of 理财 aggregation.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from calendar import monthrange
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

import pdfplumber
from openpyxl import load_workbook

LOCAL_ZONE = timezone(timedelta(hours=8), "CST")
EXCEL_DETAIL_SHEET = "招商银行信用卡流水"
EXCEL_HEADERS = [
    "顺序号",
    "交易日",
    "记账日",
    "分类",
    "交易摘要",
    "人民币金额",
    "卡号末四位",
    "原币金额",
    "原币种",
    "PDF页码",
    "PDF行号",
]
TRANS_DATE_FORMAT = "%Y-%m-%d"

CATEGORY_REPAYMENT = "还款"
CATEGORY_REFUND = "退款"
CATEGORY_CHARGE = "消费"
CATEGORY_INSTALLMENT = "分期"
CATEGORY_FEE = "费用"
CATEGORY_MAP = {
    CATEGORY_REPAYMENT: CATEGORY_REPAYMENT,
    CATEGORY_REFUND: CATEGORY_REFUND,
    CATEGORY_CHARGE: CATEGORY_CHARGE,
    CATEGORY_INSTALLMENT: CATEGORY_INSTALLMENT,
    CATEGORY_FEE: CATEGORY_FEE,
}
CHARGE_CATEGORIES = (CATEGORY_CHARGE, CATEGORY_INSTALLMENT, CATEGORY_FEE)

_MONEY_RE = re.compile(r"-?\d{1,3}(?:,\d{3})*(?:\.\d+)?|-?\d+(?:\.\d+)?")
_DATE_RE = re.compile(r"^(\d{2})/(\d{2})$")
_ORIGINAL_RE = re.compile(r"^(.*?)\(([A-Z]{2})\)$")
_STATEMENT_DATE_RE = re.compile(r"(\d{4})年(\d{2})月(\d{2})日")
_YUAN_RE = re.compile(r"¥\s*([\d,]+\.\d{2})")


class ReconcileError(Exception):
    """Raised for unrecoverable parsing, validation, or API errors."""


def parse_money(text: str) -> int:
    """Parse a CNY money string (with ¥, commas, sign) into signed minor units."""
    cleaned = text.replace("¥", "").replace(",", "").strip()
    try:
        value = Decimal(cleaned)
    except (InvalidOperation, ValueError) as exc:
        raise ReconcileError(f"invalid money value: {text!r}") from exc
    return int((value * 100).quantize(Decimal("1")))


def _split_amount_currency(original: str) -> tuple[Decimal | None, str]:
    """Split '12.12(US)' into (Decimal('12.12'), 'USD'); bare value → (value, 'CNY')."""
    original = original.replace(",", "").strip()
    match = _ORIGINAL_RE.match(original)
    if match:
        amount_text, currency = match.group(1), match.group(2)
        currency_map = {"CN": "CNY", "US": "USD"}
        return Decimal(amount_text), currency_map.get(currency, currency)
    try:
        return Decimal(original), "CNY"
    except (InvalidOperation, ValueError):
        return None, ""


@dataclass(frozen=True)
class CmbTransaction:
    trans_date: date
    post_date: date | None
    category: str
    description: str
    amount_minor: int  # signed cents: 消费 +, 还款/退款 −
    card_last4: str
    original_amount: Decimal | None
    original_currency: str
    page: int
    row: int

    @property
    def billing_date(self) -> date:
        """Date on which CMB placed the row into this statement cycle."""
        return self.post_date or self.trans_date

    @property
    def effective_date(self) -> date:
        """Date used for matching; installments/fees enter the bill on posting date."""
        if self.category in (CATEGORY_INSTALLMENT, CATEGORY_FEE) and self.post_date:
            return self.post_date
        return self.trans_date

    @property
    def key(self) -> tuple[date, int]:
        return (self.effective_date, self.amount_minor)


@dataclass(frozen=True)
class CmbStatement:
    pdf_path: Path
    statement_date: date | None
    payment_due_date: date | None
    credit_limit_minor: int | None
    new_balance_minor: int | None
    min_payment_minor: int | None
    balance_bf_minor: int | None  # 上期账单金额
    payment_minor: int | None  # 上期还款金额
    new_charges_minor: int | None  # 本期账单金额
    adjustment_minor: int | None  # 本期调整金额
    interest_minor: int | None  # 循环利息
    transactions: list[CmbTransaction] = field(default_factory=list)


def _resolve_year(trans_month: int, statement_year: int, statement_month: int) -> int:
    """Credit-card billing spans the prior month into the statement month."""
    if trans_month > statement_month:
        return statement_year - 1
    return statement_year


def _parse_transaction_line(
    line: str, category: str, year: int, statement_month: int, page: int, row: int
) -> CmbTransaction | None:
    tokens = line.split()
    if len(tokens) < 5:
        return None
    if not _DATE_RE.match(tokens[0]):
        return None
    # Last three tokens are RMB amount, card last4, original amount.
    rmb_text, card, original_text = tokens[-3], tokens[-2], tokens[-1]
    if not re.match(r"^\d{4}$", card):
        return None
    try:
        amount_minor = parse_money(rmb_text)
    except ReconcileError:
        return None
    # Count leading date tokens (1 for 还款, 2 for 退款/消费).
    date_tokens: list[tuple[int, int]] = []
    cursor = 0
    while cursor < len(tokens) - 3 and _DATE_RE.match(tokens[cursor]):
        mm, dd = _DATE_RE.match(tokens[cursor]).group(1), _DATE_RE.match(tokens[cursor]).group(2)
        date_tokens.append((int(mm), int(dd)))
        cursor += 1
    if not date_tokens:
        return None
    trans_month_val, trans_day = date_tokens[0]
    trans_year = _resolve_year(trans_month_val, year, statement_month)
    try:
        trans_date = date(trans_year, trans_month_val, trans_day)
    except ValueError as exc:
        raise ReconcileError(f"invalid transaction date: {date_tokens[0]}") from exc
    post_date: date | None = None
    if len(date_tokens) == 2:
        post_month, post_day = date_tokens[1]
        post_year = _resolve_year(post_month, year, statement_month)
        try:
            post_date = date(post_year, post_month, post_day)
        except ValueError as exc:
            raise ReconcileError(f"invalid post date: {date_tokens[1]}") from exc
    description = " ".join(tokens[cursor:-3])
    original_amount, original_currency = _split_amount_currency(original_text)
    return CmbTransaction(
        trans_date=trans_date,
        post_date=post_date,
        category=category,
        description=description,
        amount_minor=amount_minor,
        card_last4=card,
        original_amount=original_amount,
        original_currency=original_currency,
        page=page,
        row=row,
    )


def _parse_header_line(label: str, lines: list[str], idx: int) -> str | None:
    """Find a money/date value on the same line as label or the next non-empty line."""
    if label in lines[idx]:
        remainder = lines[idx].replace(label, "").strip()
        if remainder:
            return remainder
        if idx + 1 < len(lines):
            return lines[idx + 1].strip()
    return None


def parse_statement(pdf_path: Path, password: str | None = None) -> CmbStatement:
    """Parse a CMB credit-card statement PDF into a CmbStatement."""
    pdf_path = pdf_path.resolve()
    if not pdf_path.is_file() or pdf_path.suffix.lower() != ".pdf":
        raise ReconcileError(f"input must be an existing PDF: {pdf_path}")
    try:
        pdf = pdfplumber.open(pdf_path, password=password)
    except Exception as exc:  # noqa: BLE001
        raise ReconcileError(f"failed to open PDF {pdf_path}: {exc}") from exc
    with pdf:
        pages = pdf.pages
        page_texts = [page.extract_text() or "" for page in pages]
    lines: list[str] = []
    for text in page_texts:
        lines.extend(text.split("\n"))

    statement_date: date | None = None
    payment_due_date: date | None = None
    credit_limit_minor: int | None = None
    new_balance_minor: int | None = None
    min_payment_minor: int | None = None
    balance_bf_minor: int | None = None
    payment_minor: int | None = None
    new_charges_minor: int | None = None
    adjustment_minor: int | None = None
    interest_minor: int | None = None

    year = 0
    statement_month = 0
    for idx, line in enumerate(lines):
        match = _STATEMENT_DATE_RE.search(line)
        if match and "账单日" in ((lines[idx - 1] if idx > 0 else "") + line):
            year = int(match.group(1))
            statement_month = int(match.group(2))
            try:
                statement_date = date(year, statement_month, int(match.group(3)))
            except ValueError:
                pass
    if year == 0:
        for line in lines:
            match = _STATEMENT_DATE_RE.search(line)
            if match and "Statement Date" in line:
                year = int(match.group(1))
                statement_month = int(match.group(2))
                try:
                    statement_date = date(year, statement_month, int(match.group(3)))
                except ValueError:
                    pass
                break
    if year == 0:
        raise ReconcileError("could not determine statement year/date")

    for idx, line in enumerate(lines):
        if "到期还款日" in line or "Payment Due Date" in line:
            match = _STATEMENT_DATE_RE.search(line) or (
                _STATEMENT_DATE_RE.search(lines[idx + 1]) if idx + 1 < len(lines) else None
            )
            if match:
                try:
                    payment_due_date = date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
                except ValueError:
                    pass
        if "信用额度" in line and "¥" in line:
            yuan = _YUAN_RE.search(line)
            if yuan:
                credit_limit_minor = parse_money(yuan.group(1))
        if "本期最低还款额" in line and "¥" in line:
            yuan = _YUAN_RE.search(line)
            if yuan:
                min_payment_minor = parse_money(yuan.group(1))
        # The six-value balance identity line, e.g.
        # ¥ 2,637.01 ¥ 4,899.24 ¥ 4,899.24 ¥ 3,476.41 ¥ 839.40 ¥ 0.00
        # Order: New Balance, Balance B/F, Payment, New Charges, Adjustment, Interest.
        if line.count("¥") >= 6:
            values = [parse_money(m.group(1)) for m in _YUAN_RE.finditer(line)]
            if len(values) >= 6:
                (
                    new_balance_minor,
                    balance_bf_minor,
                    payment_minor,
                    new_charges_minor,
                    adjustment_minor,
                    interest_minor,
                ) = values[:6]

    # Walk lines again, tracking the active category section header.
    transactions: list[CmbTransaction] = []
    current_category = ""
    page = 0
    row_on_page = 0
    for text in page_texts:
        page += 1
        row_on_page = 0
        for line in text.split("\n"):
            stripped = line.strip()
            if stripped in CATEGORY_MAP:
                current_category = CATEGORY_MAP[stripped]
                continue
            if not current_category:
                continue
            first_token = stripped.split()[0] if stripped.split() else ""
            if not _DATE_RE.match(first_token):
                continue
            row_on_page += 1
            txn = _parse_transaction_line(
                stripped, current_category, year, statement_month, page, row_on_page
            )
            if txn is not None:
                transactions.append(txn)

    return CmbStatement(
        pdf_path=pdf_path,
        statement_date=statement_date,
        payment_due_date=payment_due_date,
        credit_limit_minor=credit_limit_minor,
        new_balance_minor=new_balance_minor,
        min_payment_minor=min_payment_minor,
        balance_bf_minor=balance_bf_minor,
        payment_minor=payment_minor,
        new_charges_minor=new_charges_minor,
        adjustment_minor=adjustment_minor,
        interest_minor=interest_minor,
        transactions=transactions,
    )


def validate_statement(statement: CmbStatement) -> None:
    """Run the five statement-level balance checks; raise on any failure."""
    txns = statement.transactions
    charges = sum(t.amount_minor for t in txns if t.category in CHARGE_CATEGORIES)
    refunds = sum(t.amount_minor for t in txns if t.category == CATEGORY_REFUND)
    repayments = sum(t.amount_minor for t in txns if t.category == CATEGORY_REPAYMENT)
    interest = statement.interest_minor or 0

    errors: list[str] = []
    if statement.new_charges_minor is not None and charges != statement.new_charges_minor:
        errors.append(
            f"消费合计 {charges / 100:.2f} ≠ 本期账单金额 {statement.new_charges_minor / 100:.2f}"
        )
    if statement.adjustment_minor is not None and -refunds != statement.adjustment_minor:
        errors.append(
            f"退款合计 {refunds / 100:.2f} ≠ 本期调整金额 {statement.adjustment_minor / 100:.2f}"
        )
    if statement.payment_minor is not None and -repayments != statement.payment_minor:
        errors.append(
            f"还款合计 {repayments / 100:.2f} ≠ 上期还款金额 {statement.payment_minor / 100:.2f}"
        )
    if (
        statement.new_balance_minor is not None
        and statement.balance_bf_minor is not None
    ):
        expected = statement.balance_bf_minor + charges + refunds + repayments + interest
        if expected != statement.new_balance_minor:
            errors.append(
                f"余额等式不成立：上期 {statement.balance_bf_minor / 100:.2f} + 流水合计 "
                f"{(charges + refunds + repayments) / 100:.2f} + 利息 {interest / 100:.2f} "
                f"= {expected / 100:.2f} ≠ 本期应还 {statement.new_balance_minor / 100:.2f}"
            )
    if errors:
        raise ReconcileError("账单级余额校验失败：" + "; ".join(errors))


def _to_date(value: Any) -> date | None:
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value.astimezone(LOCAL_ZONE).date() if value.tzinfo else value.date()
    if isinstance(value, date):
        return value
    text = str(value).strip()
    for fmt in (TRANS_DATE_FORMAT, "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    raise ReconcileError(f"invalid date value in Excel: {value!r}")


def parse_statement_excel(xlsx_path: Path) -> CmbStatement:
    """Read a converted CMB Excel workbook back into a CmbStatement for validation."""
    xlsx_path = xlsx_path.resolve()
    workbook = load_workbook(xlsx_path, data_only=True, read_only=True)
    try:
        summary = workbook["转换说明"]
    except KeyError as exc:
        raise ReconcileError(f"missing 转换说明 sheet: {xlsx_path}") from exc
    meta: dict[str, str] = {}
    for row in summary.iter_rows(values_only=True):
        if row and row[0]:
            meta[str(row[0]).strip()] = "" if row[1] is None else str(row[1]).strip()
    try:
        details = workbook[EXCEL_DETAIL_SHEET]
    except KeyError as exc:
        raise ReconcileError(f"missing {EXCEL_DETAIL_SHEET} sheet") from exc
    transactions: list[CmbTransaction] = []
    rows_iter = details.iter_rows(values_only=True)
    next(rows_iter, None)  # skip header
    for row in rows_iter:
        if not row or row[0] is None:
            continue
        seq, trans_date_raw, post_date_raw, category, description, amount_raw, card, orig_raw, orig_cur, page, rownum = row
        trans_date = _to_date(trans_date_raw)
        post_date = _to_date(post_date_raw)
        if trans_date is None or category is None:
            continue
        amount_minor = int(round(float(amount_raw) * 100))
        original_amount = (
            Decimal(str(orig_raw)) if orig_raw is not None and orig_raw != "" else None
        )
        transactions.append(
            CmbTransaction(
                trans_date=trans_date,
                post_date=post_date,
                category=str(category),
                description=str(description or ""),
                amount_minor=amount_minor,
                card_last4=str(card or ""),
                original_amount=original_amount,
                original_currency=str(orig_cur or ""),
                page=int(page) if page is not None else 0,
                row=int(rownum) if rownum is not None else 0,
            )
        )
    workbook.close()
    pdf_name = meta.get("源文件", "")
    pdf_path = Path(pdf_name) if pdf_name else xlsx_path.with_suffix(".pdf")
    statement_date = _to_date(meta.get("账单日"))
    new_balance_text = meta.get("本期应还金额", "")
    new_balance_minor = parse_money(new_balance_text) if new_balance_text else None
    return CmbStatement(
        pdf_path=pdf_path,
        statement_date=statement_date,
        payment_due_date=None,
        credit_limit_minor=None,
        new_balance_minor=new_balance_minor,
        min_payment_minor=None,
        balance_bf_minor=None,
        payment_minor=None,
        new_charges_minor=None,
        adjustment_minor=None,
        interest_minor=None,
        transactions=transactions,
    )


# --------------------------------------------------------------------------- #
# ezBookkeeping client (mirrors icbc_reconcile.EzBookkeepingClient).
# --------------------------------------------------------------------------- #


class EzBookkeepingClient:
    """Minimal read-only ezBookkeeping API client over urllib."""

    def __init__(
        self,
        base_url: str,
        timeout: float = 30.0,
        allowed_business_posts: frozenset[str] = frozenset(),
    ) -> None:
        parsed = urllib.parse.urlparse(base_url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise ReconcileError(f"base_url must be an absolute URL: {base_url!r}")
        path = parsed.path.rstrip("/")
        if not path.endswith("/api"):
            path = path + "/api"
        self.base_url = f"{parsed.scheme}://{parsed.netloc}{path}"
        self.timeout = timeout
        self.allowed_business_posts = frozenset(allowed_business_posts)
        self.token: str | None = None
        self._ssl_context = ssl.create_default_context()
        if parsed.scheme == "http":
            self._ssl_context = None

    def _request(
        self, method: str, path: str, data: dict[str, Any] | None = None
    ) -> Any:
        if method not in ("GET", "POST"):
            raise ReconcileError(f"unsupported method {method!r}")
        if method == "POST" and path != "/authorize.json" and path not in self.allowed_business_posts:
            raise ReconcileError(f"blocked non-read-only POST: {path}")
        url = self.base_url + path
        headers = {
            "Accept": "application/json",
            "Accept-Language": "zh-Hans",
            "X-Timezone-Name": "Asia/Shanghai",
            "X-Timezone-Offset": "-480",
        }
        body = None
        if data is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(data).encode("utf-8")
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout, context=self._ssl_context) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            message = exc.read().decode("utf-8", errors="replace")
            raise ReconcileError(f"HTTP {exc.code} for {path}: {message}") from exc
        except urllib.error.URLError as exc:
            raise ReconcileError(f"network error for {path}: {exc.reason}") from exc
        if not isinstance(payload, dict) or not payload.get("success"):
            code = payload.get("errorCode") if isinstance(payload, dict) else None
            msg = payload.get("errorMessage") if isinstance(payload, dict) else None
            raise ReconcileError(f"API error {code} for {path}: {msg}")
        return payload.get("result")

    def authorize(self, login_name: str, password: str) -> None:
        result = self._request("POST", "/authorize.json", {"loginName": login_name, "password": password})
        if not isinstance(result, dict):
            raise ReconcileError("authorize response missing result object")
        if result.get("need2FA"):
            raise ReconcileError("account requires 2FA; password-only flow cannot continue")
        token = result.get("token")
        if not token:
            raise ReconcileError("authorize response missing token")
        self.token = str(token)

    def _get(self, path: str, query: dict[str, str] | None = None) -> Any:
        if query:
            path = f"{path}?{urllib.parse.urlencode(query)}"
        return self._request("GET", path)

    def list_accounts(self) -> list[dict[str, Any]]:
        result = self._get("/v1/accounts/list.json", {"visible_only": "false"})
        return result if isinstance(result, list) else []

    def list_transactions(
        self,
        account_id: str,
        start_time: int,
        end_time: int,
        *,
        with_pictures: bool = False,
    ) -> list[dict[str, Any]]:
        query = {
            "account_ids": str(account_id),
            "start_time": str(start_time),
            "end_time": str(end_time),
            "with_pictures": "true" if with_pictures else "false",
            "trim_account": "true",
            "trim_category": "true",
            "trim_tag": "true",
        }
        result = self._get("/v1/transactions/list/all.json", query)
        return result if isinstance(result, list) else []


def flatten_accounts(accounts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    flat: list[dict[str, Any]] = []
    for account in accounts:
        flat.append(account)
        flat.extend(flatten_accounts(account.get("subAccounts") or []))
    return flat


def select_account(
    accounts: list[dict[str, Any]], selector: str | None
) -> dict[str, Any]:
    if selector:
        matches = [a for a in accounts if str(a.get("id")) == selector or str(a.get("name")) == selector]
        if len(matches) == 1:
            return matches[0]
        available = ", ".join(f"{a.get('name')}({a.get('id')})" for a in accounts)
        raise ReconcileError(
            f"account selector {selector!r} matched {len(matches)} accounts; available: {available}"
        )
    raise ReconcileError("an account name or id is required for CMB reconciliation (use --account)")


@dataclass(frozen=True)
class OnlineTransaction:
    occurred_at: datetime
    amount_minor: int
    transaction_id: str
    transaction_type: int
    comment: str
    source_account_id: str = ""
    destination_account_id: str = ""
    source_amount_minor: int = 0
    destination_amount_minor: int = 0

    @property
    def key(self) -> tuple[date, int]:
        return (self.occurred_at.astimezone(LOCAL_ZONE).date(), self.amount_minor)


def normalize_online_transactions(
    rows: list[dict[str, Any]], account_id: str
) -> tuple[list[OnlineTransaction], list[dict[str, Any]]]:
    """Normalize online rows to the credit-card 'owed' sign convention.

    消费 (expense) increases what is owed → positive; 还款/退款 (transfer-in /
    income) decrease what is owed → negative. Amounts are taken as absolute
    minor units and signed by type + role so the convention is unambiguous
    regardless of the API's stored sign. Verify empirically against a known
    charge before trusting the report.
    """
    normalized: list[OnlineTransaction] = []
    unsupported: list[dict[str, Any]] = []
    for row in rows:
        txn_type = row.get("type")
        source_id = str(row.get("sourceAccountId") or "")
        dest_id = str(row.get("destinationAccountId") or "")
        try:
            occurred_at = datetime.fromtimestamp(int(row["time"]), LOCAL_ZONE)
        except (KeyError, TypeError, ValueError):
            unsupported.append(row)
            continue
        comment = str(row.get("comment") or "")
        txn_id = str(row.get("id") or "")
        amount_minor: int | None = None
        if txn_type == 2:  # income / refund → owed decreases
            amount_minor = -abs(int(row.get("sourceAmount") or 0))
        elif txn_type == 3:  # expense / charge → owed increases
            amount_minor = abs(int(row.get("sourceAmount") or 0))
        elif txn_type == 4:  # transfer
            if source_id == account_id:
                amount_minor = abs(int(row.get("sourceAmount") or 0))  # card is source → owed increases
            elif dest_id == account_id:
                amount_minor = -abs(int(row.get("destinationAmount") or 0))  # repayment in → owed decreases
            else:
                unsupported.append(row)
                continue
        elif txn_type == 1:  # balance delta increases account balance → owed decreases
            amount_minor = -int(row.get("balanceDelta") or 0)
        else:
            unsupported.append(row)
            continue
        normalized.append(
            OnlineTransaction(
                occurred_at=occurred_at,
                amount_minor=amount_minor,
                transaction_id=txn_id,
                transaction_type=txn_type,
                comment=comment,
                source_account_id=source_id,
                destination_account_id=dest_id,
                source_amount_minor=abs(int(row.get("sourceAmount") or 0)),
                destination_amount_minor=abs(int(row.get("destinationAmount") or 0)),
            )
        )
    return normalized, unsupported


# --------------------------------------------------------------------------- #
# Reconciliation.
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class ExactMatch:
    bank: CmbTransaction
    online: OnlineTransaction


@dataclass(frozen=True)
class NearMatch:
    bank: CmbTransaction
    online: OnlineTransaction

    @property
    def amount_delta_minor(self) -> int:
        return self.bank.amount_minor - self.online.amount_minor

    @property
    def date_delta_days(self) -> int:
        """Signed online date minus bank matching date."""
        online_date = self.online.occurred_at.astimezone(LOCAL_ZONE).date()
        return (online_date - self.bank.effective_date).days


@dataclass(frozen=True)
class RefundChargePair:
    charge: CmbTransaction
    refund: CmbTransaction


@dataclass(frozen=True)
class Reconciliation:
    exact_matched_count: int
    near_matches: list[NearMatch]
    bank_only: list[CmbTransaction]
    online_only: list[OnlineTransaction]
    refund_charge_pairs: list[RefundChargePair]
    exact_matches: list[ExactMatch] = field(default_factory=list)

    @property
    def matched_count(self) -> int:
        return self.exact_matched_count + len(self.near_matches)


def reconcile(
    bank_transactions: list[CmbTransaction],
    online_transactions: list[OnlineTransaction],
    amount_tolerance_minor: int = 5,
    small_amount_limit_minor: int = 1000,
    date_tolerance_days: int = 0,
    pair_refund_charge: bool = True,
) -> Reconciliation:
    """Exact/date match, then amount-first date tolerance, then refund pairing."""
    if date_tolerance_days < 0:
        raise ReconcileError("date tolerance cannot be negative")
    online_by_key: dict[tuple[date, int], list[int]] = defaultdict(list)
    for index, txn in enumerate(online_transactions):
        online_by_key[txn.key].append(index)

    exact_matches: list[ExactMatch] = []
    bank_matched: list[bool] = [False] * len(bank_transactions)
    online_matched: list[bool] = [False] * len(online_transactions)
    for bank_index, bank_txn in enumerate(bank_transactions):
        candidates = online_by_key.get(bank_txn.key)
        if not candidates:
            continue
        online_index = None
        for candidate in candidates:
            if not online_matched[candidate]:
                online_index = candidate
                break
        if online_index is None:
            continue
        bank_matched[bank_index] = True
        online_matched[online_index] = True
        candidates.remove(online_index)
        exact_matches.append(ExactMatch(bank_txn, online_transactions[online_index]))

    # Cross-currency card charges are stored online as CNY→foreign-card transfers.
    # Pair by the exact foreign amount, then disclose the CNY conversion difference.
    near_matches: list[NearMatch] = []
    foreign_candidates: list[tuple[int, int, int]] = []
    for bank_index, bank_txn in enumerate(bank_transactions):
        if bank_matched[bank_index] or bank_txn.original_currency in ("", "CNY"):
            continue
        if bank_txn.original_amount is None:
            continue
        original_minor = int((abs(bank_txn.original_amount) * 100).quantize(Decimal(1)))
        for online_index, online_txn in enumerate(online_transactions):
            if online_matched[online_index] or online_txn.transaction_type != 4:
                continue
            if online_txn.source_account_id == online_txn.destination_account_id:
                continue
            date_delta = abs(
                (
                    bank_txn.effective_date
                    - online_txn.occurred_at.astimezone(LOCAL_ZONE).date()
                ).days
            )
            if date_delta > date_tolerance_days:
                continue
            if original_minor != online_txn.destination_amount_minor:
                continue
            foreign_candidates.append(
                (
                    abs(bank_txn.amount_minor - online_txn.amount_minor),
                    bank_index,
                    online_index,
                )
            )
    foreign_candidates.sort()
    for _, bank_index, online_index in foreign_candidates:
        if bank_matched[bank_index] or online_matched[online_index]:
            continue
        bank_matched[bank_index] = True
        online_matched[online_index] = True
        near_matches.append(
            NearMatch(bank_transactions[bank_index], online_transactions[online_index])
        )

    # Tolerance / fuzzy match within the same calendar day and direction.
    bank_pending = [
        (i, t) for i, t in enumerate(bank_transactions) if not bank_matched[i]
    ]
    online_pending = [
        (i, t) for i, t in enumerate(online_transactions) if not online_matched[i]
    ]
    candidates: list[tuple[int, int, int, int]] = []  # (amount_delta, date_delta_days, bank_idx, online_idx)
    for bank_index, bank_txn in bank_pending:
        for online_index, online_txn in online_pending:
            if bank_txn.amount_minor * online_txn.amount_minor <= 0:
                continue
            date_delta = abs(
                (
                    bank_txn.effective_date
                    - online_txn.occurred_at.astimezone(LOCAL_ZONE).date()
                ).days
            )
            if date_delta > date_tolerance_days:
                continue
            amount_delta = abs(bank_txn.amount_minor - online_txn.amount_minor)
            normal = amount_delta <= amount_tolerance_minor
            small = (
                abs(bank_txn.amount_minor) <= small_amount_limit_minor
                and abs(online_txn.amount_minor) <= small_amount_limit_minor
                and amount_delta <= 100
            )
            if normal or small:
                candidates.append((amount_delta, date_delta, bank_index, online_index))
    candidates.sort(key=lambda item: (item[0], item[1], item[2], item[3]))
    for _, _, bank_index, online_index in candidates:
        if bank_matched[bank_index] or online_matched[online_index]:
            continue
        bank_matched[bank_index] = True
        online_matched[online_index] = True
        near_matches.append(
            NearMatch(bank_transactions[bank_index], online_transactions[online_index])
        )

    bank_only = [t for i, t in enumerate(bank_transactions) if not bank_matched[i]]
    online_only = [t for i, t in enumerate(online_transactions) if not online_matched[i]]
    refund_charge_pairs = (
        pair_refund_charge_bank_only(bank_only) if pair_refund_charge else []
    )
    paired_ids = {id(p.charge) for p in refund_charge_pairs} | {id(p.refund) for p in refund_charge_pairs}
    bank_only_unpaired = [t for t in bank_only if id(t) not in paired_ids]

    return Reconciliation(
        exact_matched_count=len(exact_matches),
        near_matches=near_matches,
        bank_only=bank_only_unpaired,
        online_only=online_only,
        refund_charge_pairs=refund_charge_pairs,
        exact_matches=exact_matches,
    )


def _channel_prefix(description: str) -> str:
    return description.split("-", 1)[0] if "-" in description else description


def pair_refund_charge_bank_only(
    transactions: list[CmbTransaction],
) -> list[RefundChargePair]:
    """Pair equal-and-opposite charge/refund bank-only rows (same channel, ≤2 days)."""
    charges = [t for t in transactions if t.category == CATEGORY_CHARGE and t.amount_minor > 0]
    refunds = [t for t in transactions if t.category == CATEGORY_REFUND and t.amount_minor < 0]
    pairs: list[RefundChargePair] = []
    used_refund: set[int] = set()
    for charge in charges:
        for refund in refunds:
            if id(refund) in used_refund:
                continue
            if charge.amount_minor + refund.amount_minor != 0:
                continue
            if abs((charge.trans_date - refund.trans_date).days) > 2:
                continue
            same_desc = charge.description == refund.description
            same_channel = _channel_prefix(charge.description) == _channel_prefix(refund.description)
            if not (same_desc or same_channel):
                continue
            pairs.append(RefundChargePair(charge=charge, refund=refund))
            used_refund.add(id(refund))
            break
    return pairs


def partition_online_by_period(
    transactions: list[OnlineTransaction],
    period_start: datetime,
    period_end: datetime,
    tolerance_seconds: int,
) -> tuple[list[OnlineTransaction], list[OnlineTransaction]]:
    within: list[OnlineTransaction] = []
    outside: list[OnlineTransaction] = []
    lower = period_start - timedelta(seconds=tolerance_seconds)
    upper = period_end + timedelta(seconds=tolerance_seconds)
    for txn in transactions:
        if lower <= txn.occurred_at <= upper:
            within.append(txn)
        else:
            outside.append(txn)
    return within, outside


def statement_period(statement: CmbStatement) -> tuple[datetime, datetime]:
    """Return the complete billing cycle, including quiet statement-date days."""
    if statement.statement_date is None:
        transaction_dates = [transaction.trans_date for transaction in statement.transactions]
        if not transaction_dates:
            raise ReconcileError("statement has no transactions to reconcile")
        start_date = min(transaction_dates)
        end_date = max(transaction_dates)
    else:
        end_date = statement.statement_date
        previous_month = end_date.month - 1 or 12
        previous_year = end_date.year - 1 if end_date.month == 1 else end_date.year
        previous_day = min(end_date.day, monthrange(previous_year, previous_month)[1])
        start_date = date(previous_year, previous_month, previous_day) + timedelta(days=1)
        outside = [
            transaction.billing_date
            for transaction in statement.transactions
            if not start_date <= transaction.billing_date <= end_date
        ]
        if outside:
            raise ReconcileError(
                f"statement rows fall outside derived billing cycle {start_date} ~ {end_date}"
            )
    return (
        datetime.combine(start_date, datetime.min.time(), LOCAL_ZONE),
        datetime.combine(end_date, datetime.max.time(), LOCAL_ZONE),
    )


# --------------------------------------------------------------------------- #
# Report.
# --------------------------------------------------------------------------- #


def format_money(minor: int) -> str:
    sign = "-" if minor < 0 else ""
    value = abs(minor) / 100
    return f"{sign}{value:,.2f}"


def _money_row(txn: CmbTransaction) -> str:
    location = f"PDF p{txn.page}/r{txn.row}"
    date_label = str(txn.effective_date)
    if txn.effective_date != txn.trans_date:
        date_label += f"（交易日 {txn.trans_date}）"
    return (
        f"| {date_label} | {format_money(txn.amount_minor)} | "
        f"{txn.category} | {txn.description} | {location} |"
    )


def render_report(
    statement: CmbStatement,
    account: dict[str, Any],
    online_transactions: list[OnlineTransaction],
    reconciliation: Reconciliation,
    outside_period: list[OnlineTransaction],
    unsupported: list[dict[str, Any]],
    detail_limit: int,
    amount_tolerance_minor: int,
    small_amount_limit_minor: int,
    date_tolerance_days: int,
) -> str:
    lines: list[str] = []
    period_label = (
        f"{statement.statement_date:%Y-%m-%d}" if statement.statement_date else "未知"
    )
    txn_dates = [t.effective_date for t in statement.transactions]
    bank_range = (
        f"{min(txn_dates)} ~ {max(txn_dates)}" if txn_dates else "无"
    )
    period_start, period_end = statement_period(statement)
    lines.append("# 招商银行信用卡核对报告")
    lines.append("")
    lines.append(f"- 账单日：{period_label}")
    lines.append(f"- 完整账期：{period_start:%Y-%m-%d} ~ {period_end:%Y-%m-%d}")
    lines.append(f"- 银行流水范围：{bank_range}")
    lines.append(f"- 线上账户：{account.get('name')}（id {account.get('id')}）")
    rec = reconciliation
    excluded_bank_ids = {
        id(transaction)
        for pair in rec.refund_charge_pairs
        for transaction in (pair.charge, pair.refund)
    }
    statistical_bank = [
        transaction
        for transaction in statement.transactions
        if id(transaction) not in excluded_bank_ids
    ]
    lines.append(
        f"- 纳入统计：银行 {len(statistical_bank)} 笔，线上 {len(online_transactions)} 笔"
        f"（银行原始 {len(statement.transactions)} 笔，退款—消费抵销排除 {len(excluded_bank_ids)} 笔）"
    )
    if statement.new_balance_minor is not None:
        lines.append(f"- 本期应还金额：¥ {format_money(statement.new_balance_minor)}")
    lines.append("")
    lines.append("## 结论")
    time_differences = [n for n in rec.near_matches if n.date_delta_days != 0]
    same_day_differences = [n for n in rec.near_matches if n.date_delta_days == 0]
    lines.append(
        f"- 精确匹配 {rec.exact_matched_count} 笔；时间差匹配 {len(time_differences)} 笔；"
        f"同日金额差匹配 {len(same_day_differences)} 笔。"
    )
    lines.append(
        f"- 银行侧未匹配 {len(rec.bank_only)} 笔；线上侧未匹配 {len(rec.online_only)} 笔；"
        f"账期外 {len(outside_period)} 笔；不支持类型 {len(unsupported)} 笔。"
    )
    if rec.refund_charge_pairs:
        lines.append(
            f"- 银行退款—消费抵销 {len(rec.refund_charge_pairs)} 组（{len(excluded_bank_ids)} 笔），仅作追溯，不纳入任何核对统计。"
        )
    amount_diffs = [n for n in rec.near_matches if n.amount_delta_minor != 0]
    if amount_diffs:
        total = sum(n.amount_delta_minor for n in amount_diffs)
        lines.append(
            f"- 容差匹配中 {len(amount_diffs)} 笔金额不同，金额差（银行 − 线上）合计 {format_money(total)} 元。"
        )
    lines.append("")
    lines.append("## 汇总")
    lines.append("| 来源 | 笔数 | 消费 | 还款 | 退款 |")
    lines.append("|---|---|---|---|---|")
    bank_charges = sum(1 for t in statistical_bank if t.category in CHARGE_CATEGORIES)
    bank_refunds = sum(1 for t in statistical_bank if t.category == CATEGORY_REFUND)
    bank_repay = sum(1 for t in statistical_bank if t.category == CATEGORY_REPAYMENT)
    bank_charges_amt = sum(t.amount_minor for t in statistical_bank if t.category in CHARGE_CATEGORIES)
    bank_refunds_amt = sum(t.amount_minor for t in statistical_bank if t.category == CATEGORY_REFUND)
    bank_repay_amt = sum(t.amount_minor for t in statistical_bank if t.category == CATEGORY_REPAYMENT)
    lines.append(
        f"| 银行账单（已排除抵销） | {len(statistical_bank)} | "
        f"{format_money(bank_charges_amt)}（{bank_charges} 笔） | "
        f"{format_money(bank_repay_amt)}（{bank_repay} 笔） | "
        f"{format_money(bank_refunds_amt)}（{bank_refunds} 笔） |"
    )
    online_pos = sum(t.amount_minor for t in online_transactions if t.amount_minor > 0)
    online_neg = sum(t.amount_minor for t in online_transactions if t.amount_minor < 0)
    lines.append(
        f"| 线上账本 | {len(online_transactions)} | "
        f"{format_money(online_pos)}（应还增加） | — | {format_money(online_neg)}（应还减少） |"
    )
    lines.append("")

    if rec.refund_charge_pairs:
        lines.append("## 不纳入统计的退款—消费抵销")
        lines.append("| 消费日期 | 消费金额 | 退款日期 | 退款金额 | 摘要 |")
        lines.append("|---|---|---|---|---|")
        for pair in rec.refund_charge_pairs:
            lines.append(
                f"| {pair.charge.trans_date} | {format_money(pair.charge.amount_minor)} | "
                f"{pair.refund.trans_date} | {format_money(pair.refund.amount_minor)} | "
                f"{pair.charge.description} |"
            )
        lines.append("")

    if amount_diffs:
        lines.append("## 已配对的时间/金额差异")
        lines.append("| 银行日期 | 银行金额 | 线上时间 | 线上金额 | 时间差（线上 − 银行） | 金额差（银行 − 线上） | 交易 ID |")
        lines.append("|---|---:|---|---:|---:|---:|---|")
        for near in amount_diffs:
            lines.append(
                f"| {near.bank.effective_date} | {format_money(near.bank.amount_minor)} | "
                f"{near.online.occurred_at.astimezone(LOCAL_ZONE):%Y-%m-%d %H:%M:%S} | "
                f"{format_money(near.online.amount_minor)} | {near.date_delta_days:+d} 天 | "
                f"{format_money(near.amount_delta_minor)} | "
                f"{near.online.transaction_id} |"
            )
        lines.append("")

    if detail_limit == 0:
        lines.append("## 明细")
        lines.append("- 命令参数要求省略逐笔明细。")
    else:
        same_amount = [n for n in rec.near_matches if n.amount_delta_minor == 0]
        if same_amount:
            lines.append("## 金额相同的时间差匹配")
            lines.append("| 银行日期 | 银行金额 | 线上时间 | 时间差（线上 − 银行） | 交易 ID |")
            lines.append("|---|---:|---|---:|---|")
            for near in same_amount[:detail_limit]:
                lines.append(
                    f"| {near.bank.effective_date} | {format_money(near.bank.amount_minor)} | "
                    f"{near.online.occurred_at.astimezone(LOCAL_ZONE):%Y-%m-%d %H:%M:%S} | "
                    f"{near.date_delta_days:+d} 天 | "
                    f"{near.online.transaction_id} |"
                )
            lines.append("")

        lines.append("## 银行有、线上无")
        if rec.bank_only:
            lines.append("| 日期 | 金额 | 分类 | 摘要 | PDF 位置 |")
            lines.append("|---|---|---|---|---|")
            for txn in rec.bank_only[:detail_limit]:
                lines.append(_money_row(txn))
            if len(rec.bank_only) > detail_limit:
                lines.append(f"| … | … | … | 共 {len(rec.bank_only)} 笔，仅显示前 {detail_limit} 笔 | |")
        else:
            lines.append("- 无")
        lines.append("")

        lines.append("## 线上有、银行无")
        if rec.online_only:
            lines.append("| 时间 | 金额 | 类型 | 备注 | 交易 ID |")
            lines.append("|---|---|---|---|---|")
            type_names = {1: "余额调整", 2: "收入", 3: "支出", 4: "转账"}
            for txn in rec.online_only[:detail_limit]:
                lines.append(
                    f"| {txn.occurred_at.astimezone(LOCAL_ZONE):%Y-%m-%d %H:%M:%S} | "
                    f"{format_money(txn.amount_minor)} | {type_names.get(txn.transaction_type, '?')} | "
                    f"{txn.comment} | {txn.transaction_id} |"
                )
            if len(rec.online_only) > detail_limit:
                lines.append(f"| … | … | … | 共 {len(rec.online_only)} 笔，仅显示前 {detail_limit} 笔 | |")
        else:
            lines.append("- 无")
        lines.append("")

    lines.append("## 核对规则与限制")
    rules = [
        "PDF 账单先一一对应转换为 Excel，后续核对只读取 Excel；本报告不修改线上记录。",
        "匹配键为“入账自然日 + 有符号分金额”，普通消费/退款/还款使用交易日，分期与费用使用记账日；消费、分期与费用记正，还款与退款记负。",
        f"精确多重集匹配完成后，允许最多相差 {date_tolerance_days} 个自然日的同方向候选；候选先按金额差、再按日期差排序。普通金额差 ≤ 0.05 元，双方绝对金额均不超过 10.00 元时放宽至金额差 ≤ 1.00 元。",
        f"外币消费若线上记为从人民币信用卡转入外币信用卡，则允许最多相差 {date_tolerance_days} 个自然日，并要求原币金额完全一致；人民币换汇差额完整披露。",
        "禁止消费与还款、消费与退款互相匹配；所有候选均一对一消费，且全量精确匹配优先于时间差匹配。",
        "银行侧未匹配中等额反向的同渠道消费与退款（相距 ≤ 2 天）一对一抵销，并从银行总笔数、匹配数及差异数中完全排除。",
        "还款按信用卡侧转账入账处理；如需核对借记卡侧转出，另行跨账户核对。",
        "金额按有符号分金额处理；交易日按 UTC+8、仅日期。",
        "线上交易按信用卡“应还”口径归一化符号：支出增应还为正、转账入账与退款减应还为负。请在首次核对时用已知消费核实符号方向。",
    ]
    for rule in rules:
        lines.append(f"- {rule}")
    lines.append("")
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# CLI.
# --------------------------------------------------------------------------- #


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("statement", type=Path, help="CMB statement PDF or converted XLSX")
    parser.add_argument("--base-url", default="http://localhost:8080/", help="ezBookkeeping site URL")
    parser.add_argument("--username", help="omit to validate the statement locally without API calls")
    parser.add_argument("--account", default="招行信用卡", help="ezBookkeeping account name or id")
    parser.add_argument("--output", type=Path, help="markdown report path")
    parser.add_argument("--detail-limit", type=int, default=50, help="max unmatched rows per side; 0 omits detail")
    parser.add_argument("--time-tolerance", type=int, default=10, help="statement boundary tolerance in seconds")
    parser.add_argument("--amount-tolerance-cents", type=int, default=5, help="near-match tolerance in cents")
    parser.add_argument("--small-amount-limit-cents", type=int, default=1000, help="both ≤ this allows amount difference")
    parser.add_argument("--date-tolerance-days", type=int, default=0, help="maximum cross-day difference for near matches")
    parser.add_argument("--strict", action="store_true", help="exit code 2 when unmatched rows exist")
    return parser.parse_args(argv)


def load_statement(path: Path) -> CmbStatement:
    if path.suffix.lower() == ".pdf":
        password = os.environ.get("CMB_PDF_PASSWORD")
        statement = parse_statement(path, password)
        validate_statement(statement)
        return statement
    if path.suffix.lower() == ".xlsx":
        return parse_statement_excel(path)
    raise ReconcileError(f"unsupported input type: {path}")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    statement = load_statement(args.statement)
    if not args.username:
        print(
            f"validated {len(statement.transactions)} rows from {statement.pdf_path.name}"
        )
        if statement.new_balance_minor is not None:
            print(f"本期应还金额 ¥ {format_money(statement.new_balance_minor)}")
        return 0

    password = os.environ.get("EZBOOKKEEPING_PASSWORD")
    if not password:
        password = getpass.getpass("ezBookkeeping password: ")
    client = EzBookkeepingClient(args.base_url)
    client.authorize(args.username, password)
    accounts = flatten_accounts(client.list_accounts())
    account = select_account(accounts, args.account)
    account_id = str(account["id"])

    period_start, period_end = statement_period(statement)
    raw_online = client.list_transactions(
        account_id,
        int((period_start - timedelta(days=args.date_tolerance_days)).timestamp()),
        int((period_end + timedelta(days=args.date_tolerance_days)).timestamp()),
    )
    online_transactions, unsupported = normalize_online_transactions(raw_online, account_id)
    within, outside = partition_online_by_period(
        online_transactions,
        period_start,
        period_end,
        args.time_tolerance + args.date_tolerance_days * 86400,
    )
    reconciliation = reconcile(
        statement.transactions,
        within,
        amount_tolerance_minor=args.amount_tolerance_cents,
        small_amount_limit_minor=args.small_amount_limit_cents,
        date_tolerance_days=args.date_tolerance_days,
    )
    report = render_report(
        statement,
        account,
        within,
        reconciliation,
        outside,
        unsupported,
        detail_limit=args.detail_limit,
        amount_tolerance_minor=args.amount_tolerance_cents,
        small_amount_limit_minor=args.small_amount_limit_cents,
        date_tolerance_days=args.date_tolerance_days,
    )
    output_path = args.output or args.statement.with_name(f"{args.statement.stem}_核对报告.md")
    output_path.write_text(report, encoding="utf-8", newline="\n")
    print(f"report written to {output_path.resolve()}")
    if args.strict and (reconciliation.bank_only or reconciliation.online_only or unsupported):
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReconcileError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
