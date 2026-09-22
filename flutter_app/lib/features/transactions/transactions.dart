import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/currency_selection.dart';
import '../../core/formatting.dart';
import '../../ui/common.dart';
import '../../ui/quick_add_startup.dart';
import '../system/native_features.dart';
import '../system/amap_location.dart';
import '../system/map_contract.dart';
import 'transaction_totals.dart';
import 'transaction_schedule.dart';
import '../catalogs/catalog_business.dart' show AccountDisplayBalance;
import '../catalogs/catalogs.dart'
    show SwipeActionsRow, accountCategories, accountCategoryIcons;

export 'transaction_schedule.dart';

const dateRangeNames = {
  0: 'All',
  1: 'Today',
  2: 'Yesterday',
  3: 'Recent 7 days',
  4: 'Recent 30 days',
  5: 'This week',
  6: 'Last week',
  7: 'This month',
  8: 'Last month',
  9: 'This year',
  10: 'Last year',
  11: 'This fiscal year',
  12: 'Last fiscal year',
  101: 'Recent 12 months',
  102: 'Recent 24 months',
  103: 'Recent 36 months',
  104: 'Recent 2 years',
  105: 'Recent 3 years',
  106: 'Recent 5 years',
};

Map<int, String> dateRangesForScene(int scene) => {
  for (final entry in dateRangeNames.entries)
    if (scene == 1
        ? entry.key == 0 || entry.key >= 9
        : scene == 2
        ? entry.key != 1 && entry.key != 2
        : entry.key < 100)
      entry.key: entry.value,
};

class TransactionFilter {
  TransactionFilter();

  factory TransactionFilter.fromAmountQuery(Map<String, String> query) {
    final filter = TransactionFilter()..readAmountFilter(query['value'] ?? '');
    if (!['gt', 'lt', 'eq', 'ne', 'bt', 'nb'].contains(filter.amountOperator)) {
      filter.selectAmountOperator('');
    }
    final type = query['type'];
    if (type != null && ['gt', 'lt', 'eq', 'ne', 'bt', 'nb'].contains(type)) {
      filter.selectAmountOperator(type);
    }
    return filter;
  }
  int type = 0;
  int relatedAccountType = 0;
  int periodType = 0;
  int? afterTime;
  DateTime? start;
  DateTime? end;
  bool preciseTimes = false;
  Set<String> accounts = {};
  Set<String> categories = {};
  bool noAccounts = false;
  bool noCategories = false;
  Set<String> tags = {};
  int tagMode = 0;
  bool noTags = false;
  bool pictures = false;
  bool ignoreCase = true;
  int? minimumAmount;
  int? maximumAmount;
  String amountOperator = '';
  final List<RecordData> additionalTagFilters = [];
  String keyword = '';

  TransactionFilter copy() => TransactionFilter()..replaceWith(this);

  void replaceWith(TransactionFilter value) {
    type = value.type;
    relatedAccountType = value.relatedAccountType;
    periodType = value.periodType;
    afterTime = value.afterTime;
    start = value.start;
    end = value.end;
    preciseTimes = value.preciseTimes;
    accounts = {...value.accounts};
    categories = {...value.categories};
    noAccounts = value.noAccounts;
    noCategories = value.noCategories;
    readTagFilter(value.encodedTagFilter);
    tagMode = value.tagMode;
    pictures = value.pictures;
    ignoreCase = value.ignoreCase;
    minimumAmount = value.minimumAmount;
    maximumAmount = value.maximumAmount;
    amountOperator = value.amountOperator;
    keyword = value.keyword;
  }

  void selectAmountOperator(String value) {
    amountOperator = value;
    if (value.isEmpty) {
      minimumAmount = null;
      maximumAmount = null;
    } else {
      minimumAmount ??= 0;
      maximumAmount ??= 0;
    }
  }

  String? get amountProblem =>
      ['bt', 'nb'].contains(amountOperator) &&
          (maximumAmount ?? 0) < (minimumAmount ?? 0)
      ? 'Incorrect amount range'
      : null;

  void selectType(int value, List<RecordData> allCategories) {
    type = value;
    if (value == 0) return;
    final allowed = flatten(allCategories, 'subCategories')
        .where((item) => number(item['type']) == value - 1)
        .map((item) => string(item['id']))
        .toSet();
    categories = categories.intersection(allowed);
    noCategories = false;
  }

  void setPeriod(AppController app, int period) {
    preciseTimes = false;
    periodType = period;
    final selected = flatten(app.accounts, 'subAccounts')
        .where(
          (account) =>
              number(account['type']) != 2 &&
              accounts.contains(string(account['id'])),
        )
        .toList();
    final account = selected.length == 1 ? selected.first : <String, dynamic>{};
    afterTime = period == 71 ? number(account['lastReconciledTime']) : null;
    final range = app.formatter.dateRange(
      period,
      statementDay: number(
        account['creditCardStatementDate'] ??
            lookup(
              app.accounts,
              account['parentId'],
            )['creditCardStatementDate'],
      ),
      lastReconciledTime: number(account['lastReconciledTime']),
    );
    start = range == null || range.minTime == 0
        ? null
        : app.formatter.localDate(
            DateTime.fromMillisecondsSinceEpoch(
              range.minTime * 1000,
              isUtc: true,
            ),
          );
    end = range == null || range.maxTime == 0
        ? null
        : app.formatter.localDate(
            DateTime.fromMillisecondsSinceEpoch(
              range.maxTime * 1000,
              isUtc: true,
            ),
          );
  }

  void readTagFilter(String value) {
    tags.clear();
    additionalTagFilters.clear();
    noTags = value == 'none';
    for (final encoded in value.split(';')) {
      final parts = encoded.split(':');
      if (parts.length != 2 || !['0', '1', '2', '3'].contains(parts[0])) {
        continue;
      }
      final ids = parts[1].split(',').where((id) => id.isNotEmpty).toSet();
      if (ids.isEmpty) continue;
      if (tags.isEmpty) {
        tagMode = number(parts[0]);
        tags = ids;
      } else {
        additionalTagFilters.add({
          'mode': number(parts[0]),
          'tagIds': ids.toList(),
        });
      }
    }
  }

  String get encodedTagFilter => noTags
      ? 'none'
      : [
          if (tags.isNotEmpty) '$tagMode:${tags.join(',')}',
          for (final rule in additionalTagFilters)
            '${rule['mode']}:${(rule['tagIds'] as List).join(',')}',
        ].join(';');
  void readAmountFilter(String value) {
    final parts = value.split(':');
    amountOperator = parts.length > 1 ? parts[0] : '';
    minimumAmount = parts.length > 1 ? int.tryParse(parts[1]) : null;
    maximumAmount = parts.length > 2 ? int.tryParse(parts[2]) : null;
  }

  String get encodedAmountFilter => minimumAmount == null
      ? ''
      : '${amountOperator.isEmpty ? 'gt' : amountOperator}:$minimumAmount${['bt', 'nb'].contains(amountOperator) ? ':${maximumAmount ?? minimumAmount}' : ''}';

  bool matches(RecordData item, {DateTime Function(RecordData)? dateOf}) {
    if (noAccounts || noCategories) return false;
    if (type != 0 && number(item['type']) != type) return false;
    if (afterTime != null && number(item['time']) <= afterTime!) return false;
    final displayed = (dateOf ?? storedTransactionDate)(item);
    DateTime wall(DateTime value) => DateTime.utc(
      value.year,
      value.month,
      value.day,
      value.hour,
      value.minute,
      value.second,
    );
    if (preciseTimes &&
        (start != null && wall(displayed).isBefore(wall(start!)) ||
            end != null && wall(displayed).isAfter(wall(end!)))) {
      return false;
    }
    final date = DateTime.utc(displayed.year, displayed.month, displayed.day);
    if (start != null &&
        date.isBefore(DateTime.utc(start!.year, start!.month, start!.day))) {
      return false;
    }
    if (end != null &&
        date.isAfter(DateTime.utc(end!.year, end!.month, end!.day))) {
      return false;
    }
    if (accounts.isNotEmpty) {
      final sourceMatches = accounts.contains(string(item['sourceAccountId']));
      final destinationMatches = accounts.contains(
        string(item['destinationAccountId']),
      );
      if (number(item['type']) == 4 &&
              relatedAccountType == 1 &&
              !sourceMatches ||
          number(item['type']) == 4 &&
              relatedAccountType == 2 &&
              !destinationMatches ||
          !sourceMatches && !destinationMatches) {
        return false;
      }
    }
    if (categories.isNotEmpty &&
        !categories.contains(string(item['categoryId']))) {
      return false;
    }
    final itemTags = (item['tagIds'] as List? ?? []).map(string).toSet();
    if (noTags && itemTags.isNotEmpty) return false;
    if (tags.isNotEmpty) {
      final any = itemTags.intersection(tags).isNotEmpty;
      final all = tags.every(itemTags.contains);
      if (!switch (tagMode) {
        1 => all,
        2 => !any,
        3 => !all,
        _ => any,
      }) {
        return false;
      }
    }
    for (final rule in additionalTagFilters) {
      final selected = (rule['tagIds'] as List).map(string).toSet();
      final any = itemTags.intersection(selected).isNotEmpty;
      final all = selected.every(itemTags.contains);
      if (!switch (number(rule['mode'])) {
        1 => all,
        2 => !any,
        3 => !all,
        _ => any,
      }) {
        return false;
      }
    }
    if (pictures &&
        (item['pictures'] as List? ?? item['pictureIds'] as List? ?? [])
            .isEmpty) {
      return false;
    }
    final destinationAmount =
        number(item['type']) == 4 &&
        !accounts.contains(string(item['sourceAccountId'])) &&
        accounts.contains(string(item['destinationAccountId']));
    final value = number(
      item[destinationAmount ? 'destinationAmount' : 'sourceAmount'],
    );
    if (amountOperator.isNotEmpty && minimumAmount != null) {
      if (!switch (amountOperator) {
        'gt' => value > minimumAmount!,
        'lt' => value < minimumAmount!,
        'eq' => value == minimumAmount!,
        'ne' => value != minimumAmount!,
        'bt' =>
          value >= minimumAmount! && value <= (maximumAmount ?? minimumAmount!),
        'nb' =>
          value < minimumAmount! || value > (maximumAmount ?? minimumAmount!),
        _ => true,
      }) {
        return false;
      }
    } else {
      if (minimumAmount != null && value < minimumAmount!) return false;
      if (maximumAmount != null && value > maximumAmount!) return false;
    }
    final description = string(item['comment']);
    return ignoreCase
        ? description.toLowerCase().contains(keyword.toLowerCase())
        : description.contains(keyword);
  }
}

class TransactionListPage extends ConsumerStatefulWidget {
  const TransactionListPage({
    super.key,
    this.query = const {},
    this.initialFilter,
    this.originalTimezone = true,
    this.showAddAction = true,
  });
  final Map<String, String> query;
  final TransactionFilter? initialFilter;
  final bool originalTimezone;
  final bool showAddAction;
  @override
  ConsumerState<TransactionListPage> createState() => _TransactionListState();
}

List<RecordData> topLevelFilterSelection(
  List<RecordData> all,
  Set<String> ids,
) => all
    .where(
      (item) =>
          ids.contains(string(item['id'])) &&
          !ids.contains(string(item['parentId'])),
    )
    .toList();

Map<String, String> transactionListAddQuery(
  TransactionFilter filter,
  AppController app,
  DateTime now,
) {
  final query = <String, String>{if (filter.type > 1) 'type': '${filter.type}'};
  final accounts = topLevelFilterSelection(
    flatten(app.accounts, 'subAccounts'),
    filter.accounts,
  );
  final categories = topLevelFilterSelection(
    flatten(app.categories, 'subCategories'),
    filter.categories,
  );
  if (accounts.length == 1 && number(accounts.single['type']) != 2) {
    query['accountId'] = string(accounts.single['id']);
  }
  if (categories.length == 1 && string(categories.single['parentId']) != '0') {
    query['categoryId'] = string(categories.single['id']);
  }
  if (filter.encodedTagFilter.isNotEmpty) {
    final included = <String, bool>{
      for (final id in filter.tags) id: filter.tagMode < 2,
    };
    for (final rule in filter.additionalTagFilters) {
      for (final id in (rule['tagIds'] as List).map(string)) {
        included[id] = number(rule['mode']) < 2;
      }
    }
    query['tagIds'] = included.entries
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .join(',');
  }
  if (filter.start != null && filter.end != null) {
    DateTime wall(DateTime value, bool end) => app.formatter.wallTime(
      value.year,
      value.month,
      value.day,
      filter.preciseTimes
          ? value.hour
          : end
          ? 23
          : 0,
      filter.preciseTimes
          ? value.minute
          : end
          ? 59
          : 0,
      filter.preciseTimes
          ? value.second
          : end
          ? 59
          : 0,
    );
    final start = wall(filter.start!, false), end = wall(filter.end!, true);
    if (now.isBefore(start)) {
      query['time'] = '${start.millisecondsSinceEpoch ~/ 1000}';
    }
    if (now.isAfter(end)) {
      query['time'] = '${end.millisecondsSinceEpoch ~/ 1000}';
    }
  }
  return query;
}

class _TransactionListState extends NativeState<TransactionListPage> {
  late final TransactionFilter filter;
  int visibleCount = 50;
  int availableCount = 0;
  bool loadMoreQueued = false;
  bool showSearch = false;
  late final searchController = TextEditingController(text: filter.keyword);
  int pageType = 0;
  int? calendarDay;
  final collapsedMonths = <DateTime>{};
  @override
  void initState() {
    super.initState();
    filter = widget.initialFilter?.copy() ?? TransactionFilter();
    visibleCount = number(app.settings['itemsCountInTransactionListPage'] ?? 15)
        .clamp(5, 100);
    if (widget.initialFilter != null) {
      showSearch = filter.keyword.isNotEmpty;
      return;
    }
    filter.type = number(widget.query['type']);
    final accountId =
        widget.query['accountId'] ??
        widget.query['accountIds'] ??
        widget.query['account_ids'];
    if (accountId != null) {
      filter.accounts = expandSelection(
        accountId.split(','),
        app.accounts,
        'subAccounts',
      );
    }
    final categoryId =
        widget.query['categoryId'] ?? widget.query['categoryIds'];
    if (categoryId != null) {
      filter.categories = expandSelection(
        categoryId.split(','),
        app.categories,
        'subCategories',
      );
    }
    filter.start = DateTime.tryParse(widget.query['date'] ?? '');
    if (filter.start != null) filter.periodType = 255;
    filter.end = filter.start;
    if (widget.query['dateType'] != null) {
      setPeriod(number(widget.query['dateType']));
    }
    for (final key in ['minTime', 'maxTime']) {
      final seconds = int.tryParse(widget.query[key] ?? '');
      if (seconds != null && seconds > 0) {
        filter.periodType = 255;
        final value = app.formatter.localDate(
          DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
        );
        if (key == 'minTime') {
          filter.start = value;
        } else {
          filter.end = value;
        }
      }
    }
    filter.keyword = widget.query['keyword'] ?? '';
    filter.ignoreCase =
        number(
          widget.query['matchMode'] ??
              app.settings['defaultKeywordMatchModeInTransactionListPage'] ??
              1,
        ) ==
        1;
    filter.relatedAccountType = number(widget.query['relatedAccountType']);
    filter.readTagFilter(widget.query['tagFilter'] ?? '');
    filter.readAmountFilter(widget.query['amountFilter'] ?? '');
    showSearch = filter.keyword.isNotEmpty;
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  bool get canAdd =>
      !topLevelFilterSelection(
        flatten(app.accounts, 'subAccounts'),
        filter.accounts,
      ).any((item) => number(item['type']) == 2) ||
      topLevelFilterSelection(
            flatten(app.accounts, 'subAccounts'),
            filter.accounts,
          ).length !=
          1;

  Future<void> removeTransaction(RecordData item) async {
    if (!app.canEditTransaction(item)) return;
    if (!await confirm(
      context,
      t('Are you sure you want to delete this transaction?'),
      destructive: true,
    )) {
      return;
    }
    await run(
      () => number(item['type']) == 1
          ? onlineMutation('v1/transactions/delete.json', {'id': item['id']})
          : app.deleteTransaction(string(item['id'])),
    );
  }

  Future<void> transactionActions(RecordData item) async {
    final action = await choose(
      context,
      t('More'),
      {
        'copy': t('Copy'),
        if (app.canEditTransaction(item)) 'delete': t('Delete'),
      },
      destructive: {'delete'},
    );
    if (!mounted) return;
    if (action == 'copy') {
      context.push(
        '/transaction/add?id=${Uri.encodeQueryComponent(string(item['id']))}&copy=true',
      );
    } else if (action == 'delete') {
      await removeTransaction(item);
    }
  }

  @override
  DateTime transactionDate(RecordData item) => app.formatter.transactionDate(
    item,
    originalTimezone: widget.originalTimezone,
  );

  void setPeriod(int period) {
    filter.setPeriod(app, period);
  }

  void changedFilter(VoidCallback change) => setState(() {
    change();
    visibleCount = number(app.settings['itemsCountInTransactionListPage'] ?? 15)
        .clamp(5, 100);
  });

  void loadMore() {
    if (loadMoreQueued || pageType == 1 || visibleCount >= availableCount) {
      return;
    }
    loadMoreQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      loadMoreQueued = false;
      if (mounted && pageType != 1 && visibleCount < availableCount) {
        setState(() => visibleCount += 50);
      }
    });
  }

  String selectedName(String kind) {
    final account = kind == 'account';
    final ids = account ? filter.accounts : filter.categories;
    final all = flatten(
      account ? app.accounts : app.categories,
      account ? 'subAccounts' : 'subCategories',
    );
    final selected = all
        .where(
          (item) =>
              ids.contains(string(item['id'])) &&
              !ids.contains(string(item['parentId'])),
        )
        .toList();
    return selected.length == 1
        ? string(selected.first['name'])
        : t(
            selected.isEmpty
                ? (account ? 'Account' : 'Category')
                : (account ? 'Multiple Accounts' : 'Multiple Categories'),
          );
  }

  Widget toolbarChoice(
    String title,
    bool active,
    void Function(BuildContext)? open,
  ) => Expanded(
    child: Builder(
      builder: (anchor) => CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        onPressed: open == null ? null : () => open(anchor),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            color: open == null
                ? CupertinoColors.inactiveGray
                : active
                ? brand
                : CupertinoColors.label.resolveFrom(context),
          ),
        ),
      ),
    ),
  );

  Widget menuHeading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        color: CupertinoColors.secondaryLabel,
      ),
    ),
  );

  Widget menuChoice(
    BuildContext menu,
    String title,
    String value, {
    bool selected = false,
    bool excluded = false,
    Widget? leading,
    String? subtitle,
  }) => ItemRow(
    title,
    leading: leading,
    subtitle: subtitle,
    trailing: selected
        ? Icon(
            excluded ? CupertinoIcons.multiply : CupertinoIcons.check_mark,
            size: 18,
            color: brand,
          )
        : const SizedBox.shrink(),
    onTap: () => Navigator.pop(menu, value),
  );

  Future<void> multipleFilter(String kind) async {
    final selected = kind == 'account' ? filter.accounts : filter.categories;
    final query = <String, String>{
      'type': 'custom',
      if (kind == 'tag') 'tagFilter': filter.encodedTagFilter,
      if (kind != 'tag' &&
          (selected.isNotEmpty ||
              (kind == 'account' ? filter.noAccounts : filter.noCategories)))
        'selectedIds': selected.join(','),
      if (kind == 'category' && filter.type > 1)
        'allowCategoryTypes': '${filter.type - 1}',
    };
    final result = await context.push<Object>(
      '/settings/filter/$kind?${Uri(queryParameters: query).query}',
    );
    if (!mounted || result == null) return;
    changedFilter(() {
      if (kind == 'tag') {
        filter.readTagFilter(string(result));
      } else {
        final ids = (result as List).map(string).toSet();
        if (kind == 'account') {
          filter.accounts = expandSelection(ids, app.accounts, 'subAccounts');
          filter.noAccounts = ids.isEmpty;
        } else {
          filter.categories = expandSelection(
            ids,
            app.categories,
            'subCategories',
          );
          filter.noCategories = ids.isEmpty;
        }
      }
    });
  }

  Future<void> moreFilters(BuildContext anchor) async {
    final selectedTagStates = {
      for (final id in filter.tags) id: filter.tagMode < 2,
      for (final rule in filter.additionalTagFilters)
        for (final id in (rule['tagIds'] as List).map(string))
          id: number(rule['mode']) < 2,
    };
    final selectedTags = selectedTagStates.keys.toSet();
    String groupOf(RecordData tag) =>
        string(tag['groupId']).isEmpty ? '0' : string(tag['groupId']);
    final groups = {
      '0',
      ...app.tagGroups.map((group) => string(group['id'])),
      ...app.tags.map(groupOf),
    };
    final result = await anchoredPopover<String>(
      anchor,
      (menu) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          menuHeading(t('Type')),
          for (final type in [0, 1, 2, 3, 4])
            menuChoice(
              menu,
              t(type == 0 ? 'All' : transactionType(type)),
              'type:$type',
              selected: filter.type == type,
            ),
          menuHeading(t('Amount')),
          for (final entry in const {
            '': 'All',
            'gt': 'Greater than',
            'lt': 'Less than',
            'eq': 'Equal to',
            'ne': 'Not equal to',
            'bt': 'Between',
            'nb': 'Not between',
          }.entries)
            menuChoice(
              menu,
              t(entry.value),
              'amount:${entry.key}',
              selected: filter.amountOperator == entry.key,
              subtitle:
                  entry.key.isNotEmpty && filter.amountOperator == entry.key
                  ? '${amount(filter.minimumAmount ?? 0)}${['bt', 'nb'].contains(entry.key) ? ' – ${amount(filter.maximumAmount ?? 0)}' : ''}'
                  : null,
            ),
          menuHeading(t('Tags')),
          menuChoice(
            menu,
            t('All'),
            'tag:',
            selected: filter.encodedTagFilter.isEmpty,
          ),
          menuChoice(
            menu,
            t('Without Tags'),
            'tag:none',
            selected: filter.noTags,
          ),
          if (app.tags.isNotEmpty)
            menuChoice(
              menu,
              t('Multiple Tags'),
              'tags',
              selected: selectedTags.length > 1,
            ),
          for (final group in groups)
            if (app.tags.any(
              (tag) =>
                  groupOf(tag) == group &&
                  (tag['hidden'] != true ||
                      selectedTags.contains(string(tag['id']))),
            )) ...[
              menuHeading(
                group == '0'
                    ? t('Default Group')
                    : recordName(app.tagGroups, group),
              ),
              for (final tag in app.tags.where(
                (tag) =>
                    groupOf(tag) == group &&
                    (tag['hidden'] != true ||
                        selectedTags.contains(string(tag['id']))),
              ))
                menuChoice(
                  menu,
                  string(tag['name']),
                  'tag:0:${tag['id']}',
                  selected: selectedTags.contains(string(tag['id'])),
                  excluded: selectedTagStates[string(tag['id'])] == false,
                ),
            ],
        ],
      ),
    );
    if (!mounted || result == null) return;
    if (result == 'tags') {
      await multipleFilter('tag');
      return;
    }
    if (result.startsWith('type:')) {
      changedFilter(
        () => filter.selectType(number(result.substring(5)), app.categories),
      );
    } else if (result.startsWith('tag:')) {
      changedFilter(() => filter.readTagFilter(result.substring(4)));
    } else {
      final relation = result.substring(7);
      if (relation.isEmpty) {
        changedFilter(() => filter.selectAmountOperator(''));
      } else {
        final query = Uri(
          queryParameters: {
            'type': relation,
            'value': filter.encodedAmountFilter,
          },
        ).query;
        final value = await context.push<String>(
          '/transaction/filter/amount?$query',
        );
        if (mounted && value != null) {
          changedFilter(() => filter.readAmountFilter(value));
        }
      }
    }
  }

  Future<void> catalogFilter(BuildContext anchor, String kind) async {
    final account = kind == 'account';
    final selected = account ? filter.accounts : filter.categories;
    final roots = account
        ? app.accounts
        : app.categories
              .where(
                (item) =>
                    filter.type == 0 || number(item['type']) == filter.type - 1,
              )
              .toList();
    final children = account ? 'subAccounts' : 'subCategories';
    final expanded = {
      for (final parent in roots)
        if (flatten([
          parent,
        ], children).any((item) => selected.contains(string(item['id']))))
          string(parent['id']),
    };
    bool visible(RecordData item) =>
        item['hidden'] != true ||
        flatten([
          item,
        ], children).any((child) => selected.contains(string(child['id'])));
    final result = await anchoredPopover<String>(
      anchor,
      (menu) => StatefulBuilder(
        builder: (menu, rebuild) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            menuChoice(
              menu,
              t('All'),
              '',
              selected:
                  selected.isEmpty &&
                  !(account ? filter.noAccounts : filter.noCategories),
            ),
            if (roots.isNotEmpty)
              menuChoice(
                menu,
                t(account ? 'Multiple Accounts' : 'Multiple Categories'),
                'multiple',
                selected: selected.length > 1,
              ),
            for (final parent in roots.where(visible)) ...[
              if (account)
                menuChoice(
                  menu,
                  string(parent['name']),
                  string(parent['id']),
                  selected: selected.contains(string(parent['id'])),
                  leading: recordIcon(parent),
                )
              else
                ItemRow(
                  string(parent['name']),
                  leading: recordIcon(parent),
                  trailing: Icon(
                    expanded.contains(string(parent['id']))
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    size: 16,
                  ),
                  onTap: () => rebuild(() {
                    if (!expanded.remove(string(parent['id']))) {
                      expanded.add(string(parent['id']));
                    }
                  }),
                ),
              if (account || expanded.contains(string(parent['id'])))
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!account)
                        menuChoice(
                          menu,
                          t('All'),
                          string(parent['id']),
                          selected: selected.contains(string(parent['id'])),
                        ),
                      for (final item in records(parent[children]).where(
                        (item) =>
                            (item['hidden'] != true &&
                                (!account || parent['hidden'] != true)) ||
                            selected.contains(string(item['id'])),
                      ))
                        menuChoice(
                          menu,
                          string(item['name']),
                          string(item['id']),
                          selected: selected.contains(string(item['id'])),
                          leading: recordIcon(item),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result == 'multiple') {
      await multipleFilter(kind);
      return;
    }
    changedFilter(() {
      final ids = result.isEmpty
          ? <String>{}
          : expandSelection([result], roots, children);
      if (account) {
        filter.accounts = ids;
        filter.noAccounts = false;
      } else {
        filter.categories = ids;
        filter.noCategories = false;
      }
    });
  }

  Future<void> dateFilter(BuildContext anchor) async {
    final selected = flatten(app.accounts, 'subAccounts')
        .where(
          (item) =>
              number(item['type']) != 2 &&
              filter.accounts.contains(string(item['id'])),
        )
        .toList();
    final account = selected.length == 1 ? selected.first : <String, dynamic>{};
    final statementDay = number(
      account['creditCardStatementDate'] ??
          lookup(app.accounts, account['parentId'])['creditCardStatementDate'],
    );
    final ranges = {
      if (pageType != 1) ...dateRangesForScene(0) else 7: 'This month',
      if (pageType == 1) 8: 'Last month',
      if (pageType != 1 && statementDay > 0) 51: 'Current Billing Cycle',
      if (pageType != 1 && statementDay > 0) 52: 'Previous Billing Cycle',
      if (pageType != 1 &&
          app.user['useLastReconciledTime'] == true &&
          number(account['lastReconciledTime']) > 0)
        71: 'Since Last Reconciled Time',
      255: 'Custom Date',
    };
    final result = await anchoredPopover<String>(
      anchor,
      (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in ranges.entries)
            menuChoice(
              menu,
              t(entry.value),
              '${entry.key}',
              selected: filter.periodType == entry.key,
            ),
        ],
      ),
    );
    if (!mounted || result == null) return;
    final period = number(result);
    if (period == 255) {
      var start = filter.start ?? app.formatter.localDate(DateTime.now());
      var end = filter.end ?? start;
      final range = await showCupertinoModalPopup<(DateTime, DateTime)>(
        context: context,
        builder: (sheet) => SizedBox(
          height: pageType == 1 ? 360 : 300,
          child: StatefulBuilder(
            builder: (sheet, rebuild) => NativePage(
              title: t(pageType == 1 ? 'Select Month' : 'Custom Date Range'),
              back: false,
              trailing: actionButton(t('Apply'), () async {
                if (end.isBefore(start) && pageType != 1) {
                  await inform(sheet, t('Invalid date range'));
                  return;
                }
                Navigator.pop(sheet, (start, end));
              }),
              children: [
                if (pageType == 1)
                  SizedBox(
                    height: 230,
                    child: CupertinoDatePicker(
                      mode: CupertinoDatePickerMode.monthYear,
                      initialDateTime: start,
                      onDateTimeChanged: (date) {
                        start = DateTime(date.year, date.month);
                        end = DateTime(date.year, date.month + 1, 0);
                      },
                    ),
                  )
                else
                  Section(
                    children: [
                      for (final first in [true, false])
                        ItemRow(
                          t(first ? 'Start Date' : 'End Date'),
                          value: dateText(first ? start : end),
                          onTap: () async {
                            final date = await pickDate(
                              sheet,
                              t(first ? 'Start Date' : 'End Date'),
                              first ? start : end,
                              time: false,
                            );
                            if (date != null) {
                              rebuild(() {
                                if (first) {
                                  start = date;
                                } else {
                                  end = date;
                                }
                              });
                            }
                          },
                        ),
                    ],
                  ),
                actionButton(t('Cancel'), () => Navigator.pop(sheet)),
              ],
            ),
          ),
        ),
      );
      if (!mounted || range == null) return;
      changedFilter(() {
        filter.start = DateTime(range.$1.year, range.$1.month, range.$1.day);
        filter.end = DateTime(range.$2.year, range.$2.month, range.$2.day);
        filter.periodType = 255;
        filter.preciseTimes = false;
        filter.afterTime = null;
        if (pageType == 1) normalizeCalendarMonth();
      });
    } else {
      changedFilter(() {
        filter.setPeriod(app, period);
        if (pageType == 1) normalizeCalendarMonth();
      });
    }
  }

  void normalizeCalendarMonth() {
    final date = filter.start ?? app.formatter.localDate(DateTime.now());
    filter.start = DateTime(date.year, date.month);
    filter.end = DateTime(date.year, date.month + 1, 0);
    filter.periodType = 255;
    calendarDay = (calendarDay ?? app.formatter.localDate(DateTime.now()).day)
        .clamp(1, filter.end!.day);
  }

  Future<void> selectView() async {
    final selected = await choose(context, t('Details'), {
      0: t('Transaction List'),
      1: t('Transaction Calendar'),
      2: t('Transaction Gallery'),
    }, selected: pageType);
    if (selected != null && mounted) {
      setState(() {
        pageType = selected;
        if (pageType == 1) normalizeCalendarMonth();
      });
    }
  }

  Map<int, AccountDisplayBalance> totals(Iterable<RecordData> items) {
    final cached = app.settings['cachedExchangeRates'];
    final table = cached is Map ? cached : const {};
    return transactionTotals(
      transactions: items,
      accounts: flatten(app.accounts, 'subAccounts'),
      selectedAccounts: filter.accounts,
      defaultCurrency: string(app.user['defaultCurrency']),
      rates: {
        string(table['baseCurrency']): '1',
        for (final rate in records(table['exchangeRates']))
          string(rate['currency']): string(rate['rate']),
      },
    );
  }

  String totalText(AccountDisplayBalance total, int type) =>
      '${type == 2 ? '+' : '-'}${amount(total.value, total.currency)}${total.incomplete || !app.initialSyncComplete ? '*' : ''}';

  void month(int direction) {
    final selected = filter.start ?? DateTime.now();
    setState(() {
      final end = filter.end ?? DateTime(selected.year, selected.month + 1, 0);
      if (pageType == 1) {
        filter.start = DateTime(selected.year, selected.month + direction);
        normalizeCalendarMonth();
      } else if ([51, 52].contains(filter.periodType)) {
        filter.start = DateTime(
          selected.year,
          selected.month + direction,
          selected.day,
        );
        filter.end = DateTime(end.year, end.month + direction, end.day);
      } else if ([7, 8, 0].contains(filter.periodType)) {
        filter.start = DateTime(selected.year, selected.month + direction);
        filter.end = DateTime(selected.year, selected.month + direction + 1, 0);
      } else if ([
        9,
        10,
        11,
        12,
        101,
        102,
        103,
        104,
        105,
        106,
      ].contains(filter.periodType)) {
        filter.start = DateTime(
          selected.year + direction,
          selected.month,
          selected.day,
        );
        filter.end = DateTime(end.year + direction, end.month, end.day);
      } else {
        final days =
            DateTime.utc(end.year, end.month, end.day)
                .difference(
                  DateTime.utc(selected.year, selected.month, selected.day),
                )
                .inDays +
            1;
        filter.start = DateTime(
          selected.year,
          selected.month,
          selected.day + days * direction,
        );
        filter.end = DateTime(end.year, end.month, end.day + days * direction);
      }
      filter.afterTime = null;
    });
  }

  @override
  Widget buildPage(BuildContext _) {
    final items =
        app.transactions
            .where((item) => filter.matches(item, dateOf: transactionDate))
            .where(
              (item) => pageType != 2 || transactionPictures(item).isNotEmpty,
            )
            .toList()
          ..sort(compareTransactionsNewestFirst);
    availableCount = items.length;
    final visibleItems = pageType == 1
        ? items
              .where((item) => transactionDate(item).day == calendarDay)
              .toList()
        : items.take(visibleCount).toList();
    final groups = <DateTime, List<RecordData>>{};
    for (final item in visibleItems) {
      groups
          .putIfAbsent(
            DateTime.utc(
              transactionDate(item).year,
              transactionDate(item).month,
            ),
            () => [],
          )
          .add(item);
    }
    return NativePage(
      title: t(
        pageType == 1
            ? 'Transaction Calendar'
            : pageType == 2
            ? 'Transaction Gallery'
            : 'Details',
      ),
      onTitleTap: selectView,
      busy: busy,
      onRefresh: app.refresh,
      onScrollNearEnd: pageType != 1 && items.length > visibleCount
          ? loadMore
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconButton(
            CupertinoIcons.search,
            t('Search'),
            () => changedFilter(() {
              showSearch = !showSearch;
              if (!showSearch) {
                searchController.clear();
                filter.keyword = '';
              }
            }),
          ),
          if (widget.showAddAction)
            iconButton(
              CupertinoIcons.add,
              t('Add Transaction'),
              canAdd
                  ? () => context.push(
                      '/transaction/add?${Uri(queryParameters: transactionListAddQuery(filter, app, DateTime.now())).query}',
                    )
                  : null,
            ),
        ],
      ),
      bottom: Container(
        height: 64,
        decoration: BoxDecoration(
          color: CupertinoColors.systemBackground.resolveFrom(context),
          border: const Border(
            top: BorderSide(color: CupertinoColors.separator, width: .5),
          ),
        ),
        child: Row(
          children: [
            iconButton(
              CupertinoIcons.chevron_left,
              t('Previous Period'),
              filter.start == null && filter.end == null
                  ? null
                  : () => month(-1),
            ),
            toolbarChoice(
              filter.periodType == 0
                  ? t('Date')
                  : filter.periodType == 255 && filter.start != null
                  ? app.formatter.month(filter.start!)
                  : t(
                      dateRangeNames[filter.periodType] ??
                          (filter.periodType == 51
                              ? 'Current Billing Cycle'
                              : filter.periodType == 52
                              ? 'Previous Billing Cycle'
                              : 'Since Last Reconciled Time'),
                    ),
              filter.periodType != 0,
              dateFilter,
            ),
            iconButton(
              CupertinoIcons.chevron_right,
              t('Next Period'),
              filter.start == null && filter.end == null
                  ? null
                  : () => month(1),
            ),
            toolbarChoice(
              selectedName('category'),
              filter.categories.isNotEmpty || filter.noCategories,
              filter.type == 1
                  ? null
                  : (anchor) => catalogFilter(anchor, 'category'),
            ),
            toolbarChoice(
              selectedName('account'),
              filter.accounts.isNotEmpty || filter.noAccounts,
              (anchor) => catalogFilter(anchor, 'account'),
            ),
            Builder(
              builder: (anchor) => CupertinoButton(
                padding: const EdgeInsets.all(8),
                onPressed: () => moreFilters(anchor),
                child: Semantics(
                  label: t('More'),
                  child: Icon(
                    CupertinoIcons.ellipsis_vertical,
                    color:
                        filter.type != 0 ||
                            filter.encodedAmountFilter.isNotEmpty ||
                            filter.encodedTagFilter.isNotEmpty
                        ? brand
                        : CupertinoColors.label.resolveFrom(context),
                  ),
                ),
              ),
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
        if (app.pendingCount > 0 || app.conflicts.isNotEmpty)
          Section(
            children: [
              ItemRow(
                t('Sync'),
                value: '${app.pendingCount}',
                onTap: () => Navigator.of(context).push(
                  nativeRoute(context, builder: (_) => const SyncStatusPage()),
                ),
              ),
            ],
          ),
        if (showSearch)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: CupertinoSearchTextField(
              controller: searchController,
              placeholder: t('Search transaction description'),
              onSuffixTap: () => changedFilter(() {
                searchController.clear();
                filter.keyword = '';
                showSearch = false;
              }),
              onChanged: (value) => setState(() {
                filter.keyword = value;
                visibleCount = number(
                  app.settings['itemsCountInTransactionListPage'] ?? 15,
                ).clamp(5, 100);
              }),
            ),
          ),
        if (pageType == 1) calendar(items),
        for (final entry in groups.entries)
          Section(
            children: [
              if (pageType != 1)
                ItemRow(
                  app.formatter.month(entry.key),
                  onTap: () => setState(() {
                    if (!collapsedMonths.remove(entry.key)) {
                      collapsedMonths.add(entry.key);
                    }
                  }),
                  trailing:
                      app.settings['showTotalAmountInTransactionListPage'] ==
                          false
                      ? null
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (final type in [2, 3])
                              Text(
                                totalText(
                                  totals(
                                    items.where(
                                      (item) =>
                                          transactionDate(item).year ==
                                              entry.key.year &&
                                          transactionDate(item).month ==
                                              entry.key.month,
                                    ),
                                  )[type]!,
                                  type,
                                ),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: amountColor(app, type, context),
                                ),
                              ),
                          ],
                        ),
                ),
              if (pageType == 2 && !collapsedMonths.contains(entry.key))
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 3,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                    children: [
                      for (final item in entry.value)
                        for (final (index, picture) in transactionPictures(
                          item,
                        ).indexed)
                          _TransactionThumbnail(
                            key: ValueKey(picture['pictureId']),
                            picture: picture,
                            label:
                                '${t('Picture')} ${app.formatter.digits('${index + 1}')} · '
                                '${recordName(flatten(app.categories, 'subCategories'), item['categoryId'])} · '
                                '${dateText(transactionDate(item), time: true)}',
                            onTap: () => context.push(
                              '/transaction/edit?id=${item['id']}',
                            ),
                          ),
                    ],
                  ),
                ),
              if (pageType != 2 &&
                  (pageType == 1 || !collapsedMonths.contains(entry.key)))
                for (final item in entry.value)
                  SwipeActionsRow(
                    key: ValueKey(item['id']),
                    onLongPress: () => transactionActions(item),
                    actions: {
                      if (number(item['type']) != 1)
                        t('Duplicate'): () => context.push(
                          '/transaction/add?id=${item['id']}&type=${item['type']}',
                        ),
                      if (app.canEditTransaction(item)) ...{
                        t('Edit'): () => context.push(
                          '/transaction/edit?id=${item['id']}&type=${item['type']}',
                        ),
                        t('Delete'): () => removeTransaction(item),
                      },
                    },
                    child: TransactionRow(
                      item: item,
                      app: app,
                      showDate: true,
                      filterAccounts: filter.accounts,
                      previousItem: entry.value.indexOf(item) > 0
                          ? entry.value[entry.value.indexOf(item) - 1]
                          : null,
                    ),
                  ),
            ],
          ),
        if (visibleItems.isEmpty) emptyState(t('No transactions')),
      ],
    );
  }

  Widget calendar(List<RecordData> items) {
    final month = filter.start ?? app.formatter.localDate(DateTime.now());
    final days = DateTime(month.year, month.month + 1, 0).day;
    final firstDay = number(app.user['firstDayOfWeek']);
    final offset =
        (DateTime(month.year, month.month).weekday % 7 - firstDay + 7) % 7;
    final byDay = <int, List<RecordData>>{};
    for (final item in items) {
      byDay.putIfAbsent(transactionDate(item).day, () => []).add(item);
    }
    final dayTotals = {
      for (final entry in byDay.entries) entry.key: totals(entry.value),
    };
    return Section(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              ItemRow(app.formatter.month(month)),
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
                        child: dayCell(
                          week * 7 + column - offset + 1,
                          days,
                          month,
                          dayTotals,
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

  Widget dayCell(
    int day,
    int days,
    DateTime month,
    Map<int, Map<int, AccountDisplayBalance>> totalsByDay,
  ) {
    if (day < 1 || day > days) return const SizedBox(height: 68);
    final values = totalsByDay[day];
    final date = DateTime(month.year, month.month, day);
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: 8),
      onPressed: () => setState(() => calendarDay = day),
      child: Container(
        decoration: BoxDecoration(
          color: calendarDay == day ? brand.withValues(alpha: .16) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            Text(
              app.formatter.calendarDate(date),
              style: TextStyle(
                fontSize: 16,
                color: calendarDay == day
                    ? brand
                    : CupertinoColors.label.resolveFrom(context),
              ),
            ),
            Text(
              app.formatter.calendarDate(date, alternate: true),
              maxLines: 1,
              style: TextStyle(
                fontSize: 9,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            for (final type in [2, 3])
              Text(
                values == null
                    ? ''
                    : app.settings['showTotalAmountInTransactionListPage'] ==
                          false
                    ? ''
                    : '${type == 2 ? '+' : '-'}${amount(values[type]!.value)}${values[type]!.incomplete ? '*' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9,
                  color: amountColor(app, type, context),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TransactionThumbnail extends ConsumerStatefulWidget {
  const _TransactionThumbnail({
    super.key,
    required this.picture,
    required this.onTap,
    required this.label,
  });
  final RecordData picture;
  final VoidCallback onTap;
  final String label;
  @override
  ConsumerState<_TransactionThumbnail> createState() =>
      _TransactionThumbnailState();
}

class _TransactionThumbnailState extends ConsumerState<_TransactionThumbnail> {
  late final Future<String?> path = ref
      .read(appControllerProvider)
      .picturePath(string(widget.picture['pictureId']));
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    onTap: widget.onTap,
    child: ExcludeSemantics(
      child: GestureDetector(
        onTap: widget.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: FutureBuilder<String?>(
            future: path,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CupertinoActivityIndicator());
              }
              if (snapshot.data == null) {
                return Icon(
                  CupertinoIcons.photo,
                  semanticLabel: tr(context, 'Picture'),
                );
              }
              return Image.file(
                File(snapshot.data!),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const Icon(CupertinoIcons.exclamationmark_circle),
              );
            },
          ),
        ),
      ),
    ),
  );
}

String syncStatusLabel(RecordData item) =>
    const {
      'pending': 'Pending Synchronization',
      'rejected': 'Synchronization Failed',
      'failed': 'Synchronization Failed',
      'conflict': 'Conflict',
    }[item['syncStatus']] ??
    string(item['syncStatus']);

class TransactionRow extends StatelessWidget {
  const TransactionRow({
    super.key,
    required this.item,
    required this.app,
    this.showDate = false,
    this.filterAccounts = const {},
    this.hideAmount = false,
    this.previousItem,
  });
  final RecordData item;
  final AppController app;
  final bool showDate;
  final Set<String> filterAccounts;
  final bool hideAmount;
  final RecordData? previousItem;
  @override
  Widget build(BuildContext context) {
    final category = lookup(
      flatten(app.categories, 'subCategories'),
      item['categoryId'],
    );
    final accounts = flatten(app.accounts, 'subAccounts');
    final account = lookup(accounts, item['sourceAccountId']);
    final type = number(item['type']);
    final showDestination =
        type == 4 &&
        !filterAccounts.contains(string(item['sourceAccountId'])) &&
        filterAccounts.contains(string(item['destinationAccountId']));
    final displayedAccount = showDestination
        ? lookup(accounts, item['destinationAccountId'])
        : account;
    final displayedAmount =
        item[showDestination ? 'destinationAmount' : 'sourceAmount'];
    final tags = (item['tagIds'] as List? ?? [])
        .map((id) => recordName(app.tags, id))
        .where((name) => name.isNotEmpty)
        .join(' · ');
    final sub = [
      if (string(item['comment']).isNotEmpty) string(item['comment']),
      '${string(account['name'])}${type == 4 ? ' → ${recordName(accounts, item['destinationAccountId'])}' : ''}',
      if (app.settings['showTagInTransactionListPage'] != false &&
          tags.isNotEmpty)
        tags,
      if (item['syncStatus'] != null) app.t(syncStatusLabel(item)),
    ].join(' · ');
    if (showDate) {
      final date = app.formatter.transactionDate(item);
      final name = string(category['name']).isEmpty
          ? app.t(transactionType(type))
          : string(category['name']);
      return CupertinoButton(
        padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
        onPressed: () => context.push(
          '/transaction/edit?id=${Uri.encodeQueryComponent(string(item['id']))}',
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 36,
              child: Opacity(
                opacity:
                    previousItem == null ||
                        isoDate(date) !=
                            isoDate(
                              app.formatter.transactionDate(previousItem!),
                            )
                    ? 1
                    : 0,
                child: Column(
                  children: [
                    Text(
                      app.formatter.calendarDate(date),
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                    Text(
                      app.formatter.pattern(date, 'ddd'),
                      style: TextStyle(
                        fontSize: 10,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            recordIcon(category),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.label.resolveFrom(context),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        hideAmount || item['hideAmount'] == true
                            ? '••••'
                            : app.formatter.amount(
                                displayedAmount,
                                currency: string(displayedAccount['currency']),
                              ),
                        style: TextStyle(
                          fontSize: 17,
                          color: amountColor(app, type, context),
                        ),
                      ),
                    ],
                  ),
                  if (string(item['comment']).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        string(item['comment']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    '${app.formatter.time(date)}  ${string(account['name'])}${type == 4 ? ' → ${recordName(accounts, item['destinationAccountId'])}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                  if (app.settings['showTagInTransactionListPage'] != false &&
                      tags.isNotEmpty)
                    Text(
                      tags,
                      style: const TextStyle(fontSize: 11, color: brand),
                    ),
                  if (item['syncStatus'] != null)
                    Text(
                      app.t(syncStatusLabel(item)),
                      style: const TextStyle(fontSize: 11, color: brand),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return ItemRow(
      string(category['name']).isEmpty
          ? app.t(transactionType(type))
          : string(category['name']),
      leading: recordIcon(category),
      subtitle: sub,
      trailing: Text(
        hideAmount || item['hideAmount'] == true
            ? '••••'
            : app.formatter.amount(
                displayedAmount,
                currency: string(displayedAccount['currency']),
              ),
        style: TextStyle(color: amountColor(app, type, context), fontSize: 16),
      ),
      onTap: () => context.push(
        '/transaction/edit?id=${Uri.encodeQueryComponent(string(item['id']))}',
      ),
    );
  }
}

class TransactionFilterPage extends ConsumerStatefulWidget {
  const TransactionFilterPage({
    super.key,
    required this.filter,
    this.amountOnly = false,
    this.returnAmountFilter = false,
    this.tagsOnly = false,
    this.dateScene = 0,
    this.statistics = false,
    this.accountOnly = false,
    this.allowDateRange = true,
  });
  final TransactionFilter filter;
  final bool amountOnly;
  final bool returnAmountFilter;
  final bool tagsOnly;
  final int dateScene;
  final bool statistics;
  final bool accountOnly;
  final bool allowDateRange;
  @override
  ConsumerState<TransactionFilterPage> createState() =>
      _TransactionFilterState();
}

class _TransactionFilterState extends NativeState<TransactionFilterPage> {
  late final f = widget.filter.copy();
  Future<void> many(
    String title,
    List<RecordData> items,
    Set<String> current,
    void Function(Set<String>) update,
  ) async {
    final result = await selectMany(context, t(title), items, current);
    if (result != null && mounted) {
      setState(
        () => update(
          title == 'Accounts'
              ? expandSelection(result, app.accounts, 'subAccounts')
              : title == 'Categories'
              ? expandSelection(result, app.categories, 'subCategories')
              : result.toSet(),
        ),
      );
    }
  }

  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t(widget.amountOnly ? 'Filter Amount' : 'Filter'),
    trailing: actionButton(t('Apply'), () async {
      final problem = f.amountProblem;
      if (problem != null) {
        await inform(context, t(problem));
        return;
      }
      widget.filter.replaceWith(f);
      if (mounted) {
        Navigator.pop(
          context,
          widget.returnAmountFilter ? f.encodedAmountFilter : null,
        );
      }
    }),
    children: [
      if (!widget.amountOnly)
        Section(
          children: [
            if (!widget.tagsOnly) ...[
              if (!widget.statistics)
                ItemRow(
                  t('Type'),
                  value: t(f.type == 0 ? 'All' : transactionType(f.type)),
                  onTap: () async {
                    final value = await choose(context, t('Type'), {
                      0: t('All'),
                      for (final type in [1, 2, 3, 4])
                        type: t(transactionType(type)),
                    }, selected: f.type);
                    if (value != null && mounted) {
                      setState(() => f.selectType(value, app.categories));
                    }
                  },
                ),
              if (!widget.statistics && f.type == 4)
                ItemRow(
                  t('Transfer Direction'),
                  value: t(
                    const {
                      0: 'All',
                      1: 'Transfer Out',
                      2: 'Transfer In',
                    }[f.relatedAccountType]!,
                  ),
                  onTap: () async {
                    final value = await choose(
                      context,
                      t('Transfer Direction'),
                      {0: t('All'), 1: t('Transfer Out'), 2: t('Transfer In')},
                      selected: f.relatedAccountType,
                    );
                    if (value != null && mounted) {
                      setState(() => f.relatedAccountType = value);
                    }
                  },
                ),
              if (widget.allowDateRange)
                ItemRow(
                  t('Date Range'),
                  onTap: () async {
                    final accounts = flatten(app.accounts, 'subAccounts')
                        .where(
                          (account) =>
                              number(account['type']) != 2 &&
                              f.accounts.contains(string(account['id'])),
                        )
                        .toList();
                    final account = accounts.length == 1
                        ? accounts.first
                        : <String, dynamic>{};
                    final statementDay = number(
                      account['creditCardStatementDate'] ??
                          lookup(
                            app.accounts,
                            account['parentId'],
                          )['creditCardStatementDate'],
                    );
                    final period = await choose(context, t('Date Range'), {
                      for (final entry in dateRangesForScene(
                        widget.dateScene,
                      ).entries)
                        entry.key: t(entry.value),
                      if (widget.dateScene == 0 && statementDay > 0)
                        51: t('Current Billing Cycle'),
                      if (widget.dateScene == 0 && statementDay > 0)
                        52: t('Previous Billing Cycle'),
                      if (widget.dateScene == 0 &&
                          number(account['lastReconciledTime']) > 0)
                        71: t('Since Last Reconciled Time'),
                    });
                    if (period != null && mounted) {
                      setState(() => f.setPeriod(app, period));
                    }
                  },
                ),
              if (widget.allowDateRange)
                ItemRow(
                  t('Start Date'),
                  value: f.start == null ? t('All') : dateText(f.start!),
                  onTap: () async {
                    final value = await pickDate(
                      context,
                      t('Start Date'),
                      f.start ?? DateTime.now(),
                      time: false,
                    );
                    if (value != null && mounted) {
                      f.afterTime = null;
                      f.preciseTimes = false;
                      f.periodType = 255;
                      setState(
                        () => f.start = DateTime(
                          value.year,
                          value.month,
                          value.day,
                        ),
                      );
                    }
                  },
                ),
              if (widget.allowDateRange)
                ItemRow(
                  t('End Date'),
                  value: f.end == null ? t('All') : dateText(f.end!),
                  onTap: () async {
                    final value = await pickDate(
                      context,
                      t('End Date'),
                      f.end ?? DateTime.now(),
                      time: false,
                    );
                    if (value != null && mounted) {
                      f.afterTime = null;
                      f.preciseTimes = false;
                      f.periodType = 255;
                      setState(
                        () => f.end = DateTime(
                          value.year,
                          value.month,
                          value.day,
                        ),
                      );
                    }
                  },
                ),
              ItemRow(
                t('Accounts'),
                value: '${f.accounts.length}',
                onTap: () => many(
                  'Accounts',
                  flatten(app.accounts, 'subAccounts'),
                  f.accounts,
                  (value) {
                    f.accounts = value;
                    f.noAccounts = false;
                  },
                ),
              ),
              if (!widget.accountOnly)
                ItemRow(
                  t('Categories'),
                  value: '${f.categories.length}',
                  onTap: () => many(
                    'Categories',
                    flatten(app.categories, 'subCategories'),
                    f.categories,
                    (value) {
                      f.categories = value;
                      f.noCategories = false;
                    },
                  ),
                ),
            ],
            if (!widget.accountOnly) ...[
              ItemRow(
                t('Tags'),
                value: '${f.tags.length}',
                onTap: () =>
                    many('Tags', app.tags, f.tags, (value) => f.tags = value),
              ),
              ItemRow(
                t('Tag Filter'),
                value: t(
                  const [
                    'Include Any Selected Tags',
                    'Include All Selected Tags',
                    'Exclude Any Selected Tags',
                    'Exclude All Selected Tags',
                  ][f.tagMode],
                ),
                onTap: () async {
                  final value = await choose(context, t('Tag Filter'), {
                    0: t('Include Any Selected Tags'),
                    1: t('Include All Selected Tags'),
                    2: t('Exclude Any Selected Tags'),
                    3: t('Exclude All Selected Tags'),
                  }, selected: f.tagMode);
                  if (value != null && mounted) {
                    setState(() => f.tagMode = value);
                  }
                },
              ),
              for (final rule in f.additionalTagFilters)
                ItemRow(
                  t(
                    const [
                      'Include Any Selected Tags',
                      'Include All Selected Tags',
                      'Exclude Any Selected Tags',
                      'Exclude All Selected Tags',
                    ][number(rule['mode'])],
                  ),
                  subtitle: (rule['tagIds'] as List)
                      .map((id) => recordName(app.tags, id))
                      .join(', '),
                  trailing: iconButton(
                    CupertinoIcons.minus_circle,
                    t('Remove'),
                    () => setState(() => f.additionalTagFilters.remove(rule)),
                  ),
                ),
              ItemRow(
                t('Add Tag Filter'),
                onTap: () async {
                  final ids = await selectMany(
                    context,
                    t('Tags'),
                    app.tags,
                    [],
                  );
                  if (ids == null || ids.isEmpty || !mounted) return;
                  final mode = await choose(context, t('Tag Filter'), {
                    0: t('Include Any Selected Tags'),
                    1: t('Include All Selected Tags'),
                    2: t('Exclude Any Selected Tags'),
                    3: t('Exclude All Selected Tags'),
                  });
                  if (mode != null && mounted) {
                    setState(() {
                      f.noTags = false;
                      f.additionalTagFilters.add({'mode': mode, 'tagIds': ids});
                    });
                  }
                },
              ),
              toggleRow(
                t('No Tags'),
                f.noTags,
                (value) => setState(() {
                  f.noTags = value;
                  if (value) {
                    f.tags.clear();
                    f.additionalTagFilters.clear();
                  }
                }),
              ),
              if (!widget.tagsOnly && !widget.statistics)
                toggleRow(
                  t('Must Have Pictures'),
                  f.pictures,
                  (value) => setState(() => f.pictures = value),
                ),
              if (!widget.tagsOnly)
                toggleRow(
                  t('Ignore Case'),
                  f.ignoreCase,
                  (value) => setState(() => f.ignoreCase = value),
                ),
              if (widget.statistics)
                InputRow(
                  t('Search'),
                  value: f.keyword,
                  onChanged: (value) => f.keyword = value,
                ),
            ],
          ],
        ),
      if (!widget.tagsOnly && !widget.statistics)
        Section(
          title: t('Amount'),
          children: [
            ItemRow(
              t('Comparison'),
              value: t(
                const {
                  '': 'None',
                  'gt': 'Greater than',
                  'lt': 'Less than',
                  'eq': 'Equal to',
                  'ne': 'Not equal to',
                  'bt': 'Between',
                  'nb': 'Not between',
                }[f.amountOperator]!,
              ),
              onTap: () async {
                final value = await choose(context, t('Comparison'), {
                  for (final entry in const {
                    '': 'None',
                    'gt': 'Greater than',
                    'lt': 'Less than',
                    'eq': 'Equal to',
                    'ne': 'Not equal to',
                    'bt': 'Between',
                    'nb': 'Not between',
                  }.entries)
                    entry.key: t(entry.value),
                }, selected: f.amountOperator);
                if (value != null && mounted) {
                  setState(() => f.selectAmountOperator(value));
                }
              },
            ),
            if (f.amountOperator.isNotEmpty)
              ItemRow(
                t(
                  ['gt', 'bt', 'nb'].contains(f.amountOperator)
                      ? 'Minimum Amount'
                      : f.amountOperator == 'lt'
                      ? 'Maximum Amount'
                      : 'Amount',
                ),
                value: f.minimumAmount == null
                    ? t('None')
                    : amount(f.minimumAmount),
                onTap: () async {
                  final value = await amountPad(context, f.minimumAmount ?? 0);
                  if (value != null && mounted) {
                    setState(() => f.minimumAmount = value);
                  }
                },
              ),
            if (['bt', 'nb'].contains(f.amountOperator))
              ItemRow(
                t('Maximum Amount'),
                value: f.maximumAmount == null
                    ? t('None')
                    : amount(f.maximumAmount),
                onTap: () async {
                  final value = await amountPad(context, f.maximumAmount ?? 0);
                  if (value != null && mounted) {
                    setState(() => f.maximumAmount = value);
                  }
                },
              ),
          ],
        ),
      actionButton(
        t('Reset'),
        () => setState(() {
          if (widget.amountOnly) {
            f.selectAmountOperator('');
            return;
          }
          if (widget.tagsOnly) {
            f.tags.clear();
            f.additionalTagFilters.clear();
            f.noTags = false;
            return;
          }
          f.type = 0;
          f.relatedAccountType = 0;
          f.periodType = 0;
          f.afterTime = null;
          f.preciseTimes = false;
          f.start = null;
          f.end = null;
          f.accounts.clear();
          f.categories.clear();
          f.noAccounts = false;
          f.noCategories = false;
          f.tags.clear();
          f.additionalTagFilters.clear();
          f.amountOperator = '';
          f.noTags = false;
          f.pictures = false;
          f.minimumAmount = null;
          f.maximumAmount = null;
          f.keyword = '';
        }),
      ),
    ],
  );
}

List<RecordData> transactionPictures(RecordData item) {
  final pictures = records(item['pictures']);
  final ids = pictures.map((picture) => string(picture['pictureId'])).toSet();
  return [
    ...pictures,
    for (final id in (item['pictureIds'] as List? ?? []).map(string))
      if (id.isNotEmpty && ids.add(id)) {'pictureId': id},
  ];
}

void applyTransactionQuery(RecordData data, Map<String, String> query) {
  const fields = {
    'type': 'type',
    'amount': 'sourceAmount',
    'destinationAmount': 'destinationAmount',
    'time': 'time',
  };
  for (final field in fields.entries) {
    final value = int.tryParse(query[field.key] ?? '');
    if (value != null) data[field.value] = value;
  }
  const stringFields = {
    'accountId': 'sourceAccountId',
    'destinationAccountId': 'destinationAccountId',
    'categoryId': 'categoryId',
    'comment': 'comment',
  };
  for (final field in stringFields.entries) {
    if (query.containsKey(field.key)) data[field.value] = query[field.key];
  }
  if (query.containsKey('tagIds')) {
    data['tagIds'] = query['tagIds']!
        .split(',')
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
  }
}

class TransactionEditPage extends ConsumerStatefulWidget {
  const TransactionEditPage({
    super.key,
    required this.route,
    this.query = const {},
    this.initialData,
  });
  final String route;
  final Map<String, String> query;
  final RecordData? initialData;
  @override
  ConsumerState<TransactionEditPage> createState() => _TransactionEditState();
}

({int time, int utcOffset}) transactionTimeFromWall(
  DateTime wall, {
  String timeZone = '',
  int utcOffset = 0,
}) {
  final value = timeZone.isEmpty
      ? DateTime.utc(
          wall.year,
          wall.month,
          wall.day,
          wall.hour,
          wall.minute,
          wall.second,
        )
      : tz.TZDateTime(
          tz.getLocation(timeZone),
          wall.year,
          wall.month,
          wall.day,
          wall.hour,
          wall.minute,
          wall.second,
        );
  return (
    time:
        value.millisecondsSinceEpoch ~/ 1000 -
        (timeZone.isEmpty ? utcOffset * 60 : 0),
    utcOffset: timeZone.isEmpty ? utcOffset : value.timeZoneOffset.inMinutes,
  );
}

RecordData duplicateTransactionData(
  RecordData source, {
  required DateTime now,
  bool withTime = false,
  bool withGeo = false,
}) {
  final copy = {...source};
  for (final key in [
    'id',
    'version',
    'timeSequenceId',
    'syncStatus',
    'editable',
  ]) {
    copy.remove(key);
  }
  copy['pictures'] = <RecordData>[];
  copy['pictureIds'] = <String>[];
  if (!withTime) {
    copy['time'] = now.millisecondsSinceEpoch ~/ 1000;
    copy['utcOffset'] = now.timeZoneOffset.inMinutes;
    copy['timeZone'] = '';
  }
  if (!withGeo) {
    copy['geoLocation'] = null;
    copy['geoLocationName'] = null;
  }
  return copy;
}

class _TransactionEditState extends NativeState<TransactionEditPage> {
  late RecordData data;
  bool ready = false;
  bool saved = false;
  bool closing = false;
  bool dirty = false;
  bool picturesExpanded = false;
  bool amountPadOpen = false;
  bool selectorOpen = false;
  int selectorGeneration = 0;
  int transferConversionGeneration = 0;
  bool launcherAmountEntered = false;
  bool gpsAttempted = false;
  String gpsStatus = '';
  bool consumingShares = false;
  bool shareReadFailed = false;
  final descriptionFocusNode = FocusNode();
  bool get template => widget.route.startsWith('/template');
  bool get embeddedAmountPadEnabled =>
      !template && data['id'] == null && widget.route.endsWith('/add');
  bool get readOnly =>
      widget.route.endsWith('/detail') ||
      !template &&
          data['id'] != null &&
          !app.canEditTransaction(
            lookup(app.transactions, data['id']).isEmpty
                ? data
                : lookup(app.transactions, data['id']),
          );
  int get type => number(data['type']);
  bool get scheduled => template && number(data['templateType']) == 2;
  bool get autoDraftAllowed =>
      !template &&
      widget.route.endsWith('/add') &&
      widget.query['noTransactionDraft'] != 'true' &&
      widget.initialData == null &&
      widget.query['id'] == null &&
      widget.query['templateId'] == null;
  String get draftKey =>
      'transactionDraft:${widget.route}:${widget.initialData != null ? 'recognized' : widget.query['id'] ?? 'new'}';
  @override
  void initState() {
    super.initState();
    final now = app.formatter.localDate(DateTime.now());
    data = {
      'type': number(widget.query['type'] ?? 3),
      'sourceAmount': 0,
      'serviceCharge': 0,
      'originalCurrency': '',
      'originalAmount': 0,
      'destinationAmount': 0,
      'sourceAccountId': '0',
      'destinationAccountId': '0',
      'categoryId': '0',
      'time': now.millisecondsSinceEpoch ~/ 1000,
      'utcOffset': now.timeZoneOffset.inMinutes,
      'timeZone': app.settings['timeZone'],
      'tagIds': <String>[],
      'pictures': <RecordData>[],
      'pictureIds': <String>[],
      'hideAmount': false,
      'comment': '',
      'templateType': number(widget.query['templateType'] ?? 1),
      'name': '',
      'scheduledFrequencyType': 0,
      'scheduledFrequency': '',
    };
    applyQuery();
    picturesExpanded =
        app.settings['alwaysShowTransactionPicturesInMobileTransactionEditPage'] ==
        true;
    Future.microtask(load);
  }

  @override
  void dispose() {
    descriptionFocusNode.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final id = widget.query['id'];
    final templateId = widget.query['templateId'];
    Future<void> loadData() async {
      if (widget.initialData != null) {
        data = {...data, ...widget.initialData!};
        data.remove('id');
        if (!widget.initialData!.containsKey('utcOffset')) {
          data['utcOffset'] = app.formatter
              .localDate(
                DateTime.fromMillisecondsSinceEpoch(
                  number(data['time']) * 1000,
                  isUtc: true,
                ),
              )
              .timeZoneOffset
              .inMinutes;
        }
      } else if (id != null) {
        var item = lookup(template ? app.templates : app.transactions, id);
        if (item.isEmpty) {
          item = Map<String, dynamic>.from(
            await app.get(
              template
                  ? 'v1/transaction/templates/get.json'
                  : 'v1/transactions/get.json',
              query: {'id': id, 'with_pictures': true},
            ),
          );
        }
        data = {...data, ...item};
        if (widget.route.endsWith('/add')) {
          data = duplicateTransactionData(
            data,
            now: app.formatter.localDate(DateTime.now()),
            withTime: widget.query['withTime'] == 'true',
            withGeo: widget.query['withGeoLocation'] == 'true',
          );
        }
      } else if (templateId != null) {
        data = {...data, ...lookup(app.templates, templateId)}..remove('id');
        final now = app.formatter.localDate(DateTime.now());
        data['time'] = now.millisecondsSinceEpoch ~/ 1000;
        data['utcOffset'] = now.timeZoneOffset.inMinutes;
        data['timeZone'] = app.settings['timeZone'];
      } else if (autoDraftAllowed &&
          app.settings[draftKey] is String &&
          string(app.settings[draftKey]).isNotEmpty &&
          !readOnly) {
        if (mounted &&
            await confirm(context, t('Restore transaction draft?'))) {
          data = {
            ...data,
            ...Map<String, dynamic>.from(
              jsonDecode(app.settings[draftKey] as String),
            ),
          };
        }
      }
      data['pictures'] = transactionPictures(data);
      data['pictureIds'] = records(data['pictures'])
          .map((picture) => string(picture['pictureId']))
          .toList();
      if (mounted) setState(() => ready = true);
    }

    if (widget.query['launcher'] == 'true') {
      await loadData();
    } else {
      await run(loadData);
    }
    final shouldEditAmount =
        mounted &&
        !template &&
        widget.route.endsWith('/add') &&
        widget.query['quickAmount'] != 'true' &&
        !launcherAmountEntered;
    final shouldAutoLocate =
        mounted &&
        !template &&
        data['id'] == null &&
        data['geoLocation'] == null &&
        (widget.query['copy'] == 'true' ||
            app.settings['autoGetCurrentGeoLocation'] == true) &&
        !gpsAttempted;
    if (shouldEditAmount || shouldAutoLocate) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (shouldAutoLocate && !gpsAttempted) unawaited(autoLocate());
        if (shouldEditAmount) {
          if (embeddedAmountPadEnabled) {
            await editSourceAmount();
          } else {
            await editSourceAmount(instant: widget.query['launcher'] == 'true');
          }
        }
      });
    }
    if (mounted) consumeShares();
  }

  Future<void> consumeShares() async {
    if (consumingShares ||
        shareReadFailed ||
        !ready ||
        template ||
        readOnly ||
        app.locked ||
        !app.hasSharedPictures) {
      return;
    }
    final capacity = 10 - records(data['pictures']).length;
    if (capacity <= 0) return;
    consumingShares = true;
    try {
      await app.takeSharedPictures(
        maxCount: capacity,
        beforeAcknowledge: (pictures) async {
          if (!mounted) {
            throw StateError(
              'Transaction editor closed before shared pictures were attached',
            );
          }
          final current = records(data['pictures']);
          final ids = current.map((item) => string(item['pictureId'])).toSet();
          setState(() {
            data['pictures'] = [
              ...current,
              ...pictures.where(
                (picture) => ids.add(string(picture['pictureId'])),
              ),
            ];
            data['pictureIds'] = records(data['pictures'])
                .map((picture) => string(picture['pictureId']))
                .toList();
            dirty = true;
            picturesExpanded = true;
          });
          await app.setPreference(draftKey, jsonEncode(data));
        },
      );
    } catch (error) {
      shareReadFailed = true;
      if (mounted) await inform(context, app.errorText(error));
    } finally {
      consumingShares = false;
    }
  }

  void applyQuery() {
    applyTransactionQuery(data, widget.query);
    if (widget.query['time'] != null) {
      final date = app.formatter.localDate(
        DateTime.fromMillisecondsSinceEpoch(
          number(data['time']) * 1000,
          isUtc: true,
        ),
      );
      data['utcOffset'] = date.timeZoneOffset.inMinutes;
    }
  }

  Future<void> autoLocate() async {
    gpsAttempted = true;
    if (mounted) {
      setState(() => gpsStatus = t('Getting Current Location'));
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('Location services disabled');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('Location permission denied');
      }
      if (!mounted) return;
      Map<String, dynamic> point;
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 15),
          ),
        );
        point = {
          'latitude': position.latitude,
          'longitude': position.longitude,
        };
        try {
          final name = await reverseGeocodeNative(
            position.latitude,
            position.longitude,
          );
          if (name.isNotEmpty) point['name'] = name;
        } catch (_) {
          // Use AMap below when the platform geocoder is unavailable.
        }
      } catch (_) {
        if (!mounted) return;
        point = await getAmapCurrentLocation(context, app);
      }
      if (string(point['name']).isEmpty && mounted) {
        try {
          point = await getAmapCurrentLocation(context, app);
        } catch (_) {
          // Retain the coordinates when neither geocoder can resolve a name.
        }
      }
      if (mounted && data['geoLocation'] == null) {
        change('geoLocation', {
          'latitude': point['latitude'],
          'longitude': point['longitude'],
        });
        change('geoLocationName', string(point['name']));
      }
      gpsStatus = '';
    } catch (_) {
      gpsStatus = t('Unable to get current geographic location');
    }
    if (mounted) setState(() {});
  }

  void change(String key, dynamic value) {
    setState(() {
      data[key] = value;
      dirty = true;
    });
    if (autoDraftAllowed &&
        app.settings['autoSaveTransactionDraft'] == 'enabled') {
      app.setPreference(draftKey, jsonEncode(data));
    }
    if (type == 4 &&
        {'sourceAmount', 'sourceAccountId', 'destinationAccountId', 'time', 'utcOffset', 'type'}.contains(key)) {
      unawaited(recalculateTransferDestinationAmount());
    }
  }

  Future<bool> recalculateTransferDestinationAmount() async {
    final generation = ++transferConversionGeneration;
    final source = accountCurrency(string(data['sourceAccountId']));
    final destination = accountCurrency(string(data['destinationAccountId']));
    if (source.isEmpty || destination.isEmpty) return false;
    if (source == destination) {
      change('destinationAmount', number(data['sourceAmount']));
      return true;
    }
    change('destinationAmount', 0);
    final wall = transactionDate(data);
    final date =
        '${wall.year.toString().padLeft(4, '0')}-${wall.month.toString().padLeft(2, '0')}-${wall.day.toString().padLeft(2, '0')}';
    try {
      dynamic response;
      try {
        response = await app.get(
          'v1/exchange_rates/historical.json',
          query: {'date': date},
        );
      } catch (_) {
        response = null;
      }
      if (response == null) {
        final cachedAt = number(app.settings['exchangeRatesCachedAt']);
        final cachedDate = cachedAt > 0
            ? DateTime.fromMillisecondsSinceEpoch(cachedAt * 1000)
            : null;
        if (cachedDate != null &&
            '${cachedDate.year.toString().padLeft(4, '0')}-${cachedDate.month.toString().padLeft(2, '0')}-${cachedDate.day.toString().padLeft(2, '0')}' == date) {
          response = app.settings['cachedExchangeRates'];
        }
      }
      if (!mounted || generation != transferConversionGeneration || response is! Map) {
        return false;
      }
      final rates = <String, String>{
        string(response['baseCurrency']): '1',
        for (final row in records(response['exchangeRates']))
          string(row['currency']): string(row['rate']),
      };
      if (rates[source] == null || rates[destination] == null) return false;
      final raw = BookkeepingFormatter.convertAggregate(
        number(data['sourceAmount']),
        rates[source]!,
        rates[destination]!,
        truncate: true,
      ).toInt();
      var fraction = 2;
      for (final currency in records(app.formatter.reference['currencies'])) {
        if (string(currency['code']) == destination) {
          fraction = number(currency['fraction']);
          break;
        }
      }
      final factor = fraction == 0 ? 100 : fraction == 1 ? 10 : 1;
      final converted = raw ~/ factor * factor;
      if (mounted && generation == transferConversionGeneration) {
        change('destinationAmount', converted);
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  void setWallTime(DateTime wall) {
    final value = transactionTimeFromWall(
      wall,
      timeZone: string(data['timeZone']),
      utcOffset: number(data['utcOffset']),
    );
    change('time', value.time);
    change('utcOffset', value.utcOffset);
    recalculateAccountAmount();
  }

  Future<void> editSourceAmount({bool instant = false}) async {
    if (!mounted || !ready || readOnly || amountPadOpen) return;
    if (embeddedAmountPadEnabled) {
      setState(() => amountPadOpen = true);
      return;
    }
    amountPadOpen = true;
    try {
      final value = await amountPad(
        context,
        number(data['sourceAmount']),
        instant: instant,
      );
      if (value != null && mounted) change('sourceAmount', value);
    } finally {
      amountPadOpen = false;
    }
  }

  Future<T?> openSelector<T>(Future<T?> Function(bool nonBlocking) show) async {
    if (!embeddedAmountPadEnabled) return show(false);
    final generation = ++selectorGeneration;
    setState(() => selectorOpen = true);
    try {
      return await show(true);
    } finally {
      if (mounted && selectorGeneration == generation) {
        setState(() => selectorOpen = false);
      }
    }
  }

  void closeOpenSelector() {
    if (!mounted || !selectorOpen) return;
    selectorGeneration++;
    setState(() => selectorOpen = false);
    Navigator.of(context, rootNavigator: true).pop();
  }

  void handleContentInteraction() {
    if (amountPadOpen) closeEmbeddedAmountPad();
    if (selectorOpen) closeOpenSelector();
  }

  void updateEmbeddedAmount(int value) {
    if (!mounted) return;
    setState(() {
      data['sourceAmount'] = value;
      dirty = true;
    });
    if (type == 4) unawaited(recalculateTransferDestinationAmount());
  }

  void closeEmbeddedAmountPad([int? value]) {
    if (!mounted || !amountPadOpen || !embeddedAmountPadEnabled) return;
    setState(() {
      data['sourceAmount'] = value ?? number(data['sourceAmount']);
      amountPadOpen = false;
      dirty = true;
    });
    if (type == 4) unawaited(recalculateTransferDestinationAmount());
    if (autoDraftAllowed &&
        app.settings['autoSaveTransactionDraft'] == 'enabled') {
      app.setPreference(draftKey, jsonEncode(data));
    }
  }

  Future<void> completeEmbeddedAmount(int value) async {
    closeEmbeddedAmountPad(value);
    if (mounted && type != 1) {
      await selectCategory(openAccountAfter: true);
    }
  }

  List<RecordData> categoryGroups() => app.categories
      .where((item) => number(item['type']) == type - 1)
      .map(
        (item) => {
          ...item,
          'subCategories': records(item['subCategories'])
              .where(
                (child) =>
                    child['hidden'] != true ||
                    string(child['id']) == string(data['categoryId']),
              )
              .toList(),
        },
      )
      .where(
        (item) =>
            item['hidden'] != true || records(item['subCategories']).isNotEmpty,
      )
      .toList();

  List<int> accountCategoryOrder() {
    final order = string(app.settings['accountCategoryOrders'])
        .split(',')
        .map(number)
        .where(accountCategories.containsKey)
        .toList();
    for (final category in accountCategories.keys) {
      if (!order.contains(category)) order.add(category);
    }
    return order;
  }

  List<RecordData> accountGroups(List<RecordData> items) => [
    for (final category in accountCategoryOrder())
      if (items.any((item) => number(item['category']) == category))
        {
          'id': 'account-category-$category',
          'name': t(accountCategories[category]!),
          'icon': accountCategoryIcons[category],
          'iconType': 0,
          'color': '000000',
          'currency': '',
          'subAccounts': items
              .where((item) => number(item['category']) == category)
              .toList(),
        },
  ];

  String categoryPath(String id) {
    for (final parent in app.categories) {
      final child = lookup(records(parent['subCategories']), id);
      if (child.isNotEmpty) {
        return '${parent['name']} › ${child['name']}';
      }
    }
    return recordName(flatten(app.categories, 'subCategories'), id);
  }

  String accountPath(String id) {
    final item = lookup(flatten(app.accounts, 'subAccounts'), id);
    if (item.isEmpty) return '';
    final category = accountCategories[number(item['category'])];
    return category == null
        ? string(item['name'])
        : '${t(category)} › ${item['name']}';
  }

  String accountCurrency(String id) =>
      string(lookup(flatten(app.accounts, 'subAccounts'), id)['currency']);

  RecordData get sourceAccount =>
      lookup(flatten(app.accounts, 'subAccounts'), data['sourceAccountId']);

  bool get multiCurrencyCreditCard =>
      !template &&
      (type == 2 || type == 3) &&
      number(sourceAccount['category']) == 3;

  String get transactionCurrency {
    final original = string(data['originalCurrency']);
    return original.isEmpty
        ? accountCurrency(string(data['sourceAccountId']))
        : original;
  }

  Future<void> selectTransactionCurrency() async {
    final account = accountCurrency(string(data['sourceAccountId']));
    final allowed = effectiveCurrencyCodes(
      settings: app.settings,
      user: app.user,
      accounts: app.accounts,
      extra: [account, string(data['originalCurrency'])],
    );
    final choices = {
      for (final item in await currencyChoices(allowed: allowed))
        string(item['id']): string(item['name']),
    };
    if (!mounted) return;
    final selected = await openSelector(
      (nonBlocking) => choose<String>(
        context,
        t('Transaction Currency'),
        choices,
        selected: transactionCurrency,
        nonBlocking: nonBlocking,
      ),
    );
    if (!mounted || selected == null || selected == transactionCurrency) {
      return;
    }
    if (selected == account) {
      change('originalCurrency', '');
      change('originalAmount', 0);
      return;
    }
    change('originalCurrency', selected);
    if (number(data['originalAmount']) == 0) {
      change('originalAmount', number(data['sourceAmount']));
    }
    await recalculateAccountAmount();
  }

  Future<void> editOriginalAmount() async {
    final value = await amountPad(context, number(data['originalAmount']));
    if (value == null || !mounted) return;
    change('originalAmount', value);
    await recalculateAccountAmount();
  }

  int conversionGeneration = 0;
  Future<void> recalculateAccountAmount() async {
    final generation = ++conversionGeneration;
    final account = accountCurrency(string(data['sourceAccountId']));
    final original = string(data['originalCurrency']);
    if (!multiCurrencyCreditCard || original.isEmpty || original == account) {
      if (original.isNotEmpty || number(data['originalAmount']) != 0) {
        change('originalCurrency', '');
        change('originalAmount', 0);
      }
      return;
    }
    final wall = transactionDate(data);
    final date =
        '${wall.year.toString().padLeft(4, '0')}-${wall.month.toString().padLeft(2, '0')}-${wall.day.toString().padLeft(2, '0')}';
    try {
      final response = await app.get(
        'v1/exchange_rates/historical.json',
        query: {'date': date},
      );
      if (!mounted || generation != conversionGeneration || response is! Map) {
        return;
      }
      final rates = <String, String>{
        string(response['baseCurrency']): '1',
        for (final row in records(response['exchangeRates']))
          string(row['currency']): string(row['rate']),
      };
      if (rates[original] == null || rates[account] == null) return;
      final amount = BookkeepingFormatter.convertAggregate(
        number(data['originalAmount']),
        rates[original]!,
        rates[account]!,
        truncate: true,
      ).toInt();
      if (mounted && generation == conversionGeneration) {
        change('sourceAmount', amount);
      }
    } catch (_) {
      // Keep the manually editable account amount when no historical rate exists.
    }
  }

  Future<void> selectSourceCurrency() async {
    final currencies =
        leafAccounts(app)
            .map((item) => string(item['currency']))
            .where((currency) => currency.isNotEmpty && currency != '---')
            .toSet()
            .toList()
          ..sort();
    if (currencies.isEmpty) return;
    final current = accountCurrency(string(data['sourceAccountId']));
    final selected = await openSelector(
      (nonBlocking) => choose<String>(
        context,
        t('Currency'),
        {for (final currency in currencies) currency: currency},
        selected: current,
        nonBlocking: nonBlocking,
      ),
    );
    if (!mounted || selected == null || selected == current) return;
    final compatible = leafAccounts(app)
        .where((item) => string(item['currency']) == selected)
        .toList();
    if (compatible.length == 1) {
      change('sourceAccountId', compatible.single['id']);
    } else {
      await selectAccount('sourceAccountId', 'Account', compatible);
    }
  }

  Future<void> selectCategory({bool openAccountAfter = false}) async {
    final chosen = await openSelector(
      (nonBlocking) => chooseGroupedRecord(
        context,
        t('Category'),
        categoryGroups(),
        childrenKey: 'subCategories',
        selected: string(data['categoryId']),
        emptyText: t('No available category'),
        nonBlocking: nonBlocking,
      ),
    );
    if (chosen == null || !mounted) return;
    change('categoryId', chosen);
    if (openAccountAfter && mounted) {
      final selected = await selectAccount(
        'sourceAccountId',
        'Account',
        leafAccounts(app),
      );
      if (selected) await focusDescription();
    }
  }

  Future<bool> selectAccount(
    String key,
    String title,
    List<RecordData> items,
  ) async {
    final chosen = await openSelector(
      (nonBlocking) => chooseGroupedRecord(
        context,
        t(title),
        accountGroups(items),
        childrenKey: 'subAccounts',
        selected: string(data[key]),
        emptyText: t('No available account'),
        nonBlocking: nonBlocking,
      ),
    );
    if (chosen == null || !mounted) return false;
    change(key, chosen);
    if (key == 'sourceAccountId') await recalculateAccountAmount();
    return true;
  }

  Future<void> focusDescription() async {
    while (mounted && ModalRoute.of(context)?.isCurrent != true) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (mounted) descriptionFocusNode.requestFocus();
  }

  Future<void> save({bool again = false, bool keepData = false}) async {
    if (busy || closing) return;
    if (!template &&
        number(data['sourceAmount']) == 0 &&
        !await confirm(
          context,
          t('The amount is zero. Do you want to continue?'),
        )) {
      return;
    }
    final result = await run(() async {
      if (number(data['sourceAmount']).abs() > 999999999999999 ||
          number(data['destinationAmount']).abs() > 999999999999999 ||
          number(data['serviceCharge']) < 0 ||
          number(data['sourceAmount']) + number(data['serviceCharge']) > 999999999999999) {
        throw FormatException(t('Amount is too large'));
      }
      if (string(data['sourceAccountId']).isEmpty ||
          string(data['sourceAccountId']) == '0') {
        throw FormatException(t('Please select an account'));
      }
      if (type != 1 &&
          (string(data['categoryId']).isEmpty ||
              string(data['categoryId']) == '0')) {
        throw FormatException(t('Please select a category'));
      }
      if (type == 4 &&
          (string(data['destinationAccountId']) == '0' ||
              data['destinationAccountId'] == data['sourceAccountId'])) {
        throw FormatException(
          t('Please select a different destination account'),
        );
      }
      if (type == 4 && !await recalculateTransferDestinationAmount()) {
        throw FormatException(t('Unable to retrieve exchange rates data'));
      }
      if (string(data['comment']).length > 255) {
        throw FormatException(t('Description is too long'));
      }
      if ((data['tagIds'] as List? ?? []).length > 10) {
        throw FormatException(t('Too many tags'));
      }
      final body = {
        ...data,
        'destinationAccountId': type == 4 ? data['destinationAccountId'] : '0',
        'destinationAmount': type == 4 ? data['destinationAmount'] : 0,
        'serviceCharge': type == 4 ? data['serviceCharge'] : 0,
      };
      if (string(body['originalCurrency']).isEmpty) {
        body.remove('originalCurrency');
        body.remove('originalAmount');
      }
      if (template) {
        if (string(data['name']).trim().isEmpty) {
          throw FormatException(t('Please enter a template name'));
        }
        await onlineMutation(
          'v1/transaction/templates/${data['id'] == null ? 'add' : 'modify'}.json',
          body,
        );
      } else if (type == 1) {
        await onlineMutation(
          'v1/transactions/${data['id'] == null ? 'add' : 'modify'}.json',
          body,
        );
      } else {
        await app.saveTransaction(body);
      }
      await app.setPreference(draftKey, '');
      saved = true;
      dirty = false;
    });
    if (result && mounted) {
      if (again || keepData) {
        setState(() {
          data.remove('id');
          data['pictures'] = <RecordData>[];
          data['pictureIds'] = <String>[];
          if (again) {
            final now = app.formatter.localDate(DateTime.now());
            data.addAll({
              'sourceAmount': 0,
              'serviceCharge': 0,
              'originalCurrency': '',
              'originalAmount': 0,
              'destinationAmount': 0,
              'sourceAccountId': widget.query['accountId'] ?? '0',
              'destinationAccountId': '0',
              'categoryId': '0',
              'comment': '',
              'tagIds': <String>[],
              'geoLocation': null,
              'geoLocationName': null,
              'hideAmount': false,
              'time': now.millisecondsSinceEpoch ~/ 1000,
              'utcOffset': now.timeZoneOffset.inMinutes,
              'timeZone': app.settings['timeZone'],
            });
            applyQuery();
            gpsAttempted = false;
          }
          saved = false;
        });
        if (again && app.settings['autoGetCurrentGeoLocation'] == true) {
          autoLocate();
        }
      } else {
        await finishAndClose();
      }
    }
  }

  Future<void> picture(ImageSource source) async {
    await run(() async {
      final pictures = records(data['pictures']);
      if (pictures.length >= 10) throw FormatException(t('Too many pictures'));
      final file = await ImagePicker().pickImage(
        source: source,
        imageQuality: const {
          1: 93,
          2: 90,
          3: 85,
          4: 80,
        }[number(app.settings['transactionPictureQuality'])],
        maxWidth: const {
          1: 3840.0,
          2: 2560.0,
          3: 1920.0,
          4: 1280.0,
        }[number(app.settings['transactionPictureQuality'])],
        maxHeight: const {
          1: 3840.0,
          2: 2560.0,
          3: 1920.0,
          4: 1280.0,
        }[number(app.settings['transactionPictureQuality'])],
      );
      if (file == null) return;
      final staged = await app.stagePicture(file.path);
      if (mounted) {
        change('pictures', [...pictures, staged]);
        change('pictureIds', [
          ...(data['pictureIds'] as List? ?? []),
          staged['pictureId'],
        ]);
      }
    });
  }

  Future<void> location() async {
    final selected = await chooseLocation(
      context,
      initial: data['geoLocation'] == null
          ? null
          : Map<String, dynamic>.from(data['geoLocation']),
      initialName: string(data['geoLocationName']),
      readOnly: readOnly,
    );
    if (selected != null && mounted && !readOnly) {
      change('geoLocation', {
        'latitude': selected['latitude'],
        'longitude': selected['longitude'],
      });
      change('geoLocationName', string(selected['name']));
    }
  }

  Future<void> more() async {
    final action = await choose(context, t('More'), {
      if (readOnly && app.canEditTransaction(data)) 'edit': t('Edit'),
      if (!readOnly &&
          !template &&
          app.config['transactionFromAITextRecognition'] == true)
        'recognize': t('AI Clipboard Text Recognition'),
      if (!readOnly && type == 4) ...{
        'swapAccounts': t('Swap Account'),
      },
      if (!readOnly) 'pasteSource': t('Paste Amount'),
      if (!readOnly && data['id'] != null)
        'hideAmount': t(
          data['hideAmount'] == true ? 'Show Amount' : 'Hide Amount',
        ),
      if (!readOnly &&
          !template &&
          app.config['enableTransactionPictures'] == true &&
          !picturesExpanded)
        'pictures': t('Add Picture'),
      if (!template && data['id'] != null) 'copy': t('Copy'),
      if (data['id'] != null && (template || app.canEditTransaction(data)))
        'delete': t('Delete'),
    });
    if (!mounted || action == null) return;
    if (action == 'edit') context.push('/transaction/edit?id=${data['id']}');
    if (action == 'pictures') {
      setState(() => picturesExpanded = true);
      return;
    }
    if (action == 'hideAmount') {
      change('hideAmount', data['hideAmount'] != true);
      return;
    }
    if (action == 'swapAccounts') {
      final sourceAccount = data['sourceAccountId'];
      change('sourceAccountId', data['destinationAccountId']);
      change('destinationAccountId', sourceAccount);
      return;
    }
    if (action.startsWith('paste')) {
      await run(() async {
        final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
        if (clipboard == null) return;
        change(
          'sourceAmount',
          parseAmount(clipboard.text ?? ''),
        );
      });
      return;
    }
    if (action == 'recognize') {
      final result = await recognizeTransaction(context, clipboard: true);
      if (result != null && mounted) {
        for (final entry in result.entries) {
          change(entry.key, entry.value);
        }
      }
      return;
    }
    if (action == 'copy') {
      final copy = duplicateTransactionData(
        data,
        now: app.formatter.localDate(DateTime.now()),
      );
      Navigator.of(context).push(
        nativeRoute(
          context,
          builder: (_) => TransactionEditPage(
            route: '/transaction/add',
            query: const {'copy': 'true'},
            initialData: copy,
          ),
        ),
      );
    }
    if (mounted &&
        action == 'delete' &&
        await confirm(
          context,
          t('Are you sure you want to delete?'),
          destructive: true,
        )) {
      final result = await run(() async {
        if (template) {
          await onlineMutation('v1/transaction/templates/delete.json', {
            'id': data['id'],
          });
        } else if (type == 1) {
          await onlineMutation('v1/transactions/delete.json', {
            'id': data['id'],
          });
        } else {
          await app.deleteTransaction(string(data['id']));
        }
      });
      if (result && mounted) await finishAndClose();
    }
  }

  Future<void> quickSave() async {
    if (template || data['id'] != null) {
      await save();
      return;
    }
    var action = number(
      app.settings['quickAddButtonActionInMobileTransactionEditPage'],
    );
    if (action == 1) {
      final selected = await choose(context, t('Save'), {
        0: t('Save'),
        2: t('Save & New'),
        3: t('Save & Duplicate'),
      });
      if (selected == null) return;
      action = selected;
    }
    await save(again: action == 2, keepData: action == 3);
  }

  Future<void> leavePage() async {
    if (closing) return;
    final mode = string(app.settings['autoSaveTransactionDraft']);
    if (autoDraftAllowed && mode == 'enabled') {
      await app.setPreference(draftKey, jsonEncode(data));
    } else if (autoDraftAllowed && mode == 'confirmation') {
      final result = await choose(context, t('Save transaction draft?'), {
        'save': t('Save'),
        'discard': t('Discard'),
        'cancel': t('Cancel'),
      });
      if (result == null || result == 'cancel') return;
      await app.setPreference(
        draftKey,
        result == 'save' ? jsonEncode(data) : '',
      );
    } else if (!await confirm(
      context,
      t('Discard unsaved changes?'),
      destructive: true,
    )) {
      return;
    }
    await finishAndClose();
  }

  Future<void> finishAndClose() async {
    if (!mounted || closing) return;
    setState(() {
      closing = true;
      saved = true;
      dirty = false;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.pop(context);
    } else {
      context.go('/');
    }
  }

  @override
  Widget buildPage(BuildContext _) {
    if (!ready && widget.query['launcher'] == 'true') {
      return QuickAddStartupPage(
        initialAmount: number(data['sourceAmount']),
        onAmountChanged: (amount) {
          data['sourceAmount'] = amount;
          launcherAmountEntered = true;
          dirty = amount != 0;
        },
      );
    }
    if (ready && widget.route.endsWith('/detail') && !dirty) {
      final latest = lookup(app.transactions, data['id']);
      if (latest.isNotEmpty) {
        data = {...latest, 'pictures': transactionPictures(latest)};
        data['pictureIds'] = records(data['pictures'])
            .map((picture) => string(picture['pictureId']))
            .toList();
      }
    }
    if (app.hasSharedPictures &&
        !consumingShares &&
        !shareReadFailed &&
        ready &&
        !app.locked &&
        records(data['pictures']).length < 10) {
      Future.microtask(consumeShares);
    }
    final accounts = flatten(app.accounts, 'subAccounts');
    final categories = flatten(app.categories, 'subCategories');
    final quickStyle = number(
      app.settings['quickSaveButtonStyleInMobileTransactionListPage'] ?? 4,
    );
    final quickAction = number(
      app.settings['quickAddButtonActionInMobileTransactionEditPage'],
    );
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final quickTitle = t(
      data['id'] != null || template
          ? 'Save'
          : const {
                  0: 'Save',
                  1: 'Add',
                  2: 'Save & New',
                  3: 'Save & Duplicate',
                }[quickAction] ??
                'Save',
    );
    final quickButton = CupertinoButton(
      color: brand,
      borderRadius: BorderRadius.circular(24),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
      onPressed: busy || closing || !ready ? null : quickSave,
      child: Text(
        quickTitle,
        style: const TextStyle(color: CupertinoColors.white),
      ),
    );
    final title = template
        ? (data['id'] == null ? 'Add Template' : 'Edit Template')
        : readOnly
        ? 'Transaction Details'
        : data['id'] == null
        ? 'Add Transaction'
        : 'Edit Transaction';
    return PopScope(
      canPop: !amountPadOpen && (!dirty || readOnly || saved),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (embeddedAmountPadEnabled && amountPadOpen) {
          closeEmbeddedAmountPad();
        } else {
          await leavePage();
        }
      },
      child: NativePage(
        title: t(title),
        busy: busy,
        onContentInteraction:
            embeddedAmountPadEnabled && (amountPadOpen || selectorOpen)
            ? handleContentInteraction
            : null,
        bottom: embeddedAmountPadEnabled && amountPadOpen && !landscape
            ? embeddedAmountPad(
                number(data['sourceAmount']),
                onChanged: updateEmbeddedAmount,
                onDone: completeEmbeddedAmount,
              )
            : !readOnly && quickStyle == 1
            ? SizedBox(
                height: 60,
                child: Center(child: actionButton(quickTitle, quickSave)),
              )
            : null,
        side: embeddedAmountPadEnabled && amountPadOpen && landscape
            ? embeddedAmountPad(
                number(data['sourceAmount']),
                onChanged: updateEmbeddedAmount,
                onDone: completeEmbeddedAmount,
                compact: true,
              )
            : null,
        floating: embeddedAmountPadEnabled && amountPadOpen
            ? null
            : !readOnly && quickStyle >= 2 && quickStyle <= 4
            ? Align(
                alignment: const {
                  2: Alignment.bottomLeft,
                  3: Alignment.bottomCenter,
                  4: Alignment.bottomRight,
                }[quickStyle]!,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: quickButton,
                ),
              )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            iconButton(CupertinoIcons.ellipsis, t('More'), more),
            if (!readOnly)
              iconButton(CupertinoIcons.check_mark, t('Save'), save),
          ],
        ),
        children: [
          if (shareReadFailed)
            Section(
              children: [
                ItemRow(
                  t('Retry receiving shared pictures'),
                  onTap: () {
                    setState(() => shareReadFailed = false);
                    consumeShares();
                  },
                ),
              ],
            ),
          if (app.hasSharedPictures && records(data['pictures']).length >= 10)
            Section(
              footer: t(
                'More shared pictures are waiting. Save this transaction or remove a picture to continue.',
              ),
              children: [ItemRow(t('At most 10 pictures are allowed'))],
            ),
          if (!ready)
            const Padding(
              padding: EdgeInsets.all(32),
              child: CupertinoActivityIndicator(),
            ),
          if (ready) ...[
            if (type != 1)
              Padding(
                padding: const EdgeInsets.all(16),
                child: CupertinoSlidingSegmentedControl<int>(
                  groupValue: type,
                  children: {
                    for (final value in [3, 2, 4])
                      value: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(t(transactionType(value))),
                      ),
                  },
                  onValueChanged: (value) {
                    if (!readOnly && value != null) {
                      change('type', value);
                      change(
                        'categoryId',
                        leafCategories(app, value).firstOrNull?['id'] ?? '0',
                      );
                      recalculateAccountAmount();
                    }
                  },
                ),
              ),
            Section(
              children: [
                if (template)
                  InputRow(
                    t('Template Name'),
                    value: string(data['name']),
                    readOnly: readOnly,
                    onChanged: (value) => change('name', value),
                  ),
                if (multiCurrencyCreditCard &&
                    string(data['originalCurrency']).isNotEmpty)
                  ItemRow(
                    t('Original Amount'),
                    value: amount(
                      data['originalAmount'],
                      string(data['originalCurrency']),
                    ),
                    color: amountColor(app, type, context),
                    onTap: readOnly ? null : editOriginalAmount,
                  ),
                ItemRow(
                  t(
                    type == 4
                        ? 'Transfer Out Amount'
                        : string(data['originalCurrency']).isNotEmpty
                        ? 'Account Amount'
                        : 'Amount',
                  ),
                  value: data['hideAmount'] == true && readOnly
                      ? '••••'
                      : amount(
                          data['sourceAmount'],
                          string(
                            lookup(
                              accounts,
                              data['sourceAccountId'],
                            )['currency'],
                          ),
                        ),
                  color: amountColor(app, type, context),
                  onTap: readOnly ? null : () => editSourceAmount(),
                ),
                if (type == 4)
                  ItemRow(
                    t('Service Charge'),
                    value: amount(
                      data['serviceCharge'],
                      string(
                        lookup(
                          accounts,
                          data['sourceAccountId'],
                        )['currency'],
                      ),
                    ),
                    color: brand,
                    onTap: readOnly
                        ? null
                        : () async {
                            final value = await amountPad(
                              context,
                              number(data['serviceCharge']),
                            );
                            if (value != null && mounted) {
                              change('serviceCharge', value);
                            }
                          },
                  ),
                if (type != 1)
                  ItemRow(
                    t('Category'),
                    value: categoryPath(string(data['categoryId'])),
                    leading: recordIcon(lookup(categories, data['categoryId'])),
                    onTap: readOnly ? null : () => selectCategory(),
                  ),
                ItemRow(
                  t('Account'),
                  value: accountPath(string(data['sourceAccountId'])),
                  leading: recordIcon(
                    lookup(accounts, data['sourceAccountId']),
                  ),
                  onTap: readOnly || type == 1 && data['id'] != null
                      ? null
                      : () => selectAccount(
                          'sourceAccountId',
                          'Account',
                          leafAccounts(app),
                        ),
                ),
                if (multiCurrencyCreditCard)
                  ItemRow(
                    t('Transaction Currency'),
                    value: transactionCurrency,
                    onTap: readOnly ? null : selectTransactionCurrency,
                  )
                else
                  ItemRow(
                    t('Currency'),
                    value: accountCurrency(string(data['sourceAccountId'])),
                    onTap: readOnly || type == 1 && data['id'] != null
                        ? null
                        : selectSourceCurrency,
                  ),
                if (type == 4)
                  ItemRow(
                    t('Destination Account'),
                    value: accountPath(string(data['destinationAccountId'])),
                    leading: recordIcon(
                      lookup(accounts, data['destinationAccountId']),
                    ),
                    onTap: readOnly
                        ? null
                        : () => selectAccount(
                            'destinationAccountId',
                            'Destination Account',
                            leafAccounts(app)
                                .where(
                                  (item) =>
                                      item['id'] != data['sourceAccountId'],
                                )
                                .toList(),
                          ),
                  ),
                if (!template)
                  ItemRow(
                    t('Transaction Time'),
                    value: app.formatter.pattern(
                      app.formatter.transactionDate(
                        data,
                        originalTimezone: true,
                      ),
                      'YYYY/MM/DD HH:mm',
                    ),
                    onTap: readOnly
                        ? null
                        : type == 1
                        ? null
                        : () async {
                            final value = await openSelector(
                              (nonBlocking) => pickDate(
                                context,
                                t('Transaction Time'),
                                transactionDate(data),
                                withSeconds: false,
                                nonBlocking: nonBlocking,
                              ),
                            );
                            if (value != null && mounted) {
                              setWallTime(value);
                            }
                          },
                  ),
                if (scheduled)
                  ItemRow(
                    t('Scheduled Transaction Frequency'),
                    value: scheduleDescription(data, app.formatter),
                    onTap: () async {
                      final result = await Navigator.of(context)
                          .push<RecordData>(
                            nativeRoute(
                              context,
                              builder: (_) => SchedulePage(data: data),
                            ),
                          );
                      if (result != null && mounted) {
                        for (final entry in result.entries) {
                          change(entry.key, entry.value);
                        }
                      }
                    },
                  ),
                ItemRow(
                  t('Tags'),
                  value: (data['tagIds'] as List? ?? [])
                      .map((id) => recordName(app.tags, id))
                      .join(', '),
                  onTap: readOnly
                      ? null
                      : () async {
                          final value = await openSelector(
                            (nonBlocking) => selectMany(
                              context,
                              t('Tags'),
                              app.tags
                                  .where((item) => item['hidden'] != true)
                                  .toList(),
                              (data['tagIds'] as List? ?? []).map(string),
                              nonBlocking: nonBlocking,
                            ),
                          );
                          if (value != null && mounted) change('tagIds', value);
                        },
                ),
                InputRow(
                  t('Description'),
                  value: string(data['comment']),
                  lines: 3,
                  readOnly: readOnly,
                  focusNode: descriptionFocusNode,
                  onChanged: (value) => change('comment', value),
                ),
                if (!readOnly && data['id'] != null)
                  toggleRow(
                    t('Hide Amount'),
                    data['hideAmount'] == true,
                    (value) => change('hideAmount', value),
                  ),
              ],
            ),
            if (!template)
              Section(
                title: t('Geographic Location'),
                children: [
                  ItemRow(
                    data['geoLocation'] == null
                        ? t('No Location')
                        : string(data['geoLocationName']).isNotEmpty
                        ? string(data['geoLocationName'])
                        : formatNativeCoordinate(
                            Map<String, dynamic>.from(data['geoLocation']),
                            number(app.user['coordinateDisplayType']),
                          ),
                    subtitle: gpsStatus.isNotEmpty
                        ? gpsStatus
                        : data['geoLocation'] != null &&
                              string(data['geoLocationName']).isNotEmpty
                        ? formatNativeCoordinate(
                            Map<String, dynamic>.from(data['geoLocation']),
                            number(app.user['coordinateDisplayType']),
                          )
                        : null,
                    leading: const Icon(CupertinoIcons.location),
                    onTap: !readOnly || data['geoLocation'] != null
                        ? location
                        : null,
                  ),
                  if (data['geoLocation'] != null && !readOnly)
                    ItemRow(
                      t('Remove Location'),
                      destructive: true,
                      onTap: () {
                        change('geoLocation', null);
                        change('geoLocationName', null);
                      },
                    ),
                ],
              ),
            if (!template &&
                (app.config['enableTransactionPictures'] == true &&
                        picturesExpanded ||
                    records(data['pictures']).isNotEmpty))
              Section(
                title: t('Pictures'),
                children: [
                  for (final picture in records(data['pictures']))
                    ItemRow(
                      t('Picture'),
                      subtitle:
                          string(picture['pictureId']).startsWith('local:')
                          ? t('Pending upload')
                          : null,
                      leading: const Icon(CupertinoIcons.photo),
                      onTap: () => Navigator.of(context).push(
                        nativeRoute(
                          context,
                          builder: (_) => PicturePage(picture: picture),
                        ),
                      ),
                      trailing: readOnly
                          ? null
                          : iconButton(
                              CupertinoIcons.minus_circle,
                              t('Remove'),
                              () {
                                change(
                                  'pictures',
                                  records(data['pictures'])
                                      .where(
                                        (item) =>
                                            item['pictureId'] !=
                                            picture['pictureId'],
                                      )
                                      .toList(),
                                );
                                change(
                                  'pictureIds',
                                  (data['pictureIds'] as List? ?? [])
                                      .where((id) => id != picture['pictureId'])
                                      .toList(),
                                );
                              },
                            ),
                    ),
                  if (!readOnly)
                    ItemRow(
                      t('Take Photo'),
                      leading: const Icon(CupertinoIcons.camera),
                      onTap: () => picture(ImageSource.camera),
                    ),
                  if (!readOnly)
                    ItemRow(
                      t('Choose Photo'),
                      leading: const Icon(CupertinoIcons.photo_on_rectangle),
                      onTap: () => picture(ImageSource.gallery),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

const frequencyNames = {
  0: 'Disabled',
  3: 'Daily',
  5: 'Every N Days',
  1: 'Weekly',
  2: 'Monthly',
  4: 'Yearly',
};

class SchedulePage extends ConsumerStatefulWidget {
  const SchedulePage({super.key, required this.data});
  final RecordData data;
  @override
  ConsumerState<SchedulePage> createState() => _ScheduleState();
}

class _ScheduleState extends NativeState<SchedulePage> {
  late RecordData data = {...widget.data};
  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t('Scheduled Transaction Frequency'),
    trailing: actionButton(
      t('Save'),
      () => Navigator.pop(context, {
        for (final key in [
          'scheduledFrequencyType',
          'scheduledFrequency',
          'scheduledStartDate',
          'scheduledEndDate',
        ])
          key: data[key],
      }),
    ),
    children: [
      Section(
        children: [
          ItemRow(
            t('Frequency'),
            value: t(
              frequencyNames[number(data['scheduledFrequencyType'])] ??
                  'Disabled',
            ),
            onTap: () async {
              final value = await choose(
                context,
                t('Frequency'),
                frequencyNames.map((key, value) => MapEntry(key, t(value))),
                selected: number(data['scheduledFrequencyType']),
              );
              if (value != null && mounted) {
                setState(() {
                  data['scheduledFrequencyType'] = value;
                  data['scheduledFrequency'] = value == 3
                      ? '0'
                      : value == 0
                      ? ''
                      : value == 4
                      ? '101'
                      : '1';
                });
              }
            },
          ),
          if (![0, 3].contains(number(data['scheduledFrequencyType'])))
            ItemRow(
              t('Schedule'),
              value: scheduleDescription(data, app.formatter),
              onTap: () async {
                final type = number(data['scheduledFrequencyType']);
                final choices = <RecordData>[];
                if (type == 1) {
                  for (var index = 0; index < 7; index++) {
                    final day =
                        (number(app.user['firstDayOfWeek']) + index) % 7;
                    choices.add({
                      'id': '$day',
                      'name': t(
                        const [
                          'Sunday',
                          'Monday',
                          'Tuesday',
                          'Wednesday',
                          'Thursday',
                          'Friday',
                          'Saturday',
                        ][day],
                      ),
                    });
                  }
                }
                if (type == 2) {
                  for (var day = 1; day <= 28; day++) {
                    choices.add({
                      'id': '$day',
                      'name': scheduleMonthDays([day], app.formatter),
                    });
                  }
                  for (var day = 1; day <= 3; day++) {
                    choices.add({
                      'id': '${-day}',
                      'name': scheduleMonthDays([-day], app.formatter),
                    });
                  }
                }
                if (type == 4) {
                  for (var month = 1; month <= 12; month++) {
                    for (
                      var day = 1;
                      day <= DateTime(2025, month + 1, 0).day;
                      day++
                    ) {
                      choices.add({
                        'id': '${month * 100 + day}',
                        'name': app.formatter.monthDay(
                          DateTime(2024, month, day),
                        ),
                      });
                    }
                  }
                }
                if (type == 5) {
                  final value = await choose<int>(context, t('Every N Days'), {
                    for (var n = 1; n <= 180; n++)
                      n: app.formatter.digits('$n'),
                  }, selected: number(data['scheduledFrequency']));
                  if (value != null && mounted) {
                    setState(() => data['scheduledFrequency'] = '$value');
                  }
                  return;
                }
                final selected = await selectMany(
                  context,
                  t('Schedule'),
                  choices,
                  string(data['scheduledFrequency']).split(','),
                  minimumSelections: 1,
                );
                if (selected != null && selected.isNotEmpty && mounted) {
                  setState(
                    () => data['scheduledFrequency'] =
                        (selected.map(number).toList()..sort()).join(','),
                  );
                }
              },
            ),
          for (final key in ['scheduledStartDate', 'scheduledEndDate'])
            ItemRow(
              t(key == 'scheduledStartDate' ? 'Start Date' : 'End Date'),
              value: DateTime.tryParse(string(data[key])) == null
                  ? t('No limit')
                  : dateText(DateTime.parse(string(data[key]))),
              trailing: data[key] == null
                  ? null
                  : iconButton(
                      CupertinoIcons.clear_circled,
                      t('Clear'),
                      () => setState(() => data[key] = null),
                    ),
              onTap: () async {
                final value = await pickDate(
                  context,
                  t('Date'),
                  DateTime.tryParse(string(data[key])) ?? DateTime.now(),
                  time: false,
                );
                if (value != null && mounted) {
                  setState(() => data[key] = isoDate(value));
                }
              },
            ),
        ],
      ),
    ],
  );
}

class PicturePage extends ConsumerStatefulWidget {
  const PicturePage({super.key, required this.picture});
  final RecordData picture;
  @override
  ConsumerState<PicturePage> createState() => _PictureState();
}

class _PictureState extends NativeState<PicturePage> {
  String? path;
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => run(() async {
        path = string(widget.picture['localPath']);
        if (path!.isEmpty) {
          path = await app.picturePath(string(widget.picture['pictureId']));
        }
      }),
    );
  }

  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t('Picture'),
    busy: busy,
    children: [
      if (path != null && path!.isNotEmpty)
        InteractiveViewer(
          minScale: .5,
          maxScale: 5,
          child: Image.file(File(path!)),
        )
      else if (!busy)
        emptyState(t('Picture is not available offline')),
    ],
  );
}

class SyncStatusPage extends ConsumerStatefulWidget {
  const SyncStatusPage({super.key});
  @override
  ConsumerState<SyncStatusPage> createState() => _SyncStatusState();
}

class _SyncStatusState extends NativeState<SyncStatusPage> {
  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t('Sync'),
    busy: busy || app.syncing,
    onRefresh: app.refresh,
    children: [
      Section(
        children: [
          ItemRow(t('Pending transactions'), value: '${app.pendingCount}'),
          ItemRow(
            t('Initial synchronization'),
            value: t(app.initialSyncComplete ? 'Completed' : 'In progress'),
          ),
          if (app.error != null)
            ItemRow(t('Error'), subtitle: app.errorText(app.error!)),
          ItemRow(t('Sync Now'), onTap: () => run(app.refresh)),
        ],
      ),
      for (final conflict in app.conflicts)
        Section(
          title: t('Conflict'),
          footer: t('Your changes are preserved until you choose a version.'),
          children: [
            if ((conflict['response'] as Map? ?? {})['reason'] != null ||
                (conflict['response'] as Map? ?? {})['error'] != null)
              ItemRow(t('Reason'), subtitle: conflictReason(conflict)),
            for (final side in ['local', 'server'])
              ItemRow(
                t(side == 'local' ? 'Local Version' : 'Server Version'),
                subtitleMaxLines: null,
                subtitle: conflictSummary(
                  side == 'local'
                      ? conflict['localData'] ??
                            (conflict['request'] as Map? ?? {})['data']
                      : (conflict['response'] as Map? ?? {})['transaction'],
                ),
              ),
            ItemRow(
              t('Use Server Version'),
              onTap: () =>
                  run(() => app.resolveConflict(string(conflict['id']), false)),
            ),
            ItemRow(
              t('Use Local Version'),
              subtitle: conflict['canUseLocal'] == false
                  ? t(
                      'The server deleted this transaction or cleared the ledger. Local changes are preserved and cannot be recreated automatically.',
                    )
                  : null,
              onTap: conflict['canUseLocal'] == false
                  ? null
                  : () => run(
                      () => app.resolveConflict(string(conflict['id']), true),
                    ),
            ),
            ItemRow(
              t('Copy Local Version'),
              onTap: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: conflictSummary(
                      conflict['localData'] ??
                          (conflict['request'] as Map? ?? {})['data'],
                    ),
                  ),
                );
                if (mounted) await inform(context, t('Copied'));
              },
            ),
            ItemRow(t('Later'), onTap: () => context.pop()),
          ],
        ),
    ],
  );
  String conflictReason(RecordData conflict) {
    final response = conflict['response'] as Map? ?? {};
    final error = response['error'] as Map? ?? {};
    return error['message'] != null
        ? t(string(error['message']))
        : t(switch (response['reason']) {
            'deleted' => 'The transaction has been deleted on the server.',
            'generation' => 'The ledger has been cleared on the server.',
            'version' => 'The transaction was changed on another device.',
            _ => string(response['reason']),
          });
  }

  String conflictSummary(dynamic value) {
    final item = value is Map
        ? Map<String, dynamic>.from(value)
        : <String, dynamic>{};
    if (item.isEmpty) return t('Deleted');
    final accounts = flatten(app.accounts, 'subAccounts');
    final source = lookup(accounts, item['sourceAccountId']);
    final destination = lookup(accounts, item['destinationAccountId']);
    return [
      '${t(transactionType(number(item['type'])))} ${amount(item['sourceAmount'], string(source['currency']))}',
      '${t('Account')}: ${string(source['name'])}',
      if (number(item['type']) == 4)
        '${t('Destination Account')}: ${string(destination['name'])} ${amount(item['destinationAmount'], string(destination['currency']))}',
      '${t('Category')}: ${recordName(flatten(app.categories, 'subCategories'), item['categoryId'])}',
      '${t('Tags')}: ${(item['tagIds'] as List? ?? []).map((id) => recordName(app.tags, id)).join(', ')}',
      '${t('Description')}: ${string(item['comment'])}',
      dateText(transactionDate(item), time: true),
      if (item['geoLocation'] is Map)
        '${t('Location')}: ${string(item['geoLocationName']).isNotEmpty ? '${string(item['geoLocationName'])} · ' : ''}${formatNativeCoordinate(Map<String, dynamic>.from(item['geoLocation']), number(app.user['coordinateDisplayType']))}',
      if (transactionPictures(item).isNotEmpty)
        '${t('Pictures')}: ${transactionPictures(item).length}',
    ].join('\n');
  }
}
