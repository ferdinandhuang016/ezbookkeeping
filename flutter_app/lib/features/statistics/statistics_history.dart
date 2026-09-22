import '../../core/api_client.dart';
import '../../core/formatting.dart';

/// Reproduces the server's transaction-day balances and the Web client's gap fill.
/// Balances stop at the last returned day; empty later chart buckets stay empty.
Map<DateTime, Map<String, int>> assetHistoryByDay(
  List<JsonMap> transactions,
  BookkeepingFormatter formatter, {
  int minTime = 0,
  int? maxTime,
  DateTime? now,
}) {
  int value(Object? input) =>
      input is num ? input.toInt() : int.tryParse('$input') ?? 0;
  DateTime day(int seconds) {
    final local = formatter.localDate(
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
    );
    return formatter.wallTime(local.year, local.month, local.day);
  }

  final end = maxTime ?? (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final ordered =
      transactions.where((item) => value(item['time']) <= end).toList()
        ..sort((a, b) => value(a['time']).compareTo(value(b['time'])));
  if (ordered.isEmpty) return {};
  final balances = <String, int>{};
  final beforeStart = <String, int>{};
  final changedDays = <DateTime, Map<String, int>>{};
  for (final item in ordered) {
    final type = value(item['type']);
    if (type == 1 && item['balanceDelta'] == null) {
      throw StateError(
        'Balance adjustment history requires a complete synchronization.',
      );
    }
    final changes = <String, int>{
      '${item['sourceAccountId']}': type == 1
          ? value(item['balanceDelta'])
          : (value(item['sourceAmount']) + (type == 4 ? value(item['serviceCharge']) : 0)) * (type == 3 || type == 4 ? -1 : 1),
      if (type == 4)
        '${item['destinationAccountId']}': value(item['destinationAmount']),
    };
    final time = value(item['time']);
    for (final change in changes.entries) {
      balances[change.key] = (balances[change.key] ?? 0) + change.value;
      if (time < minTime) {
        beforeStart[change.key] = balances[change.key]!;
      } else {
        changedDays.putIfAbsent(day(time), () => {})[change.key] =
            balances[change.key]!;
      }
    }
  }
  final firstTime = value(ordered.first['time']);
  final firstDay = day(minTime > firstTime ? minTime : firstTime);
  for (final balance in beforeStart.entries.where((item) => item.value != 0)) {
    changedDays
        .putIfAbsent(firstDay, () => {})
        .putIfAbsent(balance.key, () => balance.value);
  }
  if (changedDays.isEmpty) return {};
  final dates = changedDays.keys.toList()..sort();
  final result = <DateTime, Map<String, int>>{};
  final carry = <String, int>{};
  for (
    var date = dates.first;
    !date.isAfter(dates.last);
    date = formatter.wallTime(date.year, date.month, date.day + 1)
  ) {
    carry.addAll(changedDays[date] ?? {});
    result[date] = {...carry};
  }
  return result;
}
