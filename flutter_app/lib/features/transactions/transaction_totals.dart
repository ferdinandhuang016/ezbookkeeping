import '../catalogs/catalog_business.dart';

/// Mirrors calculateMonthTotalAmount: convert exact currency subtotals before
/// the final truncation, and count transfers only across the selected boundary.
Map<int, AccountDisplayBalance> transactionTotals({
  required Iterable<Map<String, dynamic>> transactions,
  required Iterable<Map<String, dynamic>> accounts,
  required Set<String> selectedAccounts,
  required String defaultCurrency,
  required Map<String, String> rates,
}) {
  final byId = {for (final account in accounts) '${account['id']}': account};
  bool selected(String id) =>
      selectedAccounts.contains(id) ||
      selectedAccounts.contains('${byId[id]?['parentId']}');
  final selectedCurrencies = {
    for (final id in selectedAccounts)
      if (byId[id]?['currency'] != null && byId[id]?['currency'] != '---')
        '${byId[id]!['currency']}',
  };
  final currency = selectedCurrencies.length == 1
      ? selectedCurrencies.single
      : defaultCurrency;
  final totals = {2: <String, int>{}, 3: <String, int>{}};
  for (final item in transactions) {
    var type = int.tryParse('${item['type']}') ?? 0;
    var accountId = '${item['sourceAccountId']}';
    var amount = int.tryParse('${item['sourceAmount']}') ?? 0;
    if (type == 4) {
      if (selectedAccounts.isEmpty) continue;
      final source = selected(accountId);
      final destination = selected('${item['destinationAccountId']}');
      if (source == destination) continue;
      type = source ? 3 : 2;
      if (destination) {
        accountId = '${item['destinationAccountId']}';
        amount = int.tryParse('${item['destinationAmount']}') ?? 0;
      }
    }
    final group = totals[type], accountCurrency = byId[accountId]?['currency'];
    if (group == null || accountCurrency == null) continue;
    group['$accountCurrency'] = (group['$accountCurrency'] ?? 0) + amount;
  }
  return {
    for (final entry in totals.entries)
      entry.key: sumConvertedBalances(entry.value, currency, rates),
  };
}
