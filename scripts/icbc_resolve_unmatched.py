# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pdfplumber==0.11.7",
#   "openpyxl==3.1.5",
# ]
# ///

"""Resolve the remaining unmatched ICBC rows with a guarded manifest."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import sys
import uuid
from collections import Counter
from datetime import datetime, time
from pathlib import Path
from typing import Any

from icbc_apply_reconciliation import (
    MUTATION_PATHS,
    fingerprint,
    get_full_transaction,
    list_full_transactions,
    write_json,
)
from icbc_reconcile import (
    LOCAL_ZONE,
    BankTransaction,
    EzBookkeepingClient,
    OnlineTransaction,
    ReconcileError,
    load_statement,
    normalize_online_transactions,
    partition_online_by_period,
    reconcile,
    reconcile_finance_aggregations,
    select_account,
    suppress_equal_opposite_bank_only,
)

SUBWAY_MIN_MINOR = 260
SUBWAY_MAX_MINOR = 280
CATEGORY_NAMES = {
    "income": "其他收入",
    "subway": "公共交通",
    "expense": "其他支出",
}


def find_category_ids(categories_by_type: dict[str, Any]) -> dict[str, str]:
    wanted = {
        (1, CATEGORY_NAMES["income"]): "income",
        (2, CATEGORY_NAMES["subway"]): "subway",
        (2, CATEGORY_NAMES["expense"]): "expense",
    }
    matches: dict[str, list[str]] = {key: [] for key in CATEGORY_NAMES}
    for groups in categories_by_type.values():
        if not isinstance(groups, list):
            continue
        for primary in groups:
            for category in primary.get("subCategories") or []:
                key = wanted.get((int(category.get("type", 0)), category.get("name")))
                if key and not category.get("hidden"):
                    matches[key].append(str(category["id"]))

    invalid = {key: values for key, values in matches.items() if len(values) != 1}
    if invalid:
        raise ReconcileError(f"expected one visible secondary category: {invalid}")
    return {key: values[0] for key, values in matches.items()}


def classify_bank_transaction(
    transaction: BankTransaction, category_ids: dict[str, str]
) -> tuple[str, int, str, str]:
    summary = transaction.summary.strip()
    if transaction.amount_minor > 0:
        return "income", 2, category_ids["income"], summary

    amount = abs(transaction.amount_minor)
    if SUBWAY_MIN_MINOR <= amount <= SUBWAY_MAX_MINOR:
        comment = f"地铁；{summary}" if summary else "地铁"
        return "subway", 3, category_ids["subway"], comment
    return "expense", 3, category_ids["expense"], summary


def collect_unmatched(
    bank_transactions: list[BankTransaction],
    rows: list[dict[str, Any]],
    account_id: str,
    fund_account_id: str,
) -> tuple[
    list[BankTransaction],
    list[OnlineTransaction],
    list[Any],
    list[OnlineTransaction],
]:
    normalized, unsupported = normalize_online_transactions(rows, account_id)
    if unsupported:
        raise ReconcileError("unsupported online rows prevent safe mutation")
    finance = reconcile_finance_aggregations(
        bank_transactions, normalized, account_id, {fund_account_id}
    )
    regular_online, outside = partition_online_by_period(
        finance.regular_online,
        bank_transactions[0].occurred_at,
        bank_transactions[-1].occurred_at,
        10,
    )
    result = reconcile(finance.regular_bank, regular_online)
    if result.near_matches:
        raise ReconcileError(
            f"expected no pending tolerance matches, found {len(result.near_matches)}"
        )
    bank_only, suppressed_pairs = suppress_equal_opposite_bank_only(result.bank_only)
    return bank_only, result.online_only, suppressed_pairs, outside


def bank_reference(transaction: BankTransaction) -> dict[str, Any]:
    return {
        "time": int(transaction.occurred_at.timestamp()),
        "amount": transaction.amount_minor,
        "summary": transaction.summary.strip(),
        "page": transaction.page,
        "row": transaction.row,
    }


def unmatched_state(
    bank_only: list[BankTransaction],
    online_only: list[OnlineTransaction],
    raw_by_id: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    return {
        "bankOnly": [bank_reference(item) for item in bank_only],
        "onlineOnly": [
            {
                "id": item.transaction_id,
                "fingerprint": fingerprint(raw_by_id[item.transaction_id]),
            }
            for item in online_only
        ],
    }


def build_manifest(
    bank_transactions: list[BankTransaction],
    rows: list[dict[str, Any]],
    account: dict[str, Any],
    fund_account: dict[str, Any],
    categories_by_type: dict[str, Any],
    accounts: list[dict[str, Any]],
) -> dict[str, Any]:
    account_id = str(account["id"])
    bank_only, online_only, suppressed_pairs, outside = collect_unmatched(
        bank_transactions, rows, account_id, str(fund_account["id"])
    )
    raw_by_id = {str(row["id"]): row for row in rows}
    category_ids = find_category_ids(categories_by_type)
    manifest_id = str(uuid.uuid4())
    creations: list[dict[str, Any]] = []
    classifications: Counter[str] = Counter()

    for transaction in bank_only:
        kind, transaction_type, category_id, comment = classify_bank_transaction(
            transaction, category_ids
        )
        classifications[kind] += 1
        reference = bank_reference(transaction)
        creations.append(
            {
                "kind": kind,
                "categoryName": CATEGORY_NAMES[kind],
                "bank": reference,
                "payload": {
                    "type": transaction_type,
                    "categoryId": category_id,
                    "time": reference["time"],
                    "utcOffset": 480,
                    "sourceAccountId": account_id,
                    "destinationAccountId": "0",
                    "sourceAmount": abs(transaction.amount_minor),
                    "destinationAmount": 0,
                    "hideAmount": False,
                    "tagIds": [],
                    "pictureIds": [],
                    "comment": comment,
                    "clientSessionId": (
                        f"icbc-unmatched-{manifest_id}-{transaction.page}-{transaction.row}"
                    ),
                },
            }
        )

    deletions = []
    for transaction in online_only:
        row = raw_by_id[transaction.transaction_id]
        if not row.get("editable"):
            raise ReconcileError(f"transaction {row['id']} is not editable")
        deletions.append(
            {
                "id": str(row["id"]),
                "expectedFingerprint": fingerprint(row),
                "before": row,
            }
        )

    state = unmatched_state(bank_only, online_only, raw_by_id)
    return {
        "version": 1,
        "manifestId": manifest_id,
        "createdAt": datetime.now(LOCAL_ZONE).isoformat(),
        "account": account,
        "fundAccount": fund_account,
        "categoryIds": category_ids,
        "summary": {
            "creations": len(creations),
            "incomeCreations": classifications["income"],
            "subwayCreations": classifications["subway"],
            "otherExpenseCreations": classifications["expense"],
            "deletions": len(deletions),
            "suppressedEqualOppositePairs": len(suppressed_pairs),
            "outsidePeriodOnline": len(outside),
        },
        "unmatchedState": state,
        "creations": creations,
        "deletions": deletions,
        "suppressedPairs": [
            {
                "outflow": bank_reference(pair.outflow),
                "inflow": bank_reference(pair.inflow),
            }
            for pair in suppressed_pairs
        ],
        "accountSnapshot": accounts,
    }


def apply_manifest(
    client: EzBookkeepingClient,
    manifest: dict[str, Any],
    journal_path: Path,
    bank_transactions: list[BankTransaction],
    period_start: int,
    period_end: int,
) -> None:
    journal: dict[str, Any] = {
        "manifestId": manifest["manifestId"],
        "startedAt": datetime.now(LOCAL_ZONE).isoformat(),
        "created": [],
        "deleted": [],
        "status": "running",
    }
    write_json(journal_path, journal)

    account_id = str(manifest["account"]["id"])
    current_rows = list_full_transactions(client, account_id, period_start, period_end)
    bank_only, online_only, _, _ = collect_unmatched(
        bank_transactions,
        current_rows,
        account_id,
        str(manifest["fundAccount"]["id"]),
    )
    current_by_id = {str(row["id"]): row for row in current_rows}
    if (
        unmatched_state(bank_only, online_only, current_by_id)
        != manifest["unmatchedState"]
    ):
        raise ReconcileError("unmatched state changed after manifest generation")

    for operation in manifest["deletions"]:
        current = get_full_transaction(client, operation["id"])
        if fingerprint(current) != operation["expectedFingerprint"]:
            raise ReconcileError(
                f"transaction {operation['id']} changed after manifest generation"
            )

    try:
        for operation in manifest["creations"]:
            result = client._request(
                "POST", "/v1/transactions/add.json", operation["payload"]
            )
            journal["created"].append(
                {
                    "kind": operation["kind"],
                    "id": str(result["id"]),
                    "bank": operation["bank"],
                }
            )
            write_json(journal_path, journal)

        for operation in manifest["deletions"]:
            current = get_full_transaction(client, operation["id"])
            if fingerprint(current) != operation["expectedFingerprint"]:
                raise ReconcileError(
                    f"transaction {operation['id']} changed before deletion"
                )
            client._request(
                "POST", "/v1/transactions/delete.json", {"id": operation["id"]}
            )
            journal["deleted"].append(operation["id"])
            write_json(journal_path, journal)
    except Exception:
        journal["status"] = "failed"
        journal["finishedAt"] = datetime.now(LOCAL_ZONE).isoformat()
        write_json(journal_path, journal)
        raise

    journal["status"] = "complete"
    journal["finishedAt"] = datetime.now(LOCAL_ZONE).isoformat()
    write_json(journal_path, journal)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("statement", type=Path, help="ICBC statement PDF or XLSX")
    parser.add_argument("--base-url", default="https://example.com/")
    parser.add_argument("--username", required=True)
    parser.add_argument("--account", default="工资卡")
    parser.add_argument("--fund-account", default="基金账户")
    parser.add_argument(
        "--manifest", type=Path, default=Path("tmp/工商银行未匹配流水处理清单.json")
    )
    parser.add_argument(
        "--backup", type=Path, default=Path("tmp/工商银行未匹配流水处理备份.json")
    )
    parser.add_argument(
        "--journal", type=Path, default=Path("tmp/工商银行未匹配流水处理执行日志.json")
    )
    parser.add_argument("--apply", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    password = os.environ.get("EZBOOKKEEPING_PASSWORD") or getpass.getpass(
        "ezBookkeeping password: "
    )
    bank_transactions = load_statement(args.statement.resolve())
    client = EzBookkeepingClient(
        args.base_url,
        allowed_business_posts=MUTATION_PATHS if args.apply else frozenset(),
    )
    client.authorize(args.username, password)
    accounts = client.list_accounts()
    account = select_account(
        accounts, args.account, bank_transactions[-1].balance_minor
    )
    fund_matches = [item for item in accounts if item.get("name") == args.fund_account]
    if len(fund_matches) != 1:
        raise ReconcileError(f"expected one fund account, found {len(fund_matches)}")
    categories = client._get("/v1/transaction/categories/list.json", {})
    if not isinstance(categories, dict):
        raise ReconcileError("category list response was not an object")

    first_day = datetime.combine(
        bank_transactions[0].occurred_at.date(), time.min, LOCAL_ZONE
    )
    last_day = datetime.combine(
        bank_transactions[-1].occurred_at.date(), time.max, LOCAL_ZONE
    )
    start_time = int(first_day.timestamp())
    end_time = int(last_day.timestamp())
    rows = list_full_transactions(client, str(account["id"]), start_time, end_time)
    manifest = build_manifest(
        bank_transactions,
        rows,
        account,
        fund_matches[0],
        categories,
        accounts,
    )
    write_json(args.manifest, manifest)
    write_json(
        args.backup,
        {
            "manifestId": manifest["manifestId"],
            "createdAt": manifest["createdAt"],
            "accountSnapshot": manifest["accountSnapshot"],
            "plannedCreations": manifest["creations"],
            "deletedOriginals": [item["before"] for item in manifest["deletions"]],
        },
    )
    print(json.dumps(manifest["summary"], ensure_ascii=True, sort_keys=True))
    if not args.apply:
        print(f"Dry run only. Manifest: {args.manifest.resolve()}")
        return 0

    apply_manifest(
        client,
        manifest,
        args.journal,
        bank_transactions,
        start_time,
        end_time,
    )
    print(f"Applied. Journal: {args.journal.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
