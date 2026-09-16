import 'package:flutter/widgets.dart';
import 'package:timezone/timezone.dart' as tz;

import 'money.dart';

typedef FormattingMap = Map<String, dynamic>;

/// Keeps the original application's pixel increments and Android accessibility
/// scaling. The preference is an enum (0..6), not a multiplier.
class BookkeepingTextScaler extends TextScaler {
  const BookkeepingTextScaler({
    required this.system,
    required this.fontSizeType,
  });
  final TextScaler system;
  final int fontSizeType;
  static const increments = [-1.0, 0.0, 1.0, 2.0, 3.0, 5.0, 7.0];
  @override
  double scale(double fontSize) => system.scale(
    (fontSize + increments[fontSizeType.clamp(0, 6)]).clamp(1, double.infinity),
  );
  @override
  double get textScaleFactor => scale(14) / 14;
  @override
  bool operator ==(Object other) =>
      other is BookkeepingTextScaler &&
      system == other.system &&
      fontSizeType == other.fontSizeType;
  @override
  int get hashCode => Object.hash(system, fontSizeType);
}

class LedgerDateRange {
  const LedgerDateRange(this.minTime, this.maxTime);
  final int minTime;
  final int maxTime;
  bool contains(int seconds) =>
      (minTime == 0 || seconds >= minTime) &&
      (maxTime == 0 || seconds <= maxTime);
}

/// Source: src/core/{numeral,currency,datetime,calendar,fiscalyear}.ts,
/// src/lib/{numeral,currency,datetime}.ts and original locale resources.
/// All amounts are integer hundredths; aggregate display has no transaction cap.
class BookkeepingFormatter {
  const BookkeepingFormatter({
    required this.user,
    required this.settings,
    required this.messages,
    required this.reference,
    required this.language,
  });
  final FormattingMap user, settings, messages, reference;
  final String language;

  BookkeepingFormatter copyWith({
    FormattingMap? user,
    FormattingMap? settings,
  }) => BookkeepingFormatter(
    user: user ?? this.user,
    settings: settings ?? this.settings,
    messages: messages,
    reference: reference,
    language: language,
  );

  static const _numerals = [
    'WesternArabicNumerals',
    'EasternArabicNumerals',
    'PersianDigits',
    'BurmeseNumerals',
    'DevanagariNumerals',
  ];
  static const _zeroes = [0x30, 0x660, 0x6f0, 0x1040, 0x966];
  static const _currencyModes = [
    'None',
    'SymbolBeforeAmount',
    'SymbolAfterAmount',
    'SymbolBeforeAmountWithoutSpace',
    'SymbolAfterAmountWithoutSpace',
    'CodeBeforeAmount',
    'CodeAfterAmount',
    'UnitBeforeAmount',
    'UnitAfterAmount',
    'NameBeforeAmount',
    'NameAfterAmount',
  ];
  static const _dates = ['YearMonthDay', 'MonthDayYear', 'DayMonthYear'];

  dynamic _message(String path) {
    dynamic result = messages;
    for (final part in path.split('.')) {
      result = result is Map ? result[part] : null;
    }
    return result;
  }

  String text(String path, [String? fallback]) =>
      _message(path)?.toString() ?? fallback ?? path;
  String _choice(String key, List<String> names, String fallback) {
    final value = int.tryParse('${user[key]}') ?? 0;
    if (value > 0 && value <= names.length) return names[value - 1];
    final name = text('default.$key', fallback);
    return names.contains(name) ? name : fallback;
  }

  int get numeralSystem =>
      _numerals.indexOf(_choice('numeralSystem', _numerals, _numerals[0])) + 1;
  String get decimalSeparator =>
      _choice('decimalSeparator', ['Dot', 'Comma'], 'Dot') == 'Comma'
      ? ','
      : '.';
  String get digitGroupingSymbol => switch (_choice('digitGroupingSymbol', [
    'Dot',
    'Comma',
    'Space',
    'Apostrophe',
  ], 'Comma')) {
    'Dot' => '.',
    'Space' => ' ',
    'Apostrophe' => "'",
    _ => ',',
  };
  int get digitGrouping =>
      ['None', 'ThousandsSeparator', 'IndianNumberGrouping'].indexOf(
        _choice('digitGrouping', [
          'None',
          'ThousandsSeparator',
          'IndianNumberGrouping',
        ], 'ThousandsSeparator'),
      ) +
      1;
  int get dateDisplayType =>
      ['Gregorian', 'Buddhist', 'Persian'].indexOf(
        _choice('dateDisplayType', [
          'Gregorian',
          'Buddhist',
          'Persian',
        ], 'Gregorian'),
      ) +
      1;
  int get calendarDisplayType =>
      [
        'Gregorian',
        'Buddhist',
        'GregorianWithChinese',
        'GregorianWithPersian',
      ].indexOf(
        _choice('calendarDisplayType', [
          'Gregorian',
          'Buddhist',
          'GregorianWithChinese',
          'GregorianWithPersian',
        ], 'Gregorian'),
      ) +
      1;
  String get defaultCurrency =>
      '${user['defaultCurrency'] ?? text('default.currency', 'USD')}';
  int get firstDayOfWeek =>
      int.tryParse('${user['firstDayOfWeek']}') ??
      [
        'Sunday',
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
      ].indexOf(text('default.firstDayOfWeek', 'Sunday'));

  String digits(String value) {
    final zero = _zeroes[numeralSystem - 1];
    return String.fromCharCodes(
      value.runes.map((r) => r >= 48 && r <= 57 ? r - 48 + zero : r),
    );
  }

  static String westernDigits(String value) => String.fromCharCodes(
    value.runes.map((r) {
      for (final zero in _zeroes) {
        if (r >= zero && r < zero + 10) return r - zero + 48;
      }
      return r;
    }),
  );

  String _group(String integer) {
    if (digitGrouping == 1) return integer;
    final parts = <String>[];
    var end = integer.length, size = 3;
    while (end > size) {
      parts.insert(0, integer.substring(end - size, end));
      end -= size;
      if (digitGrouping == 3) size = 2;
    }
    parts.insert(0, integer.substring(0, end));
    return parts.join(digitGroupingSymbol);
  }

  /// No rounding or loss of cents for zero-fraction currencies (same as Web).
  String amount(
    dynamic cents, {
    String? currency,
    bool showCurrency = true,
    bool signed = false,
    bool grouping = true,
    bool trimTailZero = false,
  }) {
    final code = currency ?? defaultCurrency;
    final info = (reference['currencies'] as List? ?? [])
        .cast<Map>()
        .where((c) => c['code'] == code)
        .firstOrNull;
    final hidden = cents == '***';
    final value = hidden ? BigInt.zero : BigInt.parse('$cents');
    var numeric = '***';
    if (!hidden) {
      final raw = value.abs().toString().padLeft(3, '0');
      final integer = raw.substring(0, raw.length - 2);
      var fraction = raw.substring(raw.length - 2);
      final count = int.tryParse('${info?['fraction']}') ?? 2;
      if (count == 0 && fraction == '00') {
        fraction = '';
      } else if (count < 2 && fraction.endsWith('0')) {
        fraction = fraction.substring(0, 1);
      }
      if (trimTailZero) {
        fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
      }
      numeric = digits(
        '${value.isNegative
            ? '-'
            : signed && value > BigInt.zero
            ? '+'
            : ''}'
        '${grouping ? _group(integer) : integer}${fraction.isEmpty ? '' : '$decimalSeparator$fraction'}',
      );
    }
    if (!showCurrency || code.isEmpty) return numeric;
    final mode =
        _currencyModes.indexOf(
          _choice('currencyDisplayType', _currencyModes, 'SymbolBeforeAmount'),
        ) +
        1;
    if (mode == 1) return numeric;
    final plural = hidden || value.abs() != BigInt.from(100);
    String symbol;
    if (mode <= 5) {
      symbol =
          '${(plural ? info?['symbol']?['plural'] : null) ?? info?['symbol']?['normal'] ?? '¤'}';
    } else if (mode <= 7) {
      symbol = code;
    } else if (mode <= 9) {
      symbol = text(
        'currency.unit.${info?['unit']}.${plural ? 'plural' : 'normal'}',
        '${info?['unit'] ?? ''}',
      );
    } else {
      symbol = text('currency.name.$code', code);
    }
    if (symbol.isEmpty) return numeric;
    final separator = mode == 4 || mode == 5 ? '' : ' ';
    return [2, 4, 6, 8, 10].contains(mode)
        ? '$symbol$separator$numeric'
        : '$numeric$separator$symbol';
  }

  String normalizeAmountInput(String text) {
    var value = westernDigits(text.trim()).replaceAll('−', '-');
    if (digitGroupingSymbol != decimalSeparator) {
      value = digitGroupingSymbol == ' '
          ? value.replaceAll(RegExp('[ \u00a0\u202f\u2007]'), '')
          : value.replaceAll(digitGroupingSymbol, '');
    }
    value = value.replaceAll(decimalSeparator, '.');
    if (value.startsWith('.')) value = '0$value';
    if (value.startsWith('-.')) value = value.replaceFirst('-.', '-0.');
    return value;
  }

  int parseAmount(String text) => Money.parse(normalizeAmountInput(text));
  String amountInput(dynamic cents) =>
      amount(cents, showCurrency: false, grouping: false);

  /// Rate values are already decimal strings, unlike amounts in hundredths.
  String decimal(String value, {bool grouping = true}) {
    if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(value)) {
      throw const FormatException('Invalid decimal');
    }
    final negative = value.startsWith('-');
    final parts = value.replaceFirst('-', '').split('.');
    return digits(
      '${negative ? '-' : ''}${grouping ? _group(parts[0]) : parts[0]}'
      '${parts.length > 1 ? '$decimalSeparator${parts[1]}' : ''}',
    );
  }

  /// Decimal rational conversion, rounded half away from zero. Only transaction
  /// validation applies maxAmount; account sums and statistics can exceed it.
  static BigInt convertAggregate(
    dynamic cents,
    String fromRate,
    String toRate, {
    bool truncate = false,
  }) {
    (BigInt, BigInt) rate(String text) {
      if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(text)) {
        throw const FormatException('Invalid exchange rate');
      }
      final parts = text.split('.');
      final n = BigInt.parse(parts.join());
      if (n <= BigInt.zero) {
        throw const FormatException('Invalid exchange rate');
      }
      return (n, BigInt.from(10).pow(parts.length == 2 ? parts[1].length : 0));
    }

    final from = rate(fromRate),
        to = rate(toRate),
        value = BigInt.parse('$cents');
    final numerator = value.abs() * to.$1 * from.$2;
    final denominator = to.$2 * from.$1;
    final result = truncate
        ? numerator ~/ denominator
        : (numerator * BigInt.two + denominator) ~/ (denominator * BigInt.two);
    return value.isNegative ? -result : result;
  }

  tz.Location? get location {
    final name = '${settings['timeZone'] ?? ''}';
    if (name.isEmpty) return null;
    try {
      return tz.getLocation(name);
    } on tz.LocationNotFoundException {
      return null;
    }
  }

  DateTime localDate(DateTime instant) {
    final zone = location;
    return zone == null ? instant.toLocal() : tz.TZDateTime.from(instant, zone);
  }

  DateTime wallTime(
    int year,
    int month,
    int day, [
    int hour = 0,
    int minute = 0,
    int second = 0,
  ]) {
    final zone = location;
    return zone == null
        ? DateTime(year, month, day, hour, minute, second)
        : tz.TZDateTime(zone, year, month, day, hour, minute, second);
  }

  DateTime transactionDate(Map item, {bool originalTimezone = true}) {
    final time = DateTime.fromMillisecondsSinceEpoch(
      (int.tryParse('${item['time']}') ?? 0) * 1000,
      isUtc: true,
    );
    if (!originalTimezone) return localDate(time);
    return time.add(
      Duration(minutes: int.tryParse('${item['utcOffset']}') ?? 0),
    );
  }

  Map get _locale =>
      reference['locales']?[language] ?? reference['locales']?['en'] ?? {};
  Map get _chineseLocale =>
      reference['chinese']?['locales']?[language] ??
      reference['chinese']?['locales']?['zh-Hans'] ??
      {};

  /// Supported Chinese range exactly matches the HKO tables bundled by Web.
  ({int year, int month, int day, bool leap, String solarTerm})? chineseDate(
    DateTime date,
  ) {
    final data = reference['chinese'] as Map?;
    if (data == null ||
        date.year < data['minYear'] ||
        date.year > data['maxYear']) {
      return null;
    }
    final epoch = (data['epoch'] as List).cast<int>();
    var remaining = DateTime.utc(
      date.year,
      date.month,
      date.day,
    ).difference(DateTime.utc(epoch[0], epoch[1], epoch[2])).inDays;
    if (remaining < 0) return null;
    final years = (data['years'] as List).cast<int>();
    String term = '';
    final solar = '${data['solarTerms'][date.year - data['minYear']]}';
    for (var i = (date.month - 1) * 2; i < date.month * 2; i++) {
      if (int.parse(solar[i], radix: 36) == date.day) {
        term = '${_chineseLocale['solarTermNames'][i]}';
      }
    }
    for (var y = 0; y < years.length; y++) {
      final bits = years[y], leap = (bits >> 1) & 15;
      for (var m = 1; m <= 12; m++) {
        final days = ((bits >> (17 - m)) & 1) == 1 ? 30 : 29;
        if (remaining < days) {
          return (
            year: data['minYear'] + y as int,
            month: m,
            day: remaining + 1,
            leap: false,
            solarTerm: term,
          );
        }
        remaining -= days;
        if (m == leap) {
          final days = bits & 1 == 1 ? 30 : 29;
          if (remaining < days) {
            return (
              year: data['minYear'] + y as int,
              month: m,
              day: remaining + 1,
              leap: true,
              solarTerm: term,
            );
          }
          remaining -= days;
        }
      }
    }
    return null;
  }

  ({int year, int month, int day})? persianDate(DateTime date) {
    final data = reference['persian'] as Map?;
    if (data == null) return null;
    final days = (data['newYearMarchDays'] as List).cast<int>();
    var year = date.year - 621;
    DateTime? start(int y) {
      final i = y - (data['minYear'] as int);
      return i >= 0 && i < days.length
          ? DateTime.utc(y + 621, 3, days[i])
          : null;
    }

    final day = DateTime.utc(date.year, date.month, date.day);
    var first = start(year);
    if (first == null) return null;
    if (day.isBefore(first)) {
      year--;
      first = start(year);
    }
    if (first == null) return null;
    final offset = day.difference(first).inDays;
    return offset < 186
        ? (year: year, month: offset ~/ 31 + 1, day: offset % 31 + 1)
        : (
            year: year,
            month: (offset - 186) ~/ 30 + 7,
            day: (offset - 186) % 30 + 1,
          );
  }

  String pattern(DateTime date, String format, {int? calendar}) {
    final cal = calendar ?? dateDisplayType;
    final persian = cal == 3 ? persianDate(date) : null;
    final year = cal == 2 ? date.year + 543 : persian?.year ?? date.year;
    final month = persian?.month ?? date.month, day = persian?.day ?? date.day;
    String list(Map source, String key, int index, String fallback) =>
        source[key] is List && index < (source[key] as List).length
        ? '${source[key][index]}'
        : fallback;
    final monthData = persian != null ? reference['persian'] as Map : _locale;
    var meridiem = date.hour < 12 ? 'AM' : 'PM';
    for (final entry in _locale['meridiem'] as List? ?? []) {
      if (date.hour * 60 + date.minute >= entry[0]) meridiem = '${entry[1]}';
    }
    String padded(int n, int width) => digits(n.toString().padLeft(width, '0'));
    final tokens = <String, String>{
      'YYYY': padded(year, 4),
      'YY': padded(year % 100, 2),
      'MMMM': list(
        monthData,
        persian != null ? 'monthNames' : 'months',
        month - 1,
        '$month',
      ),
      'MMM': list(
        monthData,
        persian != null ? 'monthShortNames' : 'monthsShort',
        month - 1,
        '$month',
      ),
      'MM': padded(month, 2),
      'M': digits('$month'),
      'DD': padded(day, 2),
      'D': digits('$day'),
      'dddd': list(_locale, 'weekdays', date.weekday % 7, '${date.weekday}'),
      'ddd': list(
        _locale,
        'weekdaysShort',
        date.weekday % 7,
        '${date.weekday}',
      ),
      'dd': list(_locale, 'weekdaysMin', date.weekday % 7, '${date.weekday}'),
      'HH': padded(date.hour, 2),
      'H': digits('${date.hour}'),
      'hh': padded((date.hour + 11) % 12 + 1, 2),
      'h': digits('${(date.hour + 11) % 12 + 1}'),
      'mm': padded(date.minute, 2),
      'm': digits('${date.minute}'),
      'ss': padded(date.second, 2),
      's': digits('${date.second}'),
      'A': meridiem,
      'Z': digits(
        '${date.timeZoneOffset.isNegative ? '-' : '+'}${(date.timeZoneOffset.inMinutes.abs() ~/ 60).toString().padLeft(2, '0')}:${(date.timeZoneOffset.inMinutes.abs() % 60).toString().padLeft(2, '0')}',
      ),
    };
    return format.replaceAllMapped(
      RegExp('YYYY|MMMM|dddd|MMM|ddd|YY|MM|DD|dd|HH|hh|mm|ss|M|D|H|h|m|s|A|Z'),
      (m) => tokens[m[0]]!,
    );
  }

  String date(
    DateTime date, {
    bool long = false,
    bool withTime = false,
    bool withSeconds = false,
  }) {
    final key = long ? 'longDate' : 'shortDate';
    final choice = _choice('${key}Format', _dates, 'YearMonthDay');
    final result = pattern(date, text('format.$key.$choice', 'YYYY-M-D'));
    return withTime
        ? '$result ${time(date, withSeconds: withSeconds)}'
        : result;
  }

  String month(DateTime date, {bool short = false}) {
    final order = _choice(
      '${short ? 'short' : 'long'}DateFormat',
      _dates,
      'YearMonthDay',
    );
    return pattern(
      date,
      text('format.${short ? 'short' : 'long'}YearMonth.$order', 'YYYY-MM'),
    );
  }

  String year(DateTime date) => pattern(
    date,
    text(
      'format.longYear.${_choice('longDateFormat', _dates, 'YearMonthDay')}',
      'YYYY',
    ),
  );
  String monthName(DateTime date) => pattern(date, 'MMMM');
  String monthDay(DateTime date) => pattern(
    date,
    text(
      'format.longMonthDay.${_choice('longDateFormat', _dates, 'YearMonthDay')}',
      'MMMM D',
    ),
  );

  String time(DateTime date, {bool withSeconds = false, bool? seconds}) {
    withSeconds = seconds ?? withSeconds;
    return pattern(date, timePattern(withSeconds: withSeconds));
  }

  String timePattern({bool withSeconds = false}) {
    final key = withSeconds ? 'longTime' : 'shortTime';
    final names = withSeconds
        ? [
            'HourMinuteSecond',
            'MeridiemIndicatorHourMinuteSecond',
            'HourMinuteSecondMeridiemIndicator',
          ]
        : [
            'HourMinute',
            'MeridiemIndicatorHourMinute',
            'HourMinuteMeridiemIndicator',
          ];
    return text(
      'format.$key.${_choice('${key}Format', names, names.first)}',
      withSeconds ? 'HH:mm:ss' : 'HH:mm',
    );
  }

  String calendarDate(DateTime date, {bool alternate = false}) {
    if (!alternate) {
      return pattern(date, 'D', calendar: calendarDisplayType == 2 ? 2 : 1);
    }
    if (calendarDisplayType == 3) {
      final value = chineseDate(date);
      if (value == null) return '';
      if (value.solarTerm.isNotEmpty) return value.solarTerm;
      return value.day == 1
          ? '${value.leap ? _chineseLocale['leapMonthPrefix'] : ''}${_chineseLocale['monthNames'][value.month - 1]}'
          : '${_chineseLocale['dayNames'][value.day - 1]}';
    }
    if (calendarDisplayType == 4) {
      final value = persianDate(date);
      if (value == null) return '';
      return value.day == 1
          ? '${reference['persian']['monthShortNames'][value.month - 1]}'
          : digits('${value.day}');
    }
    return '';
  }

  (int, int) get _fiscalStart {
    final value = int.tryParse('${user['fiscalYearStart']}') ?? 257;
    final month = (value >> 8) & 255, day = value & 255;
    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        day > DateTime.utc(2001, month + 1, 0).day) {
      return (1, 1);
    }
    return (month, day);
  }

  DateTime fiscalYearStart(DateTime date) {
    final (month, day) = _fiscalStart;
    return wallTime(
      date.month < month || (date.month == month && date.day < day)
          ? date.year - 1
          : date.year,
      month,
      day,
    );
  }

  String fiscalYear(DateTime date) {
    final start = fiscalYearStart(date), january = _fiscalStart == (1, 1);
    final offset = dateDisplayType == 2 ? 543 : 0;
    final first = start.year + offset, last = first + (january ? 0 : 1);
    final mode = _choice('fiscalYearFormat', [
      'StartYYYY_EndYYYY',
      'StartYYYY_EndYY',
      'StartYY_EndYY',
      'EndYYYY',
      'EndYY',
    ], 'EndYYYY');
    return text('format.fiscalYear.$mode', 'FY {EndYYYY}')
        .replaceAll('{StartYYYY}', digits('$first'))
        .replaceAll('{EndYYYY}', digits('$last'))
        .replaceAll(
          '{StartYY}',
          digits((first % 100).toString().padLeft(2, '0')),
        )
        .replaceAll('{EndYY}', digits((last % 100).toString().padLeft(2, '0')));
  }

  /// Boundaries are built as local civil dates, never by adding 24h through DST.
  LedgerDateRange? dateRange(
    int type, {
    DateTime? now,
    int? statementDay,
    int? lastReconciledTime,
  }) {
    if (type == 0) return const LedgerDateRange(0, 0);
    final d = localDate(now ?? DateTime.now());
    DateTime at(int y, int m, int day) => wallTime(y, m, day);
    final today = at(d.year, d.month, d.day),
        tomorrow = at(d.year, d.month, d.day + 1);
    DateTime start = today, end = tomorrow;
    switch (type) {
      case 1:
        break;
      case 2:
        start = at(d.year, d.month, d.day - 1);
        end = today;
      case 3:
        start = at(d.year, d.month, d.day - 6);
      case 4:
        start = at(d.year, d.month, d.day - 29);
      case 5 || 6:
        final day =
            d.day -
            (d.weekday % 7 - firstDayOfWeek + 7) % 7 -
            (type == 6 ? 7 : 0);
        start = at(d.year, d.month, day);
        end = at(d.year, d.month, day + 7);
      case 7 || 8:
        final month = d.month - (type == 8 ? 1 : 0);
        start = at(d.year, month, 1);
        end = at(d.year, month + 1, 1);
      case 9 || 10:
        final year = d.year - (type == 10 ? 1 : 0);
        start = at(year, 1, 1);
        end = at(year + 1, 1, 1);
      case 11 || 12:
        final current = fiscalYearStart(d),
            year = current.year - (type == 12 ? 1 : 0);
        start = at(year, current.month, current.day);
        end = at(year + 1, current.month, current.day);
      case 101 || 102 || 103:
        final months = {101: 12, 102: 24, 103: 36}[type]!;
        start = at(d.year, d.month - months + 1, 1);
        end = at(d.year, d.month + 1, 1);
      case 104 || 105 || 106:
        final years = {104: 2, 105: 3, 106: 5}[type]!;
        start = at(d.year - years + 1, 1, 1);
        end = at(d.year + 1, 1, 1);
      case 51 || 52:
        if (statementDay == null || statementDay < 1 || statementDay > 31) {
          return dateRange(type == 51 ? 7 : 8, now: now);
        }
        // Keep Web's moment.date() overflow before its clamped month shift.
        // E.g. a February 31 statement first becomes March 3 in a common year.
        DateTime shiftMonth(DateTime value, int months) {
          final first = at(value.year, value.month + months, 1);
          final last = DateTime.utc(first.year, first.month + 1, 0).day;
          return wallTime(
            first.year,
            first.month,
            value.day.clamp(1, last),
            value.hour,
            value.minute,
            value.second,
          );
        }
        final anchor = at(d.year, d.month, statementDay);
        final following = at(anchor.year, anchor.month, anchor.day + 1);
        final last = localDate(
          DateTime.fromMillisecondsSinceEpoch(
            following.millisecondsSinceEpoch - 1000,
            isUtc: true,
          ),
        );
        start = d.day <= statementDay ? shiftMonth(following, -1) : following;
        var finalSecond = d.day <= statementDay ? last : shiftMonth(last, 1);
        if (type == 52) {
          start = shiftMonth(start, -1);
          finalSecond = shiftMonth(finalSecond, -1);
        }
        return LedgerDateRange(
          start.millisecondsSinceEpoch ~/ 1000,
          finalSecond.millisecondsSinceEpoch ~/ 1000,
        );
      case 71:
        if (lastReconciledTime == null || lastReconciledTime <= 0) return null;
        return LedgerDateRange(
          lastReconciledTime,
          tomorrow.millisecondsSinceEpoch ~/ 1000 - 1,
        );
      default:
        return null;
    }
    return LedgerDateRange(
      start.millisecondsSinceEpoch ~/ 1000,
      end.millisecondsSinceEpoch ~/ 1000 - 1,
    );
  }

  String profileOptionPreview(String key, int value, DateTime now) {
    final fmt = copyWith(user: {...user, key: value});
    if (key == 'longDateFormat') return fmt.date(now, long: true);
    if (key == 'shortDateFormat' || key == 'dateDisplayType') {
      return fmt.date(now);
    }
    if (key == 'longTimeFormat' || key == 'shortTimeFormat') {
      return fmt.time(now, withSeconds: key == 'longTimeFormat');
    }
    if (key == 'fiscalYearFormat') return fmt.fiscalYear(now);
    if (key == 'calendarDisplayType') {
      return '${fmt.calendarDate(now)} ${fmt.calendarDate(now, alternate: true)}'
          .trim();
    }
    return fmt.amount(123456789);
  }
}

/// Vue i18n named/list substitutions and pipe plural choices. Resource fallback
/// happens before interpolation; missing keys remain visible for translation.
String translateMessage(
  Map messages,
  Map fallback,
  String key, {
  Map<String, dynamic> parameters = const {},
  int? plural,
}) {
  dynamic lookup(Map map) {
    if (map[key] is String) return map[key];
    dynamic value = map;
    for (final part in key.split('.')) {
      value = value is Map ? value[part] : null;
    }
    if (value is String) return value;
    // The existing UI uses unqualified leaf keys; prefer an exact path above.
    for (final child in map.values.whereType<Map>()) {
      final value = lookup(child);
      if (value != null) return value;
    }
    return null;
  }

  var result = (lookup(messages) ?? lookup(fallback) ?? key).toString();
  final values = {...parameters, 'count': ?plural, 'n': ?plural};
  if (plural != null && result.contains('|')) {
    final forms = result.split('|');
    final n = plural.abs();
    final index = forms.length == 2
        ? (n == 1 ? 0 : 1)
        : (n == 0
              ? 0
              : n == 1
              ? 1
              : 2);
    result = forms[index.clamp(0, forms.length - 1)].trim();
  }
  return result.replaceAllMapped(
    RegExp(r"\{(?:'([^']*)'|([\w]+))\}"),
    (m) => m[1] ?? (values.containsKey(m[2]) ? '${values[m[2]]}' : m[0]!),
  );
}
