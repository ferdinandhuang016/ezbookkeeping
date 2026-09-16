import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:ezbookkeeping/core/app_controller.dart';
import 'package:ezbookkeeping/core/formatting.dart';
import 'package:ezbookkeeping/features/statistics/statistics.dart';
import 'package:ezbookkeeping/features/statistics/statistics_range.dart';
import 'package:ezbookkeeping/features/statistics/statistics_bars.dart';
import 'package:ezbookkeeping/features/statistics/statistics_history.dart';
import 'package:ezbookkeeping/features/overview/home.dart';
import 'package:ezbookkeeping/features/transactions/transaction_schedule.dart';
import 'package:ezbookkeeping/features/transactions/transactions.dart'
    show TransactionFilter;

class StatisticsFixture extends AppController {
  @override
  List<Map<String, dynamic>> get transactions => [
    {
      'type': 3,
      'sourceAccountId': 'visible',
      'sourceAmount': 1850,
      'time': DateTime.utc(2099).millisecondsSinceEpoch ~/ 1000,
      'utcOffset': 0,
    },
  ];
  @override
  List<Map<String, dynamic>> get accounts => [
    {
      'id': 'p',
      'type': 2,
      'hidden': true,
      'subAccounts': [
        {
          'id': 'child',
          'parentId': 'p',
          'type': 1,
          'category': 1,
          'currency': 'CNY',
          'balance': 250,
        },
      ],
    },
    {
      'id': 'visible',
      'type': 1,
      'category': 1,
      'currency': 'CNY',
      'balance': 100,
    },
    {
      'id': 'hidden',
      'type': 1,
      'category': 1,
      'currency': 'CNY',
      'balance': 200,
      'hidden': true,
    },
    {'id': 'card', 'type': 1, 'category': 3, 'currency': 'CNY', 'balance': -75},
  ];
  @override
  List<Map<String, dynamic>> get categories => [
    {
      'id': 'parent',
      'hidden': true,
      'subCategories': [
        {'id': 'child', 'parentId': 'parent'},
      ],
    },
  ];
}

class AssetHistoryFixture extends AppController {
  @override
  List<Map<String, dynamic>> get accounts => [
    {
      'id': 'cash',
      'type': 1,
      'category': 1,
      'currency': 'CNY',
      'balance': 9000,
    },
    {'id': 'usd', 'type': 1, 'category': 2, 'currency': 'USD', 'balance': 1000},
    {
      'id': 'card',
      'type': 1,
      'category': 3,
      'currency': 'CNY',
      'balance': -7000,
    },
  ];
  @override
  List<Map<String, dynamic>> get transactions => [
    {
      'type': 2,
      'sourceAccountId': 'cash',
      'sourceAmount': 1000,
      'time': DateTime.utc(2026, 9, 20).millisecondsSinceEpoch ~/ 1000,
    },
    {
      'type': 3,
      'sourceAccountId': 'usd',
      'sourceAmount': 200,
      'time': DateTime.utc(2026, 9, 21).millisecondsSinceEpoch ~/ 1000,
    },
    {
      'type': 4,
      'sourceAccountId': 'usd',
      'sourceAmount': 100,
      'destinationAccountId': 'card',
      'destinationAmount': 700,
      'time': DateTime.utc(2026, 9, 22).millisecondsSinceEpoch ~/ 1000,
    },
    {
      'type': 1,
      'sourceAccountId': 'cash',
      'sourceAmount': 9000,
      'balanceDelta': 2000,
      'time': DateTime.utc(2026, 9, 23).millisecondsSinceEpoch ~/ 1000,
    },
  ];
}

void main() {
  tz.initializeTimeZones();
  test(
    'all mobile chart data types and their order match the original source',
    () {
      final expected = jsonDecode(
        File('test/fixtures/web_statistics_types.json').readAsStringSync(),
      ) as List;
      final actual = [categoricalData, trendData, assetData];
      for (var analysis = 0; analysis < actual.length; analysis++) {
        expect([
          for (final type in actual[analysis])
            {'type': type, 'name': chartDataNames[type]},
        ], expected[analysis]);
      }
      expect(actual.expand((types) => types), isNot(contains(16)));
    },
  );
  test('asset, liability and net-worth history preserve cross-currency debt repayments', () {
    final app = AssetHistoryFixture()..user = {'defaultCurrency': 'CNY'};
    app.settings['cachedExchangeRates'] = {
      'baseCurrency': 'USD',
      'exchangeRates': [
        {'currency': 'CNY', 'rate': '7'},
      ],
    };
    final stats = LedgerStatistics(app);
    for (final fixture in [
      [19, 15100, 7700, 7400],
      [20, 16100, 7700, 8400],
      [21, 14700, 7700, 7000],
      [22, 14000, 7000, 7000],
      [23, 16000, 7000, 9000],
    ]) {
      final time = DateTime.utc(2026, 9, fixture[0]);
      expect(stats.netAssetsAt(time, 6, {}), BigInt.from(fixture[1]));
      expect(stats.netAssetsAt(time, 7, {}), BigInt.from(fixture[2]));
      expect(stats.netAssetsAt(time, 17, {}), BigInt.from(fixture[3]));
      expect(fixture[1] - fixture[2], fixture[3]);
      expect(stats.assetBalancesAt(time, 6, {}).keys, ['cash', 'usd']);
      expect(stats.assetBalancesAt(time, 7, {}), {
        'card': BigInt.from(fixture[2]),
      });
    }
    expect(
      stats.netAssetsAt(DateTime.utc(2026, 9, 19), 17, {'cash'}),
      BigInt.from(6000),
    );
    expect(
      stats.netAssetsAt(DateTime.utc(2026, 9, 19), 6, {'card'}),
      BigInt.zero,
    );
    expect(
      stats.netAssetsAt(DateTime.utc(2026, 9, 19), 7, {'card'}),
      BigInt.from(7700),
    );
    expect(stats.assetBalancesAt(DateTime.utc(2026, 9, 19), 6, {}), {
      'cash': BigInt.from(6000),
      'usd': BigInt.from(9100),
    });
    expect(stats.assetBalancesAt(DateTime.utc(2026, 9, 23), 6, {'usd'}), {
      'usd': BigInt.from(7000),
    });
  });
  final reference = jsonDecode(
    File('assets/reference/formatting.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  BookkeepingFormatter formatter({
    String locale = 'en',
    String zone = 'UTC',
    int firstDay = 1,
  }) => BookkeepingFormatter(
    user: {'firstDayOfWeek': firstDay},
    settings: {'timeZone': zone},
    messages: jsonDecode(
      File('assets/locales/$locale.json').readAsStringSync(),
    ),
    reference: reference,
    language: locale.replaceAll('_', '-'),
  );
  test(
    'asset daily history matches original API and Web gap-fill fixtures',
    () {
      final fixture = jsonDecode(
        File('test/fixtures/web_asset_history.json').readAsStringSync(),
      ) as Map;
      final transactions = (fixture['transactions'] as List)
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      for (final item in fixture['cases'] as List) {
        final actual = assetHistoryByDay(
          transactions,
          formatter(zone: item['zone']),
          minTime: item['minTime'],
          maxTime: item['maxTime'],
        );
        expect([
          for (final day in actual.entries)
            {
              'date': [day.key.year, day.key.month, day.key.day],
              'balances': day.value,
            },
        ], item['expected']);
      }
    },
  );
  test('asset history fills only between observed days and preserves real zero activity', () {
    final fmt = formatter();
    int epoch(int month, int day) =>
        DateTime.utc(2026, month, day).millisecondsSinceEpoch ~/ 1000;
    final transactions = <Map<String, dynamic>>[
      {
        'type': 2,
        'sourceAccountId': 'cash',
        'sourceAmount': 100,
        'time': epoch(1, 1),
      },
      {
        'type': 3,
        'sourceAccountId': 'cash',
        'sourceAmount': 40,
        'time': epoch(1, 3),
      },
      {
        'type': 1,
        'sourceAccountId': 'zero',
        'sourceAmount': 0,
        'balanceDelta': 0,
        'time': epoch(1, 3),
      },
      {
        'type': 2,
        'sourceAccountId': 'cash',
        'sourceAmount': 50,
        'time': epoch(3, 1),
      },
    ];
    final january = assetHistoryByDay(transactions, fmt, maxTime: epoch(1, 31));
    expect(january.length, 3);
    expect(january.values.toList(), [
      {'cash': 100},
      {'cash': 100},
      {'cash': 60, 'zero': 0},
    ]);
    final all = assetHistoryByDay(transactions, fmt, maxTime: epoch(12, 31));
    expect(all.keys.last, fmt.wallTime(2026, 3, 1));
    expect(all.values.last, {'cash': 110, 'zero': 0});
    final later = assetHistoryByDay(
      transactions,
      fmt,
      minTime: epoch(4, 1),
      maxTime: epoch(4, 30),
    );
    expect(later, {
      fmt.wallTime(2026, 4, 1): {'cash': 110},
    });
  });
  test(
    'period shifting matches original Web full-month, fiscal and DST fixtures',
    () {
      final fixtures = jsonDecode(
        File('test/fixtures/web_statistics_ranges.json').readAsStringSync(),
      ) as List;
      for (final item in fixtures) {
        final actual = shiftStatisticsRange(
          formatter(zone: item['zone']),
          item['minTime'],
          item['maxTime'],
          item['scale'],
        );
        expect(actual.minTime, item['expected']['minTime'], reason: '$item');
        expect(actual.maxTime, item['expected']['maxTime'], reason: '$item');
      }
    },
  );
  test('mobile stacked and separate bars preserve signed-total scaling', () {
    expect(statisticsBarFractions([60, 40], 100, stacked: true), [.6, .4]);
    final stacked = statisticsBarFractions([80, 40, -60], 100, stacked: true);
    expect(stacked[0], closeTo(.4, 1e-12));
    expect(stacked[1], closeTo(.2, 1e-12));
    expect(stacked[2], 0);
    expect(statisticsBarFractions([80, 40, -60], 100, stacked: false), [
      .6,
      .3,
      0,
    ]);
    expect(statisticsBarFractions([10, -20], 100, stacked: true), [0, 0]);
  });
  test(
    'a shifted DST range keeps its sub-day boundaries in transaction filtering',
    () {
      final fmt = formatter(zone: 'America/New_York');
      final original = fmt.dateRange(5, now: fmt.wallTime(2024, 3, 7))!;
      final shifted = shiftStatisticsRange(
        fmt,
        original.minTime,
        original.maxTime,
        1,
      );
      final filter = TransactionFilter()
        ..preciseTimes = true
        ..start = fmt.localDate(
          DateTime.fromMillisecondsSinceEpoch(
            shifted.minTime * 1000,
            isUtc: true,
          ),
        )
        ..end = fmt.localDate(
          DateTime.fromMillisecondsSinceEpoch(
            shifted.maxTime * 1000,
            isUtc: true,
          ),
        );
      DateTime dateOf(Map<String, dynamic> item) => fmt.localDate(
        DateTime.fromMillisecondsSinceEpoch(
          (item['time'] as int) * 1000,
          isUtc: true,
        ),
      );
      expect(
        filter.matches({'time': shifted.minTime - 1}, dateOf: dateOf),
        false,
      );
      expect(filter.matches({'time': shifted.minTime}, dateOf: dateOf), true);
      expect(filter.matches({'time': shifted.maxTime}, dateOf: dateOf), true);
      expect(
        filter.matches({'time': shifted.maxTime + 1}, dateOf: dateOf),
        false,
      );
      expect(filter.copy().preciseTimes, true);
    },
  );
  test('home assets use current balances including future transactions and overview exclusions', () {
    final app = StatisticsFixture()..user = {'defaultCurrency': 'CNY'};
    app.settings['totalAmountExcludeAccountIds'] = {'visible': true};
    expect(overviewAssetTotals(app), {
      6: BigInt.from(100),
      7: BigInt.from(75),
      17: BigInt.from(25),
    });
    app.settings['overviewAccountFilterInHomePage'] = {'visible': true};
    expect(overviewAssetTotals(app), {
      6: BigInt.zero,
      7: BigInt.from(75),
      17: BigInt.from(-75),
    });
  });
  test('flow totals exclude internal transfers while account rows retain both sides', () {
    final app = StatisticsFixture()..user = {'defaultCurrency': 'CNY'};
    final stats = LedgerStatistics(app);
    final items = <Map<String, dynamic>>[
      {'type': 3, 'sourceAccountId': 'visible', 'sourceAmount': 50},
      {'type': 2, 'sourceAccountId': 'visible', 'sourceAmount': 75},
      {
        'type': 4,
        'sourceAccountId': 'visible',
        'destinationAccountId': 'card',
        'sourceAmount': 20,
        'destinationAmount': 20,
      },
    ];
    expect(stats.categorical(items, 11), {'visible': BigInt.from(70)});
    expect(stats.categoricalTotal(items, 11), BigInt.from(50));
    expect(stats.categoricalTotal(items, 12), BigInt.from(75));
    expect(
      stats.categoricalTotal(items, 11, accountFilter: {'visible'}),
      BigInt.from(70),
    );
    expect(
      stats.categoricalTotal(items, 12, accountFilter: {'card'}),
      BigInt.from(20),
    );
    expect(
      stats.categoricalTotal(items, 11, accountFilter: {'visible', 'card'}),
      BigInt.from(50),
    );
  });
  test('scheduled display uses localized names and configured week order', () {
    Map<String, dynamic> data(int type, String frequency) => {
      'scheduledFrequencyType': type,
      'scheduledFrequency': frequency,
    };
    expect(scheduleDescription(data(1, '4'), formatter()), 'Every Thursday');
    expect(
      scheduleDescription(data(1, '0,1,4'), formatter()),
      'Every Monday, Thursday, Sunday',
    );
    expect(
      scheduleDescription(data(1, '4'), formatter(locale: 'zh_Hans')),
      '每星期四',
    );
    expect(
      scheduleDescription(data(2, '-1'), formatter()),
      'Every last day of month',
    );
    expect(
      scheduleDescription(data(2, '1,15,-1'), formatter(locale: 'zh_Hans')),
      '每月1日、15日、倒数第1日',
    );
    expect(
      scheduleDescription(data(4, '101,1225'), formatter(locale: 'zh_Hans')),
      '每年1月1日、12月25日',
    );
    expect(scheduleDescription(data(5, '14'), formatter()), 'Every 14 days');
  });
  test('asset totals retain hidden accounts but currency totals skip only own-hidden records', () {
    final app = StatisticsFixture()..user = {'defaultCurrency': 'CNY'};
    final stats = LedgerStatistics(app);
    final assets = stats.categorical([], 6);
    expect(assets.values.fold(BigInt.zero, (a, b) => a + b), BigInt.from(550));
    expect(stats.hidden('child', 6), true);
    expect(stats.hidden('hidden', 6), true);
    expect(stats.hidden('visible', 6), false);
    expect(stats.hidden('child', 2), true);
    expect(stats.categorical([], 18), {'CNY': BigInt.from(350)});
    expect(stats.originalCurrencyBalance('CNY', 18, {}), BigInt.from(350));
    expect(stats.categorical([], 19), {'CNY': BigInt.from(75)});
    expect(stats.originalCurrencyBalance('CNY', 19, {'card'}), BigInt.from(75));
    expect(stats.categorical([], 18, accountFilter: {'visible'}), {
      'CNY': BigInt.from(100),
    });
  });
}
