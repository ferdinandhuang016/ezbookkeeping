import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/core/formatting.dart';
import 'package:ezbookkeeping/core/app_controller.dart';
import 'package:ezbookkeeping/features/catalogs/catalogs.dart';
import 'package:ezbookkeeping/features/statistics/statistics.dart';
import 'package:ezbookkeeping/features/transactions/transactions.dart';
import 'package:ezbookkeeping/features/transactions/transaction_totals.dart';
import 'package:ezbookkeeping/ui/common.dart' show expandSelection;
import 'package:ezbookkeeping/ui/common.dart' show updateTreeSelection;
import 'package:ezbookkeeping/core/transaction_permissions.dart';
import 'package:ezbookkeeping/core/transaction_ordering.dart';
import 'package:ezbookkeeping/data/ledger_repository.dart';
import 'package:timezone/data/latest.dart' as timezone;

class FixtureController extends AppController {
  @override
  List<Map<String, dynamic>> get accounts => [
    {
      'id': 'cash',
      'name': 'Cash',
      'type': 1,
      'category': 1,
      'currency': 'CNY',
      'balance': 100000,
    },
    {
      'id': 'usd',
      'name': 'USD',
      'type': 1,
      'category': 2,
      'currency': 'USD',
      'balance': 20000,
    },
    {
      'id': 'card',
      'name': 'Card',
      'type': 1,
      'category': 3,
      'currency': 'CNY',
      'balance': -5000,
    },
  ];
  @override
  List<Map<String, dynamic>> get categories => [
    {
      'id': 'food',
      'parentId': '0',
      'type': 2,
      'name': 'Food',
      'subCategories': [
        {'id': 'lunch', 'parentId': 'food', 'type': 2, 'name': 'Lunch'},
      ],
    },
  ];
  @override
  List<Map<String, dynamic>> get transactions => transactionFixtures;
  List<Map<String, dynamic>> transactionFixtures = [];
}

Map<String, dynamic> transaction({
  int type = 3,
  int amount = 3000,
  String account = 'cash',
  String target = 'usd',
  int targetAmount = 0,
  String category = 'lunch',
  List<String> tags = const [],
  int day = 10,
}) => {
  'id': 't-$day-$type',
  'type': type,
  'sourceAccountId': account,
  'destinationAccountId': target,
  'sourceAmount': amount,
  'destinationAmount': targetAmount,
  'categoryId': category,
  'tagIds': tags,
  'time': DateTime.utc(2026, 9, day, 12).millisecondsSinceEpoch ~/ 1000,
  'utcOffset': 0,
  'comment': 'Lunch',
};

void main() {
  test('monthly totals preserve fractions and count only transfers crossing selected accounts', () {
    final accounts = <Map<String, dynamic>>[
      {'id': 'cny', 'currency': 'CNY', 'parentId': 'p'},
      {'id': 'usd', 'currency': 'USD', 'parentId': 'p'},
    ];
    final items = <Map<String, dynamic>>[
      {'type': 3, 'sourceAccountId': 'usd', 'sourceAmount': 1},
      {'type': 3, 'sourceAccountId': 'usd', 'sourceAmount': 1},
      {
        'type': 4,
        'sourceAccountId': 'cny',
        'sourceAmount': 3,
        'destinationAccountId': 'usd',
        'destinationAmount': 6,
      },
    ];
    Map<int, dynamic> total(Set<String> selected) => transactionTotals(
      transactions: items,
      accounts: accounts,
      selectedAccounts: selected,
      defaultCurrency: 'CNY',
      rates: {'CNY': '1', 'USD': '2'},
    );
    expect(total({})[3].value, BigInt.one);
    expect(total({})[2].value, BigInt.zero);
    expect(total({'usd'})[2].currency, 'USD');
    expect(total({'usd'})[2].value, BigInt.from(6));
    expect(total({'cny'})[3].value, BigInt.from(4));
    expect(total({'cny', 'usd'})[3].value, BigInt.one);
    expect(total({'p'})[3].value, BigInt.one);
    items[0]['sourceAmount'] = -1;
    items[1]['sourceAmount'] = -1;
    expect(total({})[3].value, -BigInt.one);
    final missing = transactionTotals(
      transactions: items,
      accounts: accounts,
      selectedAccounts: {},
      defaultCurrency: 'JPY',
      rates: {},
    );
    expect(missing[3]!.incomplete, isTrue);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  timezone.initializeTimeZones();
  late FixtureController app;
  setUp(() {
    app = FixtureController();
    app.user = {'defaultCurrency': 'CNY'};
    app.settings = {
      'cachedExchangeRates': {
        'baseCurrency': 'USD',
        'exchangeRates': [
          {'currency': 'CNY', 'rate': '7'},
          {'currency': 'USD', 'rate': '1'},
        ],
      },
    };
  });
  tearDown(() => app.dispose());
  test('statistics and account conversions match the original Web truncate fixtures', () {
    final fixtures = jsonDecode(
      File('test/fixtures/web_exchange.json').readAsStringSync(),
    );
    for (final value in fixtures['cases']) {
      expect(
        BookkeepingFormatter.convertAggregate(
          value['amount'],
          value['fromRate'],
          value['toRate'],
          truncate: true,
        ).toString(),
        value['expected'],
      );
    }
    app.settings['cachedExchangeRates'] = {
      'baseCurrency': 'CNY',
      'exchangeRates': [
        {'currency': 'USD', 'rate': '2'},
      ],
    };
    final stats = LedgerStatistics(app);
    final first = transaction(account: 'usd', amount: 1);
    final second = transaction(account: 'usd', amount: 1);
    final expected = fixtures['grouped'];
    expect(
      stats.categorical([first, second], 1).values.single.toString(),
      expected['sameAccountCategory'],
    );
    expect(
      stats
          .categorical([
            first,
            {...second, 'categoryId': 'other'},
          ], 0)
          .values
          .single
          .toString(),
      expected['differentCategories'],
    );
    expect(
      stats
          .categorical(
            [
              first,
              {
                ...second,
                'time':
                    DateTime.utc(2026, 10, 10).millisecondsSinceEpoch ~/ 1000,
              },
            ],
            0,
            monthly: true,
          )
          .values
          .single
          .toString(),
      expected['differentMonths'],
    );
    final individually =
        convertAccountAmount(1, 'USD', 'CNY', app) +
        convertAccountAmount(1, 'USD', 'CNY', app);
    expect(individually.toString(), expected['differentAccounts']);
    expect(
      stats.sum([first, second], 3).toString(),
      expected['overviewSameCurrency'],
    );
  });
  test('durable picture IDs reconstruct offline previews without losing remote metadata', () {
    final photos = transactionPictures({
      'pictureIds': ['local:receipt', 'remote', 'local:receipt'],
      'pictures': [
        {'pictureId': 'remote', 'originalUrl': 'picture/url'},
      ],
    });
    expect(photos.length, 2);
    expect(photos.first['originalUrl'], 'picture/url');
    expect(photos.last['pictureId'], 'local:receipt');
  });
  test('reconciliation query preserves exact cents, IDs, date and tags', () {
    final data = <String, dynamic>{'sourceAmount': 0, 'tagIds': []};
    applyTransactionQuery(data, {
      'type': '3',
      'amount': '999999999999999',
      'destinationAmount': '12',
      'accountId': '9007199254740999',
      'destinationAccountId': 'usd',
      'categoryId': 'lunch',
      'tagIds': 'a,b,a',
      'time': '1789455600',
      'comment': 'Closing balance',
      'noTransactionDraft': 'true',
    });
    expect(data['sourceAmount'], 999999999999999);
    expect(data['sourceAccountId'], '9007199254740999');
    expect(data['time'], 1789455600);
    expect(data['tagIds'], ['a', 'b']);
    expect(data.containsKey('noTransactionDraft'), false);
  });
  test('statistics drilldown preserves conjunctive filters and intersects primary category', () {
    final source = TransactionFilter()
      ..accounts = {'cash'}
      ..categories = {'lunch'}
      ..start = DateTime(2026, 9, 10)
      ..end = DateTime(2026, 9, 20)
      ..readTagFilter('1:a,b;2:c')
      ..readAmountFilter('bt:100:9000')
      ..keyword = 'Lunch'
      ..ignoreCase = false;
    final selected = statisticsDrilldown(
      app,
      source,
      1,
      itemId: 'food',
      start: DateTime(2026, 9, 1),
      end: DateTime(2026, 9, 30),
    );
    expect(selected.type, 3);
    expect(selected.accounts, {'cash'});
    expect(selected.categories, {'lunch'});
    expect(selected.start, app.formatter.wallTime(2026, 9, 10));
    expect(selected.end, app.formatter.wallTime(2026, 9, 20, 23, 59, 59));
    expect(selected.periodType, 255);
    expect(selected.preciseTimes, isTrue);
    expect(selected.encodedTagFilter, '1:a,b;2:c');
    expect(selected.encodedAmountFilter, 'bt:100:9000');
    expect(selected.keyword, 'Lunch');
    expect(selected.ignoreCase, false);
    selected.accounts.clear();
    selected.additionalTagFilters.clear();
    expect(source.accounts, {'cash'});
    expect(source.additionalTagFilters, hasLength(1));
  });
  test('statistics drilldown detects the clipped period rather than the parent year', () {
    app.settings['timeZone'] = 'Asia/Hong_Kong';
    final formatter = app.formatter;
    final now = formatter.wallTime(2026, 9, 15, 12);
    final source = TransactionFilter()
      ..periodType = 9
      ..start = formatter.wallTime(2026, 1, 1)
      ..end = formatter.wallTime(2026, 12, 31, 23, 59, 59);
    for (final (month, expected) in [(9, 7), (8, 8), (6, 255)]) {
      final range = statisticsBucketRange(
        formatter,
        formatter.wallTime(2026, month, 15),
        0,
      );
      final selected = statisticsDrilldown(
        app,
        source,
        6,
        start: range.start,
        end: range.end,
        now: now,
      );
      expect(selected.periodType, expected);
      expect(selected.start, range.start);
      expect(selected.end, range.end);
      expect(selected.preciseTimes, isTrue);
    }
    final currentBalance = statisticsDrilldown(
      app,
      source,
      6,
      itemId: 'cash',
      now: now,
    );
    expect(currentBalance.periodType, 0);
    expect(currentBalance.start, isNull);
    expect(currentBalance.end, isNull);
    expect(source.periodType, 9);
  });
  test('statistics drilldown keeps DST seconds and custom clipping exact', () {
    app.settings['timeZone'] = 'America/New_York';
    final formatter = app.formatter;
    final now = formatter.wallTime(2026, 3, 8, 12);
    final day = statisticsBucketRange(formatter, now, 4);
    final source = TransactionFilter()
      ..periodType = 9
      ..start = formatter.wallTime(2026, 1, 1)
      ..end = formatter.wallTime(2026, 12, 31, 23, 59, 59);
    final selected = statisticsDrilldown(
      app,
      source,
      3,
      start: day.start,
      end: day.end,
      now: now,
    );
    expect(selected.periodType, 1);
    expect(selected.end!.difference(selected.start!).inSeconds + 1, 23 * 3600);
    source
      ..preciseTimes = true
      ..start = formatter.wallTime(2026, 3, 8, 10, 4, 23)
      ..end = formatter.wallTime(2026, 3, 8, 14, 8, 17);
    final clipped = statisticsDrilldown(
      app,
      source,
      3,
      start: day.start,
      end: day.end,
      now: now,
    );
    expect(clipped.periodType, 255);
    expect(clipped.start, source.start);
    expect(clipped.end, source.end);
    expect(clipped.preciseTimes, isTrue);
  });
  test(
    'statistics bucket dates respect daylight-saving and fiscal boundaries',
    () {
      app.settings['timeZone'] = 'America/New_York';
      final day = statisticsBucketRange(app.formatter, DateTime(2026, 3, 8), 4);
      expect(day.end.difference(day.start).inSeconds + 1, 23 * 3600);
      app.user['fiscalYearStart'] = (4 << 8) | 1;
      final fiscal = statisticsBucketRange(
        app.formatter,
        DateTime(2026, 3, 15),
        3,
      );
      expect(fiscal.start.year, 2025);
      expect(fiscal.start.month, 4);
      expect(fiscal.end.month, 3);
      expect(fiscal.end.day, 31);
    },
  );
  test('duplication variants independently preserve time and location and never reuse attachments', () {
    final source = {
      ...transaction(),
      'geoLocation': {'latitude': 1, 'longitude': 2},
      'geoLocationName': 'Office',
      'pictures': [
        {'pictureId': 'photo'},
      ],
      'pictureIds': ['photo'],
    };
    final now = DateTime.utc(2026, 9, 20, 8);
    for (final keepTime in [false, true]) {
      for (final keepGeo in [false, true]) {
        final copy = duplicateTransactionData(
          source,
          now: now,
          withTime: keepTime,
          withGeo: keepGeo,
        );
        expect(copy.containsKey('id'), false);
        expect(
          copy['time'],
          keepTime ? source['time'] : now.millisecondsSinceEpoch ~/ 1000,
        );
        expect(copy['geoLocation'], keepGeo ? source['geoLocation'] : null);
        expect(copy['geoLocationName'], keepGeo ? 'Office' : null);
        expect(copy['pictures'], isEmpty);
        expect(copy['pictureIds'], isEmpty);
      }
    }
  });
  test('deselecting a child removes its ancestor and preserves siblings', () {
    final children = [
      {'id': 'a', 'parentId': 'parent'},
      {'id': 'b', 'parentId': 'parent'},
    ];
    final parent = {'id': 'parent', 'parentId': '0', 'subCategories': children};
    final choices = [parent, ...children];
    final selected = {'parent', 'a', 'b'};
    updateTreeSelection(choices, selected, children.first, false);
    expect(selected, {'b'});
    updateTreeSelection(choices, selected, children.first, true);
    expect(selected, {'parent', 'a', 'b'});
    updateTreeSelection(choices, selected, parent, false);
    expect(selected, isEmpty);
  });
  test('same-second server ordering keeps sequence IDs exact beyond double precision', () {
    final records = [
      {...transaction(), 'id': '1', 'timeSequenceId': '10000000000000000001'},
      {...transaction(), 'id': '2', 'timeSequenceId': '10000000000000000003'},
      {...transaction(), 'id': '3', 'timeSequenceId': '10000000000000000002'},
    ];
    expect(
      LedgerRepository.projectTransactions(
        records,
        [],
      ).map((item) => item['id']),
      ['2', '3', '1'],
    );
    records.sort(compareTransactionsNewestFirst);
    expect(records.map((item) => item['id']), ['2', '3', '1']);
  });
  group('Offline editing permissions', () {
    bool allowed(
      Map<String, dynamic> item, {
      List<Map<String, dynamic>>? accounts,
      DateTime? now,
    }) => transactionCanBeEdited(
      transaction: item,
      user: app.user,
      accounts: accounts ?? app.accounts,
      formatter: app.formatter,
      now: now ?? DateTime.utc(2026, 9, 15, 12),
    );
    test('recomputes expired windows and ignores stale cached permissions', () {
      app.user['transactionEditScope'] = 3;
      expect(allowed(transaction(day: 14)), false);
      expect(allowed(transaction(day: 15)), true);
      app.user['transactionEditScope'] = 1;
      expect(allowed({...transaction(day: 10), 'editable': false}), true);
    });
    test('uses the selected timezone for a DST boundary', () {
      app.settings['timeZone'] = 'America/New_York';
      app.user['transactionEditScope'] = 2;
      final item = {
        ...transaction(),
        'time': DateTime.utc(2026, 3, 8, 5).millisecondsSinceEpoch ~/ 1000,
      };
      expect(allowed(item, now: DateTime.utc(2026, 3, 8, 12)), false);
      item['time'] = (item['time'] as int) + 1;
      expect(allowed(item, now: DateTime.utc(2026, 3, 8, 12)), true);
    });
    test(
      'hidden ancestors and the later transfer reconciliation block edits',
      () {
        app.user.addAll({
          'transactionEditScope': 7,
          'useLastReconciledTime': true,
        });
        final accounts = [
          for (final account in app.accounts)
            {
              ...account,
              'lastReconciledTime':
                  DateTime.utc(
                    2026,
                    9,
                    account['id'] == 'usd' ? 14 : 10,
                    12,
                  ).millisecondsSinceEpoch ~/
                  1000,
            },
        ];
        expect(
          allowed(transaction(type: 4, day: 13), accounts: accounts),
          false,
        );
        expect(
          allowed(transaction(type: 4, day: 15), accounts: accounts),
          true,
        );
        app.user['transactionEditScope'] = 1;
        final hidden = [
          {
            'id': 'parent',
            'type': 2,
            'hidden': true,
            'subAccounts': [
              {...app.accounts.first, 'parentId': 'parent'},
            ],
          },
        ];
        expect(allowed(transaction(), accounts: hidden), false);
      },
    );
  });
  group('Offline financial calculations', () {
    test('converts account currencies before adding amounts', () {
      final stats = LedgerStatistics(app);
      expect(
        stats.sum([
          transaction(type: 2, amount: 12345, account: 'usd'),
          transaction(type: 2, amount: 100),
        ], 2),
        BigInt.from(86515),
      );
      expect(
        stats.sum([
          transaction(type: 4, amount: 700, account: 'cash', targetAmount: 100),
        ], 3),
        BigInt.zero,
      );
    });
    test('groups secondary transactions by their actual primary category', () {
      expect(
        LedgerStatistics(app)
            .categorical([transaction(), transaction(amount: -100)], 1),
        {'food': BigInt.from(2900)},
      );
    });
    test('cash-flow account selection uses the correct transfer side', () {
      final item = transaction(type: 4, amount: 7000, targetAmount: 1000);
      final stats = LedgerStatistics(app);
      expect(stats.categorical([item], 11, accountFilter: {'cash'}), {
        'cash': BigInt.from(7000),
      });
      expect(stats.categorical([item], 11, accountFilter: {'usd'}), isEmpty);
      expect(stats.categorical([item], 12, accountFilter: {'usd'}), {
        'usd': BigInt.from(7000),
      });
    });
    test('historical balances reverse later income, expense and transfers', () {
      app.transactionFixtures = [
        transaction(amount: 3000, day: 12),
        transaction(type: 2, amount: 10000, day: 13),
        transaction(type: 4, amount: 7000, targetAmount: 1000, day: 14),
      ];
      final stats = LedgerStatistics(app);
      expect(
        stats.netAssetsAt(DateTime.utc(2026, 9, 15), 17, {}),
        BigInt.from(235000),
      );
      expect(
        stats.netAssetsAt(DateTime.utc(2026, 9, 11), 17, {}),
        BigInt.from(228000),
      );
      expect(
        stats.netAssetsAt(DateTime.utc(2026, 9, 11), 7, {}),
        BigInt.from(5000),
      );
    });
    test(
      'balance adjustment history uses its actual delta after earlier edits',
      () {
        app.transactionFixtures = [
          {
            ...transaction(type: 1, amount: 50000, day: 12),
            'balanceDelta': 10000,
          },
        ];
        expect(
          LedgerStatistics(app).netAssetsAt(DateTime.utc(2026, 9, 11), 17, {}),
          BigInt.from(225000),
        );
        app.transactionFixtures.first.remove('balanceDelta');
        expect(
          () =>
              LedgerStatistics(app)
                  .netAssetsAt(DateTime.utc(2026, 9, 11), 17, {}),
          throwsStateError,
        );
      },
    );
    test(
      'missing exchange rates fail visibly instead of mixing currencies',
      () {
        app.settings = {};
        expect(
          () => LedgerStatistics(app).convert(100, 'USD'),
          throwsStateError,
        );
      },
    );
  });
  group('Native transaction filters', () {
    test(
      'destination account amount filters use the transfer received amount',
      () {
        final filter = TransactionFilter()
          ..accounts = {'usd'}
          ..readAmountFilter('eq:100');
        expect(
          filter.matches(transaction(type: 4, amount: 700, targetAmount: 100)),
          true,
        );
        filter.accounts = {'cash'};
        expect(
          filter.matches(transaction(type: 4, amount: 700, targetAmount: 100)),
          false,
        );
      },
    );
    test('cloud tag and amount filters preserve every condition', () {
      final filter = TransactionFilter()
        ..readTagFilter('1:a,b;2:c;3:d,e')
        ..readAmountFilter('nb:-100:200');
      expect(filter.encodedTagFilter, '1:a,b;2:c;3:d,e');
      expect(filter.encodedAmountFilter, 'nb:-100:200');
      expect(
        filter.matches(transaction(amount: 201, tags: ['a', 'b', 'd'])),
        true,
      );
      expect(
        filter.matches(transaction(amount: 201, tags: ['a', 'b', 'd', 'e'])),
        false,
      );
      filter.readTagFilter('none');
      expect(filter.encodedTagFilter, 'none');
      expect(filter.matches(transaction(amount: 201, tags: ['a'])), false);
    });
    test('transfer direction matches the selected account side', () {
      final filter = TransactionFilter()
        ..type = 4
        ..accounts = {'usd'}
        ..relatedAccountType = 2;
      expect(filter.matches(transaction(type: 4)), true);
      filter.relatedAccountType = 1;
      expect(filter.matches(transaction(type: 4)), false);
    });
    test('supports all six amount comparisons and negative refunds', () {
      final f = TransactionFilter()
        ..minimumAmount = 100
        ..maximumAmount = 200;
      for (final entry in {
        'gt': false,
        'lt': false,
        'eq': true,
        'ne': false,
        'bt': true,
        'nb': false,
      }.entries) {
        f.amountOperator = entry.key;
        expect(
          f.matches(transaction(amount: 100)),
          entry.value,
          reason: entry.key,
        );
      }
      f.amountOperator = 'lt';
      f.minimumAmount = 0;
      expect(f.matches(transaction(amount: -1)), isTrue);
    });
    test('combines tag groups with AND while preserving each group logic', () {
      final f = TransactionFilter()
        ..tags = {'a', 'b'}
        ..tagMode = 0;
      f.additionalTagFilters.add({
        'mode': 2,
        'tagIds': ['blocked'],
      });
      expect(f.matches(transaction(tags: ['b', 'c'])), isTrue);
      expect(f.matches(transaction(tags: ['b', 'blocked'])), isFalse);
      expect(f.matches(transaction(tags: ['c'])), isFalse);
      f.tagMode = 1;
      expect(f.matches(transaction(tags: ['a'])), isFalse);
      expect(f.matches(transaction(tags: ['a', 'b'])), isTrue);
    });
    test('date filtering uses transaction offset at midnight', () {
      final f = TransactionFilter()
        ..start = DateTime(2026, 9, 11)
        ..end = DateTime(2026, 9, 11);
      final item = transaction()
        ..['time'] =
            DateTime.utc(2026, 9, 10, 23, 30).millisecondsSinceEpoch ~/ 1000
        ..['utcOffset'] = 120;
      expect(f.matches(item), isTrue);
    });
    test('a primary selection expands its descendants', () {
      expect(expandSelection(['food'], app.categories, 'subCategories'), {
        'food',
        'lunch',
      });
    });
  });
  test(
    'renaming a sub-account does not overwrite a concurrently changed balance',
    () {
      final unchanged = sanitizedSubAccount({
        'id': 's1',
        'name': 'New name',
        'balance': 1200,
        'balanceTime': 100,
      });
      expect(unchanged.containsKey('balance'), isFalse);
      expect(unchanged.containsKey('balanceTime'), isFalse);
      final adjusted = sanitizedSubAccount({
        'id': 's1',
        'balance': 1300,
        'balanceTime': 200,
        '_balanceChanged': true,
      });
      expect(adjusted.containsKey('balance'), isFalse);
      expect(adjusted.containsKey('balanceTime'), isFalse);
      expect(adjusted.containsKey('_balanceChanged'), isFalse);
      expect(
        sanitizedSubAccount({
          'name': 'New',
          'balance': 1300,
          'balanceTime': 200,
        })['balance'],
        1300,
      );
    },
  );
}
