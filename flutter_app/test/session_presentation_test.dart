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
  test('native Android sessions show the current app name', () {
    for (final agent in [
      'ezBookkeeping/1.0.0 (Linux; Android; Mobile) Flutter',
      'DangguiExpense/1.0.0 (Linux; Android; Mobile) Flutter',
    ]) {
      final result = presentSession({
        'userAgent': agent,
        'tokenType': 1,
        'isCurrent': true,
      });
      expect(result.name, 'Current');
      expect(result.device, SessionDevice.phone);
      expect(result.details, 'Android (Danggui Expense 1.0.0)');
    }
  });
}
