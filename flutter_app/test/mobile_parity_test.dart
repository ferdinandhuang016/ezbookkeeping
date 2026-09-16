import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone;
import 'package:ezbookkeeping/core/formatting.dart';
import 'package:ezbookkeeping/core/onboarding.dart';
import 'package:ezbookkeeping/core/app_controller.dart';
import 'package:ezbookkeeping/features/transactions/transactions.dart';

class ParityController extends AppController {
  @override
  List<Map<String, dynamic>> get accounts => [
    {'id': 'cash', 'type': 1, 'parentId': '0'},
  ];
  @override
  List<Map<String, dynamic>> get categories => [
    {
      'id': 'income',
      'type': 1,
      'parentId': '0',
      'subCategories': [
        {'id': 'salary', 'type': 1, 'parentId': 'income'},
      ],
    },
    {
      'id': 'expense',
      'type': 2,
      'parentId': '0',
      'subCategories': [
        {'id': 'food', 'type': 2, 'parentId': 'expense'},
      ],
    },
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  timezone.initializeTimeZones();
  Map<String, dynamic> record(int amount) => {
    'type': 3,
    'sourceAmount': amount,
    'time': 1,
    'utcOffset': 0,
  };

  test(
    'wall time save preserves seconds with fixed offsets and DST transitions',
    () {
      final fixed = transactionTimeFromWall(
        DateTime(2026, 9, 15, 12, 34, 57),
        utcOffset: 330,
      );
      expect(
        fixed.time,
        DateTime.utc(2026, 9, 15, 7, 4, 57).millisecondsSinceEpoch ~/ 1000,
      );
      expect(fixed.utcOffset, 330);
      final before = transactionTimeFromWall(
        DateTime(2026, 3, 8, 1, 59, 37),
        timeZone: 'America/New_York',
      );
      final after = transactionTimeFromWall(
        DateTime(2026, 3, 8, 3, 0, 43),
        timeZone: 'America/New_York',
      );
      expect(
        before.time,
        DateTime.utc(2026, 3, 8, 6, 59, 37).millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        after.time,
        DateTime.utc(2026, 3, 8, 7, 0, 43).millisecondsSinceEpoch ~/ 1000,
      );
      expect(before.utcOffset, -300);
      expect(after.utcOffset, -240);
      expect(after.time - before.time, 66);
    },
  );

  test(
    'amount route parses its saved query and returns applied comparisons',
    () {
      final original = TransactionFilter()..readAmountFilter('gt:50');
      final route = TransactionFilter.fromAmountQuery({
        'type': 'bt',
        'value': 'bt:100:200',
      });
      expect(route.encodedAmountFilter, 'bt:100:200');
      final cancelled = route.copy()..minimumAmount = 150;
      expect(cancelled.encodedAmountFilter, 'bt:150:200');
      expect(original.encodedAmountFilter, 'gt:50');
      original.readAmountFilter(route.encodedAmountFilter);
      expect(original.matches(record(150)), isTrue);
      expect(original.matches(record(50)), isFalse);
      expect(
        TransactionFilter.fromAmountQuery({'type': 'lt', 'value': 'bt:100:200'})
            .encodedAmountFilter,
        'lt:100',
      );
      expect(
        TransactionFilter.fromAmountQuery({'type': 'eq'}).encodedAmountFilter,
        'eq:0',
      );
      expect(
        TransactionFilter.fromAmountQuery({'type': 'bad', 'value': 'bad:25'})
            .encodedAmountFilter,
        isEmpty,
      );
    },
  );

  test(
    'type selection prunes incompatible categories and keeps exact dates',
    () {
      final app = ParityController();
      final filter = TransactionFilter()
        ..categories = {'food', 'salary'}
        ..accounts = {'cash'}
        ..preciseTimes = true
        ..start = DateTime(2026, 9, 15, 1, 2, 3);
      filter.selectType(2, app.categories);
      expect(filter.categories, {'salary'});
      expect(filter.accounts, {'cash'});
      expect(filter.preciseTimes, isTrue);
      filter.selectType(1, app.categories);
      expect(filter.categories, isEmpty);
      expect(filter.start!.second, 3);
      app.dispose();
    },
  );

  test(
    'list Add carries selected fields, positive tags and the displayed period',
    () {
      final app = ParityController();
      final filter = TransactionFilter()
        ..type = 2
        ..accounts = {'cash'}
        ..categories = {'salary'}
        ..readTagFilter('0:payday;2:excluded;1:monthly')
        ..start = DateTime(2026, 8, 1)
        ..end = DateTime(2026, 8, 31);
      final query = transactionListAddQuery(filter, app, DateTime(2026, 9, 15));
      expect(query['type'], '2');
      expect(query['accountId'], 'cash');
      expect(query['categoryId'], 'salary');
      expect(query['tagIds'], 'payday,monthly');
      expect(
        query['time'],
        '${DateTime(2026, 8, 31, 23, 59, 59).millisecondsSinceEpoch ~/ 1000}',
      );
      filter.preciseTimes = true;
      filter.start = DateTime(2026, 10, 1, 1, 2, 3);
      filter.end = DateTime(2026, 10, 31, 4, 5, 6);
      expect(
        transactionListAddQuery(filter, app, DateTime(2026, 9, 15))['time'],
        '${filter.start!.millisecondsSinceEpoch ~/ 1000}',
      );
      filter.type = 0;
      expect(
        transactionListAddQuery(
          filter,
          app,
          DateTime(2026, 10, 15),
        ).containsKey('type'),
        isFalse,
      );
      app.dispose();
    },
  );

  test(
    'filter drafts isolate edits until applied and preserve precise times',
    () {
      final original = TransactionFilter()
        ..readAmountFilter('bt:100:200')
        ..readTagFilter('0:a,b;2:excluded')
        ..accounts = {'cash'}
        ..preciseTimes = true
        ..start = DateTime(2026, 9, 15, 1, 2, 3);
      final draft = original.copy();
      draft.minimumAmount = 150;
      draft.accounts.add('bank');
      (draft.additionalTagFilters.single['tagIds'] as List).add('other');
      expect(original.encodedAmountFilter, 'bt:100:200');
      expect(original.accounts, {'cash'});
      expect(original.encodedTagFilter, '0:a,b;2:excluded');
      original.replaceWith(draft);
      expect(original.encodedAmountFilter, 'bt:150:200');
      expect(original.accounts, {'cash', 'bank'});
      expect(original.encodedTagFilter, '0:a,b;2:excluded,other');
      expect(original.preciseTimes, isTrue);
      expect(original.start, DateTime(2026, 9, 15, 1, 2, 3));
      draft.accounts.clear();
      expect(original.accounts, {'cash', 'bank'});
    },
  );

  test('None clears the amount predicate and relation defaults are zero', () {
    final filter = TransactionFilter()..readAmountFilter('gt:100');
    expect(filter.matches(record(1)), isFalse);
    filter.selectAmountOperator('');
    expect(filter.encodedAmountFilter, isEmpty);
    expect(filter.matches(record(-999)), isTrue);
    expect(filter.matches(record(999)), isTrue);
    filter.selectAmountOperator('eq');
    expect(filter.encodedAmountFilter, 'eq:0');
    expect(filter.matches(record(0)), isTrue);
    expect(filter.matches(record(1)), isFalse);
  });

  test('time picker formats keep seconds and original meridiem order in all locales', () {
    for (final locale in Directory(
      'assets/locales',
    ).listSync().whereType<File>()) {
      final messages = jsonDecode(locale.readAsStringSync());
      for (var choice = 0; choice <= 3; choice++) {
        final formatter = BookkeepingFormatter(
          user: {'longTimeFormat': choice},
          settings: const {},
          messages: messages,
          reference: const {},
          language: 'en',
        );
        final tokens = RegExp(r'HH|hh|mm|ss|H|h|m|s|A')
            .allMatches(formatter.timePattern(withSeconds: true))
            .map((match) => match[0]![0])
            .toList();
        expect(
          tokens.where((token) => token == 's'),
          hasLength(1),
          reason: locale.path,
        );
        if (choice == 1) expect(tokens, ['H', 'm', 's']);
        if (choice == 2) expect(tokens, ['A', 'h', 'm', 's']);
        if (choice == 3) expect(tokens, ['h', 'm', 's', 'A']);
      }
    }
  });

  test('Between and Not Between reject inverted bounds including refunds', () {
    for (final operator in ['bt', 'nb']) {
      final filter = TransactionFilter()..readAmountFilter('$operator:100:50');
      expect(filter.amountProblem, 'Incorrect amount range');
      filter.readAmountFilter('$operator:-100:-200');
      expect(filter.amountProblem, 'Incorrect amount range');
      filter.readAmountFilter('$operator:-200:-100');
      expect(filter.amountProblem, isNull);
      filter.readAmountFilter('$operator:0:0');
      expect(filter.amountProblem, isNull);
    }
  });

  test(
    'preset payload keeps all types and selected locale without UI locale',
    () {
      final presets = Map<String, dynamic>.from(
        jsonDecode(
          File('assets/reference/category_presets.json').readAsStringSync(),
        ),
      );
      final english = jsonDecode(
        File('assets/locales/en.json').readAsStringSync(),
      );
      for (final locale in Directory(
        'assets/locales',
      ).listSync().whereType<File>()) {
        final messages = jsonDecode(locale.readAsStringSync());
        final result = registrationCategories(
          presets,
          (key) => translateMessage(messages, english, key),
        );
        expect(result.map((item) => item['type']).toSet(), {1, 2, 3});
        for (final category in result) {
          expect(category['name'], isNot(startsWith('category.')));
          expect(category['icon'], isNotNull);
          for (final child in category['subCategories']) {
            expect(child['type'], category['type']);
            expect(child['name'], isNot(startsWith('category.')));
          }
        }
        expect(
          translateMessage(messages, {}, 'Incorrect amount range'),
          locale.uri.pathSegments.last == 'en.json'
              ? 'Incorrect amount range'
              : isNot('Incorrect amount range'),
          reason: locale.path,
        );
      }
      final chinese = jsonDecode(
        File('assets/locales/zh_Hans.json').readAsStringSync(),
      );
      final result = registrationCategories({
        '2': presets['2'],
      }, (key) => translateMessage(chinese, english, key));
      expect(result.map((item) => item['type']).toSet(), {2});
      expect(result.first['name'], isNot(presets['2'].first['name']));
    },
  );
}
