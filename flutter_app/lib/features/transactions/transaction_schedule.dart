import '../../core/formatting.dart';

String scheduleMonthDays(List<int> days, BookkeepingFormatter formatter) {
  String ordinal(int value) =>
      formatter.text('datetime.monthDayOrdinal.$value');
  String fill(String key, Map<String, String> values) {
    var text = formatter.text('format.misc.$key');
    for (final entry in values.entries) {
      text = text.replaceAll('{${entry.key}}', entry.value);
    }
    return text;
  }

  final sorted = [...days]
    ..sort(
      (a, b) => a.sign != b.sign ? b.sign.compareTo(a.sign) : a.compareTo(b),
    );
  if (sorted.length == 1) {
    final day = sorted.single;
    if (day == -1) return formatter.text('last day');
    return fill(day > 0 ? 'monthDay' : 'lastMonthDayInLowercase', {
      'ordinal': ordinal(day.abs()),
    });
  }
  return fill('monthDays', {
    'multiMonthDays': sorted
        .map(
          (day) => fill(
            day > 0 ? 'eachMonthDayInMonthDays' : 'eachLastMonthDayInMonthDays',
            {'ordinal': ordinal(day.abs())},
          ),
        )
        .join(formatter.text('format.misc.multiTextJoinSeparator')),
  });
}

String scheduleDescription(
  Map<String, dynamic> data,
  BookkeepingFormatter formatter,
) {
  final type = int.tryParse('${data['scheduledFrequencyType']}') ?? 0;
  final days = '${data['scheduledFrequency'] ?? ''}'
      .split(',')
      .map(int.tryParse)
      .whereType<int>()
      .toList();
  final separator = formatter.text('format.misc.multiTextJoinSeparator');
  String fill(String key, String parameter, String value) =>
      formatter.text('format.misc.$key').replaceAll('{$parameter}', value);
  switch (type) {
    case 3:
      return formatter.text('Daily');
    case 5:
      return fill(
        'everyNDays',
        'n',
        formatter.digits('${days.firstOrNull ?? 1}'),
      );
    case 1:
      final firstDay = int.tryParse('${formatter.user['firstDayOfWeek']}') ?? 0;
      days.sort(
        (a, b) => ((a - firstDay + 7) % 7).compareTo((b - firstDay + 7) % 7),
      );
      return fill(
        'everyMultiDaysOfWeek',
        'days',
        days
            .map((day) => formatter.pattern(DateTime(2023, 1, 1 + day), 'dddd'))
            .join(separator),
      );
    case 2:
      return fill(
        'everyMultiDaysOfMonth',
        'days',
        scheduleMonthDays(days, formatter),
      );
    case 4:
      days.sort();
      return fill(
        'everyMultiDaysOfYear',
        'days',
        days
            .map(
              (day) =>
                  formatter.monthDay(DateTime(2024, day ~/ 100, day % 100)),
            )
            .join(separator),
      );
    default:
      return formatter.text('Disabled');
  }
}
