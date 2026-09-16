import 'aggregate_amount.dart';

typedef WidgetTransactionDate = DateTime Function(Map<String, dynamic> item);
typedef WidgetTransactionAmount = BigInt Function(Map<String, dynamic> item);

class WidgetPeriodValues {
  const WidgetPeriodValues({
    required this.current,
    required this.comparisonCurrent,
    required this.previous,
  });

  final BigInt current;
  final BigInt comparisonCurrent;
  final BigInt previous;

  String? get yearOverYear {
    if (previous == BigInt.zero) return null;
    final percent = aggregatePercent(
      comparisonCurrent - previous,
      previous.abs(),
      precision: 1,
    );
    return comparisonCurrent > previous ? '+$percent%' : '$percent%';
  }

  String get trend => previous == BigInt.zero
      ? 'unavailable'
      : comparisonCurrent > previous
      ? 'up'
      : comparisonCurrent < previous
      ? 'down'
      : 'flat';
}

class WidgetMonthlySummary {
  const WidgetMonthlySummary({
    required this.income,
    required this.expense,
    required this.total,
  });

  final WidgetPeriodValues income;
  final WidgetPeriodValues expense;
  final WidgetPeriodValues total;
}

WidgetMonthlySummary buildWidgetMonthlySummary({
  required Iterable<Map<String, dynamic>> transactions,
  required DateTime now,
  required WidgetTransactionDate dateOf,
  required WidgetTransactionAmount amountOf,
}) {
  var income = BigInt.zero;
  var comparisonIncome = BigInt.zero;
  var previousIncome = BigInt.zero;
  var expense = BigInt.zero;
  var comparisonExpense = BigInt.zero;
  var previousExpense = BigInt.zero;

  for (final item in transactions) {
    final type = int.tryParse('${item['type']}') ?? 0;
    if (type != 2 && type != 3) continue;
    final date = dateOf(item);
    final current = date.year == now.year && date.month == now.month;
    final comparisonCurrent = current && date.day <= now.day;
    final previous =
        date.year == now.year - 1 &&
        date.month == now.month &&
        date.day <= now.day;
    if (!current && !previous) continue;
    final amount = amountOf(item);
    if (type == 2) {
      if (current) income += amount;
      if (comparisonCurrent) comparisonIncome += amount;
      if (previous) previousIncome += amount;
    } else {
      if (current) expense += amount;
      if (comparisonCurrent) comparisonExpense += amount;
      if (previous) previousExpense += amount;
    }
  }

  return WidgetMonthlySummary(
    income: WidgetPeriodValues(
      current: income,
      comparisonCurrent: comparisonIncome,
      previous: previousIncome,
    ),
    expense: WidgetPeriodValues(
      current: expense,
      comparisonCurrent: comparisonExpense,
      previous: previousExpense,
    ),
    total: WidgetPeriodValues(
      current: income - expense,
      comparisonCurrent: comparisonIncome - comparisonExpense,
      previous: previousIncome - previousExpense,
    ),
  );
}
