import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/features/settings/cloud_selection.dart';
import 'package:ezbookkeeping/core/application_settings.dart';

void main() {
  final reference = jsonDecode(
    File('assets/reference/settings.json').readAsStringSync(),
  );
  final groups = (reference['cloudGroups'] as List)
      .cast<Map<String, dynamic>>();
  CloudSettingsSelection draft() => CloudSettingsSelection(groups);
  test(
    'all 47 cloud keys include related keys but exclude local-only settings',
    () {
      final value = draft()..selectAll(true);
      expect(value.selected, (reference['cloudTypes'] as Map).keys.toSet());
      expect(value.selected, hasLength(47));
      expect(
        value.selected,
        contains('lastSelectedFileTypeInImportTransactionDialog'),
      );
      expect(value.selected, isNot(contains('theme')));
      expect(value.selected, isNot(contains('timeZone')));
      expect(value.selected, isNot(contains('pinHash')));
      value.invert();
      expect(value.selected, isEmpty);
      value.invert();
      expect(value.selected, hasLength(47));
      value.selectAll(false);
      expect(value.selected, isEmpty);
    },
  );
  test(
    'group checkbox and subcategories use the original primary-key tri-state',
    () {
      final value = draft();
      final group = groups.first;
      final item = (group['items'] as List).first as Map<String, dynamic>;
      expect(value.groupValue(group), false);
      value.selectItem(item, true);
      expect(value.groupValue(group), isNull);
      value.selectGroup(group, true);
      expect(value.groupValue(group), true);
      value.selectItem(item, false);
      expect(value.groupValue(group), isNull);
      value.selectGroup(group, false);
      expect(value.groupValue(group), false);
      expect(
        groups
            .where((group) => group['categoryName'] == 'Statistics Settings')
            .map((group) => group['categorySubName']),
        [
          'Common Settings',
          'Categorical Analysis Settings',
          'Trend Analysis Settings',
          'Asset Trends Settings',
        ],
      );
    },
  );
  test(
    'inverting an imported orphan related key follows the main checkbox',
    () {
      final value = draft();
      value.acceptRemote([
        {'settingKey': 'lastSelectedFileTypeInImportTransactionDialog'},
      ]);
      final item = value.items.firstWhere(
        (item) => item['relatedSettingKeys'] != null,
      );
      value.invert();
      expect(value.selected, containsAll(value.itemKeys(item)));
      value.selectItem(item, false);
      expect(
        value.selected.intersection(value.itemKeys(item).toSet()),
        isEmpty,
      );
    },
  );
  test('refresh updates committed state without overwriting unsubmitted checkboxes', () {
    final value = draft();
    value.acceptRemote([
      {'settingKey': 'showAccountBalance'},
    ]);
    value.selectItem(
      value.items.firstWhere((item) => item['settingKey'] == 'chartColors'),
      true,
    );
    final selected = Set.of(value.selected);
    value.acceptRemote([
      {'settingKey': 'autoUpdateExchangeRatesData'},
      {'settingKey': 'unknownFutureKey'},
    ]);
    expect(value.selected, selected);
    expect(value.saved, {'autoUpdateExchangeRatesData'});
    expect(value.enabled, true);
    expect(value.changed, true);
    value.acceptRemote(false);
    expect(value.selected, selected);
    expect(value.enabled, false);
    value.acceptRemote(false, preserveDraft: false);
    expect(value.selected, isEmpty);
    expect(value.saved, isEmpty);
    expect(value.changed, false);
  });
  test('successful upload adopts its exact keys and invalid loading leaves state intact', () {
    final value = draft()..selectAll(true);
    final rows = [
      for (final key in value.selected) {'settingKey': key},
    ];
    value.acceptRemote(rows, preserveDraft: false);
    expect(value.changed, false);
    expect(value.enabled, true);
    expect(() => value.acceptRemote(null), throwsFormatException);
    expect(value.selected, hasLength(47));
    value.acceptRemote([]);
    expect(value.selected, isEmpty);
    expect(value.enabled, false);
  });
  test('selected cloud values retain types and do not serialize local-only preferences', () {
    final selection = draft();
    selection.selectItem(
      selection.items.firstWhere(
        (item) => item['settingKey'] == 'statistics.defaultAccountFilter',
      ),
      true,
    );
    final preferences = {
      'theme': 'dark',
      'timeZone': 'Asia/Hong_Kong',
      'statistics': {
        'defaultAccountFilter': {'9223372036854775807': true},
        'defaultTimezoneType': 1,
      },
    };
    final wire = {
      for (final key in selection.selected)
        key: encodeCloudValue(settingValue(preferences, key)),
    };
    expect(wire.keys, ['statistics.defaultAccountFilter']);
    expect(decodeCloudValue(wire.values.single, 'string_boolean_map'), {
      '9223372036854775807': true,
    });
    expect(preferences['theme'], 'dark');
  });
}
