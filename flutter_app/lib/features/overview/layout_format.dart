import 'dart:convert';

/// Same normalization contract as src/lib/overview_layout.ts. Invalid widget
/// entries/settings are skipped; malformed top-level layouts are rejected.
Map<String, dynamic> normalizeMobileLayout(
  Object? input,
  Map<String, dynamic> definitions,
) {
  if (input is! Map || input['widgets'] is! List) {
    throw const FormatException(
      'Layout import failed. Please make sure the layout is valid and try again.',
    );
  }
  final widgets = <Map<String, dynamic>>[];
  final ids = <String>{};
  for (final item in input['widgets'] as List) {
    if (widgets.length >= 100) break;
    if (item is! Map ||
        item['id'] is! String ||
        (item['id'] as String).isEmpty ||
        (item['id'] as String).length > 100 ||
        ids.contains(item['id']) ||
        definitions[item['type']] is! Map) {
      continue;
    }
    final definition = definitions[item['type']] as Map;
    final settings = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(definition['defaultSettings'])),
    );
    final source = item['settings'] is Map ? item['settings'] as Map : {};
    for (final spec in definition['supportsSettings'] as List) {
      final key = spec['settingName'] as String;
      final value = source[key];
      dynamic normalized;
      switch (spec['settingType']) {
        case 'itemCountSelect':
        case 'monthSelect':
          final allowed =
              spec[spec['settingType'] == 'itemCountSelect'
                      ? 'itemCountValues'
                      : 'monthValues']
                  as List;
          if (value is num &&
              value == value.truncateToDouble() &&
              allowed.contains(value)) {
            normalized = value.toInt();
          }
        case 'accountSelect':
        case 'categorySelect':
          if (value is List) normalized = value.whereType<String>().toList();
        case 'customSelect':
          final allowed = (spec['selectValues'] as List)
              .map((e) => e['value'])
              .toList();
          if (spec['multiple'] != true) {
            if ((value is String || value is num) && allowed.contains(value)) {
              normalized = value;
            }
          } else if (value is List) {
            final selected = <dynamic>[];
            var all = false;
            for (final choice in value) {
              if (spec.containsKey('allValue') && choice == spec['allValue']) {
                selected
                  ..clear()
                  ..add(choice);
                all = true;
                break;
              }
              if ((choice is String || choice is num) &&
                  allowed.any((option) => '$option' == '$choice') &&
                  !selected.any((option) => '$option' == '$choice')) {
                selected.add(choice);
              }
            }
            if (all ||
                selected.length >= (spec['minSelections'] as int? ?? 1)) {
              normalized = selected;
            }
          }
        case 'switch':
          if (value is bool) normalized = value;
        case 'color':
          if (value is String && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value)) {
            normalized = value.toLowerCase();
          }
        case 'amount':
          if (value is String) {
            final parts = value.split(':');
            final count = ['bt', 'nb'].contains(parts.first)
                ? 3
                : ['gt', 'lt', 'eq', 'ne'].contains(parts.first)
                ? 2
                : 0;
            if (parts.length == count &&
                parts
                    .skip(1)
                    .every((part) => RegExp(r'^\s*[+-]?\d+').hasMatch(part))) {
              normalized = value;
            }
          }
        case 'tagSelect':
        case 'textbox':
          if (value is String) normalized = value;
      }
      if (normalized != null &&
          (normalized is! String || normalized.trim().isNotEmpty)) {
        settings[key] = normalized;
      }
    }
    ids.add(item['id']);
    widgets.add({'id': item['id'], 'type': item['type'], 'settings': settings});
  }
  return {'widgets': widgets};
}
