import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/core/application_settings.dart';
import 'package:ezbookkeeping/features/settings/data_settings.dart'
    show divideRate, compareDecimal, convertedRateAmount;
import 'package:ezbookkeeping/features/system/map_contract.dart';

void main() {
  test(
    'Cloud filters retain decimal string IDs and reject invalid server values',
    () {
      const id = '9223372036854775807';
      final filter = {id: true, '2': false};
      expect(
        decodeCloudValue(encodeCloudValue(filter), 'string_boolean_map'),
        filter,
      );
      expect(
        () => decodeCloudValue('{"2":1}', 'string_boolean_map'),
        throwsFormatException,
      );
      expect(() => decodeCloudValue('1', 'boolean'), throwsFormatException);
      expect(() => decodeCloudValue('NaN', 'number'), throwsFormatException);
    },
  );
  test('Restoring a different user has independent nested defaults and keeps missing statistic defaults', () {
    final defaults = <String, dynamic>{
      'statistics': {
        'defaultAccountFilter': <String, bool>{},
        'defaultTimezoneType': 0,
      },
      'totalAmountExcludeAccountIds': <String, bool>{},
    };
    final first = mergeSettings(defaults, {
      'statistics': {'defaultTimezoneType': 1},
    });
    (first['totalAmountExcludeAccountIds'] as Map)['100'] = true;
    final second = mergeSettings(defaults, {});
    expect(second['totalAmountExcludeAccountIds'], isEmpty);
    expect(first['statistics']['defaultAccountFilter'], isEmpty);
    expect(second['statistics']['defaultTimezoneType'], 0);
    putSetting(first, 'statistics.defaultAccountFilter', {'100': true});
    expect(settingValue(second, 'statistics.defaultAccountFilter'), isEmpty);
  });
  test('Custom exchange rate preserves the ratio until the server applies its base rate', () {
    expect(divideRate('1', '3'), '0.33333333333333333333');
    expect(divideRate('2', '3'), '0.66666666666666666666');
    expect(divideRate('7.1000', '1'), '7.1');
    expect(divideRate('999999999.9999', '999999999.9999'), '1');
    expect(
      compareDecimal('0.0000000000002', '0.00000000000011'),
      greaterThan(0),
    );
    expect(() => divideRate('1', '0'), throwsFormatException);
    expect(() => divideRate('-1', '1'), throwsFormatException);
    expect(() => divideRate('1000000000', '1'), throwsFormatException);
    expect(convertedRateAmount(100, '1', '0.00000001234567'), '0.00000001234');
    expect(convertedRateAmount(0, '1', '12'), '0');
  });
  test('Map bridge rejects navigation outside the configured prefix and non-web schemes', () {
    final uri = Uri.parse('https://ledger.example/books/native-map');
    expect(
      isNativeMapUrl(uri, 'https://ledger.example/books/native-map'),
      isTrue,
    );
    for (final target in [
      'javascript:alert(1)',
      'file:///books/native-map',
      'https://attacker.example/books/native-map',
      'http://ledger.example/books/native-map',
      'https://ledger.example/native-map',
      'https://ledger.example/books/native-map?redirect=1',
      'https://user@ledger.example/books/native-map',
      'https://ledger.example/books/native-map#other',
    ]) {
      expect(isNativeMapUrl(uri, target), isFalse, reason: target);
    }
  });
  test('Map messages only allow bounded numeric coordinates', () {
    expect(
      mapCoordinate({'type': 'coordinate', 'latitude': 0, 'longitude': 0}),
      {'latitude': 0, 'longitude': 0},
    );
    expect(
      mapCoordinate({'type': 'coordinate', 'latitude': 90, 'longitude': 180}),
      isNotNull,
    );
    expect(
      mapCoordinate({'type': 'coordinate', 'latitude': '1', 'longitude': 0}),
      isNull,
    );
    expect(
      mapCoordinate({
        'type': 'coordinate',
        'latitude': double.nan,
        'longitude': 0,
      }),
      isNull,
    );
    expect(
      mapCoordinate({'type': 'coordinate', 'latitude': 91, 'longitude': 0}),
      isNull,
    );
    expect(
      mapCoordinate({'type': 'execute', 'latitude': 1, 'longitude': 2}),
      isNull,
    );
  });
  test('Map location messages preserve a bounded location name', () {
    expect(
      mapLocation({
        'type': 'coordinate',
        'latitude': 1,
        'longitude': 2,
        'name': 'Office',
      }),
      {'latitude': 1, 'longitude': 2, 'name': 'Office'},
    );
    expect(
      mapLocation({
        'type': 'coordinate',
        'latitude': 1,
        'longitude': 2,
        'name': 'x' * 256,
      }),
      isNull,
    );
  });
  test(
    'Coordinate preferences keep the original order, precision and directions',
    () {
      const point = {'latitude': -22.5, 'longitude': 114.25};
      expect(formatNativeCoordinate(point, 1), '-22.500000, 114.250000');
      expect(formatNativeCoordinate(point, 2), '114.250000, -22.500000');
      expect(
        formatNativeCoordinate(point, 3),
        '22°30.00000\'S, 114°15.00000\'E',
      );
      expect(
        formatNativeCoordinate(point, 6),
        '114°15\'0.0000"E, 22°30\'0.0000"S',
      );
    },
  );
  test('AMap coordinates are normalized to stored WGS84 coordinates', () {
    final converted = gcj02ToWgs84(39.908823, 116.39747);
    expect(converted['latitude'], closeTo(39.90742, 0.0001));
    expect(converted['longitude'], closeTo(116.39123, 0.0001));
    expect(gcj02ToWgs84(51.5074, -0.1278), {
      'latitude': 51.5074,
      'longitude': -0.1278,
    });
  });
}
