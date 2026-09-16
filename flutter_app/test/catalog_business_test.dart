import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:ezbookkeeping/core/formatting.dart';
import 'package:ezbookkeeping/features/catalogs/catalog_business.dart';
import 'package:ezbookkeeping/features/settings/profile.dart'
    show fiscalYearPickerDate;

// Fixtures follow src/models/account.ts request serializers and the rejection
// rules in pkg/api/accounts.go. These are business tests, not widget tests.
void main() {
  tz.initializeTimeZones();
  final cash = <String, dynamic>{
    'name': 'Cash',
    'category': 1,
    'type': 1,
    'icon': '1',
    'iconType': 0,
    'color': 'c67e48',
    'currency': 'CNY',
    'balance': '1234',
    'balanceTime': 1750000000,
    'comment': '',
    'creditCardStatementDate': 1,
    'creditCardLimit': '0',
  };
  test('cash create omits all credit card fields rejected by server', () {
    final request = accountRequest(cash, modifying: false);
    expect(request['balance'], '1234');
    expect(request['balanceTime'], 1750000000);
    expect(request['currency'], 'CNY');
    expect(request.containsKey('creditCardStatementDate'), false);
    expect(request.containsKey('creditCardLimit'), false);
  });
  test('existing account metadata never overwrites balance or currency', () {
    final request = accountRequest({
      ...cash,
      'id': '9223372036854775806',
      '_balanceChanged': true,
      'lastReconciledTime': 1750000100,
    }, modifying: true);
    expect(request['id'], '9223372036854775806');
    expect(request['lastReconciledTime'], 1750000100);
    for (final field in [
      'balance',
      'balanceTime',
      'currency',
      'type',
      'creditCardStatementDate',
      'creditCardLimit',
      '_balanceChanged',
    ]) {
      expect(request.containsKey(field), false, reason: field);
    }
  });
  test(
    'clearing reconciled time removes it from account and child requests',
    () {
      final request = accountRequest({
        ...cash,
        'id': '10',
        'type': 2,
        'lastReconciledTime': null,
        'subAccounts': [
          {...cash, 'id': '11', 'lastReconciledTime': null},
          {...cash, 'id': '12', 'lastReconciledTime': 1750000100},
        ],
      }, modifying: true);
      expect(request.containsKey('lastReconciledTime'), false);
      expect(
        request['subAccounts'][0].containsKey('lastReconciledTime'),
        false,
      );
      expect(request['subAccounts'][1]['lastReconciledTime'], 1750000100);
    },
  );
  test('account timestamp picker preserves instant across app timezones', () {
    for (final zone in [
      'America/New_York',
      'Asia/Hong_Kong',
      'Asia/Kathmandu',
    ]) {
      final formatter = BookkeepingFormatter(
        user: {},
        settings: {'timeZone': zone},
        messages: {},
        reference: {},
        language: 'en',
      );
      for (final instant in [
        DateTime.utc(2026, 3, 8, 6, 59, 57),
        DateTime.utc(2026, 3, 8, 7, 0, 3),
        DateTime.utc(2026, 9, 15, 23, 50, 11),
      ]) {
        final seconds = instant.millisecondsSinceEpoch ~/ 1000;
        final chosen = accountTimeForPicker(seconds, formatter);
        final saved = formatter.wallTime(
          chosen.year,
          chosen.month,
          chosen.day,
          chosen.hour,
          chosen.minute,
          chosen.second,
        );
        expect(saved.millisecondsSinceEpoch ~/ 1000, seconds, reason: zone);
        final unset = accountTimeForPicker(0, formatter, now: instant);
        expect(unset.hour, formatter.localDate(instant).hour);
        expect(unset.second, instant.second);
      }
    }
  });
  test(
    'parent create clears currency and balance and inherits child category',
    () {
      final request = accountRequest({
        ...cash,
        'type': 2,
        'category': 7,
        'subAccounts': [cash],
      }, modifying: false);
      expect(request['currency'], '---');
      expect(request['balance'], '0');
      expect(request['balanceTime'], 0);
      final sub = request['subAccounts'][0] as Map;
      expect(sub['category'], 7);
      expect(sub['type'], 1);
      expect(sub['currency'], 'CNY');
      expect(sub['balance'], '1234');
      expect(sub.containsKey('creditCardStatementDate'), false);
    },
  );
  test('modify supports new subaccount and protects existing subaccount', () {
    final request = accountRequest({
      ...cash,
      'id': '10',
      'type': 2,
      'subAccounts': [
        {...cash, 'id': '11'},
        cash,
      ],
    }, modifying: true);
    final oldSub = request['subAccounts'][0] as Map;
    final newSub = request['subAccounts'][1] as Map;
    expect(oldSub.containsKey('balance'), false);
    expect(oldSub.containsKey('balanceTime'), false);
    expect(oldSub.containsKey('currency'), false);
    expect(newSub['id'], '0');
    expect(newSub['balance'], '1234');
    expect(newSub['currency'], 'CNY');
  });
  test('card can set positive credit limit and a shared currency', () {
    final card = {
      ...cash,
      'category': 3,
      'type': 2,
      'id': '10',
      'creditCardLimit': '500000',
      'creditCardStatementDate': 28,
    };
    final request = accountRequest(card, modifying: true);
    expect(request['creditCardLimit'], '500000');
    expect(request['creditCardStatementDate'], 28);
    expect(request['currency'], 'CNY');
    expect(
      accountRequest({
        ...card,
        'creditCardLimit': '0',
      }, modifying: true).containsKey('creditCardLimit'),
      false,
    );
  });
  test('displayed debt flips raw ledger balance, assets keep sign', () {
    expect(displayedAccountBalance({'category': 3, 'balance': '-1234'}), 1234);
    expect(displayedAccountBalance({'category': 5, 'balance': '100'}), -100);
    expect(displayedAccountBalance({'category': 1, 'balance': '-1234'}), -1234);
  });
  const rates = {'CNY': '1', 'USD': '2', 'EUR': '3'};
  test('overview selected children retain parent currency; shared credit includes all children', () {
    final parent = <String, dynamic>{
      ...cash,
      'id': 'p',
      'type': 2,
      'currency': '---',
      'subAccounts': [
        {...cash, 'id': 'a', 'currency': 'USD', 'balance': '2'},
        {...cash, 'id': 'b', 'currency': 'CNY', 'balance': '100'},
      ],
    };
    final selected = accountDisplayBalance(
      parent,
      'CNY',
      rates,
      selectedAccountIds: {'a'},
    )!;
    expect(selected.currency, 'CNY');
    expect(selected.value, BigInt.one);
    final card = <String, dynamic>{
      ...parent,
      'category': 3,
      'currency': 'CNY',
      'creditCardLimit': '1000',
      'subAccounts': [
        {...cash, 'id': 'a', 'category': 3, 'balance': '-100'},
        {...cash, 'id': 'b', 'category': 3, 'balance': '-200'},
      ],
    };
    expect(
      accountDisplayBalance(
        card,
        'CNY',
        rates,
        selectedAccountIds: {'a'},
      )!.value,
      BigInt.from(100),
    );
    expect(
      accountDisplayBalance(
        card,
        'CNY',
        rates,
        availableCredit: true,
        selectedAccountIds: {'a'},
      )!.value,
      BigInt.from(700),
    );
  });
  test(
    'parent preserves its only child currency, mixed currencies use default',
    () {
      final parent = {
        ...cash,
        'type': 2,
        'currency': '---',
        'subAccounts': [
          {...cash, 'currency': 'USD', 'balance': '1'},
          {...cash, 'currency': 'USD', 'balance': '1'},
        ],
      };
      final same = accountDisplayBalance(parent, 'CNY', rates)!;
      expect(same.currency, 'USD');
      expect(same.value, BigInt.two);
      final mixed = accountDisplayBalance(
        {
          ...parent,
          'subAccounts': [
            ...parent['subAccounts'] as List,
            {...cash, 'balance': '0'},
          ],
        },
        'CNY',
        rates,
      )!;
      expect(mixed.currency, 'CNY');
      expect(
        mixed.value,
        BigInt.one,
      ); // 0.5 + 0.5, never individually truncate.
    },
  );
  test(
    'exact rational totals retain fractions until final signed truncation',
    () {
      expect(
        sumConvertedBalances({'USD': 1, 'EUR': 2}, 'CNY', rates).value,
        BigInt.one,
      );
      expect(
        sumConvertedBalances({'USD': -1, 'EUR': -2}, 'CNY', rates).value,
        -BigInt.one,
      );
      expect(
        sumConvertedBalances({'USD': 1, 'EUR': -2}, 'CNY', rates).value,
        BigInt.zero,
      );
    },
  );
  test('credit requires an actual limit; shared limit is counted once', () {
    final card = {
      ...cash,
      'category': 3,
      'currency': 'CNY',
      'type': 2,
      'creditCardLimit': '10000',
      'subAccounts': [
        {...cash, 'category': 3, 'balance': '-1000'},
        {...cash, 'category': 3, 'balance': '-2000'},
      ],
    };
    expect(
      accountDisplayBalance(
        {...card, 'creditCardLimit': '0'},
        'CNY',
        rates,
        availableCredit: true,
      ),
      isNull,
    );
    expect(
      accountDisplayBalance(card, 'CNY', rates, availableCredit: true)!.value,
      BigInt.from(7000),
    );
    expect(
      accountCategoryBalance(
        [card],
        3,
        'CNY',
        rates,
        availableCredit: true,
      )!.value,
      BigInt.from(7000),
    );
  });
  test('hidden children are selectable for parent display but excluded from totals', () {
    final parent = {
      ...cash,
      'type': 2,
      'currency': '---',
      'subAccounts': [
        {...cash, 'balance': '100'},
        {...cash, 'balance': '200', 'hidden': true},
      ],
    };
    expect(
      accountDisplayBalance(parent, 'CNY', rates)!.value,
      BigInt.from(100),
    );
    expect(
      accountDisplayBalance(parent, 'CNY', rates, showHidden: true)!.value,
      BigInt.from(300),
    );
    expect(
      accountCategoryBalance([parent], 1, 'CNY', rates)!.value,
      BigInt.from(100),
    );
  });
  test(
    'category sum truncates at display and reports missing rates as incomplete',
    () {
      final accounts = [
        {...cash, 'currency': 'USD', 'balance': '1'},
        {...cash, 'currency': 'USD', 'balance': '1'},
        {...cash, 'currency': 'XXX', 'balance': '1'},
      ];
      final result = accountCategoryBalance(accounts, 1, 'CNY', rates)!;
      expect(result.value, BigInt.one);
      expect(result.incomplete, true);
    },
  );
  test(
    'available credit skips unknown limit but never fabricates converted debt',
    () {
      final known = {
        ...cash,
        'category': 3,
        'balance': '-100',
        'creditCardLimit': '1000',
      };
      final unknown = {...known, 'creditCardLimit': '0'};
      final partial = accountCategoryBalance(
        [known, unknown],
        3,
        'CNY',
        rates,
        availableCredit: true,
      )!;
      expect(partial.value, BigInt.from(900));
      expect(partial.incomplete, true);
      expect(
        accountCategoryBalance(
          [
            known,
            {...unknown, 'currency': 'XXX'},
          ],
          3,
          'CNY',
          rates,
          availableCredit: true,
        ),
        isNull,
      );
    },
  );
  Map<String, String> adjust({
    int category = 1,
    int closing = 1000,
    int wanted = 1500,
    int start = 0,
    int end = 0,
  }) => closingBalanceTransaction(
    account: {'id': '100', 'category': category},
    closingBalance: closing,
    desiredDisplayedBalance: wanted,
    startTime: start,
    endTime: end,
    now: 10000,
  );
  test('closing adjustment selects income or expense for assets and debt', () {
    expect(adjust()['type'], '2');
    expect(adjust(wanted: 500)['type'], '3');
    expect(adjust(category: 3, closing: -1000)['type'], '3');
    expect(adjust(category: 3, closing: -1000, wanted: 500)['type'], '2');
    expect(adjust(category: 3, closing: -1000)['amount'], '500');
    expect(adjust()['noTransactionDraft'], 'true');
  });
  test(
    'closing adjustment bounds timestamp only for finite past or future',
    () {
      expect(adjust().containsKey('time'), false);
      expect(adjust(start: 100, end: 9000)['time'], '9000');
      expect(adjust(start: 11000, end: 12000)['time'], '11000');
      expect(adjust(start: 100, end: 11000).containsKey('time'), false);
    },
  );
  test(
    'closing adjustment rejects difference above transaction amount limit',
    () {
      expect(
        () => adjust(closing: -999999999999999, wanted: 1),
        throwsFormatException,
      );
    },
  );
  test(
    'mark reconciled does not pass opening time or select epoch for all time',
    () {
      expect(reconciledCutoff(0, 10000), 10000);
      expect(reconciledCutoff(11000, 10000), 10000);
      expect(reconciledCutoff(9000, 10000), 9000);
    },
  );
  BookkeepingFormatter formatter([Map<String, dynamic> user = const {}]) =>
      BookkeepingFormatter(
        user: user,
        settings: {'timeZone': 'Etc/UTC'},
        messages: {},
        reference: {},
        language: 'en',
      );
  Map<String, dynamic> row(
    String date,
    int close, {
    int offset = 0,
    int seq = 0,
  }) => {
    'time': DateTime.parse(date).millisecondsSinceEpoch ~/ 1000,
    'accountClosingBalance': '$close',
    'utcOffset': offset,
    'timeSequenceId': '$seq',
  };
  List<ReconciliationBucket> buckets(
    List<Map<String, dynamic>> rows, {
    int aggregation = 4,
    bool original = false,
    bool liability = false,
    int? statementDay,
    Map<String, dynamic> user = const {},
  }) => reconciliationBuckets(
    rows,
    formatter(user),
    aggregation: aggregation,
    originalTimezone: original,
    liability: liability,
    statementDay: statementDay,
  );
  test(
    'daily chart is chronological and carries balances across empty dates',
    () {
      final values = buckets([
        row('2026-03-10T12:00:00Z', 200),
        row('2026-03-07T12:00:00Z', 100),
      ]);
      expect(values.map((v) => v.date.day), [7, 8, 9, 10]);
      expect(values.map((v) => v.close), [100, 100, 100, 200]);
    },
  );
  test('same second transactions follow timeSequenceId and liability sign', () {
    final values = buckets([
      row('2026-01-01T12:00:00Z', -300, seq: 20),
      row('2026-01-01T12:00:00Z', -100, seq: 10),
    ], liability: true);
    expect(values.single.close, 300);
  });
  test('chart respects transaction timezone instead of host timezone', () {
    expect(formatter().location?.name, 'Etc/UTC');
    final rows = [row('2026-09-15T23:30:00Z', 100, offset: 480)];
    expect(buckets(rows, original: true).single.date.day, 16);
    expect(buckets(rows).single.date.day, 15);
  });
  test('monthly chart fills empty month through leap year', () {
    final values = buckets([
      row('2024-01-31T12:00:00Z', 100),
      row('2024-03-31T12:00:00Z', 300),
    ], aggregation: 0);
    expect(values.map((v) => v.date.month), [1, 2, 3]);
    expect(values.map((v) => v.close), [100, 100, 300]);
  });
  test(
    'fiscal year and credit card statement boundaries match source rules',
    () {
      final rows = [
        row('2026-03-31T12:00:00Z', 100),
        row('2026-04-01T12:00:00Z', 200),
      ];
      final fiscal = buckets(
        rows,
        aggregation: 3,
        user: {'fiscalYearStart': (4 << 8) | 1},
      );
      expect(fiscal.map((v) => v.date), [
        DateTime.utc(2025, 4),
        DateTime.utc(2026, 4),
      ]);
      final billing = buckets(
        [row('2026-02-28T12:00:00Z', 100), row('2026-03-01T12:00:00Z', 200)],
        aggregation: 11,
        statementDay: 28,
      );
      expect(billing.map((v) => v.date), [
        DateTime.utc(2026, 2, 28),
        DateTime.utc(2026, 3, 28),
      ]);
    },
  );
  test('fiscal picker preserves all valid month end dates', () {
    for (var month = 1; month <= 12; month++) {
      final day = DateTime(2025, month + 1, 0).day;
      final date = fiscalYearPickerDate((month << 8) | day);
      expect(date.month, month);
      expect(date.day, day);
    }
    expect(fiscalYearPickerDate((2 << 8) | 29), DateTime(2025, 2, 28));
  });
}
