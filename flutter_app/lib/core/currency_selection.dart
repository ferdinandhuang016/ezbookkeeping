import 'dart:convert';

import 'package:flutter/services.dart';

typedef CurrencyRecord = Map<String, dynamic>;

Set<String> effectiveCurrencyCodes({
  required Map settings,
  required Map user,
  required List accounts,
  Iterable<String> extra = const [],
}) {
  final configured = settings['enabledCurrencies'];
  final enabled = <String>{
    if (configured is Map)
      for (final entry in configured.entries)
        if (entry.value == true) '${entry.key}',
    if (configured is! Map) 'CNY',
    if (configured is! Map) 'USD',
  };

  void collect(Iterable values) {
    for (final item in values.whereType<Map>()) {
      final currency = '${item['currency'] ?? ''}';
      if (currency.isNotEmpty && currency != '---') enabled.add(currency);
      collect(item['subAccounts'] as Iterable? ?? const []);
    }
  }

  collect(accounts);
  final defaultCurrency = '${user['defaultCurrency'] ?? ''}';
  if (defaultCurrency.isNotEmpty) enabled.add(defaultCurrency);
  enabled.addAll(extra.where((currency) => currency.isNotEmpty));
  return enabled;
}

Future<List<CurrencyRecord>> currencyChoices({Set<String>? allowed}) async {
  final decoded = jsonDecode(
    await rootBundle.loadString('assets/reference/currencies.json'),
  );
  final result = <CurrencyRecord>[];

  if (decoded is List) {
    for (final item in decoded.whereType<Map>()) {
      final code = '${item['code'] ?? ''}';
      if (code.isNotEmpty && (allowed == null || allowed.contains(code))) {
        result.add({'id': code, 'name': '$code · ${item['name']}'});
      }
    }
  } else if (decoded is Map) {
    for (final entry in decoded.entries) {
      final code = '${entry.key}';
      if (allowed == null || allowed.contains(code)) {
        final value = entry.value;
        result.add({
          'id': code,
          'name': '$code · ${value is Map ? value['name'] : value}',
        });
      }
    }
  }

  return result;
}
