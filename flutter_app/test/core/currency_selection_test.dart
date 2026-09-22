import 'package:flutter_test/flutter_test.dart';

import 'package:ezbookkeeping/core/currency_selection.dart';

void main() {
  test(
    'effective currencies retain defaults and currencies used by accounts',
    () {
      final result = effectiveCurrencyCodes(
        settings: {
          'enabledCurrencies': {'CNY': false, 'EUR': true, 'USD': false},
        },
        user: {'defaultCurrency': 'CNY'},
        accounts: [
          {
            'currency': '---',
            'subAccounts': [
              {'currency': 'USD'},
            ],
          },
        ],
        extra: ['JPY'],
      );

      expect(result, {'CNY', 'EUR', 'USD', 'JPY'});
    },
  );

  test('new users default to CNY and USD when no setting exists', () {
    final result = effectiveCurrencyCodes(
      settings: const {},
      user: const {},
      accounts: const [],
    );

    expect(result, {'CNY', 'USD'});
  });
}
