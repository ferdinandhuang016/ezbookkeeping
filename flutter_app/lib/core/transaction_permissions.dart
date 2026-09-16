import 'formatting.dart';

/// Same edit window and account availability rules as the sync API presenter.
/// Re-evaluate on each edit: a cached permission can expire while offline.
bool transactionCanBeEdited({
  required Map<String, dynamic> transaction,
  required Map<String, dynamic> user,
  required List<Map<String, dynamic>> accounts,
  required BookkeepingFormatter formatter,
  DateTime? now,
}) {
  int value(dynamic v) => int.tryParse('$v') ?? 0;
  final byId = <String, Map<String, dynamic>>{};
  void index(List<Map<String, dynamic>> items) {
    for (final item in items) {
      byId['${item['id']}'] = item;
      index(
        (item['subAccounts'] as List? ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
      );
    }
  }

  index(accounts);
  bool available(Map<String, dynamic>? account) {
    if (account == null || value(account['type']) != 1) return false;
    final visited = <String>{};
    while (account != null) {
      if (account['hidden'] == true ||
          account['deleted'] == true ||
          !visited.add('${account['id']}')) {
        return false;
      }
      final parent = '${account['parentId'] ?? '0'}';
      if (parent == '0' || parent.isEmpty) return true;
      account = byId[parent];
    }
    return false;
  }

  final source = byId['${transaction['sourceAccountId']}'];
  final destination = value(transaction['type']) == 4
      ? byId['${transaction['destinationAccountId']}']
      : null;
  if (!available(source) ||
      value(transaction['type']) == 4 && !available(destination)) {
    return false;
  }
  if (!user.containsKey('transactionEditScope')) {
    return transaction['editable'] != false;
  }
  final scope = value(user['transactionEditScope']);
  if (scope == 0) return false;
  if (scope == 1) return true;
  final instant = now ?? DateTime.now();
  final local = formatter.localDate(instant);
  final today = formatter.wallTime(local.year, local.month, local.day);
  DateTime? minimum;
  switch (scope) {
    case 2:
      minimum = today;
    case 3:
      minimum = instant.subtract(const Duration(hours: 24));
    case 4:
      minimum = formatter.wallTime(
        local.year,
        local.month,
        local.day - (local.weekday % 7 - formatter.firstDayOfWeek + 7) % 7,
      );
    case 5:
      minimum = formatter.wallTime(local.year, local.month, 1);
    case 6:
      minimum = formatter.wallTime(local.year, 1, 1);
    case 7:
      if (user['useLastReconciledTime'] != true) return false;
      final a = value(source?['lastReconciledTime']);
      final b = value(destination?['lastReconciledTime']);
      return value(transaction['time']) > (a > b ? a : b);
    default:
      return false;
  }
  return value(transaction['time']) > minimum.millisecondsSinceEpoch ~/ 1000;
}
