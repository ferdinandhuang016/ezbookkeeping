# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pdfplumber==0.11.7",
#   "openpyxl==3.1.5",
# ]
# ///

"""Build and apply a guarded ICBC-to-ezBookkeeping correction manifest."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import sys
import uuid
from collections import Counter, defaultdict
from datetime import datetime, time
from pathlib import Path
from typing import Any

from icbc_reconcile import (
    DAILY_FINANCE_PREFIX,
    LOCAL_ZONE,
    PRE_STATEMENT_RESIDUAL_COMMENT,
    EzBookkeepingClient,
    ReconcileError,
    load_statement,
    normalize_online_transactions,
    partition_online_by_period,
    reconcile,
    reconcile_finance_aggregations,
    select_account,
)

MUTATION_PATHS = frozenset(
    {
        "/v1/transactions/add.json",
        "/v1/transactions/modify.json",
        "/v1/transactions/delete.json",
    }
)
EXPECTED_AGGREGATE_COUNT = 40
EXPECTED_AGGREGATE_TOTAL = 5_419_533


def picture_ids(row: dict[str, Any]) -> list[str]:
    result: list[str] = []
    for picture in row.get("pictures") or []:
        picture_id = picture.get("id") or picture.get("pictureId")
        if picture_id:
            result.append(str(picture_id))
    return result


def payload_from_row(row: dict[str, Any]) -> dict[str, Any]:
    payload = {
        "type": int(row["type"]),
        "categoryId": str(row.get("categoryId") or "0"),
        "time": int(row["time"]),
        "utcOffset": int(row.get("utcOffset", 480)),
        "sourceAccountId": str(row["sourceAccountId"]),
        "destinationAccountId": str(row.get("destinationAccountId") or "0"),
        "sourceAmount": int(row["sourceAmount"]),
        "destinationAmount": int(row.get("destinationAmount") or 0),
        "hideAmount": bool(row.get("hideAmount", False)),
        "tagIds": [str(item) for item in row.get("tagIds") or []],
        "pictureIds": picture_ids(row),
        "comment": str(row.get("comment") or ""),
    }
    if row.get("geoLocation") is not None:
        payload["geoLocation"] = row["geoLocation"]
    return payload


def fingerprint(row: dict[str, Any]) -> str:
    comparable = {"id": str(row["id"]), **payload_from_row(row)}
    return json.dumps(
        comparable, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )


def list_full_transactions(
    client: EzBookkeepingClient, account_id: str, start_time: int, end_time: int
) -> list[dict[str, Any]]:
    return client.list_transactions(
        account_id, start_time, end_time, with_pictures=True
    )


def get_full_transaction(
    client: EzBookkeepingClient, transaction_id: str
) -> dict[str, Any]:
    result = client._get(
        "/v1/transactions/get.json",
        {
            "id": transaction_id,
            "with_pictures": "true",
            "trim_account": "true",
            "trim_category": "true",
            "trim_tag": "true",
        },
    )
    if not isinstance(result, dict):
        raise ReconcileError(f"transaction {transaction_id} lookup was not an object")
    return result


def adjust_payload_for_bank(
    row: dict[str, Any], bank_amount: int, bank_time: int, account_id: str
) -> dict[str, Any]:
    payload = payload_from_row(row)
    amount = abs(bank_amount)
    payload["time"] = bank_time
    payload["utcOffset"] = 480
    transaction_type = int(row["type"])
    if transaction_type in {2, 3}:
        payload["sourceAmount"] = amount
    elif transaction_type == 4:
        if str(row["sourceAccountId"]) == account_id:
            payload["sourceAmount"] = amount
            if int(row["sourceAmount"]) == int(row.get("destinationAmount") or 0):
                payload["destinationAmount"] = amount
        elif str(row.get("destinationAccountId")) == account_id:
            payload["destinationAmount"] = amount
            if int(row["sourceAmount"]) == int(row.get("destinationAmount") or 0):
                payload["sourceAmount"] = amount
        else:
            raise ReconcileError(f"transaction {row['id']} does not use target account")
    else:
        raise ReconcileError(f"unsupported mutable transaction type {transaction_type}")
    return {"id": str(row["id"]), **payload}


def build_manifest(
    bank_transactions: list[Any],
    rows: list[dict[str, Any]],
    accounts: list[dict[str, Any]],
    account: dict[str, Any],
    fund_account: dict[str, Any],
) -> dict[str, Any]:
    account_id = str(account["id"])
    fund_id = str(fund_account["id"])
    normalized, unsupported = normalize_online_transactions(rows, account_id)
    if unsupported:
        raise ReconcileError("unsupported online rows prevent safe mutation")
    finance = reconcile_finance_aggregations(
        bank_transactions, normalized, account_id, {fund_id}
    )
    regular_online, _ = partition_online_by_period(
        finance.regular_online,
        bank_transactions[0].occurred_at,
        bank_transactions[-1].occurred_at,
        10,
    )
    result = reconcile(finance.regular_bank, regular_online)
    raw_by_id = {str(row["id"]): row for row in rows}

    modifications: list[dict[str, Any]] = []
    for match in result.near_matches:
        row = raw_by_id[match.online.transaction_id]
        if not row.get("editable"):
            raise ReconcileError(f"transaction {row['id']} is not editable")
        after = adjust_payload_for_bank(
            row,
            match.bank.amount_minor,
            int(match.bank.occurred_at.timestamp()),
            account_id,
        )
        modifications.append(
            {
                "id": str(row["id"]),
                "expectedFingerprint": fingerprint(row),
                "before": row,
                "after": after,
                "bank": {
                    "time": int(match.bank.occurred_at.timestamp()),
                    "amount": match.bank.amount_minor,
                    "page": match.bank.page,
                    "row": match.bank.row,
                },
            }
        )

    aggregate_rows = [
        raw_by_id[item.online.transaction_id] for item in finance.aggregations
    ]
    if len(aggregate_rows) != EXPECTED_AGGREGATE_COUNT:
        raise ReconcileError(
            f"expected {EXPECTED_AGGREGATE_COUNT} fund aggregates, found {len(aggregate_rows)}"
        )
    aggregate_total = sum(int(row["sourceAmount"]) for row in aggregate_rows)
    if aggregate_total != EXPECTED_AGGREGATE_TOTAL:
        raise ReconcileError(
            f"expected aggregate total {EXPECTED_AGGREGATE_TOTAL}, found {aggregate_total}"
        )
    if any(not row.get("editable") for row in aggregate_rows):
        raise ReconcileError("at least one fund aggregate is not editable")
    if any((row.get("tagIds") or []) or picture_ids(row) for row in aggregate_rows):
        raise ReconcileError(
            "fund aggregates with tags or pictures cannot be split safely"
        )
    category_counts = Counter(str(row["categoryId"]) for row in aggregate_rows)
    if len(category_counts) != 1:
        raise ReconcileError("fund aggregates use more than one category")
    category_id = next(iter(category_counts))

    finance_bank = [
        transaction
        for aggregation in finance.aggregations
        for transaction in aggregation.bank_transactions
    ] + finance.pending_bank
    by_day: dict[str, list[Any]] = defaultdict(list)
    for transaction in finance_bank:
        by_day[transaction.occurred_at.date().isoformat()].append(transaction)

    creations: list[dict[str, Any]] = []
    manifest_id = str(uuid.uuid4())
    for day, transactions in sorted(by_day.items()):
        amount = -sum(transaction.amount_minor for transaction in transactions)
        occurred_at = max(transaction.occurred_at for transaction in transactions)
        creations.append(
            {
                "kind": "dailyFinance",
                "day": day,
                "bankRows": [
                    {"page": item.page, "row": item.row, "amount": item.amount_minor}
                    for item in transactions
                ],
                "payload": {
                    "type": 4,
                    "categoryId": category_id,
                    "time": int(occurred_at.timestamp()),
                    "utcOffset": 480,
                    "sourceAccountId": account_id,
                    "destinationAccountId": fund_id,
                    "sourceAmount": amount,
                    "destinationAmount": amount,
                    "hideAmount": False,
                    "tagIds": [],
                    "pictureIds": [],
                    "comment": f"{DAILY_FINANCE_PREFIX} {day}",
                    "clientSessionId": f"icbc-{manifest_id}-{day}",
                },
            }
        )

    first = finance.aggregations[0]
    residual = first.online_expense_minor - first.bank_expense_minor
    if residual < 0:
        raise ReconcileError("first partial finance interval has a negative residual")
    if residual:
        first_row = raw_by_id[first.online.transaction_id]
        creations.append(
            {
                "kind": "preStatementResidual",
                "payload": {
                    "type": 4,
                    "categoryId": category_id,
                    "time": int(first.online.occurred_at.timestamp()),
                    "utcOffset": int(first_row.get("utcOffset", 480)),
                    "sourceAccountId": account_id,
                    "destinationAccountId": fund_id,
                    "sourceAmount": residual,
                    "destinationAmount": residual,
                    "hideAmount": False,
                    "tagIds": [],
                    "pictureIds": [],
                    "comment": PRE_STATEMENT_RESIDUAL_COMMENT,
                    "clientSessionId": f"icbc-{manifest_id}-pre-statement-residual",
                },
            }
        )

    deletions = [
        {
            "id": str(row["id"]),
            "expectedFingerprint": fingerprint(row),
            "before": row,
        }
        for row in aggregate_rows
    ]
    return {
        "version": 1,
        "manifestId": manifest_id,
        "createdAt": datetime.now(LOCAL_ZONE).isoformat(),
        "account": account,
        "fundAccount": fund_account,
        "summary": {
            "modifications": len(modifications),
            "dailyFinanceCreations": len(by_day),
            "residualCreations": int(bool(residual)),
            "aggregateDeletions": len(deletions),
            "bankFinanceRows": len(finance_bank),
            "bankFinanceAmount": -sum(item.amount_minor for item in finance_bank),
            "preStatementResidual": residual,
        },
        "modifications": modifications,
        "creations": creations,
        "deletions": deletions,
        "accountSnapshot": accounts,
    }


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def apply_manifest(
    client: EzBookkeepingClient, manifest: dict[str, Any], journal_path: Path
) -> None:
    journal: dict[str, Any] = {
        "manifestId": manifest["manifestId"],
        "startedAt": datetime.now(LOCAL_ZONE).isoformat(),
        "modified": [],
        "created": [],
        "deleted": [],
        "status": "running",
    }
    write_json(journal_path, journal)

    targets = manifest["modifications"] + manifest["deletions"]
    for operation in targets:
        current = get_full_transaction(client, operation["id"])
        if fingerprint(current) != operation["expectedFingerprint"]:
            raise ReconcileError(
                f"transaction {operation['id']} changed after manifest generation"
            )

    try:
        for operation in manifest["modifications"]:
            client._request("POST", "/v1/transactions/modify.json", operation["after"])
            journal["modified"].append(operation["id"])
            write_json(journal_path, journal)

        for operation in manifest["creations"]:
            result = client._request(
                "POST", "/v1/transactions/add.json", operation["payload"]
            )
            journal["created"].append(
                {"kind": operation["kind"], "id": str(result["id"])}
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
        "--manifest", type=Path, default=Path("tmp/工商银行账目调整清单.json")
    )
    parser.add_argument(
        "--backup", type=Path, default=Path("tmp/工商银行账目调整备份.json")
    )
    parser.add_argument(
        "--journal", type=Path, default=Path("tmp/工商银行账目调整执行日志.json")
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
    first_day = datetime.combine(
        bank_transactions[0].occurred_at.date(), time.min, LOCAL_ZONE
    )
    last_day = datetime.combine(
        bank_transactions[-1].occurred_at.date(), time.max, LOCAL_ZONE
    )
    rows = list_full_transactions(
        client,
        str(account["id"]),
        int(first_day.timestamp()),
        int(last_day.timestamp()),
    )
    manifest = build_manifest(
        bank_transactions, rows, accounts, account, fund_matches[0]
    )
    write_json(args.manifest, manifest)
    write_json(
        args.backup,
        {
            "manifestId": manifest["manifestId"],
            "createdAt": manifest["createdAt"],
            "accountSnapshot": manifest["accountSnapshot"],
            "modifiedOriginals": [item["before"] for item in manifest["modifications"]],
            "deletedOriginals": [item["before"] for item in manifest["deletions"]],
        },
    )
    print(json.dumps(manifest["summary"], ensure_ascii=True, sort_keys=True))
    if not args.apply:
        print(f"Dry run only. Manifest: {args.manifest.resolve()}")
        return 0
    apply_manifest(client, manifest, args.journal)
    print(f"Applied. Journal: {args.journal.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
