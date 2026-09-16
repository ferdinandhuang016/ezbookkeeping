# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pdfplumber==0.11.7",
#   "openpyxl==3.1.5",
# ]
# ///

"""Run the reusable ICBC PDF-to-Excel-to-read-only-reconciliation workflow."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from icbc_pdf_to_excel import convert_pdf_to_excel
from icbc_reconcile import ReconcileError
from icbc_reconcile import main as reconcile_main


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--excel-output", type=Path)
    parser.add_argument("--report-output", type=Path)
    parser.add_argument("--base-url", default="https://example.com/")
    parser.add_argument("--username")
    parser.add_argument("--account", default="工资卡")
    parser.add_argument("--fund-account", default="基金账户")
    parser.add_argument("--detail-limit", type=int, default=200)
    parser.add_argument("--time-tolerance", type=int, default=10)
    parser.add_argument("--amount-tolerance-cents", type=int, default=5)
    parser.add_argument("--small-amount-limit-cents", type=int, default=1000)
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--force", action="store_true", help="overwrite output XLSX")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    excel_path = args.excel_output or args.pdf.with_suffix(".xlsx")
    transactions = convert_pdf_to_excel(args.pdf, excel_path, overwrite=args.force)
    print(f"Step 1/2 complete: PDF converted and validated ({len(transactions)} rows)")
    if not args.username:
        print(
            "Step 2/2 skipped: pass --username to generate the read-only online report"
        )
        return 0

    report_path = args.report_output or args.pdf.with_name(
        f"{args.pdf.stem}_核对报告.md"
    )
    reconcile_args = [
        str(excel_path),
        "--base-url",
        args.base_url,
        "--username",
        args.username,
        "--account",
        args.account,
        "--fund-account",
        args.fund_account,
        "--output",
        str(report_path),
        "--detail-limit",
        str(args.detail_limit),
        "--time-tolerance",
        str(args.time_tolerance),
        "--amount-tolerance-cents",
        str(args.amount_tolerance_cents),
        "--small-amount-limit-cents",
        str(args.small_amount_limit_cents),
    ]
    if args.strict:
        reconcile_args.append("--strict")
    result = reconcile_main(reconcile_args)
    print(f"Step 2/2 complete: read-only report written to {report_path.resolve()}")
    return result


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReconcileError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
