import 'package:ezbookkeeping/core/widget_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> row(int type, int amount, DateTime date) => {
    'type': type,
    'amount': amount,
    'date': date,
  };

  test(
    'monthly totals remain complete while year-over-year stops at today',
    () {
      final summary = buildWidgetMonthlySummary(
        transactions: [
          row(2, 10000, DateTime(2026, 9, 1)),
          row(2, 4000, DateTime(2026, 9, 20)),
          row(3, 5000, DateTime(2026, 9, 14)),
          row(3, 3000, DateTime(2026, 9, 30)),
          row(2, 8000, DateTime(2025, 9, 10)),
          row(3, 10000, DateTime(2025, 9, 15)),
          row(3, 9000, DateTime(2025, 9, 20)),
          row(4, 999999, DateTime(2026, 9, 15)),
          row(2, 777, DateTime(2026, 8, 31)),
        ],
        now: DateTime(2026, 9, 15),
        dateOf: (item) => item['date'] as DateTime,
        amountOf: (item) => BigInt.from(item['amount'] as int),
      );

      expect(summary.income.current, BigInt.from(14000));
      expect(summary.income.comparisonCurrent, BigInt.from(10000));
      expect(summary.income.previous, BigInt.from(8000));
      expect(summary.income.yearOverYear, '+25%');
      expect(summary.income.trend, 'up');
      expect(summary.expense.current, BigInt.from(8000));
      expect(summary.expense.comparisonCurrent, BigInt.from(5000));
      expect(summary.expense.previous, BigInt.from(10000));
      expect(summary.expense.yearOverYear, '-50%');
      expect(summary.expense.trend, 'down');
      expect(summary.total.current, BigInt.from(6000));
      expect(summary.total.comparisonCurrent, BigInt.from(5000));
      expect(summary.total.previous, BigInt.from(-2000));
      expect(summary.total.yearOverYear, '+350%');
      expect(summary.total.trend, 'up');
    },
  );

  test('zero comparison value is unavailable and refunds remain signed', () {
    final summary = buildWidgetMonthlySummary(
      transactions: [
        row(3, 1000, DateTime(2026, 9, 1)),
        row(3, -250, DateTime(2026, 9, 2)),
      ],
      now: DateTime(2026, 9, 15),
      dateOf: (item) => item['date'] as DateTime,
      amountOf: (item) => BigInt.from(item['amount'] as int),
    );

    expect(summary.expense.current, BigInt.from(750));
    expect(summary.expense.yearOverYear, isNull);
    expect(summary.expense.trend, 'unavailable');
    expect(summary.total.current, BigInt.from(-750));
    expect(summary.total.yearOverYear, isNull);
    expect(summary.total.trend, 'unavailable');
  });

  test('equal cutoff totals report a flat trend', () {
    final summary = buildWidgetMonthlySummary(
      transactions: [
        row(2, 1000, DateTime(2026, 9, 15)),
        row(2, 1000, DateTime(2025, 9, 15)),
      ],
      now: DateTime(2026, 9, 15),
      dateOf: (item) => item['date'] as DateTime,
      amountOf: (item) => BigInt.from(item['amount'] as int),
    );

    expect(summary.income.yearOverYear, '0%');
    expect(summary.income.trend, 'flat');
  });
}
