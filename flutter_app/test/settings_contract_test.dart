import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:ezbookkeeping/features/settings/profile.dart';
import 'package:ezbookkeeping/features/settings/data_settings.dart';
import 'package:ezbookkeeping/core/money.dart';
import 'package:ezbookkeeping/features/system/recognition_contract.dart';

void main() {
  setUpAll(tz_data.initializeTimeZones);

  test('Profile settings reference retains all editable-range modes including reconciliation', () {
    final reference = jsonDecode(
      File('assets/reference/settings.json').readAsStringSync(),
    );
    final modes = reference['options']['TransactionEditScopeType'] as List;
    expect(modes.map((mode) => mode['id']).toList(), [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(modes.last['needLastReconciledTime'], true);
  });

  test('Exchange-rate baseline truncates fractional cents and clamps extreme conversions like mobile', () {
    expect(exchangeRateBaselineAmount('0.0099'), 0);
    expect(exchangeRateBaselineAmount('12.34999'), 1234);
    expect(exchangeRateBaselineAmount('-12.34999'), -1234);
    expect(
      exchangeRateBaselineAmount('999999999999999999999999.99'),
      Money.maxAmount,
    );
    expect(
      exchangeRateBaselineAmount('-999999999999999999999999.99'),
      -Money.maxAmount,
    );
  });

  test('Avatar response preserves unsaved profile edits and omitted profile fields', () {
    final original = <String, dynamic>{
      'nickname': 'Saved',
      'email': 'saved@example.test',
      'avatarUrl': '/old.png',
      'noPassword': true,
    };
    final current = {
      ...original,
      'nickname': 'Unsaved',
      'email': 'new@example.test',
    };
    final result = preserveProfileEdits(current, original, {
      'nickname': 'Saved',
      'email': 'saved@example.test',
      'avatarUrl': '/new.jpg',
    });
    expect(result['nickname'], 'Unsaved');
    expect(result['email'], 'new@example.test');
    expect(result['avatarUrl'], '/new.jpg');
    expect(result['noPassword'], true);
    expect(original['avatarUrl'], '/old.png');
  });

  test('Recognized transaction uses selected IANA timezone at transaction time, including DST', () {
    final zone = tz.getLocation('America/New_York');
    final winter = DateTime.utc(2026, 1, 15, 17);
    final summer = DateTime.utc(2026, 7, 15, 16);
    final response = <String, dynamic>{'type': 3, 'sourceAmount': 1850};
    final a = recognizedTransaction({
      ...response,
      'time': winter.millisecondsSinceEpoch ~/ 1000,
    }, zone);
    final b = recognizedTransaction({
      ...response,
      'time': summer.millisecondsSinceEpoch ~/ 1000,
    }, zone);
    expect(a['utcOffset'], -300);
    expect(b['utcOffset'], -240);
    expect(a['timeZone'], 'America/New_York');
    expect(a['time'], winter.millisecondsSinceEpoch ~/ 1000);
    expect(
      recognizedTransaction(response, zone, now: summer)['time'],
      summer.millisecondsSinceEpoch ~/ 1000,
    );
    expect(
      recognizedTransaction(
        {...response, 'time': 0},
        zone,
        now: summer,
      )['utcOffset'],
      -240,
    );
  });

  test('Shared PNG receipt is JPEG with original mobile 1280 pixel limit and aspect ratio', () {
    final source = image.Image(width: 1600, height: 900);
    final bytes = prepareRecognitionImage(image.encodePng(source));
    expect(bytes.take(2), [0xff, 0xd8]);
    final result = image.decodeJpg(bytes)!;
    expect(result.width, 1280);
    expect(result.height, 720);
  });

  test(
    'Small receipts are not enlarged and EXIF rotation is baked before upload',
    () {
      final source = image.Image(width: 40, height: 20);
      source.exif.imageIfd.orientation = 6;
      final result = image.decodeJpg(
        prepareRecognitionImage(image.encodeJpg(source)),
      )!;
      expect(result.width, 20);
      expect(result.height, 40);
      expect(result.exif.imageIfd.hasOrientation, false);
      expect(
        () => prepareRecognitionImage(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
    },
  );
}
