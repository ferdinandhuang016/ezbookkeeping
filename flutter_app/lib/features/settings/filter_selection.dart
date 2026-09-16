import 'dart:convert';

import 'package:flutter/services.dart';

import '../../ui/common.dart' show RecordData, flatten, number, records, string;

Map<String, String> _searchCharacters = {};

Future<void> loadFilterSearchCharacters() async {
  if (_searchCharacters.isNotEmpty) return;
  _searchCharacters = Map<String, String>.from(
    jsonDecode(
      await rootBundle.loadString('assets/reference/search_characters.json'),
    ),
  );
}

String normalizeFilterSearch(String value) => value.runes.map((code) {
  final character = String.fromCharCode(code);
  return _searchCharacters[character] ?? character;
}).join();

List<RecordData> visibleFilterItems(
  List<RecordData> items,
  String children, {
  required bool showHidden,
  required String search,
}) {
  final query = normalizeFilterSearch(search);
  final result = <RecordData>[];
  for (final item in items) {
    if (!showHidden && item['hidden'] == true) continue;
    final matches = normalizeFilterSearch(string(item['name'])).contains(query);
    final visibleChildren = records(item[children])
        .where(
          (child) =>
              (showHidden || child['hidden'] != true) &&
              (matches ||
                  normalizeFilterSearch(string(child['name'])).contains(query)),
        )
        .toList();
    if (matches || visibleChildren.isNotEmpty) {
      result.add({
        ...item,
        if (item.containsKey(children)) children: visibleChildren,
      });
    }
  }
  return result;
}

class FilterSelection {
  FilterSelection({
    required this.items,
    required this.account,
    this.allowHidden = true,
    Map<String, bool> initialExcluded = const {},
    List<String>? selectedIds,
  }) {
    for (final item in all) {
      if (allowHidden || item['hidden'] != true) {
        excluded[string(item['id'])] = selectedIds != null;
      }
    }
    if (selectedIds == null) {
      excluded.addAll(initialExcluded);
    } else {
      for (final item in all.where(
        (item) => selectedIds.contains(string(item['id'])),
      )) {
        if (records(item[children]).isEmpty) {
          excluded[string(item['id'])] = false;
        } else {
          select(item, true);
        }
      }
    }
  }

  final List<RecordData> items;
  final bool account, allowHidden;
  final excluded = <String, bool>{};
  String get children => account ? 'subAccounts' : 'subCategories';
  List<RecordData> get all => flatten(items, children);

  bool checked(RecordData item) {
    final childItems = records(item[children]);
    if (account && number(item['type']) == 2 && childItems.isEmpty) return true;
    if (childItems.isEmpty) return excluded[string(item['id'])] != true;
    return childItems.every((child) => excluded[string(child['id'])] != true);
  }

  bool? checkboxValue(RecordData item, {bool parent = false}) {
    final childItems = records(item[children]);
    if (parent && childItems.isEmpty) {
      return account && number(item['type']) == 2;
    }
    final count = childItems
        .where((child) => excluded[string(child['id'])] != true)
        .length;
    if (count > 0 && count < childItems.length) return null;
    return checked(item);
  }

  void select(RecordData item, bool included, {bool parent = false}) {
    final childItems = records(item[children]);
    if (childItems.isNotEmpty) {
      for (final child in childItems) {
        excluded[string(child['id'])] = !included;
      }
    } else if (!parent || (account && number(item['type']) != 2)) {
      excluded[string(item['id'])] = !included;
    }
  }

  void selectVisible(List<RecordData> visible, int action) {
    for (final item in flatten(visible, children)) {
      final id = string(item['id']);
      if (!excluded.containsKey(id) || (account && number(item['type']) == 2)) {
        continue;
      }
      excluded[id] = action == 0
          ? false
          : action == 1
          ? true
          : excluded[id] != true;
    }
  }

  List<String> get selectedIds => [
    for (final item in all)
      if (excluded.containsKey(string(item['id'])) &&
          (allowHidden || item['hidden'] != true) &&
          checked(item))
        string(item['id']),
  ];

  Map<String, bool> get savedExcluded => {
    for (final item in all)
      if (excluded.containsKey(string(item['id'])) &&
          (allowHidden || item['hidden'] != true) &&
          !checked(item))
        string(item['id']): true,
  };
}

class TagFilterSelection {
  TagFilterSelection(this.tags, String value) {
    for (final tag in tags) {
      states[string(tag['id'])] = 0;
      modes[string(tag['groupId'])] = [0, 2];
    }
    for (final piece in value.split(';')) {
      final parts = piece.split(':');
      if (parts.length != 2) continue;
      final mode = int.tryParse(parts[0]);
      if (mode == null || mode < 0 || mode > 3) continue;
      for (final tag in tags.where(
        (tag) => parts[1].split(',').contains(string(tag['id'])),
      )) {
        final side = mode < 2 ? 0 : 1;
        states[string(tag['id'])] = side + 1;
        modes[string(tag['groupId'])]![side] = mode;
      }
    }
  }

  final List<RecordData> tags;
  final states = <String, int>{};
  final modes = <String, List<int>>{};

  int count(String group, int state) => tags
      .where(
        (tag) =>
            string(tag['groupId']) == group &&
            states[string(tag['id'])] == state,
      )
      .length;

  void setVisible(List<RecordData> visible, int state) {
    for (final tag in visible) {
      states[string(tag['id'])] = state;
    }
  }

  String get encoded {
    final pieces = <String>[];
    for (final group in modes.keys) {
      for (var state = 1; state <= 2; state++) {
        final ids = tags
            .where(
              (tag) =>
                  string(tag['groupId']) == group &&
                  states[string(tag['id'])] == state,
            )
            .map((tag) => string(tag['id']));
        if (ids.isNotEmpty) {
          pieces.add('${modes[group]![state - 1]}:${ids.join(',')}');
        }
      }
    }
    return pieces.join(';');
  }
}
