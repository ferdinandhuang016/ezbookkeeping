import '../../core/formatting.dart';
import '../../core/aggregate_amount.dart';

int _integer(dynamic value) => int.tryParse('$value') ?? 0;

bool liabilityAccount(Map account) =>
    account['isLiability'] == true ||
    [3, 5].contains(_integer(account['category']));

/// The ledger stores liabilities with the opposite sign to their displayed debt.
int displayedAccountBalance(Map account) =>
    _integer(account['balance']) * (liabilityAccount(account) ? -1 : 1);

DateTime accountTimeForPicker(
  int seconds,
  BookkeepingFormatter formatter, {
  DateTime? now,
}) => formatter.localDate(
  seconds > 0
      ? DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
      : now ?? DateTime.now(),
);

class AccountDisplayBalance {
  const AccountDisplayBalance(this.value, this.currency, this.incomplete);
  final BigInt value;
  final String currency;
  final bool incomplete;
}

/// Parent/category balances sum decimal conversions before truncating for
/// display; global assets/liabilities instead truncate each account conversion.
class _BalanceSum {
  BigInt numerator = BigInt.zero, denominator = BigInt.one;
  bool incomplete = false;

  bool add(Object amount, String from, String to, Map<String, String> rates) {
    var n = aggregateAmount(amount), d = BigInt.one;
    if (n != BigInt.zero && from != to) {
      (BigInt, BigInt)? rate(String? value) {
        if (value == null || !RegExp(r'^\d+(\.\d+)?$').hasMatch(value)) {
          return null;
        }
        final parts = value.split('.');
        final n = BigInt.parse(parts.join());
        return n > BigInt.zero
            ? (n, BigInt.from(10).pow(parts.length == 2 ? parts[1].length : 0))
            : null;
      }

      final fromRate = rate(rates[from]), toRate = rate(rates[to]);
      if (fromRate == null || toRate == null) {
        incomplete = true;
        return false;
      }
      n *= toRate.$1 * fromRate.$2;
      d = toRate.$2 * fromRate.$1;
    }
    _add(n, d);
    return true;
  }

  void _add(BigInt n, BigInt d) {
    numerator = numerator * d + n * denominator;
    denominator *= d;
    final gcd = numerator.abs().gcd(denominator);
    numerator ~/= gcd;
    denominator ~/= gcd;
  }

  void merge(_BalanceSum other) {
    _add(other.numerator, other.denominator);
    incomplete = incomplete || other.incomplete;
  }

  AccountDisplayBalance result(String currency) =>
      AccountDisplayBalance(numerator ~/ denominator, currency, incomplete);
}

AccountDisplayBalance sumConvertedBalances(
  Map<String, Object> amountsByCurrency,
  String currency,
  Map<String, String> rates,
) {
  final sum = _BalanceSum();
  for (final entry in amountsByCurrency.entries) {
    sum.add(entry.value, entry.key, currency, rates);
  }
  return sum.result(currency);
}

List<Map<String, dynamic>> _children(Map account, bool showHidden) => [
  for (final sub in account['subAccounts'] as List? ?? [])
    if (showHidden || sub['hidden'] != true) Map<String, dynamic>.from(sub),
];

bool _hasCredit(Map account) =>
    _integer(account['category']) == 3 &&
    _integer(account['creditCardLimit']) > 0 &&
    account['currency'] != null &&
    account['currency'] != '' &&
    account['currency'] != '---';

AccountDisplayBalance? accountDisplayBalance(
  Map<String, dynamic> account,
  String defaultCurrency,
  Map<String, String> rates, {
  bool showHidden = false,
  bool availableCredit = false,
  Set<String>? selectedAccountIds,
}) {
  final multiple = _integer(account['type']) == 2;
  final credit = availableCredit && _integer(account['category']) == 3;
  if (credit && !_hasCredit(account)) return null;
  final children = multiple ? _children(account, showHidden) : [account];
  var currency = '${account['currency'] ?? ''}';
  if (multiple &&
      !(_integer(account['category']) == 3 &&
          currency != '---' &&
          currency.isNotEmpty)) {
    final currencies = children.map((item) => '${item['currency']}').toSet();
    currency = currencies.length == 1 ? currencies.single : defaultCurrency;
  }
  final sum = _BalanceSum();
  if (credit) {
    sum.add(_integer(account['creditCardLimit']), currency, currency, rates);
  }
  for (final item in children) {
    if (multiple &&
        !credit &&
        selectedAccountIds != null &&
        selectedAccountIds.isNotEmpty &&
        !selectedAccountIds.contains('${item['id']}')) {
      continue;
    }
    sum.add(
      displayedAccountBalance(item) * (credit ? -1 : 1),
      '${item['currency']}',
      currency,
      rates,
    );
  }
  return credit && sum.incomplete ? null : sum.result(currency);
}

AccountDisplayBalance? accountCategoryBalance(
  List<Map<String, dynamic>> accounts,
  int category,
  String currency,
  Map<String, String> rates, {
  bool availableCredit = false,
}) {
  final credit = availableCredit && category == 3;
  final sum = _BalanceSum();
  var availableCalculated = false;
  for (final account in accounts) {
    if (_integer(account['category']) != category ||
        account['hidden'] == true) {
      continue;
    }
    final children = _integer(account['type']) == 2
        ? _children(account, false)
        : [account];
    if (credit && children.isNotEmpty) {
      final balance = _BalanceSum();
      for (final child in children) {
        balance.add(
          _integer(child['balance']),
          '${child['currency']}',
          currency,
          rates,
        );
      }
      if (balance.incomplete) return null;
      if (!_hasCredit(account)) {
        sum.incomplete = true;
        continue;
      }
      final limit = _BalanceSum();
      if (!limit.add(
        _integer(account['creditCardLimit']),
        '${account['currency']}',
        currency,
        rates,
      )) {
        sum.incomplete = true;
        continue;
      }
      sum.merge(limit);
      sum.merge(balance);
      availableCalculated = true;
      continue;
    }
    for (final child in children) {
      sum.add(
        displayedAccountBalance(child),
        '${child['currency']}',
        currency,
        rates,
      );
    }
  }
  if (credit && !availableCalculated) return null;
  return sum.result(currency);
}

/// Mirrors Account.toCreateRequest / toModifyRequest in src/models/account.ts.
/// Existing balances are changed by transactions, never by account metadata.
Map<String, dynamic> accountRequest(
  Map<String, dynamic> account, {
  required bool modifying,
  int? parentCategory,
}) {
  final child = parentCategory != null;
  final category = parentCategory ?? _integer(account['category']);
  final multiple = !child && _integer(account['type']) == 2;
  final newChild =
      child && (account['id'] == null || '${account['id']}' == '0');
  return {
    if (modifying) 'id': '${account['id'] ?? '0'}',
    for (final key in ['name', 'icon', 'iconType', 'color', 'comment'])
      if (account[key] != null) key: account[key],
    'category': category,
    if (!modifying) 'type': multiple ? 2 : 1,
    if (!modifying || newChild || (!child && category == 3))
      'currency': multiple && category != 3 ? '---' : account['currency'],
    if (!modifying || newChild) ...{
      'balance': multiple ? '0' : '${account['balance'] ?? '0'}',
      'balanceTime': multiple ? 0 : _integer(account['balanceTime']),
    },
    if (modifying) ...{
      'hidden': account['hidden'] == true,
      if (account['lastReconciledTime'] != null)
        'lastReconciledTime': account['lastReconciledTime'],
    },
    if (!child && category == 3) ...{
      'creditCardStatementDate': _integer(account['creditCardStatementDate']),
      if (_integer(account['creditCardLimit']) > 0)
        'creditCardLimit': '${account['creditCardLimit']}',
    },
    if (multiple)
      'subAccounts': [
        for (final sub in account['subAccounts'] as List? ?? [])
          accountRequest(
            Map<String, dynamic>.from(sub as Map),
            modifying: modifying,
            parentCategory: category,
          ),
      ],
  };
}

Map<String, String> closingBalanceTransaction({
  required Map account,
  required int closingBalance,
  required int desiredDisplayedBalance,
  required int startTime,
  required int endTime,
  required int now,
}) {
  final difference =
      desiredDisplayedBalance -
      closingBalance * (liabilityAccount(account) ? -1 : 1);
  if (difference.abs() > 999999999999999) {
    throw const FormatException('Numeric Overflow');
  }
  final income = liabilityAccount(account) ? difference < 0 : difference >= 0;
  return {
    'accountId': '${account['id']}',
    'type': income ? '2' : '3',
    'amount': '${difference.abs()}',
    'noTransactionDraft': 'true',
    if (endTime > 0 && endTime < now) 'time': '$endTime',
    if (now < startTime) 'time': '$startTime',
  };
}

int reconciledCutoff(int endTime, int pageOpenTime) =>
    endTime == 0 || endTime > pageOpenTime ? pageOpenTime : endTime;

class ReconciliationBucket {
  ReconciliationBucket(this.date, this.close);
  final DateTime date;
  int close;
}

/// The mobile chart shows each period's closing balance, carrying the balance
/// through empty periods between transactions. Civil dates avoid DST gaps.
List<ReconciliationBucket> reconciliationBuckets(
  List<Map<String, dynamic>> transactions,
  BookkeepingFormatter formatter, {
  required int aggregation,
  required bool originalTimezone,
  required bool liability,
  int? statementDay,
}) {
  final sorted = [...transactions]
    ..sort((a, b) {
      final time = _integer(a['time']).compareTo(_integer(b['time']));
      if (time != 0) return time;
      return (BigInt.tryParse('${a['timeSequenceId']}') ?? BigInt.zero)
          .compareTo(BigInt.tryParse('${b['timeSequenceId']}') ?? BigInt.zero);
    });
  final grouped = <String, ReconciliationBucket>{};
  for (final item in sorted) {
    final date = formatter.transactionDate(
      item,
      originalTimezone: originalTimezone,
    );
    var bucket = DateTime.utc(date.year, date.month, date.day);
    switch (aggregation) {
      case 0:
        bucket = DateTime.utc(date.year, date.month);
      case 1:
        bucket = DateTime.utc(date.year, (date.month - 1) ~/ 3 * 3 + 1);
      case 2:
        bucket = DateTime.utc(date.year);
      case 3:
        final fiscal = formatter.fiscalYearStart(date);
        bucket = DateTime.utc(fiscal.year, fiscal.month, fiscal.day);
      case 11:
        final day = (statementDay ?? 1).clamp(1, 28);
        bucket = DateTime.utc(
          date.year,
          date.month + (date.day > day ? 1 : 0),
          day,
        );
    }
    final multiplier = liability ? -1 : 1;
    final close = _integer(item['accountClosingBalance']) * multiplier;
    final key = bucket.toIso8601String();
    final existing = grouped[key];
    if (existing == null) {
      grouped[key] = ReconciliationBucket(bucket, close);
    } else {
      existing.close = close;
    }
  }
  final values = grouped.values.toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  if (values.isEmpty) return values;
  DateTime next(DateTime date) => switch (aggregation) {
    0 || 11 => DateTime.utc(date.year, date.month + 1, date.day),
    1 => DateTime.utc(date.year, date.month + 3),
    2 || 3 => DateTime.utc(date.year + 1, date.month, date.day),
    _ => DateTime.utc(date.year, date.month, date.day + 1),
  };
  final filled = <ReconciliationBucket>[];
  var close = values.first.close;
  for (
    var date = values.first.date;
    !date.isAfter(values.last.date);
    date = next(date)
  ) {
    close = grouped[date.toIso8601String()]?.close ?? close;
    filled.add(ReconciliationBucket(date, close));
  }
  return filled;
}
