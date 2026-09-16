import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/features/settings/session_presentation.dart';

void main() {
  final fixtures =
      jsonDecode(File('test/session_fixtures.json').readAsStringSync()) as List;
  for (final fixture in fixtures) {
    test('original Web session: ${fixture['label']}', () {
      final result = presentSession(
        Map<String, dynamic>.from(fixture['token']),
      );
      expect(result.name, fixture['expected']['name']);
      expect(result.details, fixture['expected']['details']);
      expect(result.device.name, fixture['expected']['device']);
    });
  }
  test('native Android session names app without exposing raw headers', () {
    final result = presentSession({
      'userAgent': 'ezBookkeeping/1.0.0 (Linux; Android; Mobile) Flutter',
      'tokenType': 1,
      'isCurrent': true,
    });
    expect(result.name, 'Current');
    expect(result.device, SessionDevice.phone);
    expect(result.details, 'Android (ezBookkeeping 1.0.0)');
  });
}
