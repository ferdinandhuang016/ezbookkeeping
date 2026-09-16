import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:ezbookkeeping/core/api_client.dart';
import 'package:ezbookkeeping/core/formatting.dart';
import 'package:ezbookkeeping/core/native_localization.dart';

Map<String, dynamic> readMessages(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  final english = readMessages('assets/native_locales/en.json');
  final chinese = {
    ...readMessages('assets/locales/zh_Hans.json'),
    ...readMessages('assets/native_locales/zh_Hans.json'),
  };
  String tr(String key) => translateMessage(chinese, english, key);

  test('all 21 native locales contain identical keys and placeholders', () {
    final files = Directory('assets/native_locales')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList();
    expect(files, hasLength(21));
    List<String> parameters(String value) =>
        RegExp(r'\{\w+\}').allMatches(value).map((match) => match[0]!).toList()
          ..sort();
    for (final file in files) {
      final messages = readMessages(file.path);
      expect(messages.keys.toSet(), english.keys.toSet(), reason: file.path);
      for (final entry in messages.entries) {
        expect(
          entry.value,
          isA<String>(),
          reason: '${file.path}: ${entry.key}',
        );
        expect((entry.value as String).trim(), isNotEmpty);
        expect(parameters(entry.value), parameters(english[entry.key]));
      }
    }
  });

  test('native assets never overwrite or modify original Web translations', () {
    for (final file in Directory(
      'assets/locales',
    ).listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      final original = readMessages(file.path);
      final additions = readMessages('assets/native_locales/$name');
      for (final key in additions.keys) {
        expect(original[key], isNot(isA<String>()), reason: '$name: $key');
      }
      expect(
        file.readAsBytesSync(),
        File('../src/locales/$name').readAsBytesSync(),
        reason: '$name must remain the exact original Web locale',
      );
    }
  });

  test('new native messages are translated in every non-English locale', () {
    final lines = File('tool/native_messages.psv').readAsLinesSync();
    final keys = lines
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .map((line) => line.split('|').first.replaceFirst('\uFEFF', ''));
    for (final file in Directory(
      'assets/native_locales',
    ).listSync().whereType<File>()) {
      if (file.uri.pathSegments.last == 'en.json') continue;
      final messages = readMessages(file.path);
      for (final key in keys) {
        // These are identical standard terms, not untranslated fallback text.
        if (const [
          'Server',
          'Avatar',
          'Preview',
          'Conflict',
          'Later',
        ].contains(key)) {
          continue;
        }
        expect(messages[key], isNot(key), reason: '${file.path}: $key');
      }
    }
  });

  test(
    'typed and persisted validation exceptions retain a translated cause',
    () {
      expect(localizedErrorText(StateError('Incorrect PIN'), tr), 'PIN码错误');
      expect(
        localizedErrorText(const FormatException('Invalid coordinates'), tr),
        tr('Invalid coordinates'),
      );
      expect(
        localizedErrorText('Bad state: Incorrect PIN', tr),
        tr('Incorrect PIN'),
      );
      expect(
        localizedErrorText(
          'FormatException: Amount value exceeds limitation',
          tr,
        ),
        tr('Amount value exceeds limitation'),
      );
      expect(
        localizedErrorText(StateError('unrecognized diagnostic 42'), tr),
        'unrecognized diagnostic 42',
      );
    },
  );

  test('backend API messages reuse original error translations', () {
    const error = ApiException(
      'current token is invalid',
      code: 202001,
      status: 401,
    );
    expect(
      localizedErrorText(error, tr),
      chinese['error']['current token is invalid'],
    );
    expect(localizedErrorText(error, tr), isNot(error.message));
    expect(error.code, 202001);
    expect(error.status, 401);
    expect(error.message, 'current token is invalid');
  });

  test('format diagnostics and nested persisted wrappers are retained', () {
    final output = localizedErrorText(
      const FormatException('Invalid decimal', '12x', 2),
      tr,
    );
    expect(output, startsWith(tr('Invalid decimal')));
    expect(output, contains('12x'));
    expect(output, contains('^'));
    expect(
      localizedErrorText(
        const FormatException('FormatException: Invalid expression'),
        tr,
      ),
      tr('Invalid expression'),
    );
    expect(
      localizedErrorText(const FormatException(), tr),
      tr('An error occurred'),
    );
  });

  test('platform failures localize the summary and preserve diagnostics', () {
    final output = localizedErrorText(
      PlatformException(
        code: 'camera_access_denied',
        message: 'Camera permission denied',
        details: 'provider=android',
      ),
      tr,
    );
    expect(output, startsWith(tr('Permission denied')));
    expect(output, contains('Camera permission denied'));
    expect(output, contains('provider=android'));
    final biometric = localizedErrorText(
      const LocalAuthException(
        code: LocalAuthExceptionCode.temporaryLockout,
        details: 'device diagnostic',
      ),
      tr,
    );
    expect(
      biometric,
      startsWith(tr('Too many attempts. Please wait before trying again')),
    );
    expect(biometric, contains('device diagnostic'));
  });
}
