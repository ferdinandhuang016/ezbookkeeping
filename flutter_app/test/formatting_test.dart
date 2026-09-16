import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;

import 'package:ezbookkeeping/core/formatting.dart';

void main() {
  tz.initializeTimeZones();
  final reference = jsonDecode(
    File('assets/reference/formatting.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final fixtures = jsonDecode(
    File('test/formatting_fixtures.json').readAsStringSync(),
  );
  BookkeepingFormatter formatter({
    String language = 'en',
    Map<String, dynamic> user = const {},
    Map<String, dynamic> settings = const {},
  }) => BookkeepingFormatter(
    user: user,
    settings: settings,
    language: language,
    reference: reference,
    messages: jsonDecode(
      File('assets/locales/${language.replaceAll('-', '_')}.json')
          .readAsStringSync(),
    ),
  );

  test(
    'all numeral systems and grouping styles match original Web fixtures',
    () {
      for (final item in fixtures['amounts']) {
        final fmt = formatter(
          user: {
            'numeralSystem': item['system'],
            'digitGrouping': item['grouping'],
            'decimalSeparator': 2,
            'digitGroupingSymbol': 3,
          },
        );
        expect(
          fmt.amount(item['value'], showCurrency: false),
          item['expected'],
        );
      }
    },
  );
  test(
    'eleven currency modes, plural units, fractions and localized inputs',
    () {
      const expected = [
        '1,234.56',
        r'$ 1,234.56',
        r'1,234.56 $',
        r'$1,234.56',
        r'1,234.56$',
        'USD 1,234.56',
        '1,234.56 USD',
        'Dollars 1,234.56',
        '1,234.56 Dollars',
        'United States Dollar 1,234.56',
        '1,234.56 United States Dollar',
      ];
      for (var mode = 1; mode <= 11; mode++) {
        expect(
          formatter(user: {'currencyDisplayType': mode})
              .amount(123456, currency: 'USD'),
          expected[mode - 1],
        );
      }
      final fmt = formatter(user: {'currencyDisplayType': 8});
      expect(fmt.amount(-100, currency: 'USD'), 'Dollar -1.00');
      expect(fmt.amount(100, currency: 'JPY'), 'Yen 1');
      expect(fmt.amount(101, currency: 'JPY'), 'Yen 1.01');
      expect(fmt.amount(110, currency: 'JPY'), 'Yen 1.1');
      final comma = formatter(language: 'de', user: {'numeralSystem': 3});
      expect(comma.parseAmount('۱.۲۳۴,۵۶'), 123456);
      expect(comma.parseAmount('-,۵۰'), -50);
      expect(() => comma.parseAmount('۱,۲۳۴'), throwsFormatException);
      expect(formatter().parseAmount('9,999,999,999,999.99'), 999999999999999);
      expect(
        () => formatter().parseAmount('10,000,000,000,000.00'),
        throwsFormatException,
      );
    },
  );
  test('aggregate display and decimal rate conversion never use binary floats or transaction limits', () {
    expect(
      formatter().amount('123456789012345678901', showCurrency: false),
      '1,234,567,890,123,456,789.01',
    );
    expect(
      BookkeepingFormatter.convertAggregate(
        '99999999999999999',
        '1',
        '1.00000000000000001',
      ),
      BigInt.parse('100000000000000000'),
    );
    expect(
      BookkeepingFormatter.convertAggregate(-1, '2', '1'),
      BigInt.from(-1),
    );
    expect(BookkeepingFormatter.convertAggregate(1, '3', '1'), BigInt.zero);
    expect(
      () => BookkeepingFormatter.convertAggregate(100, '0', '1'),
      throwsFormatException,
    );
  });
  test('Chinese calendar HKO dates, leap months, solar terms match original functions', () {
    final fmt = formatter(language: 'zh-Hans');
    for (final item in fixtures['chinese']) {
      final d = item['date'], expected = item['expected'];
      final actual = fmt.chineseDate(DateTime.utc(d[0], d[1], d[2]));
      expect(actual, isNotNull);
      expect(
        [actual!.year, actual.month, actual.day, actual.leap, actual.solarTerm],
        [
          expected['year'],
          expected['month'],
          expected['day'],
          expected['isLeapMonth'],
          expected['solarTermName'],
        ],
      );
    }
    expect(fmt.chineseDate(DateTime.utc(1999, 1, 1)), isNull);
    expect(fmt.chineseDate(DateTime.utc(2101, 1, 1)), isNull);
    expect(
      fmt
          .copyWith(user: {'calendarDisplayType': 3})
          .calendarDate(DateTime.utc(2023, 3, 22), alternate: true),
      '闰二月',
    );
  });
  test('Persian leap and new year dates match the existing jalaali-js implementation', () {
    for (final item in fixtures['persian']) {
      final d = item['date'], expected = item['expected'];
      final actual = formatter().persianDate(DateTime.utc(d[0], d[1], d[2]));
      expect(
        [actual!.year, actual.month, actual.day],
        [expected['jy'], expected['jm'], expected['jd']],
      );
    }
  });
  test('locale date defaults, Buddhist/Persian display and original meridiem labels', () {
    final date = DateTime.utc(2024, 3, 20, 13, 5, 9);
    expect(formatter().date(date), '3/20/2024');
    expect(formatter().date(date, long: true), 'March 20, 2024');
    expect(formatter(language: 'zh-Hans').date(date), '2024-3-20');
    expect(
      formatter(user: {'dateDisplayType': 2, 'shortDateFormat': 1}).date(date),
      '2567-3-20',
    );
    expect(
      formatter(user: {'dateDisplayType': 3, 'shortDateFormat': 1}).date(date),
      '1403-1-1',
    );
    expect(formatter().time(date, withSeconds: true), '01:05:09 PM');
    expect(
      formatter(user: {'numeralSystem': 3, 'shortTimeFormat': 1}).time(date),
      '۱۳:۰۵',
    );
    expect(
      formatter(language: 'zh-Hans', user: {'shortTimeFormat': 2}).time(date),
      '下午 01:05',
    );
  });
  test(
    'IANA timezone cross day, DST day lengths, week and fiscal boundaries',
    () {
      final fmt = formatter(
        settings: {'timeZone': 'America/New_York'},
        user: {'firstDayOfWeek': 1, 'fiscalYearStart': 1025},
      );
      expect(fmt.localDate(DateTime.utc(2024, 3, 10, 4, 30)).day, 9);
      final spring = fmt.dateRange(1, now: DateTime.utc(2024, 3, 10, 12))!;
      final fall = fmt.dateRange(1, now: DateTime.utc(2024, 11, 3, 12))!;
      expect(spring.maxTime - spring.minTime + 1, 23 * 3600);
      expect(fall.maxTime - fall.minTime + 1, 25 * 3600);
      expect(
        DateTime.fromMillisecondsSinceEpoch(spring.minTime * 1000, isUtc: true),
        DateTime.utc(2024, 3, 10, 5),
      );
      final week = fmt.dateRange(5, now: DateTime.utc(2024, 3, 10, 12))!;
      expect(
        fmt
            .localDate(
              DateTime.fromMillisecondsSinceEpoch(
                week.minTime * 1000,
                isUtc: true,
              ),
            )
            .day,
        4,
      );
      final fiscal = fmt.dateRange(11, now: DateTime.utc(2024, 3, 31, 12))!;
      expect(
        fmt
            .localDate(
              DateTime.fromMillisecondsSinceEpoch(
                fiscal.minTime * 1000,
                isUtc: true,
              ),
            )
            .year,
        2023,
      );
      expect(fmt.fiscalYear(DateTime(2024, 3, 31)), 'FY 2024');
      expect(fmt.fiscalYear(DateTime(2024, 4, 1)), 'FY 2025');
      final recent = fmt.dateRange(101, now: DateTime.utc(2024, 3, 10, 12))!;
      expect(
        fmt
            .localDate(
              DateTime.fromMillisecondsSinceEpoch(
                recent.minTime * 1000,
                isUtc: true,
              ),
            )
            .month,
        4,
      );
    },
  );
  test(
    'original transaction offset remains separate from application timezone',
    () {
      final fmt = formatter(settings: {'timeZone': 'America/New_York'});
      final item = {
        'time': DateTime.utc(2024, 3, 10, 4).millisecondsSinceEpoch ~/ 1000,
        'utcOffset': 480,
      };
      expect(fmt.transactionDate(item).hour, 12);
      expect(fmt.transactionDate(item, originalTimezone: false).day, 9);
      expect(fmt.transactionDate(item, originalTimezone: false).hour, 23);
    },
  );
  test('all 21 locales and Gregorian Buddhist Persian date preferences match Web', () {
    for (final item in fixtures['dates']) {
      final d = item['date'];
      final fmt = formatter(
        language: item['language'],
        user: {
          'dateDisplayType': item['display'],
          'longDateFormat': item['order'],
          'shortDateFormat': item['order'],
        },
      );
      expect(
        fmt.date(
          DateTime.utc(d[0], d[1], d[2], d[3], d[4], d[5]),
          long: item['long'],
        ),
        item['expected'],
        reason:
            '${item['language']} ${item['display']} ${item['order']} ${item['long']}',
      );
    }
  });
  test(
    'billing days in short months preserve original Web overflow behavior',
    () {
      final fmt = formatter(settings: {'timeZone': 'Etc/UTC'});
      for (final item in fixtures['billingRanges']) {
        final d = item['date'];
        final range = fmt.dateRange(
          item['type'],
          now: DateTime.utc(d[0], d[1], d[2], 12),
          statementDay: item['statementDay'],
        )!;
        expect(
          [range.minTime, range.maxTime],
          [item['expected']['minTime'], item['expected']['maxTime']],
          reason: '$d ${item['statementDay']} ${item['type']}',
        );
      }
    },
  );
  test('arbitrary precision rate entry and display honors locale separators and digits', () {
    final fmt = formatter(language: 'de', user: {'numeralSystem': 3});
    expect(fmt.normalizeAmountInput('۱.۲۳۴,۵۶۷۸'), '1234.5678');
    expect(fmt.decimal('1234.5678'), '۱.۲۳۴,۵۶۷۸');
    for (var system = 1; system <= 5; system++) {
      final f = formatter(user: {'numeralSystem': system});
      expect(f.parseAmount(f.amount(123456, showCurrency: false)), 123456);
    }
  });
  test('translations support fallback interpolation, literals and plural alternatives', () {
    final messages = {
      'one': '{count} 张图片',
      'names': 'No items | One item | {n} items',
      'literal': "{'@'} {name}",
    };
    expect(
      translateMessage(messages, {}, 'one', parameters: {'count': 5}),
      '5 张图片',
    );
    expect(translateMessage(messages, {}, 'names', plural: 0), 'No items');
    expect(translateMessage(messages, {}, 'names', plural: 1), 'One item');
    expect(translateMessage(messages, {}, 'names', plural: 4), '4 items');
    expect(
      translateMessage(messages, {}, 'literal', parameters: {'name': 'User'}),
      '@ User',
    );
    expect(
      translateMessage(
        messages,
        {'fallback': 'Hello {name}'},
        'fallback',
        parameters: {'name': 'A'},
      ),
      'Hello A',
    );
  });
  test('font size preference uses source pixel increments and retains system accessibility', () {
    expect(
      const BookkeepingTextScaler(
        system: TextScaler.noScaling,
        fontSizeType: 0,
      ).scale(14),
      13,
    );
    expect(
      const BookkeepingTextScaler(
        system: TextScaler.noScaling,
        fontSizeType: 6,
      ).scale(17),
      24,
    );
    expect(
      const BookkeepingTextScaler(
        system: TextScaler.linear(2),
        fontSizeType: 2,
      ).scale(14),
      30,
    );
  });
}
