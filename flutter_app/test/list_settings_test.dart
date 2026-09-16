import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/core/list_settings.dart';
import 'package:ezbookkeeping/ui/common.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final reference = jsonDecode(
    File('assets/reference/settings.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final defaults = (reference['chartColors'] as List).cast<String>();
  const defaultOrder = ['1', '2', '8', '3', '4', '5', '6', '9', '7'];

  test('Stored chart colors normalize valid tokens and reject prefixed values like original settings', () {
    expect(
      effectiveChartColors(
        '  C67E48 ,invalid, 001122 ,#ffffff,fff,000000',
        defaults,
      ),
      ['c67e48', '001122', '000000'],
    );
  });

  test(
    'Empty and invalid stored palettes restore an independent default draft',
    () {
      for (final value in ['', ',bad,,#fff,#123456']) {
        final current = effectiveChartColors(value, defaults);
        expect(current, defaults);
        current.removeLast();
        expect(effectiveChartColors(value, defaults), defaults);
        expect(current.length, defaults.length - 1);
      }
    },
  );

  test(
    'Editor and chart rendering share cloud palette normalization and fallback',
    () {
      final app = AppController();
      addTearDown(app.dispose);
      for (final value in ['', 'invalid', ' C67E48 ,bad, 001122 ', '#ffffff']) {
        app.settings['chartColors'] = value;
        final draft = effectiveChartColors(value, defaults);
        expect(appChartColors(app), draft.map(itemColor).toList());
      }
    },
  );

  test('Multiline imports accept optional hash and comma while preserving valid duplicates', () {
    expect(importChartColors(' #C67E48\r\n001122, #ffffff\nnope\n#c67e48'), [
      'c67e48',
      '001122',
      'ffffff',
      'c67e48',
    ]);
  });

  test('Failed import rejects before assigning the palette and leaves text available to correct', () {
    var draft = ['001122', '334455'];
    var input = 'invalid\n#fff';
    expect(() => draft = importChartColors(input), throwsFormatException);
    expect(draft, ['001122', '334455']);
    expect(input, 'invalid\n#fff');
    input = '#abcdef\n123456';
    draft = importChartColors(input);
    expect(draft, ['abcdef', '123456']);
  });

  test('Reset palettes use the original empty sentinel; custom order survives roundtrip', () {
    expect(encodeSettingOrder([...defaults], defaults), '');
    expect(
      effectiveChartColors(encodeSettingOrder(defaults, defaults), defaults),
      defaults,
    );
    const custom = ['abcdef', '001122'];
    expect(encodeSettingOrder(custom, defaults), 'abcdef,001122');
    expect(
      effectiveChartColors(encodeSettingOrder(custom, defaults), defaults),
      custom,
    );
  });

  test('Default account categories retain original IDs, reset sentinel and dirty state', () {
    final options = (reference['options']['AccountCategory'] as List)
        .map((item) => '${item['id']}')
        .toList();
    expect(options, defaultOrder);
    expect(settingOrderModified([...defaultOrder], defaultOrder), isFalse);
    final moved = [...defaultOrder]..remove('7');
    moved.insert(0, '7');
    expect(settingOrderModified(moved, defaultOrder), isTrue);
    expect(encodeSettingOrder(moved, defaultOrder), '7,1,2,8,3,4,5,6,9');
    expect(encodeSettingOrder([...defaultOrder], defaultOrder), '');
    expect(defaultOrder.first, '1');
  });

  test(
    'Palette dirty state clears when an edit is restored to its starting value',
    () {
      final saved = effectiveChartColors('C67E48,001122', defaults);
      expect(settingOrderModified(['c67e48', '001122'], saved), isFalse);
      expect(settingOrderModified(['001122', 'c67e48'], saved), isTrue);
      expect(settingOrderModified(['c67e48', '001122'], saved), isFalse);
      expect(settingOrderModified([], saved), isTrue);
    },
  );

  test('Drag list stays inside a small viewport and makes long or large-text content scroll', () {
    expect(
      settingsListViewportHeight(
        availableHeight: 500,
        itemCount: 2,
        fontSize: 17,
      ),
      128,
    );
    expect(
      settingsListViewportHeight(
        availableHeight: 220,
        itemCount: 30,
        fontSize: 17,
      ),
      220,
    );
    expect(
      settingsListViewportHeight(
        availableHeight: 220,
        itemCount: 3,
        fontSize: 40,
      ),
      220,
    );
    expect(
      settingsListViewportHeight(
        availableHeight: -20,
        itemCount: 3,
        fontSize: 40,
      ),
      0,
    );
    expect(
      settingsListViewportHeight(
        availableHeight: 500,
        itemCount: 0,
        fontSize: 17,
      ),
      0,
    );
  });
}
