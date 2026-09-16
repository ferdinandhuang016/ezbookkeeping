import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/core/money.dart';
import 'package:ezbookkeeping/core/api_client.dart';

void main() {
  group('integer monetary rules', () {
    test('exact boundaries and negative cents', () {
      expect(Money.parse('9999999999999.99'), Money.maxAmount);
      expect(Money.parse('-9999999999999.99'), -Money.maxAmount);
      expect(Money.parse('-0.01'), -1);
      expect(Money.format(-1), '-0.01');
      expect(() => Money.parse('10000000000000'), throwsFormatException);
      expect(() => Money.parse('1.001'), throwsFormatException);
      expect(() => Money.parse('NaN'), throwsFormatException);
    });
    test('decimal rates round half up without binary floating point', () {
      expect(Money.convert(1, '1.5'), 2);
      expect(Money.convert(-1, '1.5'), -2);
      expect(Money.convert(10000, '0.12345'), 1235);
      expect(Money.convert(123456789, '0.000001'), 123);
    });
    test('calculator supports precedence and parentheses', () {
      expect(Money.calculate('0.1 + 0.2'), 30);
      expect(Money.calculate('(1 + 2) × 3'), 900);
      expect(Money.calculate('1/3*3'), 100);
      expect(Money.calculate('-(2 + 3) / 2'), -250);
      expect(Money.calculate('0.005'), 1);
      expect(() => Money.calculate('1 / 0'), throwsFormatException);
      expect(() => Money.calculate('1foo'), throwsFormatException);
      expect(() => Money.calculate('(1+2'), throwsFormatException);
    });
  });
  group('server deployment prefix', () {
    test('preserves path and port', () {
      final api = ApiClient(' https://example.org:8443/finance/ ');
      expect(api.serverUrl, 'https://example.org:8443/finance/');
      expect(api.dio.options.baseUrl, 'https://example.org:8443/finance/api/');
      expect(
        api.relativePath('/api/v1/transactions/list.json'),
        'v1/transactions/list.json',
      );
      expect(
        normalizeServerUrl('http://192.168.1.2:8080'),
        'http://192.168.1.2:8080/',
      );
    });
    test('rejects non-HTTP and embedded credentials', () {
      for (final value in [
        'ftp://example.org',
        'https://a:b@example.org',
        'https://example.org?token=a',
        'https://example.org/#fragment',
        'example.org',
      ]) {
        expect(() => normalizeServerUrl(value), throwsFormatException);
      }
    });
  });
}
