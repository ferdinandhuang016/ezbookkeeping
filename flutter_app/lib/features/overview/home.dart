import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart'
    show Theme, ReorderableListView, ReorderableDelayedDragStartListener;
import 'package:image_picker/image_picker.dart';

import '../../core/formatting.dart';
import '../../core/aggregate_amount.dart';
import '../../ui/common.dart';
import '../catalogs/catalogs.dart';
import '../catalogs/catalog_business.dart';
import '../statistics/statistics.dart';
import '../statistics/statistics_bars.dart';
import '../transactions/transactions.dart';
import '../system/native_features.dart';
import 'layout_format.dart';

part 'layout_editor.dart';

const periodNames = {
  1: 'Today',
  5: 'This week',
  7: 'This month',
  9: 'This year',
};

Map<int, BigInt> overviewAssetTotals(AppController app) {
  final excluded = expandSelection(
    (app.settings['overviewAccountFilterInHomePage'] as Map? ?? {}).entries
        .where((entry) => entry.value == true)
        .map((entry) => string(entry.key)),
    app.accounts,
    'subAccounts',
  );
  final result = {6: BigInt.zero, 7: BigInt.zero, 17: BigInt.zero};
  final stats = LedgerStatistics(app);
  for (final account in leafAccounts(
    app,
  ).where((item) => !excluded.contains(string(item['id'])))) {
    final amount = stats.convert(
      number(account['balance']),
      string(account['currency']),
    );
    if (liabilityAccount(account)) {
      result[7] = result[7]! - amount;
    } else {
      result[6] = result[6]! + amount;
    }
    result[17] = result[17]! + amount;
  }
  return result;
}

const defaultOverview = <String, dynamic>{
  'widgets': [
    {
      'id': 'default-current-month-overview',
      'type': 'current-month-overview',
      'settings': {'height': 3},
    },
    {
      'id': 'default-period-income-expense',
      'type': 'period-income-expense',
      'settings': {
        'dateRanges': [1, 5, 7, 9],
      },
    },
  ],
};
RecordData overviewLayout(AppController app) {
  final value = app.settings['mobileOverviewPageLayout'];
  try {
    if (value is String && value.isNotEmpty) {
      return Map<String, dynamic>.from(jsonDecode(value));
    }
  } catch (_) {
    /* A malformed cloud layout falls back to the original mobile default. */
  }
  return Map<String, dynamic>.from(jsonDecode(jsonEncode(defaultOverview)));
}

List<RecordData> periodTransactions(AppController app, int period) {
  final filter = overviewTransactionFilter(app, period);
  final originalTimezone =
      number(app.settings['timezoneUsedForStatisticsInHomePage']) == 1;
  return app.transactions
      .where(
        (item) => filter.matches(
          item,
          dateOf: (item) => app.formatter.transactionDate(
            item,
            originalTimezone: originalTimezone,
          ),
        ),
      )
      .toList();
}

TransactionFilter overviewTransactionFilter(AppController app, int period) {
  final filter = TransactionFilter()..setPeriod(app, period);
  final excludedAccounts = expandSelection(
    (app.settings['overviewAccountFilterInHomePage'] as Map? ?? {}).entries
        .where((entry) => entry.value == true)
        .map((entry) => string(entry.key)),
    app.accounts,
    'subAccounts',
  );
  final excludedCategories = expandSelection(
    (app.settings['overviewTransactionCategoryFilterInHomePage'] as Map? ?? {})
        .entries
        .where((entry) => entry.value == true)
        .map((entry) => string(entry.key)),
    app.categories,
    'subCategories',
  );
  if (excludedAccounts.isNotEmpty) {
    filter.accounts = flatten(app.accounts, 'subAccounts')
        .where(
          (account) =>
              number(account['type']) != 2 &&
              !excludedAccounts.contains(string(account['id'])),
        )
        .map((account) => string(account['id']))
        .toSet();
    filter.noAccounts = filter.accounts.isEmpty;
  }
  if (excludedCategories.isNotEmpty) {
    filter.categories = flatten(app.categories, 'subCategories')
        .where(
          (category) => !excludedCategories.contains(string(category['id'])),
        )
        .map((category) => string(category['id']))
        .toSet();
    filter.noCategories = filter.categories.isEmpty;
  }
  return filter;
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key, this.previewWidget});
  final RecordData? previewWidget;
  @override
  ConsumerState<HomePage> createState() => _HomeState();
}

class _HomeState extends NativeState<HomePage> {
  RecordData definitions = {};
  void showTransactions(int period, {String? categoryId}) {
    final selected = overviewTransactionFilter(app, period);
    if (categoryId != null) {
      final ids = expandSelection(
        [categoryId],
        app.categories,
        'subCategories',
      );
      selected.categories = selected.categories.isEmpty
          ? ids
          : selected.categories.intersection(ids);
      selected.noCategories = selected.categories.isEmpty;
      selected.type = 3;
    }
    Navigator.of(context).push(
      nativeRoute(
        context,
        builder: (_) => TransactionListPage(
          initialFilter: selected,
          originalTimezone:
              number(app.settings['timezoneUsedForStatisticsInHomePage']) == 1,
        ),
      ),
    );
  }

  String periodDescription(int period) {
    final range = app.formatter.dateRange(period);
    if (range == null || range.minTime == 0 || range.maxTime == 0) return '';
    final start = app.formatter.localDate(
      DateTime.fromMillisecondsSinceEpoch(range.minTime * 1000, isUtc: true),
    );
    final end = app.formatter.localDate(
      DateTime.fromMillisecondsSinceEpoch(range.maxTime * 1000, isUtc: true),
    );
    if (period == 1) return app.formatter.date(start, long: true);
    if (period == 9) return app.formatter.year(start);
    return app.t(
      'format.misc.startEndRange',
      parameters: {
        'start': app.formatter.monthDay(start),
        'end': app.formatter.monthDay(end),
      },
    );
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => run(() async {
        definitions = Map<String, dynamic>.from(
          jsonDecode(
            await rootBundle.loadString(
              'assets/reference/overview_widgets.json',
            ),
          ),
        );
      }),
    );
  }

  Future<void> templates() async {
    final value = await choose(context, t('Transaction Templates'), {
      if (app.config['transactionFromAITextRecognition'] == true)
        'ai-text': t('Create Transaction from Text'),
      if (app.config['transactionFromAITextRecognition'] == true)
        'ai-clipboard': t('Create Transaction from Clipboard'),
      if (app.config['transactionFromAIImageRecognition'] == true)
        'ai-image': t('Create Transaction from Receipt'),
      for (final item in app.templates.where(
        (item) => number(item['templateType']) == 1 && item['hidden'] != true,
      ))
        string(item['id']): string(item['name']),
    });
    if (value != null && mounted) {
      if (value.startsWith('ai-')) {
        String? path;
        if (value == 'ai-image') {
          final source = await choose(context, t('Picture'), {
            ImageSource.camera: t('Take Photo'),
            ImageSource.gallery: t('Choose Picture'),
          });
          if (source == null) return;
          path = (await ImagePicker().pickImage(source: source))?.path;
          if (path == null || !mounted) return;
        }
        final recognized = await recognizeTransaction(
          context,
          clipboard: value == 'ai-clipboard',
          imageRecognition: value == 'ai-image',
          imagePath: path,
        );
        if (recognized != null && mounted) {
          Navigator.of(context).push(
            nativeRoute(
              context,
              builder: (_) => TransactionEditPage(
                route: '/transaction/add',
                initialData: recognized,
              ),
            ),
          );
        }
        return;
      }
      context.push('/transaction/add?templateId=$value');
    }
  }

  @override
  Widget buildPage(BuildContext _) => widget.previewWidget != null
      ? buildWidget(widget.previewWidget!)
      : NativePage(
          title: t('global.app.title'),
          back: false,
          busy: busy,
          onRefresh: app.refresh,
          trailing: iconButton(
            CupertinoIcons.slider_horizontal_3,
            t('Edit Overview Layout'),
            () => context.push('/settings/overview_layout'),
          ),
          bottom: Container(
            height: 64,
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: const Border(
                top: BorderSide(color: CupertinoColors.separator, width: .5),
              ),
            ),
            child: Row(
              children: [
                tab(CupertinoIcons.list_bullet, 'Details', '/transaction/list'),
                tab(CupertinoIcons.creditcard, 'Accounts', '/account/list'),
                Expanded(
                  child: GestureDetector(
                    onLongPress: templates,
                    child: Semantics(
                      label: t('Add Transaction'),
                      button: true,
                      child: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => context.push('/transaction/add'),
                        child: Icon(
                          CupertinoIcons.plus_app,
                          size: 32,
                          color: CupertinoColors.label.resolveFrom(context),
                        ),
                      ),
                    ),
                  ),
                ),
                tab(
                  CupertinoIcons.chart_pie,
                  'Statistics',
                  '/statistic/transaction',
                ),
                tab(CupertinoIcons.gear_alt, 'Settings', '/settings'),
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
                    value: '${app.downloadedCount}',
                    trailing: const CupertinoActivityIndicator(),
                  ),
                ],
              ),
            if (app.pendingCount > 0)
              Section(
                children: [
                  ItemRow(
                    t('Pending transactions'),
                    value: '${app.pendingCount}',
                    onTap: () => Navigator.of(context).push(
                      nativeRoute(
                        context,
                        builder: (_) => const SyncStatusPage(),
                      ),
                    ),
                  ),
                ],
              ),
            for (final widget in records(overviewLayout(app)['widgets']))
              buildWidget(widget),
          ],
        );
  Widget tab(IconData icon, String title, String route) => Expanded(
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: () => context.push(route),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 24,
            color: CupertinoColors.label.resolveFrom(context),
          ),
          const SizedBox(height: 3),
          Text(
            t(title),
            style: TextStyle(
              fontSize: 11,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    ),
  );
  Widget buildWidget(RecordData widget) {
    final type = string(widget['type']);
    final definition = definitions[type] as Map? ?? {};
    final settings = <String, dynamic>{
      ...Map<String, dynamic>.from(definition['defaultSettings'] as Map? ?? {}),
      ...Map<String, dynamic>.from(widget['settings'] as Map? ?? {}),
    };
    final title = settings['showTitle'] == true
        ? t(
            string(settings['title']).isEmpty
                ? string(definition['name'])
                : string(settings['title']),
          )
        : null;
    final stats = LedgerStatistics(app);
    final visible = app.settings['showAmountInHomePage'] != false;
    String display(Object value) =>
        visible ? amount(value, stats.currency) : '••••';
    Widget footer(
      String label,
      String value, {
      Color? valueColor,
      bool secondary = false,
    }) {
      final color =
          (secondary ? CupertinoColors.secondaryLabel : CupertinoColors.label)
              .resolveFrom(context);
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, height: 1.2, color: color),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  color: valueColor ?? color,
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget card(List<Widget> children) => Section(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 14.2,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ),
              ...children,
            ],
          ),
        ),
      ],
    );
    Widget divider() => Padding(
      padding: const EdgeInsetsDirectional.only(start: 16),
      child: Container(
        height: 0,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              width: .5,
              color: CupertinoColors.separator.resolveFrom(context),
            ),
          ),
        ),
      ),
    );

    try {
      if (type == 'current-month-overview' || type == 'asset-summary') {
        final asset = type == 'asset-summary';
        final assets = asset ? overviewAssetTotals(app) : <int, BigInt>{};
        final current = periodTransactions(app, 7);
        final primary = asset ? assets[17]! : stats.sum(current, 3);
        final income = asset ? assets[6]! : stats.sum(current, 2);
        final liabilities = asset ? assets[7]! : BigInt.zero;
        final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
        final color = itemColor(
          settings[dark ? 'darkBackgroundColor' : 'lightBackgroundColor'] ??
              (dark ? 'a92f2f' : 'd43f3f'),
        );
        final foreground = color.computeLuminance() > .45
            ? CupertinoColors.black
            : CupertinoColors.white;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Container(
            height:
                const {1: 110.0, 2: 160.0, 3: 220.0}[number(
                  settings['height'],
                )] ??
                220,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(24),
            ),
            alignment: Alignment.bottomLeft,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: DefaultTextStyle(
              style: TextStyle(color: foreground, fontSize: 17, height: 1.4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: asset
                          ? [TextSpan(text: t('Net assets'))]
                          : [
                              TextSpan(
                                text: app.formatter.monthName(
                                  app.formatter.localDate(DateTime.now()),
                                ),
                                style: const TextStyle(fontSize: 22.1),
                              ),
                              const TextSpan(text: ' · '),
                              TextSpan(
                                text: t('Expense'),
                                style: const TextStyle(fontSize: 14.2),
                              ),
                            ],
                    ),
                  ),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          display(primary),
                          style: const TextStyle(
                            fontSize: 25.5,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      CupertinoButton(
                        minimumSize: const Size(32, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        onPressed: () =>
                            app.setPreference('showAmountInHomePage', !visible),
                        child: Icon(
                          visible
                              ? CupertinoIcons.eye_slash_fill
                              : CupertinoIcons.eye_fill,
                          color: foreground,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    asset
                        ? '${t('Total assets')} ${display(income)} | ${t('Total liabilities')} ${display(liabilities)}'
                        : '${t('Monthly income')} ${display(income)}',
                    style: TextStyle(
                      fontSize: 14.2,
                      color: foreground.withValues(alpha: .6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      if (type == 'period-income-expense') {
        return Section(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            for (final period
                in (settings['dateRanges'] as List? ?? [1, 5, 7, 9]).map(
                  number,
                ))
              ItemRow(
                t(periodNames[period] ?? 'All'),
                subtitle: periodDescription(period),
                titleWeight: FontWeight.w400,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 19,
                ),
                leading: Icon(
                  period == 9
                      ? CupertinoIcons.square_stack_3d_up
                      : CupertinoIcons.calendar,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          display(
                            stats.sum(periodTransactions(app, period), 2),
                          ),
                          style: TextStyle(
                            color: amountColor(app, 2, context),
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          display(
                            stats.sum(periodTransactions(app, period), 3),
                          ),
                          style: TextStyle(
                            color: amountColor(app, 3, context),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 8),
                    const CupertinoListTileChevron(),
                  ],
                ),
                onTap: () => showTransactions(period),
              ),
          ],
        );
      }
      if (type == 'period-net-income-and-savings-rate') {
        final items = periodTransactions(
          app,
          number(settings['dateRange'] ?? 7),
        );
        final income = stats.sum(items, 2);
        final expense = stats.sum(items, 3);
        return card([
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('Net Income'),
                  style: const TextStyle(fontSize: 12, height: 1.2),
                ),
                const SizedBox(height: 8),
                Text(
                  display(income - expense),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 25.5,
                    height: 1.4,
                    color: amountColor(app, 2, context),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t('Savings Rate'),
                    style: const TextStyle(fontSize: 17, height: 1.4),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  !visible
                      ? '*.**%'
                      : income == BigInt.zero
                      ? (expense == BigInt.zero ? homePercent(app, 0, 2) : '-')
                      : '${app.formatter.digits(aggregatePercent(income - expense, income).replaceAll('.', app.formatter.decimalSeparator))}%',
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.4,
                    color: brand,
                  ),
                ),
              ],
            ),
          ),
          divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              children: [
                footer(
                  t('Income'),
                  display(income),
                  valueColor: amountColor(app, 2, context),
                ),
                footer(
                  t('Expense'),
                  display(expense),
                  valueColor: amountColor(app, 3, context),
                ),
              ],
            ),
          ),
        ]);
      }
      if (type == 'current-month-expense-progress') {
        final now = app.formatter.localDate(DateTime.now());
        final days = DateTime(now.year, now.month + 1, 0).day;
        final expense = stats.sum(periodTransactions(app, 7), 3);
        return card([
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  display(expense),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 25.5,
                    height: 1.4,
                    color: amountColor(app, 3, context),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t('Month elapsed'),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    Text(
                      homePercent(app, now.day * 100 / days, 0),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Container(
                    height: 4,
                    color: CupertinoColors.systemGrey5.resolveFrom(context),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: FractionallySizedBox(
                        widthFactor: now.day / days,
                        child: Container(color: brand),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              children: [
                footer(
                  t('Estimated month-end expense'),
                  display(
                    BookkeepingFormatter.convertAggregate(
                      expense,
                      '${now.day}',
                      '$days',
                    ),
                  ),
                ),
                footer(
                  t('Last month total'),
                  display(stats.sum(periodTransactions(app, 8), 3)),
                  secondary: true,
                ),
              ],
            ),
          ),
        ]);
      }
      if (type == 'account-balance-list') {
        final ids = (settings['accountIds'] as List? ?? []).map(string).toSet();
        final items = app.accounts
            .where(
              (item) =>
                  item['hidden'] != true &&
                  (ids.isEmpty ||
                      ids.contains(string(item['id'])) ||
                      records(item['subAccounts']).any(
                        (child) =>
                            child['hidden'] != true &&
                            ids.contains(string(child['id'])),
                      )),
            )
            .toList();
        if (settings['sortBy'] == 'balance') {
          BigInt score(RecordData item) {
            var total = BigInt.zero;
            final values = number(item['type']) == 2
                ? records(item['subAccounts'])
                      .where((child) => ids.contains(string(child['id'])))
                : [item];
            for (final value in values) {
              final balance = number(value['balance']);
              try {
                total += stats.convert(balance, string(value['currency']));
              } catch (_) {
                // The original balance ordering retains the raw amount when
                // an exchange rate is unavailable; the display flags it.
                total += BigInt.from(balance);
              }
            }
            return total;
          }

          items.sort((a, b) => score(b).compareTo(score(a)));
        }
        final cached = app.settings['cachedExchangeRates'];
        final table = cached is Map ? cached : const {};
        final rates = {
          string(table['baseCurrency']): '1',
          for (final row in records(table['exchangeRates']))
            string(row['currency']): string(row['rate']),
        };
        String balanceText(RecordData item) {
          final result = accountDisplayBalance(
            item,
            stats.currency,
            rates,
            availableCredit:
                settings['showAvailableCreditForCreditCard'] == true,
            selectedAccountIds: ids,
          );
          if (result == null) return '';
          if (!visible && settings['alwaysShowAmount'] != true) return '••••';
          return '${amount(result.value, result.currency)}${result.incomplete ? '*' : ''}';
        }

        return Section(
          title: title,
          children: [
            if (items.isEmpty) ItemRow(t('No data')),
            for (final item in items.take(number(settings['itemCount'] ?? 4)))
              ItemRow(
                string(item['name']),
                leading: recordIcon(item),
                value: balanceText(item),
                onTap: () =>
                    context.push('/transaction/list?accountId=${item['id']}'),
              ),
          ],
        );
      }
      if (type == 'expense-category-ranking') {
        final values =
            stats
                .categorical(
                  periodTransactions(app, number(settings['dateRange'] ?? 7)),
                  settings['categoryLevel'] == 'secondary' ? 2 : 1,
                )
                .entries
                .toList()
              ..sort((a, b) => b.value.compareTo(a.value));
        final total = values.fold<BigInt>(
          BigInt.zero,
          (sum, entry) => sum + entry.value,
        );
        return card([
          if (values.isEmpty) ItemRow(t('No data')),
          for (final entry in values.take(
            number(settings['itemCount'] ?? 5),
          )) ...[
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              onPressed: () => showTransactions(
                number(settings['dateRange'] ?? 7),
                categoryId: entry.key,
              ),
              child: DefaultTextStyle(
                style: TextStyle(
                  fontSize: 17,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
                child: Row(
                  children: [
                    recordIcon(lookup(stats.categories, entry.key)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Flexible(
                            child: Text(
                              recordName(stats.categories, entry.key),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (entry.value >= BigInt.zero) ...[
                            const SizedBox(width: 6),
                            Text(
                              '${app.formatter.digits(aggregatePercent(entry.value, total).replaceAll('.', app.formatter.decimalSeparator))}%',
                              style: TextStyle(
                                fontSize: 11.9,
                                color: CupertinoColors.label
                                    .resolveFrom(context)
                                    .withValues(alpha: .6),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        display(entry.value),
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const CupertinoListTileChevron(),
                  ],
                ),
              ),
            ),
            StatisticsBars(
              fractions: [chartFraction(entry.value, total)],
              colors: [itemColor(lookup(stats.categories, entry.key)['color'])],
              stacked: true,
            ),
          ],
        ]);
      }
      if (type == 'recent-transactions') {
        final filter = TransactionFilter()
          ..accounts = expandSelection(
            (settings['accountIds'] as List? ?? []).map(string),
            app.accounts,
            'subAccounts',
          )
          ..categories = expandSelection(
            (settings['categoryIds'] as List? ?? []).map(string),
            app.categories,
            'subCategories',
          )
          ..keyword = string(settings['keyword']);
        filter.readTagFilter(string(settings['tagFilter']));
        filter.readAmountFilter(string(settings['amountFilter']));
        final items = app.transactions.where(filter.matches).toList()
          ..sort(compareTransactionsNewestFirst);
        return Section(
          title: title,
          children: [
            for (final item in items.take(number(settings['itemCount'] ?? 3)))
              TransactionRow(
                item: item,
                app: app,
                hideAmount: !visible,
                showDate: true,
                previousItem: items.indexOf(item) > 0
                    ? items[items.indexOf(item) - 1]
                    : null,
              ),
            if (items.isEmpty) ItemRow(t('No transactions')),
          ],
        );
      }
      if (type == 'transaction-calendar') {
        return TransactionCalendarWidget(settings: settings);
      }
      return const SizedBox.shrink();
    } catch (error) {
      return Section(
        title: title ?? t(string(definition['name'])),
        children: [
          ItemRow(
            t('Unable to calculate statistics'),
            subtitle: app.errorText(error),
          ),
        ],
      );
    }
  }
}

String homePercent(AppController app, double value, int precision) {
  final smallest = precision == 0 ? 1.0 : .01;
  var text = (value > 0 && value < smallest ? smallest : value).toStringAsFixed(
    precision,
  );
  if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  final formatted = app.formatter.decimal(text);
  return '${value > 0 && value < smallest ? '<' : ''}$formatted%';
}

class TransactionCalendarWidget extends ConsumerStatefulWidget {
  const TransactionCalendarWidget({super.key, required this.settings});
  final RecordData settings;
  @override
  ConsumerState<TransactionCalendarWidget> createState() =>
      _TransactionCalendarState();
}

class _TransactionCalendarState extends NativeState<TransactionCalendarWidget> {
  @override
  DateTime transactionDate(RecordData item) => app.formatter.transactionDate(
    item,
    originalTimezone:
        number(app.settings['timezoneUsedForStatisticsInHomePage']) == 1,
  );
  late DateTime month;
  @override
  void initState() {
    super.initState();
    final now = app.formatter.localDate(DateTime.now());
    month = DateTime(now.year, now.month);
  }

  @override
  Widget buildPage(BuildContext _) {
    final types = (widget.settings['transactionTypes'] as List? ?? [2, 3])
        .map(number)
        .toSet();
    final firstDay = number(app.user['firstDayOfWeek']).clamp(0, 6);
    final offset = (month.weekday % 7 - firstDay + 7) % 7;
    final days = DateTime(month.year, month.month + 1, 0).day;
    final stats = LedgerStatistics(app);
    final totals = <int, Map<int, int>>{};
    final grouped = <int, Map<int, Map<String, int>>>{};
    for (final item in periodTransactions(app, 7)) {
      final date = transactionDate(item);
      if (date.year == month.year &&
          date.month == month.month &&
          types.contains(number(item['type']))) {
        final type = number(item['type']);
        final amount = grouped
            .putIfAbsent(date.day, () => {})
            .putIfAbsent(type, () => {});
        final currency = string(
          lookup(stats.accounts, item['sourceAccountId'])['currency'],
        );
        amount[currency] =
            (amount[currency] ?? 0) + number(item['sourceAmount']);
      }
    }
    final cached = app.settings['cachedExchangeRates'] as Map? ?? {};
    final rates = {
      string(cached['baseCurrency']): '1',
      for (final rate in records(cached['exchangeRates']))
        string(rate['currency']): string(rate['rate']),
    };
    var incomplete = false;
    for (final day in grouped.entries) {
      for (final amount in day.value.entries) {
        final converted = sumConvertedBalances(
          amount.value,
          stats.currency,
          rates,
        );
        totals.putIfAbsent(day.key, () => {})[amount.key] = converted.value
            .toInt();
        incomplete = incomplete || converted.incomplete;
      }
    }
    return Section(
      footer: incomplete ? t('Exchange rate unavailable') : null,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Row(
                children: [
                  for (var day = 0; day < 7; day++)
                    Expanded(
                      child: Text(
                        app.formatter.pattern(
                          DateTime(2023, 1, 1 + (firstDay + day) % 7),
                          'ddd',
                        ),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              for (var week = 0; week < (offset + days + 6) ~/ 7; week++)
                Row(
                  children: [
                    for (var column = 0; column < 7; column++)
                      Expanded(
                        child: calendarDay(
                          week * 7 + column - offset + 1,
                          days,
                          totals,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget calendarDay(int day, int days, Map<int, Map<int, int>> totals) {
    if (day < 1 || day > days) return const SizedBox(height: 58);
    final values = totals[day] ?? {};
    final nonzero = [
      for (final type in [2, 3])
        if ((values[type] ?? 0) != 0) MapEntry(type, values[type]!),
    ];
    final showAmount =
        widget.settings['showAmount'] != false &&
        app.settings['showAmountInHomePage'] != false;
    final today = app.formatter.localDate(DateTime.now());
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: 10),
      onPressed: nonzero.isEmpty
          ? null
          : () {
              final selected = overviewTransactionFilter(app, 7)
                ..start = DateTime(month.year, month.month, day)
                ..end = DateTime(month.year, month.month, day);
              final types =
                  (widget.settings['transactionTypes'] as List? ?? [2, 3])
                      .map(number)
                      .toSet();
              if (types.length == 1) selected.type = types.first;
              Navigator.of(context).push(
                nativeRoute(
                  context,
                  builder: (_) => TransactionListPage(
                    initialFilter: selected,
                    originalTimezone:
                        number(
                          app.settings['timezoneUsedForStatisticsInHomePage'],
                        ) ==
                        1,
                  ),
                ),
              );
            },
      child: Column(
        children: [
          Text(
            app.formatter.calendarDate(DateTime(month.year, month.month, day)),
            style: TextStyle(
              fontSize: 16,
              color:
                  day == today.day &&
                      month.month == today.month &&
                      month.year == today.year
                  ? brand
                  : nonzero.isEmpty
                  ? CupertinoColors.tertiaryLabel.resolveFrom(context)
                  : CupertinoColors.label.resolveFrom(context),
            ),
          ),
          if (widget.settings['showAlternateDate'] != false)
            Text(
              app.formatter.calendarDate(
                DateTime(month.year, month.month, day),
                alternate: true,
              ),
              maxLines: 1,
              style: TextStyle(
                fontSize: 9,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          if (showAmount)
            for (final value in nonzero)
              Text(
                amount(value.value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9,
                  color: amountColor(app, value.key, context),
                ),
              )
          else if (nonzero.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final value in nonzero)
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: amountColor(app, value.key, context),
                      ),
                    ),
                ],
              ),
            ),
          if (nonzero.isEmpty) const SizedBox(height: 11),
        ],
      ),
    );
  }
}

class OverviewLayoutPage extends ConsumerStatefulWidget {
  const OverviewLayoutPage({super.key});
  @override
  ConsumerState<OverviewLayoutPage> createState() => _OverviewLayoutState();
}

class OverviewWidgetSettingsPage extends ConsumerStatefulWidget {
  const OverviewWidgetSettingsPage({
    super.key,
    required this.definition,
    required this.settings,
  });
  final RecordData definition;
  final RecordData settings;
  @override
  ConsumerState<OverviewWidgetSettingsPage> createState() =>
      _OverviewWidgetSettingsState();
}

class _OverviewWidgetSettingsState
    extends NativeState<OverviewWidgetSettingsPage> {
  late final settings = <String, dynamic>{
    ...Map<String, dynamic>.from(
      widget.definition['defaultSettings'] as Map? ?? {},
    ),
    ...widget.settings,
  };
  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t(string(widget.definition['name'])),
    trailing: actionButton(t('Save'), () => Navigator.pop(context, settings)),
    children: [
      Section(
        children: [
          for (final spec in records(widget.definition['supportsSettings']))
            setting(spec),
        ],
      ),
    ],
  );
  Widget setting(RecordData spec) {
    final key = string(spec['settingName']);
    final title = t(string(spec['displayName']));
    final type = string(spec['settingType']);
    if (type == 'switch') {
      return toggleRow(
        title,
        settings[key] == true,
        (value) => setState(() => settings[key] = value),
      );
    }
    if (type == 'textbox') {
      return InputRow(
        title,
        value: string(settings[key]),
        onChanged: (value) => settings[key] = value,
      );
    }
    String displayValue() {
      final value = settings[key];
      if (type == 'accountSelect' || type == 'categorySelect') {
        final selected = (value as List? ?? []).map(string).toSet();
        final choices = type == 'accountSelect'
            ? visibleLeaves(app.accounts, 'subAccounts')
            : visibleLeaves(app.categories, 'subCategories');
        return t(
          selected.isEmpty ||
                  choices.every((item) => selected.contains(string(item['id'])))
              ? 'All'
              : 'Partial',
        );
      }
      if (type == 'tagSelect' || type == 'amount') {
        return t(string(value).isEmpty ? 'All' : 'Custom');
      }
      if (type == 'customSelect') {
        final selected = value is List
            ? value.map(string).toSet()
            : {string(value)};
        return records(spec['selectValues'])
            .where((item) => selected.contains(string(item['value'])))
            .map((item) => t(string(item['name'])))
            .join(' / ');
      }
      if (type == 'color') return '';
      return app.formatter.digits(string(value));
    }

    return ItemRow(
      title,
      value: displayValue(),
      leading: type == 'color'
          ? Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: itemColor(settings[key]),
                borderRadius: BorderRadius.circular(6),
              ),
            )
          : null,
      onTap: () async {
        dynamic value;
        if (type == 'color') {
          value = await chooseColor(context, string(settings[key]));
        }
        if (mounted && type == 'amount') {
          final filter = TransactionFilter()
            ..readAmountFilter(string(settings[key]));
          await Navigator.of(context).push<void>(
            nativeRoute(
              context,
              builder: (_) =>
                  TransactionFilterPage(filter: filter, amountOnly: true),
            ),
          );
          value = filter.encodedAmountFilter;
        }
        if (mounted && type == 'tagSelect') {
          final filter = TransactionFilter()
            ..readTagFilter(string(settings[key]));
          await Navigator.of(context).push<void>(
            nativeRoute(
              context,
              builder: (_) =>
                  TransactionFilterPage(filter: filter, tagsOnly: true),
            ),
          );
          value = filter.encodedTagFilter;
        }
        if (mounted && (type == 'accountSelect' || type == 'categorySelect')) {
          final items = type == 'accountSelect'
              ? flatten([
                  for (final account in app.accounts)
                    if (spec['disableHiddenAccounts'] != true ||
                        account['hidden'] != true)
                      {
                        ...account,
                        'subAccounts': [
                          for (final child in records(account['subAccounts']))
                            if (spec['disableHiddenAccounts'] != true ||
                                child['hidden'] != true)
                              child,
                        ],
                      },
                ], 'subAccounts')
              : type == 'categorySelect'
              ? flatten(app.categories, 'subCategories')
              : app.tags;
          value = await selectMany(
            context,
            title,
            items,
            settings[key] is List
                ? (settings[key] as List).map(string)
                : string(settings[key]).split(':').last.split(','),
          );
        }
        if (mounted && (type == 'itemCountSelect' || type == 'monthSelect')) {
          value = await choose<int>(context, title, {
            for (final count
                in (spec[type == 'monthSelect'
                            ? 'monthValues'
                            : 'itemCountValues']
                        as List? ??
                    []))
              number(count): '$count',
          }, selected: number(settings[key]));
        }
        if (mounted && type == 'customSelect') {
          final items = records(spec['selectValues']);
          if (spec['multiple'] == true) {
            final selected = await selectMany(
              context,
              title,
              [
                for (final item in items)
                  {
                    'id': string(item['value']),
                    'name': t(string(item['name'])),
                  },
              ],
              (settings[key] as List? ?? []).map(string),
              minimumSelections: number(spec['minSelections']).clamp(1, 100),
            );
            if (selected != null &&
                selected.length >= number(spec['minSelections'])) {
              value = [
                for (final id in selected)
                  items.firstWhere(
                    (item) => string(item['value']) == id,
                  )['value'],
              ];
            }
          } else {
            value = await choose<dynamic>(context, title, {
              for (final item in items) item['value']: t(string(item['name'])),
            }, selected: settings[key]);
          }
        }
        if (value != null && mounted) setState(() => settings[key] = value);
      },
    );
  }
}
