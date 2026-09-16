import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/features/overview/layout_format.dart';

void main() {
  final definitions = jsonDecode(
    File('assets/reference/overview_widgets.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  test('layout import/export matches original Web normalization', () {
    for (final fixture in jsonDecode(
      File('test/fixtures/web_mobile_layout.json').readAsStringSync(),
    ) as List) {
      final result = normalizeMobileLayout(fixture['input'], definitions);
      expect(result, fixture['expected']);
      expect(
        normalizeMobileLayout(jsonDecode(jsonEncode(result)), definitions),
        result,
      );
    }
  });
  test(
    'invalid layout root is rejected without changing an existing draft',
    () {
      for (final input in [
        null,
        [],
        '',
        5,
        {},
        {'widgets': null},
        {'widgets': {}},
      ]) {
        expect(
          () => normalizeMobileLayout(input, definitions),
          throwsFormatException,
        );
      }
    },
  );
  test('layout normalization deep-copies mutable widget defaults', () {
    final input = {
      'widgets': [
        {'id': 'p', 'type': 'period-income-expense'},
      ],
    };
    final first = normalizeMobileLayout(input, definitions);
    ((first['widgets'] as List).single['settings']['dateRanges'] as List)
        .clear();
    expect(
      (normalizeMobileLayout(input, definitions)['widgets'] as List)
          .single['settings']['dateRanges'],
      isNotEmpty,
    );
  });
  test('JSON numeric enum values follow JavaScript integer semantics', () {
    final result = normalizeMobileLayout(
      jsonDecode(
        '{"widgets":[{"id":"a","type":"current-month-overview","settings":{"height":1.0}}]}',
      ),
      definitions,
    );
    expect((result['widgets'] as List).single['settings']['height'], 1);
  });
}
