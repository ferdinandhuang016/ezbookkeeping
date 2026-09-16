import 'package:ezbookkeeping/core/app_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('automatic cloud application preserves pending local values; explicit selected download replaces only its keys', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const channels = [
      MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
        MethodChannel('com.llfbandit.app_links/events'),
        MethodChannel('com.llfbandit.app_links/messages'),
      MethodChannel('ezbookkeeping/native'),
    ];
    for (final channel in channels) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'readShareFiles' ? <String>[] : null,
      );
    }
    final app = AppController();
    try {
      await app.initialize();
      expect(app.error, isNull);
      app.settings['theme'] = 'dark';
      app.settings['fontSize'] = 3;
      app.settings['timeZone'] = 'Asia/Hong_Kong';
      const remote = [
        {'settingKey': 'showAccountBalance', 'settingValue': 'false'},
        {
          'settingKey': 'statistics.defaultAccountFilter',
          'settingValue': '{"9223372036854775807":true}',
        },
      ];
      await app.applyCloudSettings(remote);
      expect(app.settings['showAccountBalance'], false);
      expect(app.settings['statistics']['defaultAccountFilter'], {
        '9223372036854775807': true,
      });
      await app.setPreference('showAccountBalance', true);
      await app.applyCloudSettings(remote);
      expect(app.settings['showAccountBalance'], true);
      await app.applyCloudSettings(
        [
          ...remote,
          {'settingKey': 'statistics.defaultTimezoneType', 'settingValue': '1'},
          {'settingKey': 'theme', 'settingValue': 'light'},
        ],
        selected: {'showAccountBalance'},
      );
      expect(app.settings['showAccountBalance'], false);
      expect(app.settings['statistics']['defaultTimezoneType'], 0);
      expect(app.settings['theme'], 'dark');
      expect(app.settings['fontSize'], 3);
      expect(app.settings['timeZone'], 'Asia/Hong_Kong');
      await app.applyCloudSettings(false);
      expect(app.settings['showAccountBalance'], false);
      expect(app.settings['theme'], 'dark');
    } finally {
      app.dispose();
      await Future<void>.delayed(Duration.zero);
      for (final channel in channels) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    }
  });
}
