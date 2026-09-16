import 'package:flutter/material.dart' show Theme;

import '../../core/formatting.dart';
import '../../core/aggregate_amount.dart';
import '../../ui/common.dart';
import '../transactions/transactions.dart';
import 'statistics_range.dart';
import 'statistics_bars.dart';
import 'statistics_pie.dart';
import 'statistics_history.dart';

const chartDataNames = <int, String>{
  11: 'Outflows By Account',
  0: 'Expense By Account',
  1: 'Expense By Primary Category',
  2: 'Expense By Secondary Category',
  12: 'Inflows By Account',
  3: 'Income By Account',
  4: 'Income By Primary Category',
  5: 'Income By Secondary Category',
  6: 'Account Total Assets',
  7: 'Account Total Liabilities',
  18: 'Total Assets By Currency',
  19: 'Total Liabilities By Currency',
  13: 'Total Outflows',
  8: 'Total Expense',
  14: 'Total Inflows',
  9: 'Total Income',
  15: 'Net Cash Flow',
  10: 'Net Income',
  17: 'Net Worth',
};
const categoricalData = [11, 0, 1, 2, 12, 3, 4, 5, 6, 7, 18, 19];
const trendData = [11, 0, 1, 2, 12, 3, 4, 5, 13, 8, 14, 9, 15, 10];
const assetData = [6, 7, 17];

({DateTime start, DateTime end}) statisticsBucketRange(
  BookkeepingFormatter formatter,
  DateTime date,
  int aggregation,
) {
  final start = switch (aggregation) {
    4 => formatter.wallTime(date.year, date.month, date.day),
    1 => formatter.wallTime(date.year, (date.month - 1) ~/ 3 * 3 + 1, 1),
    2 => formatter.wallTime(date.year, 1, 1),
    3 => formatter.fiscalYearStart(date),
    _ => formatter.wallTime(date.year, date.month, 1),
  };
  final next = switch (aggregation) {
    4 => formatter.wallTime(start.year, start.month, start.day + 1),
    1 => formatter.wallTime(start.year, start.month + 3, 1),
    2 || 3 => formatter.wallTime(start.year + 1, start.month, start.day),
    _ => formatter.wallTime(start.year, start.month + 1, 1),
  };
  return (start: start, end: next.subtract(const Duration(seconds: 1)));
}

TransactionFilter statisticsDrilldown(
  AppController app,
  TransactionFilter source,
  int dataType, {
  String? itemId,
  DateTime? start,
  DateTime? end,
  DateTime? now,
}) {
  final result = source.copy();
  if ([0, 1, 2, 8].contains(dataType)) result.type = 3;
  if ([3, 4, 5, 9].contains(dataType)) result.type = 2;
  if ((start != null || end != null) && !result.preciseTimes) {
    DateTime boundary(DateTime value, bool last) => app.formatter.wallTime(
      value.year,
      value.month,
      value.day,
      last ? 23 : 0,
      last ? 59 : 0,
      last ? 59 : 0,
    );
    if (result.start != null) result.start = boundary(result.start!, false);
    if (result.end != null) result.end = boundary(result.end!, true);
  }
  if (start != null && (result.start == null || start.isAfter(result.start!))) {
    result.start = start;
  }
  if (end != null && (result.end == null || end.isBefore(result.end!))) {
    result.end = end;
  }
  if (start != null || end != null) {
    result.preciseTimes = true;
    result.periodType = 255;
    final minTime = result.start?.millisecondsSinceEpoch;
    final maxTime = result.end?.millisecondsSinceEpoch;
    // TrendsBarChart detects the period after clipping it to the chart range.
    for (final type in dateRangesForScene(0).keys) {
      final range = app.formatter.dateRange(type, now: now);
      if (range != null &&
          range.minTime * 1000 == minTime &&
          range.maxTime * 1000 == maxTime) {
        result.periodType = type;
        break;
      }
    }
  }
  if ([6, 7, 18, 19].contains(dataType) && start == null) {
    result.start = null;
    result.end = null;
    result.periodType = 0;
    result.preciseTimes = false;
  }
  if (itemId != null && itemId.isNotEmpty) {
    if ([1, 2, 4, 5].contains(dataType)) {
      final ids = expandSelection(
        itemId.split(','),
        app.categories,
        'subCategories',
      );
      result.categories = result.categories.isEmpty
          ? ids
          : ids.intersection(result.categories);
      result.noCategories = result.categories.isEmpty;
    } else if ([0, 3, 6, 7, 11, 12, 18, 19].contains(dataType)) {
      final ids = [18, 19].contains(dataType)
          ? flatten(app.accounts, 'subAccounts')
                .where(
                  (account) =>
                      string(account['currency']) == itemId &&
                      ([3, 5].contains(number(account['category'])) ==
                          (dataType == 19)),
                )
                .map((account) => string(account['id']))
                .toSet()
          : expandSelection(itemId.split(','), app.accounts, 'subAccounts');
      result.accounts = result.accounts.isEmpty
          ? ids
          : ids.intersection(result.accounts);
      result.noAccounts = result.accounts.isEmpty;
    }
  }
  return result;
}

class LedgerStatistics {
  LedgerStatistics(this.app);
  final AppController app;
  List<RecordData> get accounts => flatten(app.accounts, 'subAccounts');
  List<RecordData> get categories => flatten(app.categories, 'subCategories');
  String get currency => string(app.user['defaultCurrency']);
  List<int> displayOrders(String id, int dataType) {
    final category = [1, 2, 4, 5].contains(dataType);
    final item = lookup(category ? categories : accounts, id);
    var parent = lookup(category ? categories : accounts, item['parentId']);
    if (parent.isEmpty) parent = item;
    if (category) {
      return [
        number(parent['type']),
        number(parent['displayOrder']),
        if ([2, 5].contains(dataType)) number(item['displayOrder']),
      ];
    }
    final order = string(app.settings['accountCategoryOrders'])
        .split(',')
        .indexOf(string(parent['category']));
    return [
      order < 0 ? 999999 : order,
      number(parent['displayOrder']),
      number(item['displayOrder']),
    ];
  }

  int compareEntries(
    MapEntry<String, BigInt> a,
    MapEntry<String, BigInt> b,
    int dataType,
    int sort,
  ) {
    if (sort == 0 && a.value != b.value) return b.value.compareTo(a.value);
    if (sort != 2) {
      final left = displayOrders(a.key, dataType),
          right = displayOrders(b.key, dataType);
      for (var i = 0; i < left.length && i < right.length; i++) {
        if (left[i] != right[i]) return left[i].compareTo(right[i]);
      }
    }
    final records = [1, 2, 4, 5].contains(dataType) ? categories : accounts;
    return recordName(
      records,
      a.key,
    ).toLowerCase().compareTo(recordName(records, b.key).toLowerCase());
  }

  BigInt categoricalTotal(
    List<RecordData> items,
    int dataType, {
    Set<String> accountFilter = const {},
    bool monthly = false,
    DateTime Function(RecordData)? dateOf,
  }) => categorical(
    items.where((item) {
      if (![11, 12].contains(dataType) || number(item['type']) != 4) {
        return true;
      }
      final other = string(
        item[dataType == 11 ? 'destinationAccountId' : 'sourceAccountId'],
      );
      return accountFilter.isNotEmpty && !accountFilter.contains(other);
    }).toList(),
    dataType,
    accountFilter: accountFilter,
    monthly: monthly,
    dateOf: dateOf,
  ).values.fold(BigInt.zero, (a, b) => a + b);
  bool hidden(String key, int dataType) {
    if ([18, 19].contains(dataType)) return false;
    final records = [1, 2, 4, 5].contains(dataType) ? categories : accounts;
    final item = lookup(records, key);
    return item['hidden'] == true ||
        lookup(records, item['parentId'])['hidden'] == true;
  }

  BigInt originalCurrencyBalance(
    String currency,
    int dataType,
    Set<String> selected,
  ) => accounts
      .where(
        (item) =>
            number(item['type']) != 2 &&
            item['hidden'] != true &&
            string(item['currency']) == currency &&
            (selected.isEmpty || selected.contains(string(item['id']))) &&
            ([3, 5].contains(number(item['category'])) == (dataType == 19)),
      )
      .fold<BigInt>(
        BigInt.zero,
        (sum, item) =>
            sum +
            aggregateAmount(item['balance']) *
                BigInt.from(dataType == 19 ? -1 : 1),
      );
  BigInt convert(Object value, String from) {
    final amount = aggregateAmount(value);
    if (amount == BigInt.zero || from == currency || from.isEmpty) {
      return amount;
    }
    final cached = app.settings['cachedExchangeRates'];
    final data = cached is Map
        ? Map<String, dynamic>.from(cached)
        : <String, dynamic>{};
    final rates = {
      string(data['baseCurrency']): '1',
      for (final rate in records(data['exchangeRates']))
        string(rate['currency']): string(rate['rate']),
    };
    if (!rates.containsKey(from) || !rates.containsKey(currency)) {
      throw StateError('Exchange rate unavailable: $from → $currency');
    }
    return BookkeepingFormatter.convertAggregate(
      amount,
      rates[from]!,
      rates[currency]!,
      truncate: true,
    );
  }

  BigInt transactionValue(RecordData item, {bool destination = false}) =>
      convert(
        item[destination ? 'destinationAmount' : 'sourceAmount'] ?? 0,
        string(
          lookup(
            accounts,
            item[destination ? 'destinationAccountId' : 'sourceAccountId'],
          )['currency'],
        ),
      );
  BigInt sum(Iterable<RecordData> items, int type) {
    final amounts = <String, BigInt>{};
    for (final item in items.where((item) => number(item['type']) == type)) {
      final currency = string(
        lookup(accounts, item['sourceAccountId'])['currency'],
      );
      amounts[currency] =
          (amounts[currency] ?? BigInt.zero) +
          aggregateAmount(item['sourceAmount']);
    }
    return amounts.entries.fold<BigInt>(
      BigInt.zero,
      (total, item) => total + convert(item.value, item.key),
    );
  }

  Map<String, BigInt> categorical(
    List<RecordData> items,
    int dataType, {
    Set<String> accountFilter = const {},
    bool monthly = false,
    DateTime Function(RecordData)? dateOf,
  }) {
    final values = <String, BigInt>{};
    void add(String key, BigInt value) =>
        values[key] = (values[key] ?? BigInt.zero) + value;
    if ([6, 7, 18, 19].contains(dataType)) {
      for (final account in accounts.where(
        (item) =>
            number(item['type']) != 2 &&
            (![18, 19].contains(dataType) || item['hidden'] != true) &&
            (accountFilter.isEmpty ||
                accountFilter.contains(string(item['id']))),
      )) {
        final liability = [3, 5].contains(number(account['category']));
        if (([7, 19].contains(dataType)) != liability) continue;
        final key = [18, 19].contains(dataType)
            ? string(account['currency'])
            : string(account['id']);
        add(
          key,
          convert(number(account['balance']), string(account['currency'])) *
              BigInt.from(liability ? -1 : 1),
        );
      }
      return values;
    }
    final grouped = <String, RecordData>{};
    for (final item in items) {
      final date = monthly ? (dateOf ?? storedTransactionDate)(item) : null;
      final key =
          '${item['type']}:${item['sourceAccountId']}:${item['categoryId']}:${number(item['type']) == 4 ? item['destinationAccountId'] : ''}:${date == null ? '' : '${date.year}-${date.month}'}';
      final existing = grouped[key];
      if (existing == null) {
        grouped[key] = {...item};
      } else {
        existing['sourceAmount'] =
            aggregateAmount(existing['sourceAmount']) +
            aggregateAmount(item['sourceAmount']);
        existing['destinationAmount'] =
            aggregateAmount(existing['destinationAmount']) +
            aggregateAmount(item['destinationAmount']);
      }
    }
    for (final item in grouped.values) {
      final type = number(item['type']);
      final income = [3, 4, 5, 12].contains(dataType);
      final flows = [11, 12].contains(dataType);
      if (type != (income ? 2 : 3) && !(flows && type == 4)) continue;
      String key;
      if ([0, 3, 11, 12].contains(dataType)) {
        key = string(
          item[income && type == 4
              ? 'destinationAccountId'
              : 'sourceAccountId'],
        );
      } else {
        final category = lookup(categories, item['categoryId']);
        key = string(
          [1, 4].contains(dataType) && string(category['parentId']) != '0'
              ? category['parentId']
              : item['categoryId'],
        );
      }
      if (flows && accountFilter.isNotEmpty && !accountFilter.contains(key)) {
        continue;
      }
      add(key, transactionValue(item, destination: income && type == 4));
    }
    return values;
  }

  Map<String, BigInt> assetBalancesAt(
    DateTime time,
    int dataType,
    Set<String> filter,
  ) {
    final balance = {
      for (final account in accounts.where((item) => number(item['type']) != 2))
        string(account['id']): aggregateAmount(account['balance']),
    };
    for (final item in app.transactions.where(
      (item) => DateTime.fromMillisecondsSinceEpoch(
        number(item['time']) * 1000,
        isUtc: true,
      ).isAfter(time),
    )) {
      final source = string(item['sourceAccountId']);
      final destination = string(item['destinationAccountId']);
      final type = number(item['type']);
      if (type == 1 && item['balanceDelta'] == null) {
        throw StateError(
          'Balance adjustment history requires a complete synchronization.',
        );
      }
      final sourceDelta = type == 1
          ? aggregateAmount(item['balanceDelta'])
          : aggregateAmount(item['sourceAmount']) *
                BigInt.from([3, 4].contains(type) ? -1 : 1);
      balance[source] = (balance[source] ?? BigInt.zero) - sourceDelta;
      if (type == 4) {
        balance[destination] =
            (balance[destination] ?? BigInt.zero) -
            aggregateAmount(item['destinationAmount']);
      }
    }
    final values = <String, BigInt>{};
    for (final account in accounts.where(
      (item) =>
          number(item['type']) != 2 &&
          (filter.isEmpty || filter.contains(string(item['id']))),
    )) {
      final liability = [3, 5].contains(number(account['category']));
      if (dataType == 6 && liability || dataType == 7 && !liability) continue;
      values[string(account['id'])] =
          convert(
            balance[string(account['id'])] ?? BigInt.zero,
            string(account['currency']),
          ) *
          BigInt.from(dataType == 7 ? -1 : 1);
    }
    return values;
  }

  BigInt netAssetsAt(DateTime time, int dataType, Set<String> filter) =>
      assetBalancesAt(
        time,
        dataType,
        filter,
      ).values.fold(BigInt.zero, (total, value) => total + value);
}

class StatisticsPage extends ConsumerStatefulWidget {
  const StatisticsPage({super.key});
  @override
  ConsumerState<StatisticsPage> createState() => _StatisticsState();
}

class _StatisticsState extends NativeState<StatisticsPage> {
  final filter = TransactionFilter();
  final dataMenuKey = GlobalKey();
  final sortingMenuKey = GlobalKey();
  final periodMenuKey = GlobalKey();
  final aggregationMenuKey = GlobalKey();
  int analysis = 0;
  int dataType = 1;
  int chartType = 0;
  int sort = 0;
  int aggregation = 0;
  final hiddenSeries = <String>{};
  bool get currentBalance => analysis == 0 && [6, 7, 18, 19].contains(dataType);
  bool get showAmount =>
      !currentBalance || app.settings['showAccountBalance'] != false;
  bool get canShift =>
      !currentBalance && filter.start != null && filter.end != null;

  void shiftPeriod(int direction) {
    if (!canShift) return;
    final start = filter.start!;
    final end = filter.end!;
    final minTime = filter.preciseTimes && analysis != 1
        ? start.millisecondsSinceEpoch ~/ 1000
        : app.formatter
                  .wallTime(
                    start.year,
                    start.month,
                    analysis == 1 ? 1 : start.day,
                  )
                  .millisecondsSinceEpoch ~/
              1000;
    final maxTime = filter.preciseTimes && analysis != 1
        ? end.millisecondsSinceEpoch ~/ 1000
        : app.formatter
                      .wallTime(
                        end.year,
                        analysis == 1 ? end.month + 1 : end.month,
                        analysis == 1 ? 1 : end.day + 1,
                      )
                      .millisecondsSinceEpoch ~/
                  1000 -
              1;
    final range = shiftStatisticsRange(
      app.formatter,
      minTime,
      maxTime,
      direction,
    );
    setState(() {
      filter.start = app.formatter.localDate(
        DateTime.fromMillisecondsSinceEpoch(range.minTime * 1000, isUtc: true),
      );
      filter.end = app.formatter.localDate(
        DateTime.fromMillisecondsSinceEpoch(range.maxTime * 1000, isUtc: true),
      );
      filter.periodType = 255;
      filter.preciseTimes = true;
      filter.afterTime = null;
    });
  }

  Future<void> editFilters() async {
    await Navigator.of(context).push<void>(
      nativeRoute(
        context,
        builder: (_) => TransactionFilterPage(
          filter: filter,
          dateScene: analysis,
          statistics: true,
          accountOnly: currentBalance || analysis == 2,
          allowDateRange: !currentBalance,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> selectPeriod() async {
    final value = await popoverChoices<int>(
      periodMenuKey,
      {
        for (final entry in dateRangesForScene(analysis).entries)
          entry.key: t(entry.value),
        255: t('Custom'),
      },
      filter.periodType,
      selectedSubtitle:
          filter.periodType == 255 && filter.start != null && filter.end != null
          ? '${dateText(filter.start!)} – ${dateText(filter.end!)}'
          : null,
    );
    if (value == null || !mounted) return;
    if (value == 255) {
      await editFilters();
      return;
    }
    setState(() => filter.setPeriod(app, value));
  }

  @override
  DateTime transactionDate(RecordData item) => app.formatter.transactionDate(
    item,
    originalTimezone:
        number(
          (app.settings['statistics'] as Map? ?? {})['defaultTimezoneType'],
        ) ==
        1,
  );
  void analysisDefaults(int selected) {
    analysis = selected;
    final preferences = app.settings['statistics'] as Map? ?? {};
    final name = const ['Categorical', 'Trend', 'AssetTrends'][selected];
    chartType = number(
      preferences['default${name}ChartType'] ?? (selected == 0 ? 0 : 1),
    );
    filter.setPeriod(
      app,
      number(
        preferences['default${name}ChartDataRangeType'] ??
            (selected == 0 ? 7 : 9),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    analysisDefaults(0);
    final preferences = app.settings['statistics'] as Map? ?? {};
    dataType = number(preferences['defaultChartDataType'] ?? 1);
    chartType = number(preferences['defaultCategoricalChartType']);
    sort = number(preferences['defaultSortingType']);
    filter.ignoreCase =
        number(preferences['defaultKeywordMatchMode'] ?? 1) == 1;
    final excludedAccounts = expandSelection(
      (preferences['defaultAccountFilter'] as Map? ?? {}).entries
          .where((entry) => entry.value == true)
          .map((entry) => string(entry.key)),
      app.accounts,
      'subAccounts',
    );
    if (excludedAccounts.isNotEmpty) {
      filter.accounts = flatten(app.accounts, 'subAccounts')
          .where(
            (item) =>
                number(item['type']) == 1 &&
                !excludedAccounts.contains(string(item['id'])),
          )
          .map((item) => string(item['id']))
          .toSet();
      filter.noAccounts = filter.accounts.isEmpty;
    }
    final excludedCategories = expandSelection(
      (preferences['defaultTransactionCategoryFilter'] as Map? ?? {}).entries
          .where((entry) => entry.value == true)
          .map((entry) => string(entry.key)),
      app.categories,
      'subCategories',
    );
    if (excludedCategories.isNotEmpty) {
      filter.categories = flatten(app.categories, 'subCategories')
          .where((item) => !excludedCategories.contains(string(item['id'])))
          .map((item) => string(item['id']))
          .toSet();
      filter.noCategories = filter.categories.isEmpty;
    }
  }

  void scrollToMenuSelection(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final selectedContext = key.currentContext;
      if (selectedContext != null) {
        Scrollable.ensureVisible(selectedContext, alignment: .5);
      }
    });
  }

  Future<T?> popoverChoices<T>(
    GlobalKey anchorKey,
    Map<T, String> choices,
    T selected, {
    String? selectedSubtitle,
  }) {
    final selectedKey = GlobalKey();
    return anchoredPopover<T>(anchorKey.currentContext!, (menu) {
      scrollToMenuSelection(selectedKey);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in choices.entries)
            ItemRow(
              entry.value,
              key: entry.key == selected ? selectedKey : null,
              subtitle: entry.key == selected ? selectedSubtitle : null,
              trailing: entry.key == selected
                  ? const Icon(
                      CupertinoIcons.check_mark,
                      color: brand,
                      size: 18,
                    )
                  : const SizedBox.shrink(),
              onTap: () => Navigator.pop(menu, entry.key),
            ),
        ],
      );
    });
  }

  Future<void> selectData() async {
    final selectedKey = GlobalKey();
    final selected = await anchoredPopover<(int, int)>(
      dataMenuKey.currentContext!,
      (menu) {
        scrollToMenuSelection(selectedKey);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var group = 0; group < 3; group++) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  t(
                    const [
                      'Categorical Analysis',
                      'Trend Analysis',
                      'Asset Trends',
                    ][group],
                  ),
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(menu),
                  ),
                ),
              ),
              for (final id in [categoricalData, trendData, assetData][group])
                ItemRow(
                  t(chartDataNames[id]!),
                  key: analysis == group && dataType == id ? selectedKey : null,
                  trailing: analysis == group && dataType == id
                      ? const Icon(
                          CupertinoIcons.check_mark,
                          color: brand,
                          size: 18,
                        )
                      : const SizedBox.shrink(),
                  onTap: () => Navigator.pop(menu, (group, id)),
                ),
            ],
          ],
        );
      },
      maxHeight: 440,
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (analysis != selected.$1) {
        analysisDefaults(selected.$1);
        aggregation = 0;
      }
      dataType = selected.$2;
      hiddenSeries.clear();
    });
  }

  Future<void> selectSorting() async {
    final value = await popoverChoices(sortingMenuKey, {
      0: t('Amount'),
      1: t('Display Order'),
      2: t('Name'),
    }, sort);
    if (value != null && mounted) setState(() => sort = value);
  }

  Future<void> selectAggregation() async {
    final value = await popoverChoices(aggregationMenuKey, {
      0: t('Aggregate by Month'),
      1: t('Aggregate by Quarter'),
      2: t('Aggregate by Year'),
      3: t('Aggregate by Fiscal Year'),
      if (analysis == 2) 4: t('Aggregate by Day'),
    }, aggregation);
    if (value != null && mounted) setState(() => aggregation = value);
  }

  Future<void> more() async {
    final transactionFilters = !currentBalance && analysis != 2;
    final action = await choose(context, t('More'), {
      'accounts': t('Filter Accounts'),
      if (transactionFilters) 'categories': t('Filter Transaction Categories'),
      if (transactionFilters) 'tags': t('Filter Transaction Tags'),
      if (transactionFilters) 'keyword': t('Filter transaction description'),
      'settings': t('Settings'),
    });
    if (action == null || !mounted) return;
    if (action == 'settings') {
      context.push('/statistic/settings');
    } else if (action == 'keyword') {
      final value = await prompt(
        context,
        t('Filter transaction description'),
        initial: filter.keyword,
      );
      if (value != null && mounted) setState(() => filter.keyword = value);
    } else if (action == 'tags') {
      await Navigator.of(context).push<void>(
        nativeRoute(
          context,
          builder: (_) => TransactionFilterPage(filter: filter, tagsOnly: true),
        ),
      );
      if (mounted) setState(() {});
    } else {
      final accounts = action == 'accounts';
      final choices = accounts ? app.accounts : app.categories;
      final childKey = accounts ? 'subAccounts' : 'subCategories';
      final allIds = flatten(
        choices,
        childKey,
      ).map((item) => string(item['id'])).toSet();
      final current = accounts ? filter.accounts : filter.categories;
      final none = accounts ? filter.noAccounts : filter.noCategories;
      final selected = await selectMany(
        context,
        t(accounts ? 'Filter Accounts' : 'Filter Transaction Categories'),
        choices,
        current.isEmpty && !none ? allIds : current,
      );
      if (selected == null || !mounted) return;
      final ids = expandSelection(selected, choices, childKey);
      setState(() {
        if (accounts) {
          filter.noAccounts = ids.isEmpty;
          filter.accounts = ids.containsAll(allIds) ? {} : ids;
        } else {
          filter.noCategories = ids.isEmpty;
          filter.categories = ids.containsAll(allIds) ? {} : ids;
        }
      });
    }
  }

  @override
  Widget buildPage(BuildContext _) {
    final stats = LedgerStatistics(app);
    final items = app.transactions
        .where((item) => filter.matches(item, dateOf: transactionDate))
        .toList();
    Map<String, BigInt> values = {};
    final series = <String, Map<String, BigInt>>{};
    final seriesWeights = <String, BigInt>{};
    final bucketRanges = <String, ({DateTime start, DateTime end})>{};
    String? error;
    try {
      if (analysis == 0) {
        values = stats.categorical(
          items,
          dataType,
          accountFilter: filter.accounts,
        );
      } else if (analysis == 1) {
        final groups = <String, List<RecordData>>{};
        final dates = items.map(transactionDate).toList()..sort();
        final start = filter.start ?? dates.firstOrNull;
        final end = filter.end ?? app.formatter.localDate(DateTime.now());
        if (start != null) {
          var date = DateTime(start.year, start.month);
          while (!date.isAfter(end)) {
            groups.putIfAbsent(bucket(date), () => []);
            bucketRanges[bucket(date)] = statisticsBucketRange(
              app.formatter,
              date,
              aggregation,
            );
            date = DateTime(date.year, date.month + 1);
          }
        }
        for (final item in items) {
          final date = transactionDate(item);
          final key = bucket(date);
          groups.putIfAbsent(key, () => []).add(item);
          bucketRanges[key] = statisticsBucketRange(
            app.formatter,
            date,
            aggregation,
          );
        }
        for (final entry in groups.entries) {
          if ([13, 14, 15].contains(dataType)) {
            final out = stats.categoricalTotal(
              entry.value,
              11,
              accountFilter: filter.accounts,
              monthly: true,
              dateOf: transactionDate,
            );
            final incoming = stats.categoricalTotal(
              entry.value,
              12,
              accountFilter: filter.accounts,
              monthly: true,
              dateOf: transactionDate,
            );
            values[entry.key] = dataType == 13
                ? out
                : dataType == 14
                ? incoming
                : incoming - out;
          } else if ([8, 9, 10].contains(dataType)) {
            final income = stats
                .categorical(
                  entry.value,
                  3,
                  monthly: true,
                  dateOf: transactionDate,
                )
                .values
                .fold(BigInt.zero, (a, b) => a + b);
            final expense = stats
                .categorical(
                  entry.value,
                  0,
                  monthly: true,
                  dateOf: transactionDate,
                )
                .values
                .fold(BigInt.zero, (a, b) => a + b);
            values[entry.key] = dataType == 8
                ? expense
                : dataType == 9
                ? income
                : income - expense;
          } else {
            final categoryValues = stats.categorical(
              entry.value,
              dataType,
              accountFilter: filter.accounts,
              monthly: true,
              dateOf: transactionDate,
            );
            for (final item in categoryValues.entries) {
              if (stats.hidden(item.key, dataType)) continue;
              series.putIfAbsent(item.key, () => {})[entry.key] = item.value;
              seriesWeights[item.key] =
                  (seriesWeights[item.key] ?? BigInt.zero) + item.value;
            }
            values[entry.key] = categoryValues.entries
                .where(
                  (item) =>
                      !stats.hidden(item.key, dataType) &&
                      !hiddenSeries.contains(item.key),
                )
                .fold(BigInt.zero, (a, b) => a + b.value);
          }
        }
      } else {
        final history = assetHistoryByDay(
          app.transactions,
          app.formatter,
          minTime: filter.start == null
              ? 0
              : filter.preciseTimes
              ? filter.start!.millisecondsSinceEpoch ~/ 1000
              : app.formatter
                        .wallTime(
                          filter.start!.year,
                          filter.start!.month,
                          filter.start!.day,
                        )
                        .millisecondsSinceEpoch ~/
                    1000,
          maxTime: filter.end == null
              ? null
              : filter.preciseTimes
              ? filter.end!.millisecondsSinceEpoch ~/ 1000
              : app.formatter
                            .wallTime(
                              filter.end!.year,
                              filter.end!.month,
                              filter.end!.day + 1,
                            )
                            .millisecondsSinceEpoch ~/
                        1000 -
                    1,
        );
        final bucketBalances = <String, Map<String, BigInt>>{};
        for (final day in history.entries) {
          final balances = <String, BigInt>{};
          for (final balance in day.value.entries) {
            final account = lookup(stats.accounts, balance.key);
            if (account.isEmpty ||
                filter.accounts.isNotEmpty &&
                    !filter.accounts.contains(balance.key)) {
              continue;
            }
            final liability = [3, 5].contains(number(account['category']));
            if (dataType == 6 && liability || dataType == 7 && !liability) {
              continue;
            }
            if (dataType != 17 && stats.hidden(balance.key, dataType)) continue;
            final value =
                stats.convert(balance.value, string(account['currency'])) *
                BigInt.from(dataType == 7 ? -1 : 1);
            balances[balance.key] = value;
            seriesWeights[balance.key] =
                (seriesWeights[balance.key] ?? BigInt.zero) + value;
          }
          bucketBalances[bucket(day.key)] = balances;
        }
        final start =
            filter.start ??
            history.keys.firstOrNull ??
            app.formatter.localDate(DateTime.now());
        final end =
            filter.end ??
            history.keys.lastOrNull ??
            app.formatter.localDate(DateTime.now());
        var date = app.formatter.wallTime(start.year, start.month, start.day);
        final endExclusive = app.formatter.wallTime(
          end.year,
          end.month,
          end.day + 1,
        );
        var count = 0;
        while (date.isBefore(endExclusive)) {
          if (count++ >= 1500) {
            throw StateError(
              t('Select a shorter date range or a larger aggregation period'),
            );
          }
          final range = statisticsBucketRange(app.formatter, date, aggregation);
          final next = range.end.add(const Duration(seconds: 1));
          final key = bucket(date);
          final balances = bucketBalances[key] ?? {};
          if (dataType == 17) {
            values[key] = balances.values.fold(BigInt.zero, (a, b) => a + b);
          } else {
            for (final balance in balances.entries) {
              series.putIfAbsent(balance.key, () => {})[key] = balance.value;
            }
            values[key] = balances.entries
                .where((item) => !hiddenSeries.contains(item.key))
                .fold(BigInt.zero, (total, item) => total + item.value);
          }
          bucketRanges[key] = range;
          date = next;
        }
      }
    } catch (e) {
      error = app.errorText(e);
    }
    final orderedSeries = series.entries.toList()
      ..sort(
        (a, b) => stats.compareEntries(
          MapEntry(a.key, seriesWeights[a.key] ?? BigInt.zero),
          MapEntry(b.key, seriesWeights[b.key] ?? BigInt.zero),
          dataType,
          sort,
        ),
      );
    series
      ..clear()
      ..addEntries(orderedSeries);
    if (filter.noAccounts) {
      values.clear();
      series.clear();
    }
    String label(String key) {
      if (analysis != 0) {
        final date = bucketRanges[key]?.start;
        if (date == null) return key;
        return switch (aggregation) {
          4 => dateText(date),
          1 =>
            '${app.formatter.year(date)} Q${app.formatter.digits('${(date.month - 1) ~/ 3 + 1}')}',
          2 => app.formatter.year(date),
          3 => app.formatter.fiscalYear(date),
          _ => app.formatter.month(date, short: true),
        };
      }
      if ([18, 19].contains(dataType)) {
        return '$key ${showAmount ? app.formatter.amount(stats.originalCurrencyBalance(key, dataType, filter.accounts), currency: key, showCurrency: false) : '***.**'}';
      }
      return recordName(
        [1, 2, 4, 5].contains(dataType) ? stats.categories : stats.accounts,
        key,
      );
    }

    final entries =
        values.entries
            .where(
              (entry) => analysis != 0 || !stats.hidden(entry.key, dataType),
            )
            .toList()
          ..sort(
            (a, b) => analysis != 0
                ? bucketRanges[a.key]!.start.compareTo(
                    bucketRanges[b.key]!.start,
                  )
                : stats.compareEntries(a, b, dataType, sort),
          );
    final total = values.entries.fold<BigInt>(
      BigInt.zero,
      (sum, entry) =>
          sum + (entry.value > BigInt.zero ? entry.value : BigInt.zero),
    );
    final colors = appChartColors(app);
    final stacked =
        analysis != 0 &&
        [0, 1].contains(chartType) &&
        ![11, 12].contains(dataType);
    final maximumTotal = entries.fold<BigInt>(
      BigInt.zero,
      (maximum, entry) => entry.value > maximum ? entry.value : maximum,
    );
    final maximumCategory = values.values.fold<BigInt>(
      BigInt.zero,
      (maximum, value) => value > maximum ? value : maximum,
    );
    final trendItems = <String, List<MapEntry<String, BigInt>>>{
      for (final entry in entries)
        entry.key:
            series.isEmpty
                  ? [entry]
                  : [
                      for (final item in series.entries)
                        if (!hiddenSeries.contains(item.key))
                          MapEntry(
                            item.key,
                            item.value[entry.key] ?? BigInt.zero,
                          ),
                    ]
              ..sort((a, b) => stats.compareEntries(a, b, dataType, sort)),
    };
    final totalAmount = analysis != 0 || error != null || filter.noAccounts
        ? BigInt.zero
        : stats.categoricalTotal(
            items,
            dataType,
            accountFilter: filter.accounts,
          );
    void openTransactions(int index, [String? seriesId]) {
      if (index < 0 || index >= entries.length) return;
      final key = entries[index].key;
      final range = analysis == 0 ? null : bucketRanges[key];
      final selected = statisticsDrilldown(
        app,
        filter,
        dataType,
        itemId: analysis == 0
            ? key
            : seriesId ??
                  (series.isEmpty
                      ? null
                      : series.keys
                            .where((id) => !hiddenSeries.contains(id))
                            .join(',')),
        start: range?.start,
        end: range?.end,
      );
      Navigator.of(context).push(
        nativeRoute(
          context,
          builder: (_) => TransactionListPage(
            initialFilter: selected,
            originalTimezone:
                number(
                  (app.settings['statistics'] as Map? ??
                      {})['defaultTimezoneType'],
                ) ==
                1,
          ),
        ),
      );
    }

    final totalName = t(switch (dataType) {
      11 => 'Total Outflows',
      12 => 'Total Inflows',
      3 || 4 || 5 => 'Total Income',
      0 || 1 || 2 => 'Total Expense',
      6 || 18 => 'Total Assets',
      7 || 19 => 'Total Liabilities',
      _ => 'Total Amount',
    });
    String displayValue(BigInt value) =>
        showAmount ? amount(value, stats.currency) : '***.**';
    String displayPercent(BigInt value) {
      if (value <= BigInt.zero || total <= BigInt.zero) {
        return '${app.formatter.digits('0')}%';
      }
      final text = aggregatePercent(value, total);
      return '${app.formatter.digits(text.replaceAll('.', app.formatter.decimalSeparator))}%';
    }

    Widget sortingHeader({bool summary = false}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: summary
                    ? Text(totalName, style: const TextStyle(fontSize: 12))
                    : const SizedBox.shrink(),
              ),
              Text('${t('Sort by')} ', style: const TextStyle(fontSize: 12)),
              CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: const Size(44, 28),
                key: sortingMenuKey,
                onPressed: selectSorting,
                child: Text(
                  t(const ['Amount', 'Display Order', 'Name'][sort]),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          if (summary)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(
                entries.isEmpty ? '---' : displayValue(totalAmount),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 25.5,
                  color: [0, 1, 2, 11].contains(dataType)
                      ? amountColor(app, 3)
                      : [3, 4, 5, 12].contains(dataType)
                      ? amountColor(app, 2)
                      : null,
                ),
              ),
            ),
        ],
      ),
    );
    Widget chartCard(List<Widget> children) => Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
    final showPercent = ![11, 12].contains(dataType);
    final toolbarColor = CupertinoColors.label.resolveFrom(context);
    final preferences = app.settings['statistics'] as Map? ?? {};
    final defaultPeriod = number(
      preferences['default${const ['Categorical', 'Trend', 'AssetTrends'][analysis]}ChartDataRangeType'] ??
          (analysis == 0 ? 7 : 9),
    );
    final changedPeriod =
        !currentBalance &&
        filter.periodType != defaultPeriod &&
        (filter.start != null || filter.end != null);
    Widget categoricalIcon(String id) {
      final category = [1, 2, 4, 5].contains(dataType);
      final item = lookup(category ? stats.categories : stats.accounts, id);
      return item.isEmpty
          ? const Icon(CupertinoIcons.pencil_ellipsis_rectangle, size: 24)
          : recordIcon(item);
    }

    Widget bottomText(
      String title,
      VoidCallback? action, {
      bool selected = false,
      Key? anchorKey,
    }) => Expanded(
      child: CupertinoButton(
        key: anchorKey,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        onPressed: action,
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            color: (selected ? brand : toolbarColor).withValues(
              alpha: action == null ? .55 : 1,
            ),
            fontWeight: FontWeight.normal,
          ),
        ),
      ),
    );
    Widget periodArrow(int direction) => Semantics(
      label: t(direction < 0 ? 'Previous Period' : 'Next Period'),
      button: true,
      enabled: canShift,
      child: CupertinoButton(
        padding: const EdgeInsets.all(8),
        onPressed: canShift ? () => shiftPeriod(direction) : null,
        child: Icon(
          direction < 0
              ? CupertinoIcons.arrow_left_square
              : CupertinoIcons.arrow_right_square,
          size: 24,
          color: toolbarColor.withValues(alpha: canShift ? 1 : .55),
        ),
      ),
    );
    return NativePage(
      title: t(chartDataNames[dataType] ?? 'Statistics'),
      titleKey: dataMenuKey,
      onTitleTap: selectData,
      busy: busy,
      onRefresh: app.refresh,
      trailing: iconButton(CupertinoIcons.ellipsis, t('More'), more),
      bottom: Container(
        height: 64,
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Row(
          children: [
            periodArrow(-1),
            bottomText(
              t(
                currentBalance
                    ? 'All'
                    : dateRangeNames[filter.periodType] ?? 'Custom',
              ),
              currentBalance ? null : selectPeriod,
              selected: changedPeriod,
              anchorKey: periodMenuKey,
            ),
            periodArrow(1),
            if (analysis == 0) ...[
              bottomText(
                t('Pie Chart'),
                () => setState(() => chartType = 0),
                selected: chartType == 0,
              ),
              bottomText(
                t('Bar Chart'),
                () => setState(() => chartType = 1),
                selected: chartType == 1,
              ),
            ] else
              bottomText(
                t(
                  const [
                    'Aggregate by Month',
                    'Aggregate by Quarter',
                    'Aggregate by Year',
                    'Aggregate by Fiscal Year',
                    'Aggregate by Day',
                  ][aggregation],
                ),
                selectAggregation,
                selected: aggregation != 0,
                anchorKey: aggregationMenuKey,
              ),
          ],
        ),
      ),
      children: [
        if (!app.initialSyncComplete)
          Section(
            footer: t(
              'Historical data is still synchronizing. Totals are incomplete.',
            ),
            children: [
              ItemRow(
                t('Synchronizing'),
                trailing: const CupertinoActivityIndicator(),
              ),
            ],
          ),
        if (error != null)
          Section(
            children: [
              ItemRow(t('Unable to calculate statistics'), subtitle: error),
            ],
          )
        else if (analysis == 0 && chartType == 0)
          chartCard([
            sortingHeader(),
            StatisticsPie(
              entries: entries,
              label: label,
              displayValue: displayValue,
              displayPercent: displayPercent,
              totalTitle: totalName,
              totalValue: displayValue(totalAmount),
              hasData: values.isNotEmpty,
              colors: colors,
              onOpen: openTransactions,
              showPercent: showPercent,
            ),
          ])
        else
          chartCard([
            sortingHeader(summary: analysis == 0),
            if (analysis != 0 && series.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      for (var i = 0; i < series.length; i++)
                        Semantics(
                          button: true,
                          selected: !hiddenSeries.contains(
                            series.keys.elementAt(i),
                          ),
                          child: CupertinoButton(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(44, 36),
                            onPressed: () => setState(() {
                              final id = series.keys.elementAt(i);
                              hiddenSeries.contains(id)
                                  ? hiddenSeries.remove(id)
                                  : hiddenSeries.add(id);
                            }),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  CupertinoIcons.square_fill,
                                  size: 14,
                                  color:
                                      hiddenSeries.contains(
                                        series.keys.elementAt(i),
                                      )
                                      ? CupertinoColors.systemGrey
                                      : colors[i % colors.length],
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    recordName(
                                      [1, 2, 4, 5].contains(dataType)
                                          ? stats.categories
                                          : stats.accounts,
                                      series.keys.elementAt(i),
                                    ),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color:
                                          hiddenSeries.contains(
                                            series.keys.elementAt(i),
                                          )
                                          ? CupertinoColors.systemGrey
                                          : CupertinoColors.label.resolveFrom(
                                              context,
                                            ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (entries.isEmpty) ItemRow(t('No transaction data')),
            for (var i = 0; i < entries.length; i++) ...[
              ItemRow(
                label(entries[i].key),
                leading: analysis != 0
                    ? const Icon(CupertinoIcons.calendar)
                    : categoricalIcon(entries[i].key),
                subtitle:
                    analysis == 0 &&
                        showPercent &&
                        entries[i].value >= BigInt.zero
                    ? displayPercent(entries[i].value)
                    : null,
                value:
                    analysis != 0 &&
                        !stacked &&
                        trendItems[entries[i].key]!.length > 1
                    ? null
                    : displayValue(entries[i].value),
                onTap: () => openTransactions(i),
              ),
              if (analysis == 0)
                StatisticsBars(
                  fractions: [
                    ([11, 12].contains(dataType) ? maximumCategory : total) <=
                            BigInt.zero
                        ? 0
                        : chartFraction(
                            entries[i].value,
                            [11, 12].contains(dataType)
                                ? maximumCategory
                                : total,
                          ),
                  ],
                  colors: [
                    itemColor(
                      lookup(
                        [1, 2, 4, 5].contains(dataType)
                            ? stats.categories
                            : stats.accounts,
                        entries[i].key,
                      )['color'],
                    ),
                  ],
                  stacked: true,
                )
              else
                StatisticsBars(
                  fractions: statisticsBarFractions(
                    trendItems[entries[i].key]!
                        .map((item) => item.value)
                        .toList(),
                    maximumTotal,
                    stacked: stacked || trendItems[entries[i].key]!.length <= 1,
                  ),
                  colors: [
                    for (final item in trendItems[entries[i].key]!)
                      colors[(series.isEmpty
                              ? 0
                              : series.keys.toList().indexOf(item.key)) %
                          colors.length],
                  ],
                  stacked: stacked || trendItems[entries[i].key]!.length <= 1,
                ),
            ],
          ]),
      ],
    );
  }

  String bucket(DateTime date) {
    if (aggregation == 4) return dateText(date);
    if (aggregation == 2) return '${date.year}';
    if (aggregation == 3) {
      return app.formatter.fiscalYear(date);
    }
    if (aggregation == 1) return '${date.year} Q${(date.month - 1) ~/ 3 + 1}';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}';
  }
}

class StatisticsSettingsPage extends ConsumerStatefulWidget {
  const StatisticsSettingsPage({super.key});
  @override
  ConsumerState<StatisticsSettingsPage> createState() =>
      _StatisticsSettingsState();
}

class _StatisticsSettingsState extends NativeState<StatisticsSettingsPage> {
  Map<String, dynamic> get prefs =>
      Map<String, dynamic>.from(app.settings['statistics'] as Map? ?? {});
  Future<void> set(String key, dynamic value) =>
      app.setPreference('statistics', {...prefs, key: value});
  Future<void> option(String key, String title, Map<int, String> values) async {
    final value = await choose(
      context,
      t(title),
      values.map((key, value) => MapEntry(key, t(value))),
      selected: number(prefs[key]),
    );
    if (value != null) await set(key, value);
  }

  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t('Statistics Settings'),
    children: [
      Section(
        children: [
          ItemRow(
            t('Default Chart Data'),
            value: t(
              chartDataNames[number(prefs['defaultChartDataType'] ?? 1)] ??
                  'Expense By Primary Category',
            ),
            onTap: () => option('defaultChartDataType', 'Default Chart Data', {
              for (final type in categoricalData) type: chartDataNames[type]!,
            }),
          ),
          ItemRow(
            t('Default Timezone'),
            value: t(
              number(prefs['defaultTimezoneType']) == 0
                  ? 'Application Timezone'
                  : 'Transaction Timezone',
            ),
            onTap: () => option('defaultTimezoneType', 'Default Timezone', {
              0: 'Application Timezone',
              1: 'Transaction Timezone',
            }),
          ),
          ItemRow(
            t('Default Sort By'),
            value: t(
              const ['Amount', 'Display Order', 'Name'][number(
                prefs['defaultSortingType'],
              ).clamp(0, 2)],
            ),
            onTap: () => option('defaultSortingType', 'Default Sort By', {
              0: 'Amount',
              1: 'Display Order',
              2: 'Name',
            }),
          ),
          ItemRow(
            t('Default Account Filter'),
            onTap: () async {
              final choices = flatten(app.accounts, 'subAccounts');
              final excluded = prefs['defaultAccountFilter'] as Map? ?? {};
              final selected = await selectMany(
                context,
                t('Accounts'),
                choices,
                choices
                    .where((item) => excluded[string(item['id'])] != true)
                    .map((item) => string(item['id'])),
              );
              if (selected != null) {
                await set('defaultAccountFilter', {
                  for (final item in choices)
                    if (!selected.contains(string(item['id'])))
                      string(item['id']): true,
                });
              }
            },
          ),
          ItemRow(
            t('Default Category Filter'),
            onTap: () async {
              final choices = flatten(app.categories, 'subCategories');
              final excluded =
                  prefs['defaultTransactionCategoryFilter'] as Map? ?? {};
              final selected = await selectMany(
                context,
                t('Categories'),
                choices,
                choices
                    .where((item) => excluded[string(item['id'])] != true)
                    .map((item) => string(item['id'])),
              );
              if (selected != null) {
                await set('defaultTransactionCategoryFilter', {
                  for (final item in choices)
                    if (!selected.contains(string(item['id'])))
                      string(item['id']): true,
                });
              }
            },
          ),
          ItemRow(
            t('Keyword Match Mode'),
            value: t(
              number(prefs['defaultKeywordMatchMode']) == 1
                  ? 'Ignore Case'
                  : 'Database Default Setting',
            ),
            onTap: () => option(
              'defaultKeywordMatchMode',
              'Keyword Match Mode',
              {0: 'Database Default Setting', 1: 'Ignore Case'},
            ),
          ),
        ],
      ),
      for (final group in ['Categorical', 'Trend', 'AssetTrends'])
        Section(
          title: t(
            group == 'Categorical'
                ? 'Categorical Analysis'
                : group == 'Trend'
                ? 'Trend Analysis'
                : 'Asset Trends',
          ),
          children: [
            ItemRow(
              t('Default Chart Type'),
              onTap: () => option(
                'default${group}ChartType',
                'Default Chart Type',
                group == 'Categorical'
                    ? {0: 'Pie Chart', 1: 'Bar Chart'}
                    : {0: 'Area Chart', 1: 'Column Chart', 2: 'Bubble Chart'},
              ),
            ),
            ItemRow(
              t('Default Date Range'),
              onTap: () => option(
                'default${group}ChartDataRangeType',
                'Default Date Range',
                dateRangesForScene(
                  group == 'Categorical'
                      ? 0
                      : group == 'Trend'
                      ? 1
                      : 2,
                ),
              ),
            ),
          ],
        ),
      Section(
        children: [
          ItemRow(
            t('Chart Color Scheme'),
            onTap: () => context.push('/settings/chart_color_scheme'),
          ),
        ],
      ),
    ],
  );
}
