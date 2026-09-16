import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/core/app_controller.dart';
import 'package:ezbookkeeping/features/settings/data_settings.dart';
import 'package:ezbookkeeping/features/settings/mobile_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'exchange-rate baseline displays the number without currency decoration',
    () {
      final app = AppController();
      app.user = {'defaultCurrency': 'CNY', 'currencyDisplayType': 0};
      expect(exchangeRateBaseAmount(app, 100, 'CNY'), '1.00');
      expect(exchangeRateBaseAmount(app, -1234, 'USD'), '-12.34');
      app.user['currencyDisplayType'] = 1;
      expect(exchangeRateBaseAmount(app, 100, 'EUR'), '1.00');
      app.dispose();
    },
  );
  final fixture = jsonDecode(
    File('test/fixtures/web_exchange_about.json').readAsStringSync(),
  );
  test(
    'exchange-rate displayed precision matches the original mobile formatter',
    () {
      for (final row in fixture['display']) {
        expect(
          convertedRateAmount(row['cents'], row['from'], row['to']),
          row['expected'],
          reason: '$row',
        );
      }
    },
  );
  test('custom rates preserve original Go storage with default and changed base rates', () {
    for (final row in fixture['updateRates']) {
      final value = divideRate(row['target'], row['base']);
      for (final projection in (row['serverStored'] as Map).entries) {
        // CreateUserCustomExchangeRate parses decimal text then truncates after
        // applying the database's base currency rate, not before it.
        final stored = (double.parse(value) * int.parse(projection.key))
            .truncate();
        expect(
          stored,
          projection.value,
          reason: '${row['target']}/${row['base']} @ ${projection.key}',
        );
      }
    }
    expect(() => divideRate('1.00001', '1'), throwsFormatException);
    expect(() => divideRate('0', '1'), throwsFormatException);
  });
  test(
    'About provider websites and FAQ locale use the original mobile targets',
    () {
      expect(mapProviderWebsites, fixture['websites']);
      expect(mapProviderWebsites['custom'], isNull);
      expect(
        documentationUrl('zh-Hans'),
        'https://ezbookkeeping.mayswind.net/zh_Hans/faq/',
      );
      expect(
        documentationUrl('zh_Hant'),
        'https://ezbookkeeping.mayswind.net/zh_Hans/faq/',
      );
      expect(documentationUrl('en'), 'https://ezbookkeeping.mayswind.net/faq/');
      expect(
        externalWebUri('http://localhost:8000/books/help')?.path,
        '/books/help',
      );
      expect(externalWebUri('javascript:alert(1)'), isNull);
      expect(externalWebUri('https:///help'), isNull);
    },
  );
}
