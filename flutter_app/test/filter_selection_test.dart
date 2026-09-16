import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/features/settings/filter_selection.dart';

const accountItems = <Map<String, dynamic>>[
  {
    'id': '9223372036854775807',
    'name': 'Everyday Bank',
    'type': 2,
    'category': 2,
    'parentId': '0',
    'subAccounts': [
      {
        'id': '10',
        'name': 'Café EUR',
        'type': 1,
        'parentId': '9223372036854775807',
      },
      {'id': '11', 'name': 'USD', 'type': 1, 'parentId': '9223372036854775807'},
      {
        'id': '12',
        'name': 'Old EUR',
        'type': 1,
        'parentId': '9223372036854775807',
        'hidden': true,
      },
    ],
  },
  {'id': '20', 'name': 'Cash', 'type': 1, 'category': 1, 'parentId': '0'},
  {
    'id': '30',
    'name': 'Hidden Bank',
    'type': 2,
    'category': 2,
    'parentId': '0',
    'hidden': true,
    'subAccounts': [
      {'id': '31', 'name': 'Visible child', 'type': 1, 'parentId': '30'},
    ],
  },
];

const categoryItems = <Map<String, dynamic>>[
  {
    'id': '100',
    'name': 'Food',
    'type': 2,
    'parentId': '0',
    'subCategories': [
      {'id': '101', 'name': 'Lunch', 'type': 2, 'parentId': '100'},
      {'id': '102', 'name': 'Dinner', 'type': 2, 'parentId': '100'},
      {
        'id': '103',
        'name': 'Old Lunch',
        'type': 2,
        'parentId': '100',
        'hidden': true,
      },
    ],
  },
  {
    'id': '200',
    'name': 'Empty',
    'type': 2,
    'parentId': '0',
    'subCategories': [],
  },
];

const tagItems = <Map<String, dynamic>>[
  {'id': '1', 'name': 'Holiday', 'groupId': '0'},
  {'id': '2', 'name': 'Home', 'groupId': '0'},
  {'id': '3', 'name': 'Old Home', 'groupId': '0', 'hidden': true},
  {'id': '4', 'name': 'Work', 'groupId': '9'},
  {'id': '5', 'name': 'Office', 'groupId': '9'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFilterSearchCharacters);

  test('Search follows original accent, fullwidth, case folding and kana normalization', () {
    for (final pair in [
      ['Café', 'CAFE'],
      ['Ｓａｖｉｎｇｓ', 'savings'],
      ['Straße', 'STRASSE'],
      ['ひらがな', 'ヒラガナ'],
      ['Cafe\u0301', 'café'],
      ['한글', '한글'],
    ]) {
      expect(normalizeFilterSearch(pair[0]), normalizeFilterSearch(pair[1]));
    }
  });

  test('Account search retains matching child under parent and hides hidden ancestors', () {
    final result = visibleFilterItems(
      accountItems,
      'subAccounts',
      showHidden: false,
      search: 'cafe',
    );
    expect(result.map((item) => item['id']), ['9223372036854775807']);
    expect((result.single['subAccounts'] as List).map((item) => item['id']), [
      '10',
    ]);
    expect(
      visibleFilterItems(
        accountItems,
        'subAccounts',
        showHidden: false,
        search: 'Visible child',
      ),
      isEmpty,
    );
  });

  test('Matching account parent includes all visible children without changing original tree', () {
    final result = visibleFilterItems(
      accountItems,
      'subAccounts',
      showHidden: false,
      search: 'BANK',
    );
    expect((result.single['subAccounts'] as List).map((item) => item['id']), [
      '10',
      '11',
    ]);
    expect((accountItems.first['subAccounts'] as List).length, 3);
    final hidden = visibleFilterItems(
      accountItems,
      'subAccounts',
      showHidden: true,
      search: 'Bank',
    );
    expect(hidden.length, 2);
    expect((hidden.first['subAccounts'] as List).length, 3);
  });

  test(
    'Custom account parent IDs expand into children and use exact string IDs',
    () {
      final selection = FilterSelection(
        items: accountItems,
        account: true,
        selectedIds: ['9223372036854775807'],
      );
      expect(selection.selectedIds, ['9223372036854775807', '10', '11', '12']);
      expect(selection.savedExcluded, {'20': true, '30': true, '31': true});
    },
  );

  test('Omitted custom selection includes all while explicit empty selection includes none', () {
    final all = FilterSelection(items: accountItems, account: true);
    final none = FilterSelection(
      items: accountItems,
      account: true,
      selectedIds: [],
    );
    expect(all.savedExcluded, isEmpty);
    expect(none.selectedIds, isEmpty);
    expect(all.selectedIds.length, 7);
  });

  test('Parent checkbox derives mixed state; searching scopes parent toggle and final save uses full tree', () {
    final selection = FilterSelection(
      items: accountItems,
      account: true,
      selectedIds: ['10'],
    );
    expect(selection.checkboxValue(accountItems.first, parent: true), isNull);
    final filtered = visibleFilterItems(
      accountItems,
      'subAccounts',
      showHidden: false,
      search: 'USD',
    );
    selection.select(filtered.single, true, parent: true);
    expect(selection.selectedIds, ['10', '11']);
    expect(selection.savedExcluded['9223372036854775807'], isTrue);
    expect(selection.excluded['12'], isTrue);
    expect(selection.checkboxValue(filtered.single, parent: true), isTrue);
    expect(selection.checkboxValue(accountItems.first, parent: true), isNull);
  });

  test('Bulk account selection only changes visible leaves; inversion leaves hidden values intact', () {
    final selection = FilterSelection(
      items: accountItems,
      account: true,
      selectedIds: [],
    );
    final filtered = visibleFilterItems(
      accountItems,
      'subAccounts',
      showHidden: false,
      search: 'Bank',
    );
    selection.selectVisible(filtered, 0);
    expect(selection.selectedIds, ['10', '11']);
    expect(selection.excluded['12'], isTrue);
    selection.selectVisible(filtered, 2);
    expect(selection.selectedIds, isEmpty);
    selection.selectVisible(filtered, 0);
    selection.selectVisible(filtered, 1);
    expect(selection.selectedIds, isEmpty);
  });

  test('Persistent exclusion maps are isolated until save and missing keys remain included', () {
    final stored = {'11': true};
    final selection = FilterSelection(
      items: accountItems,
      account: true,
      initialExcluded: stored,
    );
    expect(selection.savedExcluded, {'9223372036854775807': true, '11': true});
    selection.select(accountItems.first, true, parent: true);
    expect(stored, {'11': true});
    expect(selection.savedExcluded, isEmpty);
  });

  test('Account total-amount selector omits hidden IDs from saved and returned settings', () {
    final selection = FilterSelection(
      items: accountItems,
      account: true,
      allowHidden: false,
      initialExcluded: {'12': true, '30': true},
    );
    expect(selection.savedExcluded, {'9223372036854775807': true});
    expect(selection.selectedIds, isNot(contains('12')));
    expect(selection.selectedIds, isNot(contains('30')));
    expect(selection.selectedIds, contains('31'));
  });

  test('Category parent expands selected IDs and searched bulk scope preserves hidden child', () {
    final selection = FilterSelection(
      items: categoryItems,
      account: false,
      selectedIds: ['100'],
    );
    expect(selection.selectedIds, ['100', '101', '102', '103']);
    final filtered = visibleFilterItems(
      categoryItems,
      'subCategories',
      showHidden: false,
      search: 'Lunch',
    );
    selection.selectVisible(filtered, 1);
    expect(selection.selectedIds, ['102', '103']);
    expect(selection.savedExcluded, {'100': true, '101': true, '200': true});
    expect(selection.checkboxValue(categoryItems.first, parent: true), isNull);
  });

  test('Empty primary category checkbox matches original no-op while bulk selection still saves it', () {
    final selection = FilterSelection(
      items: categoryItems,
      account: false,
      selectedIds: [],
    );
    expect(selection.checkboxValue(categoryItems.last, parent: true), isFalse);
    selection.select(categoryItems.last, true, parent: true);
    expect(selection.selectedIds, isEmpty);
    selection.selectVisible([categoryItems.last], 0);
    expect(selection.selectedIds, ['200']);
  });

  test('Tag round trip preserves per-group include/exclude modes and ignores deleted IDs', () {
    final selection = TagFilterSelection(tagItems, '1:1,2;3:3;0:4;2:5,missing');
    expect(selection.count('0', 1), 2);
    expect(selection.count('0', 2), 1);
    expect(selection.modes, {
      '0': [1, 3],
      '9': [0, 2],
    });
    expect(selection.encoded, '1:1,2;3:3;0:4;2:5');
  });

  test('Tag bulk search scope and hidden toggle do not reset other selections or matching modes', () {
    final selection = TagFilterSelection(tagItems, '1:1,2,3;3:4,5');
    final visible = visibleFilterItems(
      tagItems,
      'subCategories',
      showHidden: false,
      search: 'Home',
    );
    selection.setVisible(visible, 2);
    expect(selection.count('0', 1), 2);
    expect(selection.encoded, '1:1,3;2:2;3:4,5');
    selection.setVisible(visible, 0);
    expect(selection.encoded, '1:1,3;3:4,5');
    expect(selection.modes['0'], [1, 2]);
  });
}
