import '../../core/formatting.dart';

/// Original getShiftedDateRange: whole months, anniversary periods, then an
/// exact elapsed-time shift. Month/year additions clamp the day like Moment.
LedgerDateRange shiftStatisticsRange(
  BookkeepingFormatter formatter,
  int minTime,
  int maxTime,
  int scale,
) {
  DateTime fromSeconds(int value) => formatter.localDate(
    DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true),
  );
  int seconds(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;
  DateTime monthsAfter(DateTime value, int months) {
    final first = DateTime(value.year, value.month + months);
    final lastDay = DateTime(first.year, first.month + 1, 0).day;
    return formatter.wallTime(
      first.year,
      first.month,
      value.day > lastDay ? lastDay : value.day,
      value.hour,
      value.minute,
      value.second,
    );
  }

  final start = fromSeconds(minTime);
  final end = fromSeconds(maxTime);
  if (seconds(formatter.wallTime(start.year, start.month, 1)) == minTime &&
      seconds(formatter.wallTime(end.year, end.month + 1, 1)) - 1 == maxTime) {
    final months = (end.year - start.year) * 12 + end.month - start.month + 1;
    final nextStart = monthsAfter(start, months * scale);
    return LedgerDateRange(
      seconds(nextStart),
      seconds(monthsAfter(nextStart, months)) - 1,
    );
  }
  for (final months in [12, 1]) {
    if (seconds(monthsAfter(start, months)) - 1 == maxTime ||
        seconds(monthsAfter(end, -months)) + 1 == minTime) {
      return LedgerDateRange(
        seconds(monthsAfter(start, months * scale)),
        seconds(monthsAfter(end, months * scale)),
      );
    }
  }
  final duration = (maxTime - minTime + 1) * scale;
  return LedgerDateRange(minTime + duration, maxTime + duration);
}
