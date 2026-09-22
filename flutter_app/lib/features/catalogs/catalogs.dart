import 'dart:convert';

import 'package:flutter/services.dart';

import '../../ui/common.dart';
import '../../ui/selection_sheets.dart';
import '../../core/formatting.dart';
import '../../core/currency_selection.dart';
import '../../core/onboarding.dart';
import '../transactions/transactions.dart';
import 'catalog_business.dart';

const accountCategories = <int, String>{
  1: 'Cash',
  2: 'Checking Account',
  8: 'Savings Account',
  3: 'Credit Card',
  4: 'Virtual Account',
  5: 'Debt Account',
  6: 'Receivables',
  9: 'Certificate of Deposit',
  7: 'Investment Account',
};
const accountCategoryIcons = <int, String>{
  1: '1',
  2: '100',
  8: '100',
  3: '100',
  4: '500',
  5: '600',
  6: '700',
  9: '110',
  7: '800',
};
const availableColors = [
  '000000',
  '8e8e93',
  'ff3b30',
  'ff2d55',
  'ff6b22',
  'ff9500',
  'ffcc00',
  'cddc39',
  '009688',
  '4cd964',
  '5ac8fa',
  '2196f3',
  '673ab7',
  '9c27b0',
];
int convertAccountAmount(int value, String from, String to, AppController app) {
  if (value == 0 || from == to || from.isEmpty) return value;
  final table = app.settings['cachedExchangeRates'] as Map? ?? {};
  final rates = {
    string(table['baseCurrency']): '1',
    for (final row in records(table['exchangeRates']))
      string(row['currency']): string(row['rate']),
  };
  if (rates[from] == null || rates[to] == null) {
    throw StateError('Exchange rate unavailable: $from → $to');
  }
  return BookkeepingFormatter.convertAggregate(
    value,
    rates[from]!,
    rates[to]!,
    truncate: true,
  ).toInt();
}

RecordData sanitizedSubAccount(RecordData child) {
  final result = {...child}..remove('_balanceChanged');
  if (child['id'] != null && string(child['id']) != '0') {
    result.remove('balance');
    result.remove('balanceTime');
  }
  return result;
}

class SwipeActionsRow extends StatefulWidget {
  const SwipeActionsRow({
    super.key,
    required this.child,
    required this.actions,
    this.onLongPress,
  });
  final Widget child;
  final Map<String, VoidCallback> actions;
  final VoidCallback? onLongPress;
  @override
  State<SwipeActionsRow> createState() => _SwipeActionsRowState();
}

class _SwipeActionsRowState extends State<SwipeActionsRow> {
  double offset = 0;
  @override
  Widget build(BuildContext context) {
    final width = widget.actions.length * 74.0;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: ExcludeSemantics(
              excluding: offset == 0,
              child: IgnorePointer(
                ignoring: offset == 0,
                child: Row(
                  textDirection: TextDirection.ltr,
                  mainAxisAlignment: rtl
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in widget.actions.entries)
                      SizedBox(
                        width: 74,
                        child: CupertinoButton(
                          padding: const EdgeInsets.all(4),
                          color: entry.key == tr(context, 'Delete')
                              ? CupertinoColors.destructiveRed
                              : entry.key == tr(context, 'Edit')
                              ? CupertinoColors.systemOrange
                              : brand,
                          borderRadius: BorderRadius.zero,
                          onPressed: () {
                            setState(() => offset = 0);
                            entry.value();
                          },
                          child: entry.key == tr(context, 'Delete')
                              ? Icon(
                                  CupertinoIcons.trash,
                                  color: CupertinoColors.white,
                                  size: 28,
                                  semanticLabel: entry.key,
                                )
                              : Text(
                                  entry.key,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: CupertinoColors.white,
                                    fontSize: 14,
                                  ),
                                ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          GestureDetector(
            onLongPress: widget.onLongPress == null
                ? null
                : () {
                    HapticFeedback.vibrate();
                    widget.onLongPress!();
                  },
            onHorizontalDragUpdate: (details) => setState(
              () => offset = (offset + details.delta.dx).clamp(
                rtl ? 0 : -width,
                rtl ? width : 0,
              ),
            ),
            onHorizontalDragEnd: (details) => setState(
              () => offset =
                  (details.primaryVelocity ?? 0) * (rtl ? 1 : -1) > 100 ||
                      offset.abs() > width / 2
                  ? (rtl ? width : -width)
                  : 0,
            ),
            child: Transform.translate(
              offset: Offset(offset, 0),
              child: Container(
                color: CupertinoColors.secondarySystemGroupedBackground
                    .resolveFrom(context),
                child: widget.child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool> accountActions(
  NativeState state,
  RecordData account, {
  String? action,
  bool allowEdit = true,
}) async {
  final context = state.context, app = state.app;
  final t = state.t;
  action ??= await choose(context, string(account['name']), {
    if (allowEdit) 'edit': t('Edit'),
    'transactions': t('Transactions'),
    'reconcile': t('Reconciliation Statement'),
    if (app.user['useLastReconciledTime'] == true)
      'mark': t('Mark as Reconciled'),
    'move': t('Move All Transactions'),
    'clear': t('Clear All Transactions'),
    'hide': t(account['hidden'] == true ? 'Show' : 'Hide'),
    'delete': t('Delete'),
  });
  if (action == null || !context.mounted) return false;
  final id = string(account['id']);
  if (action == 'edit') {
    final editId =
        string(account['parentId']).isNotEmpty &&
            string(account['parentId']) != '0'
        ? string(account['parentId'])
        : id;
    context.push('/account/edit?id=$editId');
  } else if (action == 'transactions') {
    context.push('/transaction/list?accountId=$id');
  } else if (['reconcile', 'mark', 'move', 'clear'].contains(action)) {
    var target = account;
    if (number(account['type']) == 2) {
      final selected = await choose<String>(context, t('Sub-account'), {
        for (final sub in records(account['subAccounts']))
          string(sub['id']): string(sub['name']),
      });
      if (selected == null || !context.mounted) return false;
      target = lookup(records(account['subAccounts']), selected);
    }
    final targetId = string(target['id']);
    if (action == 'reconcile') {
      context.push('/account/reconciliation_statements?accountId=$targetId');
    }
    if (action == 'move') {
      context.push('/account/move_all_transactions?fromAccountId=$targetId');
    }
    if (action == 'mark' &&
        await confirm(
          context,
          t(
            'Are you sure you want to update the last reconciled time of this account to the current time?',
          ),
        )) {
      await state.run(
        () => state.onlineMutation(
          'v1/accounts/update/last_reconciled_time.json',
          {
            'id': targetId,
            'lastReconciledTime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          },
        ),
        success: true,
      );
    }
    if (context.mounted &&
        action == 'clear' &&
        await confirm(
          context,
          t('Are you sure you want to clear all transactions?'),
          message: string(target['name']),
          destructive: true,
        )) {
      if (!context.mounted) return false;
      final password = await prompt(
        context,
        t('Please enter your current password to confirm.'),
        secret: true,
      );
      if (password != null) {
        await state.run(
          () => state.onlineMutation(
            'v1/data/clear/transactions/by_account.json',
            {'accountId': targetId, 'password': password},
          ),
          success: true,
        );
      }
    }
  } else if (action == 'hide') {
    await state.run(
      () => state.onlineMutation('v1/accounts/hide.json', {
        'id': id,
        'hidden': account['hidden'] != true,
      }),
    );
  } else if (action == 'delete' &&
      await confirm(
        context,
        t('Are you sure you want to delete this account?'),
        message: string(account['name']),
        destructive: true,
      )) {
    return state.run(
      () => state.onlineMutation(
        string(account['parentId']).isNotEmpty &&
                string(account['parentId']) != '0'
            ? 'v1/accounts/sub_account/delete.json'
            : 'v1/accounts/delete.json',
        {'id': id},
      ),
    );
  }
  return false;
}

class AccountListPage extends ConsumerStatefulWidget {
  const AccountListPage({super.key});
  @override
  ConsumerState<AccountListPage> createState() => _AccountListState();
}

class _AccountListState extends NativeState<AccountListPage> {
  bool showHidden = false;
  late bool availableCredit =
      number(app.settings['defaultCreditCardAmountDisplayTypeInMobile']) == 1;
  bool get showBalances => app.settings['showAccountBalance'] != false;
  Future<void> sortAccounts([List<RecordData>? group]) async {
    final items = await reorderItems(context, t('Sort'), group ?? app.accounts);
    if (items != null) {
      await run(
        () => onlineMutation('v1/accounts/move.json', {
          'newDisplayOrders': [
            for (var i = 0; i < items.length; i++)
              {'id': items[i]['id'], 'displayOrder': i + 1},
          ],
        }),
      );
    }
  }

  Future<void> more() async {
    final action = await choose(context, t('More'), {
      'hidden': t(showHidden ? 'Hide Hidden Accounts' : 'Show Hidden Accounts'),
      'sort': t('Sort'),
      'categories': t('Account Category Order'),
      'balances': t(showBalances ? 'Hide Amount' : 'Show Amount'),
      'included': t('Set Accounts Included in Total'),
    });
    if (!mounted) return;
    if (action == 'hidden') setState(() => showHidden = !showHidden);
    if (action == 'balances') {
      await app.setPreference('showAccountBalance', !showBalances);
    }
    if (action == 'included' && mounted) {
      context.push('/settings/filter/account?type=accountListTotalAmount');
    }
    if (action == 'categories' && mounted) {
      context.push('/settings/account_category_display_order');
    }
    if (action == 'sort') await sortAccounts();
  }

  String accountAmount(RecordData account, {bool child = false}) {
    if (child && availableCredit && number(account['category']) == 3) return '';
    return displayBalance(
      accountDisplayBalance(
        account,
        string(app.user['defaultCurrency']),
        exchangeRates,
        showHidden: showHidden,
        availableCredit: availableCredit,
      ),
    );
  }

  Map<String, String> get exchangeRates {
    final table = app.settings['cachedExchangeRates'] as Map? ?? {};
    return {
      string(table['baseCurrency']): '1',
      for (final row in records(table['exchangeRates']))
        string(row['currency']): string(row['rate']),
    };
  }

  String displayBalance(AccountDisplayBalance? balance) {
    if (balance == null) return '';
    if (!showBalances) return '••••';
    return '${amount('${balance.value}', balance.currency)}${balance.incomplete ? '+' : ''}';
  }

  Widget accountRow(
    RecordData item, {
    bool child = false,
    List<RecordData>? siblings,
  }) => SwipeActionsRow(
    key: ValueKey('account-${item['id']}'),
    onLongPress: () => sortAccounts(siblings),
    actions: {
      t('Edit'): () => accountActions(this, item, action: 'edit'),
      t('More'): () => accountActions(this, item),
      t('Delete'): () => accountActions(this, item, action: 'delete'),
    },
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: ItemRow(
        string(item['name']),
        leading: recordIcon(item, fallback: CupertinoIcons.creditcard),
        subtitle: [
          if (item['hidden'] == true) t('Hidden'),
          string(item['comment']),
        ].where((e) => e.isNotEmpty).join(' · '),
        value: accountAmount(item, child: child),
        padding: child
            ? const EdgeInsetsDirectional.fromSTEB(34, 2, 8, 2)
            : const EdgeInsetsDirectional.fromSTEB(14, 2, 8, 2),
        onTap: () => context.push('/transaction/list?accountId=${item['id']}'),
        trailing: iconButton(
          CupertinoIcons.ellipsis,
          t('More'),
          () => accountActions(this, item),
        ),
      ),
    ),
  );

  @override
  Widget buildPage(BuildContext context) {
    final items = app.accounts
        .where((item) => showHidden || item['hidden'] != true)
        .toList();
    final excluded = expandSelection(
      (app.settings['totalAmountExcludeAccountIds'] as Map? ?? {}).entries
          .where((e) => e.value == true)
          .map((e) => string(e.key)),
      app.accounts,
      'subAccounts',
    );
    var assets = 0, liabilities = 0;
    String? rateError;
    for (final item in leafAccounts(
      app,
    ).where((item) => !excluded.contains(string(item['id'])))) {
      try {
        final value = convertAccountAmount(
          number(item['balance']),
          string(item['currency']),
          string(app.user['defaultCurrency']),
          app,
        );
        if (liabilityAccount(item)) {
          liabilities -= value;
        } else {
          assets += value;
        }
      } on StateError catch (error) {
        rateError = string(error.message);
      }
    }
    final order = string(app.settings['accountCategoryOrders'])
        .split(',')
        .map(number)
        .where(accountCategories.containsKey)
        .toList();
    for (final category in accountCategories.keys) {
      if (!order.contains(category)) order.add(category);
    }
    final totals = {
      'Total Assets': assets,
      'Total Liabilities': liabilities,
      'Net Assets': assets - liabilities,
    };
    String totalValue(int value) => !showBalances
        ? '••••'
        : rateError != null
        ? t('Exchange rate unavailable')
        : amount(value, string(app.user['defaultCurrency']));
    return NativePage(
      title: t('Accounts'),
      busy: busy,
      onRefresh: app.refresh,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconButton(CupertinoIcons.ellipsis, t('More'), more),
          iconButton(
            CupertinoIcons.add,
            t('Add Account'),
            () => context.push('/account/add'),
          ),
        ],
      ),
      children: [
        Section(
          margin: const EdgeInsets.fromLTRB(8, 2, 8, 6),
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final horizontal =
                    rateError == null &&
                    constraints.maxWidth >= 320 &&
                    MediaQuery.textScalerOf(context).scale(14) <= 18;
                if (!horizontal) {
                  return Column(
                    children: [
                      for (final entry in totals.entries)
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: ItemRow(
                            t(entry.key),
                            value: totalValue(entry.value),
                            compact: true,
                          ),
                        ),
                    ],
                  );
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in totals.entries)
                        Expanded(
                          child: Semantics(
                            label:
                                '${t(entry.key)}: ${totalValue(entry.value)}',
                            child: ExcludeSemantics(
                              child: Column(
                                children: [
                                  Text(
                                    t(entry.key),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: CupertinoColors.secondaryLabel
                                          .resolveFrom(context),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    totalValue(entry.value),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: entry.key == 'Total Assets'
                                          ? CupertinoColors.systemRed
                                                .resolveFrom(context)
                                          : entry.key == 'Total Liabilities'
                                          ? CupertinoColors.systemBlue
                                                .resolveFrom(context)
                                          : CupertinoColors.label.resolveFrom(
                                              context,
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        for (final category in order)
          if (items.any((item) => number(item['category']) == category) ||
              app.settings['hideCategoriesWithoutAccounts'] != true)
            Section(
              margin: const EdgeInsets.fromLTRB(8, 2, 8, 6),
              title:
                  '${t(accountCategories[category]!)}  ${displayBalance(accountCategoryBalance(app.accounts, category, string(app.user['defaultCurrency']), exchangeRates, availableCredit: availableCredit))}',
              children: [
                if (category == 3)
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: ItemRow(
                      t(
                        availableCredit
                            ? 'Available Credit'
                            : 'Outstanding Balance',
                      ),
                      compact: true,
                      onTap: () async {
                        final selected = await choose<bool>(
                          context,
                          t('Default Credit Card Amount'),
                          {
                            false: t('Outstanding Balance'),
                            true: t('Available Credit'),
                          },
                          selected: availableCredit,
                        );
                        if (selected != null && mounted) {
                          setState(() => availableCredit = selected);
                        }
                      },
                    ),
                  ),
                for (final item in items.where(
                  (item) => number(item['category']) == category,
                )) ...[
                  accountRow(
                    item,
                    siblings: app.accounts
                        .where((e) => number(e['category']) == category)
                        .toList(),
                  ),
                  for (final sub in records(
                    item['subAccounts'],
                  ).where((sub) => showHidden || sub['hidden'] != true))
                    accountRow(
                      sub,
                      child: true,
                      siblings: records(item['subAccounts']),
                    ),
                ],
                if (!items.any((item) => number(item['category']) == category))
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: ItemRow(t('No available account'), compact: true),
                  ),
              ],
            ),
      ],
    );
  }
}

class AccountEditPage extends ConsumerStatefulWidget {
  const AccountEditPage({super.key, this.query = const {}});
  final Map<String, String> query;
  @override
  ConsumerState<AccountEditPage> createState() => _AccountEditState();
}

class _AccountEditState extends NativeState<AccountEditPage> {
  late RecordData data;
  bool subOrderChanged = false;
  @override
  void initState() {
    super.initState();
    data = {
      'name': '',
      'category': 1,
      'type': 1,
      'icon': '1',
      'iconType': 0,
      'color': '000000',
      'currency': string(app.user['defaultCurrency']).isEmpty
          ? 'USD'
          : app.user['defaultCurrency'],
      'balance': '0',
      'balanceTime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'comment': '',
      'hidden': false,
      'creditCardStatementDate': 0,
      'creditCardLimit': '0',
      'subAccounts': <RecordData>[],
      ...lookup(flatten(app.accounts, 'subAccounts'), widget.query['id']),
    };
  }

  Future<void> save() async {
    final result = await run(() async {
      if (string(data['name']).trim().isEmpty) {
        throw FormatException(t('Please enter an account name'));
      }
      if (number(data['type']) == 2 && records(data['subAccounts']).isEmpty) {
        throw FormatException(t('Please add a sub-account'));
      }
      final body = accountRequest(data, modifying: data['id'] != null);
      await onlineMutation(
        'v1/accounts/${data['id'] == null ? 'add' : 'modify'}.json',
        body,
      );
      if (subOrderChanged && data['id'] != null) {
        final persisted = records(
          lookup(app.accounts, data['id'])['subAccounts'],
        );
        final order = [
          for (final child in records(data['subAccounts']))
            persisted.firstWhere(
              (saved) => child['id'] != null
                  ? saved['id'] == child['id']
                  : saved['name'] == child['name'] &&
                        saved['currency'] == child['currency'],
            ),
        ];
        await onlineMutation('v1/accounts/move.json', {
          'newDisplayOrders': [
            for (var index = 0; index < order.length; index++)
              {'id': order[index]['id'], 'displayOrder': index + 1},
          ],
        });
      }
    });
    if (result && mounted) context.pop();
  }

  Future<void> editSub(RecordData? original) async {
    final result = await Navigator.of(context).push<RecordData>(
      nativeRoute(
        context,
        builder: (_) => SubAccountPage(
          data:
              original ??
              {
                'name': '',
                'currency': data['currency'] == '---'
                    ? app.user['defaultCurrency']
                    : data['currency'],
                'balance': '0',
                'balanceTime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
                'icon': data['icon'],
                'iconType': data['iconType'],
                'color': data['color'],
                'category': data['category'],
                'type': 1,
                'comment': '',
                'hidden': false,
              },
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        final items = records(data['subAccounts']);
        final index = original == null
            ? -1
            : items.indexWhere(
                (item) =>
                    item['id'] == original['id'] &&
                    item['name'] == original['name'],
              );
        if (index < 0) {
          items.add(result);
        } else {
          items[index] = result;
        }
        data['subAccounts'] = items;
      });
    }
  }

  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t(data['id'] == null ? 'Add Account' : 'Edit Account'),
    busy: busy,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (number(data['type']) == 2)
          iconButton(CupertinoIcons.ellipsis, t('More'), () async {
            final action = await choose(context, t('More'), {
              'add': t('Add Sub-account'),
            });
            if (action == 'add' && mounted) await editSub(null);
          }),
        iconButton(CupertinoIcons.check_mark, t('Save'), save),
      ],
    ),
    children: [
      Section(
        children: [
          InputRow(
            t('Account Name'),
            value: string(data['name']),
            onChanged: (value) => data['name'] = value,
          ),
          ItemRow(
            t('Category'),
            value: t(accountCategories[number(data['category'])] ?? 'Cash'),
            leading: recordIcon({
              'currency': '',
              'icon': accountCategoryIcons[number(data['category'])] ?? '1',
              'iconType': 0,
              'color': '000000',
            }),
            onTap: () async {
              final value = await chooseGroupedRecord(
                context,
                t('Category'),
                [
                  {
                    'name': '',
                    'items': [
                      for (final entry in accountCategories.entries)
                        {
                          'id': '${entry.key}',
                          'name': t(entry.value),
                          'currency': '',
                          'icon': accountCategoryIcons[entry.key],
                          'iconType': 0,
                          'color': '000000',
                        },
                    ],
                  },
                ],
                childrenKey: 'items',
                selected: '${data['category']}',
                emptyText: t('No available category'),
                showGroupHeaders: false,
              );
              if (value != null && mounted) {
                setState(() {
                  data['category'] = number(value);
                  data.remove('isLiability');
                  data.remove('isAsset');
                  data['subAccounts'] = [
                    for (final child in records(data['subAccounts']))
                      {...child, 'category': value}
                        ..remove('isLiability')
                        ..remove('isAsset'),
                  ];
                });
              }
            },
          ),
          if (data['id'] == null)
            ItemRow(
              t('Account Type'),
              value: t(
                number(data['type']) == 2
                    ? 'Multiple Sub-accounts'
                    : 'Single Account',
              ),
              onTap: () async {
                final value = await choose(context, t('Account Type'), {
                  1: t('Single Account'),
                  2: t('Multiple Sub-accounts'),
                }, selected: number(data['type']));
                if (value != null && mounted) {
                  setState(() => data['type'] = value);
                }
              },
            ),
          ItemRow(
            t('Icon'),
            leading: recordIcon(data),
            onTap: () async {
              final value = await chooseOriginalIcon(
                context,
                'account',
                string(data['icon']),
                iconType: number(data['iconType']),
                color: string(data['color']),
              );
              if (value != null && mounted) {
                setState(() => data.addAll(value));
              }
            },
          ),
          ItemRow(
            t('Color'),
            leading: Container(
              width: 24,
              height: 24,
              color: itemColor(data['color']),
            ),
            onTap: () async {
              final value = await chooseColor(context, string(data['color']));
              if (value != null && mounted) {
                setState(() => data['color'] = value);
              }
            },
          ),
          if (number(data['type']) != 2 || number(data['category']) == 3)
            ItemRow(
              t('Currency'),
              value: string(data['currency']),
              onTap:
                  data['id'] != null &&
                      !(number(data['type']) == 2 &&
                          number(data['category']) == 3)
                  ? null
                  : () async {
                      final value = await chooseCurrency(
                        context,
                        string(data['currency']),
                        allowed: effectiveCurrencyCodes(
                          settings: app.settings,
                          user: app.user,
                          accounts: app.accounts,
                          extra: [string(data['currency'])],
                        ),
                      );
                      if (value != null && mounted) {
                        setState(() => data['currency'] = value);
                      }
                    },
            ),
          if (number(data['type']) != 2) ...[
            ItemRow(
              t(data['id'] == null ? 'Initial Balance' : 'Balance'),
              value: amount(
                displayedAccountBalance(data),
                string(data['currency']),
              ),
              onTap: data['id'] != null
                  ? null
                  : () async {
                      final value = await amountPad(
                        context,
                        displayedAccountBalance(data),
                      );
                      if (value != null && mounted) {
                        setState(() {
                          data['balance'] =
                              '${value * (liabilityAccount(data) ? -1 : 1)}';
                          data['balanceTime'] =
                              DateTime.now().millisecondsSinceEpoch ~/ 1000;
                        });
                      }
                    },
            ),
            if (data['id'] == null)
              ItemRow(
                t('Balance Time'),
                value: dateText(
                  accountTimeForPicker(
                    number(data['balanceTime']),
                    app.formatter,
                  ),
                  time: true,
                ),
                onTap: () async {
                  final value = await pickDate(
                    context,
                    t('Balance Time'),
                    accountTimeForPicker(
                      number(data['balanceTime']),
                      app.formatter,
                    ),
                  );
                  if (value != null && mounted) {
                    setState(
                      () => data['balanceTime'] =
                          app.formatter
                              .wallTime(
                                value.year,
                                value.month,
                                value.day,
                                value.hour,
                                value.minute,
                                value.second,
                              )
                              .millisecondsSinceEpoch ~/
                          1000,
                    );
                  }
                },
              ),
          ],
          if (data['id'] != null &&
              number(data['type']) == 1 &&
              app.user['useLastReconciledTime'] == true)
            ItemRow(
              t('Last Reconciled Time'),
              value: number(data['lastReconciledTime']) == 0
                  ? t('None')
                  : dateText(
                      accountTimeForPicker(
                        number(data['lastReconciledTime']),
                        app.formatter,
                      ),
                      time: true,
                    ),
              onTap: () async {
                final selected = await pickDate(
                  context,
                  t('Last Reconciled Time'),
                  accountTimeForPicker(
                    number(data['lastReconciledTime']),
                    app.formatter,
                  ),
                );
                if (selected != null && mounted) {
                  setState(
                    () => data['lastReconciledTime'] =
                        app.formatter
                            .wallTime(
                              selected.year,
                              selected.month,
                              selected.day,
                              selected.hour,
                              selected.minute,
                              selected.second,
                            )
                            .millisecondsSinceEpoch ~/
                        1000,
                  );
                }
              },
              trailing: number(data['lastReconciledTime']) == 0
                  ? null
                  : iconButton(
                      CupertinoIcons.clear_circled,
                      t('Clear'),
                      () => setState(() => data['lastReconciledTime'] = null),
                    ),
            ),
          if (data['id'] != null)
            toggleRow(
              t('Visible'),
              data['hidden'] != true,
              (value) => setState(() => data['hidden'] = !value),
            ),
          if (number(data['category']) == 3) ...[
            ItemRow(
              t('Statement Date'),
              value: '${data['creditCardStatementDate']}',
              onTap: () async {
                final value = await choose(context, t('Statement Date'), {
                  for (var day = 1; day <= 28; day++) day: '$day',
                  0: t('None'),
                }, selected: number(data['creditCardStatementDate']));
                if (value != null && mounted) {
                  setState(() => data['creditCardStatementDate'] = value);
                }
              },
            ),
            ItemRow(
              t('Credit Limit'),
              value: amount(data['creditCardLimit']),
              onTap: () async {
                final value = await amountPad(
                  context,
                  number(data['creditCardLimit']),
                );
                if (value != null && mounted) {
                  setState(() => data['creditCardLimit'] = '$value');
                }
              },
            ),
          ],
          InputRow(
            t('Description'),
            value: string(data['comment']),
            lines: 3,
            onChanged: (value) => data['comment'] = value,
          ),
        ],
      ),
      if (number(data['type']) == 2)
        Section(
          title: t('Sub-accounts'),
          children: [
            for (final item in records(data['subAccounts']))
              ItemRow(
                string(item['name']),
                leading: recordIcon(item),
                value: amount(
                  displayedAccountBalance(item),
                  string(item['currency']),
                ),
                onTap: () => editSub(item),
                trailing: iconButton(
                  CupertinoIcons.minus_circle,
                  t('Delete'),
                  () async {
                    if (!await confirm(
                      context,
                      t('Delete this sub-account?'),
                      destructive: true,
                    )) {
                      return;
                    }
                    if (item['id'] != null) {
                      final result = await run(
                        () => onlineMutation(
                          'v1/accounts/sub_account/delete.json',
                          {'id': item['id']},
                        ),
                      );
                      if (!result) return;
                    }
                    if (mounted) {
                      setState(
                        () => data['subAccounts'] = records(data['subAccounts'])
                            .where(
                              (sub) =>
                                  sub['name'] != item['name'] ||
                                  sub['id'] != item['id'],
                            )
                            .toList(),
                      );
                    }
                  },
                ),
              ),
            ItemRow(t('Add Sub-account'), onTap: () => editSub(null)),
            if (records(data['subAccounts']).length > 1)
              ItemRow(
                t('Sort Sub-accounts'),
                onTap: () async {
                  final items = records(data['subAccounts']);
                  final order = await reorderItems(context, t('Sort'), [
                    for (var index = 0; index < items.length; index++)
                      {...items[index], 'id': '$index'},
                  ]);
                  if (order != null && mounted) {
                    setState(() {
                      subOrderChanged = true;
                      data['subAccounts'] = [
                        for (final row in order) items[number(row['id'])],
                      ];
                    });
                  }
                },
              ),
          ],
        ),
    ],
  );
}

class SubAccountPage extends ConsumerStatefulWidget {
  const SubAccountPage({super.key, required this.data});
  final RecordData data;
  @override
  ConsumerState<SubAccountPage> createState() => _SubAccountState();
}

class _SubAccountState extends NativeState<SubAccountPage> {
  late final data = {...widget.data};
  Future<void> pickTime(String key) async {
    final seconds = number(data[key]);
    final value = await pickDate(
      context,
      t(key == 'balanceTime' ? 'Balance Time' : 'Last Reconciled Time'),
      accountTimeForPicker(seconds, app.formatter),
    );
    if (value != null && mounted) {
      setState(
        () => data[key] =
            app.formatter
                .wallTime(
                  value.year,
                  value.month,
                  value.day,
                  value.hour,
                  value.minute,
                  value.second,
                )
                .millisecondsSinceEpoch ~/
            1000,
      );
    }
  }

  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t('Sub-account'),
    trailing: actionButton(t('Save'), () {
      if (string(data['name']).trim().isNotEmpty) Navigator.pop(context, data);
    }),
    children: [
      Section(
        children: [
          InputRow(
            t('Name'),
            value: string(data['name']),
            onChanged: (value) => data['name'] = value,
          ),
          ItemRow(
            t('Icon'),
            leading: recordIcon(data),
            onTap: () async {
              final value = await chooseOriginalIcon(
                context,
                'account',
                string(data['icon']),
                iconType: number(data['iconType']),
                color: string(data['color']),
              );
              if (value != null && mounted) setState(() => data.addAll(value));
            },
          ),
          ItemRow(
            t('Color'),
            leading: Container(
              width: 24,
              height: 24,
              color: itemColor(data['color']),
            ),
            onTap: () async {
              final value = await chooseColor(context, string(data['color']));
              if (value != null && mounted) {
                setState(() => data['color'] = value);
              }
            },
          ),
          ItemRow(
            t('Currency'),
            value: string(data['currency']),
            onTap: data['id'] != null
                ? null
                : () async {
                    final value = await chooseCurrency(
                      context,
                      string(data['currency']),
                      allowed: effectiveCurrencyCodes(
                        settings: app.settings,
                        user: app.user,
                        accounts: app.accounts,
                        extra: [string(data['currency'])],
                      ),
                    );
                    if (value != null && mounted) {
                      setState(() => data['currency'] = value);
                    }
                  },
          ),
          ItemRow(
            t('Balance'),
            value: amount(
              displayedAccountBalance(data),
              string(data['currency']),
            ),
            onTap: data['id'] != null
                ? null
                : () async {
                    final value = await amountPad(
                      context,
                      displayedAccountBalance(data),
                    );
                    if (value != null && mounted) {
                      setState(() {
                        data['balance'] =
                            '${value * (liabilityAccount(data) ? -1 : 1)}';
                        data['balanceTime'] =
                            DateTime.now().millisecondsSinceEpoch ~/ 1000;
                      });
                    }
                  },
          ),
          if (data['id'] == null)
            ItemRow(
              t('Balance Time'),
              value: dateText(
                accountTimeForPicker(
                  number(data['balanceTime']),
                  app.formatter,
                ),
                time: true,
              ),
              onTap: () => pickTime('balanceTime'),
            ),
          if (data['id'] != null && app.user['useLastReconciledTime'] == true)
            ItemRow(
              t('Last Reconciled Time'),
              value: number(data['lastReconciledTime']) == 0
                  ? t('None')
                  : dateText(
                      accountTimeForPicker(
                        number(data['lastReconciledTime']),
                        app.formatter,
                      ),
                      time: true,
                    ),
              onTap: () => pickTime('lastReconciledTime'),
              trailing: number(data['lastReconciledTime']) == 0
                  ? null
                  : iconButton(
                      CupertinoIcons.clear_circled,
                      t('Clear'),
                      () => setState(() => data['lastReconciledTime'] = null),
                    ),
            ),
          InputRow(
            t('Description'),
            value: string(data['comment']),
            onChanged: (value) => data['comment'] = value,
          ),
          if (data['id'] != null)
            toggleRow(
              t('Hidden'),
              data['hidden'] == true,
              (value) => setState(() => data['hidden'] = value),
            ),
        ],
      ),
    ],
  );
}

Future<String?> chooseColor(BuildContext context, String current) =>
    chooseOriginalColor(context, current, availableColors);
Future<String?> chooseCurrency(
  BuildContext context,
  String current, {
  Set<String>? allowed,
}) async {
  final choices = {
    for (final item in await currencyChoices(allowed: allowed))
      string(item['id']): string(item['name']),
  };
  if (!context.mounted) return null;
  return choose(context, 'Currency', choices, selected: current);
}

class ReconciliationPage extends ConsumerStatefulWidget {
  const ReconciliationPage({super.key, this.query = const {}});
  final Map<String, String> query;
  @override
  ConsumerState<ReconciliationPage> createState() => _ReconciliationState();
}

class _ReconciliationState extends NativeState<ReconciliationPage> {
  int startTime = 0, endTime = 0, period = 7, aggregation = 4;
  final pageOpenTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  RecordData? result;
  bool chart = false, originalTimezone = false;
  String get accountId => widget.query['accountId'] ?? widget.query['id'] ?? '';
  RecordData get account =>
      lookup(flatten(app.accounts, 'subAccounts'), accountId);
  String get currency => string(account['currency']);
  int get statementDay => number(
    account['creditCardStatementDate'] ??
        lookup(app.accounts, account['parentId'])['creditCardStatementDate'],
  );
  Map<int, String> get periods => {
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
    if (statementDay > 0) 51: 'Current Billing Cycle',
    if (statementDay > 0) 52: 'Previous Billing Cycle',
    if (app.user['useLastReconciledTime'] == true &&
        number(account['lastReconciledTime']) > 0)
      71: 'Since Last Reconciled Time',
    255: 'Custom Date',
  };
  @override
  void initState() {
    super.initState();
    final preferred = number(
      app.settings['reconciliationStatementPageDefaultDateRangeTypeInMobile'] ??
          7,
    );
    setPeriod(
      periods.containsKey(preferred) && preferred != 255 ? preferred : 7,
    );
  }

  void setPeriod(int value) {
    final range = app.formatter.dateRange(
      value,
      statementDay: statementDay,
      lastReconciledTime: number(account['lastReconciledTime']),
    );
    if (range == null) return;
    period = value;
    startTime = range.minTime;
    endTime = range.maxTime;
    result = null;
  }

  Future<void> date(bool start) async {
    final seconds = start ? startTime : endTime;
    final selected = await pickDate(
      context,
      t(start ? 'Start Date' : 'End Date'),
      app.formatter.localDate(
        seconds == 0
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
      ),
      time: false,
    );
    if (selected == null || !mounted) return;
    setState(() {
      period = 255;
      result = null;
      if (start) {
        startTime =
            app.formatter
                .wallTime(selected.year, selected.month, selected.day)
                .millisecondsSinceEpoch ~/
            1000;
      } else {
        endTime =
            app.formatter
                    .wallTime(selected.year, selected.month, selected.day + 1)
                    .millisecondsSinceEpoch ~/
                1000 -
            1;
      }
    });
  }

  Future<void> load({bool afterMutation = false}) async {
    await run(() async {
      if (number(account['type']) != 1 || endTime != 0 && startTime > endTime) {
        throw StateError(t('Parameter Invalid'));
      }
      if (afterMutation || app.pendingCount > 0) {
        await app.refreshAfterMutation();
        if (app.pendingCount > 0) {
          throw StateError(t('Please synchronize pending transactions first'));
        }
      }
      result = Map<String, dynamic>.from(
        await app.get(
          'v1/transactions/reconciliation_statements.json',
          query: {
            'account_id': accountId,
            'start_time': startTime,
            'end_time': endTime,
          },
        ),
      );
    });
  }

  Future<void> navigate(String path) async {
    await context.push(path);
    if (mounted && result != null) await load(afterMutation: true);
  }

  Future<void> more() async {
    final cutoff = reconciledCutoff(endTime, pageOpenTime);
    final action = await choose<String>(context, t('More'), {
      'add': t('Add Transaction'),
      if (number(result?['closingBalance']).abs() <= 999999999999999)
        'balance': t('Update Closing Balance'),
      if (app.user['useLastReconciledTime'] == true &&
          cutoff > number(account['lastReconciledTime']))
        'mark': t('Mark as Reconciled'),
      'refresh': t('Refresh'),
    });
    if (action == null || !mounted) return;
    if (action == 'refresh') await load();
    if (action == 'add') {
      await navigate('/transaction/add?accountId=$accountId');
    }
    if (mounted && action == 'balance') {
      final displayed =
          number(result!['closingBalance']) *
          (liabilityAccount(account) ? -1 : 1);
      final wanted = await amountPad(context, displayed);
      if (wanted == null || !mounted) return;
      Map<String, String>? parameters;
      final valid = await run(() async {
        parameters = closingBalanceTransaction(
          account: account,
          closingBalance: number(result!['closingBalance']),
          desiredDisplayedBalance: wanted,
          startTime: startTime,
          endTime: endTime,
          now: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );
      });
      if (valid && mounted) {
        await navigate(
          Uri(path: '/transaction/add', queryParameters: parameters).toString(),
        );
      }
    }
    if (mounted &&
        action == 'mark' &&
        await confirm(context, t('Mark as Reconciled'))) {
      await run(
        () => onlineMutation('v1/accounts/update/last_reconciled_time.json', {
          'id': accountId,
          'lastReconciledTime': cutoff,
        }),
        success: true,
      );
    }
  }

  Future<void> remove(RecordData item) async {
    if (!await confirm(
      context,
      t('Are you sure you want to delete?'),
      destructive: true,
    )) {
      return;
    }
    final deleted = await run(() async {
      if (number(item['type']) == 1) {
        await onlineMutation('v1/transactions/delete.json', {'id': item['id']});
      } else {
        await app.deleteTransaction(string(item['id']));
        await app.refreshAfterMutation();
      }
    });
    if (deleted) await load();
  }

  Widget transaction(RecordData item) => SwipeActionsRow(
    key: ValueKey('reconcile-${item['id']}'),
    actions: {
      if (number(item['type']) != 1)
        t('Duplicate'): () =>
            navigate('/transaction/add?id=${item['id']}&type=${item['type']}'),
      if (app.canEditTransaction(item) && number(item['type']) != 1)
        t('Edit'): () => navigate('/transaction/edit?id=${item['id']}'),
      if (app.canEditTransaction(item)) t('Delete'): () => remove(item),
    },
    child: Column(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: number(item['type']) == 1
              ? null
              : () => navigate(
                  '/transaction/edit?id=${Uri.encodeQueryComponent(string(item['id']))}',
                ),
          child: AbsorbPointer(
            child: TransactionRow(
              item: item,
              app: app,
              filterAccounts: {accountId},
            ),
          ),
        ),
        ItemRow(
          t('Balance'),
          value: amount(
            number(item['accountClosingBalance']) *
                (liabilityAccount(account) ? -1 : 1),
            currency,
          ),
        ),
      ],
    ),
  );

  String bucketDate(DateTime value) => switch (aggregation) {
    2 => app.formatter.digits('${value.year}'),
    3 => app.formatter.fiscalYear(value),
    1 =>
      '${app.formatter.digits('${value.year}')} Q${app.formatter.digits('${(value.month - 1) ~/ 3 + 1}')}',
    0 =>
      '${app.formatter.digits('${value.year}')} / ${app.formatter.digits('${value.month}')}',
    _ => dateText(value),
  };

  @override
  Widget buildPage(BuildContext _) {
    final items = records(result?['transactions']);
    final buckets = reconciliationBuckets(
      items,
      app.formatter,
      aggregation: aggregation,
      originalTimezone: originalTimezone,
      liability: liabilityAccount(account),
      statementDay: statementDay,
    );
    final maxBalance = buckets.fold<int>(
      0,
      (max, item) => item.close > max ? item.close : max,
    );
    final periodsMap = {
      for (final entry in periods.entries) entry.key: t(entry.value),
    };
    final aggregates = {
      4: 'Daily',
      0: 'Monthly',
      1: 'Quarterly',
      2: 'Yearly',
      3: 'FiscalYearly',
      if (statementDay > 0) 11: 'BillingCycle',
    };
    return NativePage(
      title: t('Reconciliation Statement'),
      busy: busy,
      onRefresh: result == null ? null : load,
      trailing: iconButton(
        result == null ? CupertinoIcons.check_mark : CupertinoIcons.ellipsis,
        t(result == null ? 'Continue' : 'More'),
        result == null ? load : more,
      ),
      children: [
        Section(
          children: [
            ItemRow(
              string(account['name']),
              value: t(periods[period] ?? 'Custom Date'),
              onTap: () async {
                final value = await choose<int>(
                  context,
                  t('Date Range'),
                  periodsMap,
                  selected: period,
                );
                if (value == null || !mounted) return;
                if (value == 255) {
                  await date(true);
                  if (mounted) await date(false);
                } else {
                  setState(() => setPeriod(value));
                }
              },
            ),
            for (final start in [true, false])
              ItemRow(
                t(start ? 'Start Date' : 'End Date'),
                value: (start ? startTime : endTime) == 0
                    ? t('All')
                    : dateText(
                        app.formatter.localDate(
                          DateTime.fromMillisecondsSinceEpoch(
                            (start ? startTime : endTime) * 1000,
                          ),
                        ),
                        time: true,
                      ),
                onTap: () => date(start),
              ),
          ],
        ),
        if (result != null) ...[
          Section(
            children: [
              ItemRow(
                t('Total Transactions'),
                value: app.formatter.digits('${items.length}'),
              ),
              for (final entry in {
                'totalInflows': 'Total Inflows',
                'totalOutflows': 'Total Outflows',
                'openingBalance': 'Opening Balance',
                'closingBalance': 'Closing Balance',
              }.entries)
                ItemRow(
                  t(entry.value),
                  value: amount(
                    number(result![entry.key]) *
                        (liabilityAccount(account) &&
                                entry.key.endsWith('Balance')
                            ? -1
                            : 1),
                    currency,
                  ),
                ),
              ItemRow(
                t('Total Balance'),
                value: amount(
                  number(result!['totalInflows']) -
                      number(result!['totalOutflows']),
                  currency,
                ),
              ),
            ],
          ),
          Section(
            children: [
              toggleRow(
                t('Account Balance Trends'),
                chart,
                (value) => setState(() => chart = value),
              ),
              if (chart) ...[
                ItemRow(
                  t('Time Granularity'),
                  value: t(aggregates[aggregation]!),
                  onTap: () async {
                    final value = await choose<int>(
                      context,
                      t('Time Granularity'),
                      aggregates.map((k, v) => MapEntry(k, t(v))),
                      selected: aggregation,
                    );
                    if (value != null && mounted) {
                      setState(() => aggregation = value);
                    }
                  },
                ),
                ItemRow(
                  t('Timezone Used for Date Range'),
                  value: t(
                    originalTimezone
                        ? 'Transaction Timezone'
                        : 'Application Timezone',
                  ),
                  onTap: () async {
                    final value = await choose<bool>(
                      context,
                      t('Timezone Used for Date Range'),
                      {
                        false: t('Application Timezone'),
                        true: t('Transaction Timezone'),
                      },
                      selected: originalTimezone,
                    );
                    if (value != null && mounted) {
                      setState(() => originalTimezone = value);
                    }
                  },
                ),
              ],
            ],
          ),
          if (items.isEmpty) emptyState(t('No transaction data')),
          if (chart)
            Section(
              children: [
                for (final bucket in buckets)
                  Column(
                    children: [
                      ItemRow(
                        bucketDate(bucket.date),
                        leading: const Icon(CupertinoIcons.calendar),
                        value: amount(bucket.close, currency),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(60, 0, 16, 12),
                        child: LayoutBuilder(
                          builder: (_, constraints) => Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              height: 4,
                              width: maxBalance > 0
                                  ? constraints.maxWidth *
                                        (bucket.close / maxBalance).clamp(0, 1)
                                  : 0,
                              decoration: BoxDecoration(
                                color: appChartColors(app).first,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            )
          else
            Section(
              children: [
                for (var index = 0; index < items.length; index++) ...[
                  if (index == 0 ||
                      dateText(transactionDate(items[index])) !=
                          dateText(transactionDate(items[index - 1])))
                    ItemRow(dateText(transactionDate(items[index]))),
                  transaction(items[index]),
                ],
              ],
            ),
        ],
      ],
    );
  }
}

class MoveTransactionsPage extends ConsumerStatefulWidget {
  const MoveTransactionsPage({super.key, this.query = const {}});
  final Map<String, String> query;
  @override
  ConsumerState<MoveTransactionsPage> createState() => _MoveTransactionsState();
}

class _MoveTransactionsState extends NativeState<MoveTransactionsPage> {
  String destination = '';
  String typedName = '';
  @override
  Widget buildPage(BuildContext _) {
    final sourceId = widget.query['fromAccountId'] ?? '';
    final accounts = leafAccounts(app);
    final source = lookup(accounts, sourceId);
    return NativePage(
      title: t('Move All Transactions'),
      busy: busy,
      trailing: iconButton(CupertinoIcons.check_mark, t('Confirm'), () async {
        if (destination.isEmpty ||
            typedName != recordName(accounts, destination)) {
          await inform(
            context,
            t('Please re-enter the target account name to confirm'),
          );
          return;
        }
        if (!await confirm(
          context,
          t('Are you sure you want to move all transactions?'),
        )) {
          return;
        }
        final result = await run(
          () => onlineMutation('v1/transactions/move/all.json', {
            'fromAccountId': sourceId,
            'toAccountId': destination,
          }),
        );
        if (result && mounted) context.pop();
      }),
      children: [
        Section(
          title: t('Move All Transactions'),
          footer: t('All transactions will be moved to the selected account.'),
          children: [
            ItemRow(t('Source Account'), value: string(source['name'])),
            ItemRow(
              t('Target Account'),
              value: recordName(accounts, destination),
              onTap: () async {
                final value = await choose(context, t('Target Account'), {
                  for (final item in accounts.where(
                    (item) =>
                        item['id'] != sourceId &&
                        item['currency'] == source['currency'],
                  ))
                    string(item['id']): string(item['name']),
                }, selected: destination);
                if (value != null && mounted) {
                  setState(() => destination = value);
                }
              },
            ),
            InputRow(
              t('Confirm Target Account Name'),
              value: typedName,
              onChanged: (value) => typedName = value,
            ),
          ],
        ),
      ],
    );
  }
}

enum CatalogKind { categories, tags, groups, templates, schedules }

class CatalogListPage extends ConsumerStatefulWidget {
  const CatalogListPage({super.key, required this.kind, this.query = const {}});
  final CatalogKind kind;
  final Map<String, String> query;
  @override
  ConsumerState<CatalogListPage> createState() => _CatalogListState();
}

class _CatalogListState extends NativeState<CatalogListPage> {
  bool hidden = false;
  String search = '';
  String groupId = '0';
  String get endpoint => switch (widget.kind) {
    CatalogKind.categories => 'v1/transaction/categories',
    CatalogKind.tags => 'v1/transaction/tags',
    CatalogKind.groups => 'v1/transaction/tags/groups',
    _ => 'v1/transaction/templates',
  };
  String get title => switch (widget.kind) {
    CatalogKind.categories => 'Transaction Categories',
    CatalogKind.tags => 'Transaction Tags',
    CatalogKind.groups => 'Tag Groups',
    CatalogKind.templates => 'Transaction Templates',
    CatalogKind.schedules => 'Scheduled Transactions',
  };
  List<RecordData> get items => switch (widget.kind) {
    CatalogKind.categories =>
      (widget.query['id'] != null && widget.query['id'] != '0'
              ? records(
                  lookup(app.categories, widget.query['id'])['subCategories'],
                )
              : app.categories)
          .where(
            (item) => number(item['type']) == number(widget.query['type'] ?? 2),
          )
          .toList(),
    CatalogKind.tags =>
      app.tags.where((item) => string(item['groupId']) == groupId).toList(),
    CatalogKind.groups => app.tagGroups,
    _ =>
      app.templates
          .where(
            (item) =>
                number(item['templateType']) ==
                (widget.kind == CatalogKind.schedules ? 2 : 1),
          )
          .toList(),
  };
  Future<void> edit(RecordData? item) async {
    if (widget.kind == CatalogKind.categories) {
      final parent = lookup(app.categories, widget.query['id']);
      context.push(
        Uri(
          path: '/category/${item == null ? 'add' : 'edit'}',
          queryParameters: {
            'type': widget.query['type'] ?? '2',
            if (item == null) ...{
              'parentId': widget.query['id'] ?? '0',
              'icon': string(parent['icon']),
              'iconType': string(parent['iconType']),
              'color': string(parent['color']),
            } else
              'id': string(item['id']),
          },
        ).toString(),
      );
      return;
    }
    if (widget.kind == CatalogKind.templates ||
        widget.kind == CatalogKind.schedules) {
      context.push(
        '/template/${item == null ? 'add' : 'edit'}?templateType=${widget.kind == CatalogKind.schedules ? 2 : 1}${item == null ? '' : '&id=${item['id']}'}',
      );
      return;
    }
    await Navigator.of(context).push<void>(
      nativeRoute(
        context,
        builder: (_) => TagEditPage(
          group: widget.kind == CatalogKind.groups,
          data: item ?? {'name': '', 'groupId': groupId},
          onSave: (data) => onlineMutation(
            '$endpoint/${item == null ? 'add' : 'modify'}.json',
            data,
          ),
        ),
      ),
    );
  }

  Future<void> sortItems([
    List<RecordData>? specified,
    bool? descending,
  ]) async {
    var order = specified ?? items;
    if (descending == null) {
      final selected = await reorderItems(context, t('Sort'), order);
      if (selected == null) return;
      order = selected;
    } else {
      final indices = await const MethodChannel('ezbookkeeping/native')
          .invokeListMethod<int>('sortStrings', {
            'values': [for (final item in order) string(item['name'])],
            'locale': app.languageTag,
            'descending': descending,
          });
      if (indices == null || !mounted) return;
      order = [for (final index in indices) order[index]];
      if (!await confirm(
        context,
        t(descending ? 'Sort by Name (Z to A)' : 'Sort by Name (A to Z)'),
      )) {
        return;
      }
    }
    await run(
      () => onlineMutation('$endpoint/move.json', {
        'newDisplayOrders': [
          for (var index = 0; index < order.length; index++)
            {'id': order[index]['id'], 'displayOrder': index + 1},
        ],
      }),
    );
  }

  Future<void> groupAction(String action) async {
    final endpoint = 'v1/transaction/tags/groups';
    final group = lookup(app.tagGroups, groupId);
    if (action == 'deleteGroup') {
      if (!await confirm(
        context,
        t('Delete Tag Group'),
        message: string(group['name']),
        destructive: true,
      )) {
        return;
      }
      await run(() => onlineMutation('$endpoint/delete.json', {'id': groupId}));
      if (mounted) setState(() => groupId = '0');
    } else {
      final name = await prompt(
        context,
        t(action == 'addGroup' ? 'Add Tag Group' : 'Rename Tag Group'),
        initial: action == 'addGroup' ? '' : string(group['name']),
      );
      if (name == null || name.trim().isEmpty) return;
      await run(
        () => onlineMutation(
          '$endpoint/${action == 'addGroup' ? 'add' : 'modify'}.json',
          {'name': name.trim(), if (action != 'addGroup') 'id': groupId},
        ),
      );
    }
  }

  Future<void> more() async {
    final action = await choose(context, t('More'), {
      'hidden': t(hidden ? 'Hide Hidden Items' : 'Show Hidden Items'),
      'sort': t('Sort'),
      if (widget.kind == CatalogKind.tags) 'groups': t('Tag Groups'),
      if (widget.kind == CatalogKind.tags) 'batch': t('Add Multiple Tags'),
      if (widget.kind == CatalogKind.tags) ...{
        'addGroup': t('Add Tag Group'),
        if (groupId != '0') 'renameGroup': t('Rename Tag Group'),
        if (groupId != '0') 'deleteGroup': t('Delete Tag Group'),
        'sortAsc': t('Sort by Name (A to Z)'),
        'sortDesc': t('Sort by Name (Z to A)'),
      },
      if (widget.kind == CatalogKind.categories)
        'preset': t('Add Preset Categories'),
    });
    if (!mounted || action == null) return;
    if (action == 'hidden') setState(() => hidden = !hidden);
    if (action == 'groups') context.push('/tag/group/list');
    if (['addGroup', 'renameGroup', 'deleteGroup'].contains(action)) {
      await groupAction(action);
    }
    if (action == 'sortAsc' || action == 'sortDesc') {
      await sortItems(null, action == 'sortDesc');
    }
    if (mounted && action == 'preset') {
      context.push('/category/preset?type=${widget.query['type'] ?? 2}');
    }
    if (action == 'sort') await sortItems();
    if (mounted && action == 'batch') {
      final names = await prompt(context, t('Tag names separated by commas'));
      if (names != null) {
        await run(
          () => onlineMutation('$endpoint/add_batch.json', {
            'tags': [
              for (final name
                  in names
                      .split(',')
                      .map((name) => name.trim())
                      .where((name) => name.isNotEmpty))
                {'name': name, 'groupId': groupId},
            ],
            'groupId': groupId,
            'skipExists': true,
          }),
        );
      }
    }
  }

  Future<void> actions(RecordData item, [String? action]) async {
    action ??= await choose(context, string(item['name']), {
      'edit': t('Edit'),
      if (widget.kind == CatalogKind.tags) 'move': t('Move'),
      if (widget.kind != CatalogKind.groups)
        'hide': t(item['hidden'] == true ? 'Show' : 'Hide'),
      'delete': t('Delete'),
      if (widget.kind == CatalogKind.templates) 'use': t('Use Template'),
      if (widget.kind == CatalogKind.categories &&
          (item['parentId'] == null || string(item['parentId']) == '0'))
        'child': t('Add Secondary Category'),
      if (widget.kind == CatalogKind.categories &&
          records(item['subCategories']).isNotEmpty)
        'sortChildren': t('Sort Secondary Categories'),
    });
    if (!mounted || action == null) return;
    if (action == 'edit') edit(item);
    if (action == 'move') {
      final destination = await choose<String>(context, t('Tag Group'), {
        '0': t('Default Group'),
        for (final group in app.tagGroups)
          string(group['id']): string(group['name']),
      }, selected: string(item['groupId']));
      if (destination != null && destination != string(item['groupId'])) {
        await run(
          () => onlineMutation('$endpoint/modify.json', {
            'id': item['id'],
            'name': item['name'],
            'groupId': destination,
            'color': item['color'],
            'comment': item['comment'] ?? '',
          }),
        );
      }
      return;
    }
    if (action == 'use') {
      context.push('/transaction/add?templateId=${item['id']}');
    }
    if (action == 'child') {
      context.push(
        Uri(
          path: '/category/add',
          queryParameters: {
            'parentId': string(item['id']),
            'type': string(item['type']),
            'icon': string(item['icon']),
            'iconType': string(item['iconType']),
            'color': string(item['color']),
          },
        ).toString(),
      );
    }
    if (action == 'sortChildren') {
      final order = await reorderItems(
        context,
        t('Sort'),
        records(item['subCategories']),
      );
      if (order != null) {
        await run(
          () => onlineMutation('$endpoint/move.json', {
            'newDisplayOrders': [
              for (var index = 0; index < order.length; index++)
                {'id': order[index]['id'], 'displayOrder': index + 1},
            ],
          }),
        );
      }
    }
    if (action == 'hide') {
      await run(
        () => onlineMutation('$endpoint/hide.json', {
          'id': item['id'],
          'hidden': item['hidden'] != true,
        }),
      );
    }
    if (mounted &&
        action == 'delete' &&
        await confirm(
          context,
          t('Are you sure you want to delete?'),
          destructive: true,
        )) {
      await run(
        () => onlineMutation('$endpoint/delete.json', {'id': item['id']}),
      );
    }
  }

  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t(title),
    busy: busy,
    onRefresh: app.refresh,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        iconButton(CupertinoIcons.ellipsis, t('More'), more),
        iconButton(CupertinoIcons.add, t('Add'), () => edit(null)),
      ],
    ),
    children: [
      if (widget.kind == CatalogKind.tags)
        Section(
          children: [
            ItemRow(
              t('Tag Group'),
              value: groupId == '0'
                  ? t('Default Group')
                  : recordName(app.tagGroups, groupId),
              onTap: () async {
                final selected = await choose<String>(context, t('Tag Group'), {
                  '0': t('Default Group'),
                  for (final group in app.tagGroups)
                    string(group['id']): string(group['name']),
                }, selected: groupId);
                if (selected != null && mounted) {
                  setState(() => groupId = selected);
                }
              },
            ),
          ],
        ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: CupertinoSearchTextField(
          placeholder: t('Search'),
          onChanged: (value) => setState(() => search = value),
        ),
      ),
      Section(
        children: [
          for (final item in items.where(
            (item) =>
                (hidden || item['hidden'] != true) &&
                string(item['name'])
                    .toLowerCase()
                    .contains(search.toLowerCase()),
          )) ...[
            SwipeActionsRow(
              key: ValueKey('${widget.kind}-${item['id']}'),
              onLongPress: () => sortItems(),
              actions: {
                if (widget.kind == CatalogKind.tags)
                  t('Move'): () => actions(item, 'move'),
                t('Edit'): () => edit(item),
                t('More'): () => actions(item),
                t('Delete'): () => actions(item, 'delete'),
              },
              child: ItemRow(
                string(item['name']),
                leading: recordIcon(
                  item,
                  fallback: widget.kind == CatalogKind.tags
                      ? CupertinoIcons.tag
                      : CupertinoIcons.square_grid_2x2,
                ),
                subtitle: [
                  if (item['hidden'] == true) t('Hidden'),
                  if (widget.kind == CatalogKind.tags)
                    recordName(app.tagGroups, item['groupId']),
                  if (widget.kind == CatalogKind.schedules)
                    scheduleDescription(item, app.formatter),
                ].where((text) => text.isNotEmpty).join(' · '),
                onTap:
                    widget.kind == CatalogKind.categories &&
                        string(item['parentId']) == '0'
                    ? () => context.push(
                        '/category/list?type=${item['type']}&id=${item['id']}',
                      )
                    : () => edit(item),
                trailing: iconButton(
                  CupertinoIcons.ellipsis,
                  t('More'),
                  () => actions(item),
                ),
              ),
            ),
          ],
        ],
      ),
      if (items.isEmpty) emptyState(t('No data')),
    ],
  );
}

class TagEditPage extends ConsumerStatefulWidget {
  const TagEditPage({
    super.key,
    required this.group,
    required this.data,
    required this.onSave,
  });
  final bool group;
  final RecordData data;
  final Future<void> Function(RecordData) onSave;
  @override
  ConsumerState<TagEditPage> createState() => _TagEditState();
}

class _TagEditState extends NativeState<TagEditPage> {
  late final data = {...widget.data};
  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t(widget.group ? 'Tag Group' : 'Tag'),
    busy: busy,
    trailing: actionButton(t('Save'), () async {
      if (string(data['name']).trim().isEmpty) return;
      final result = await run(() => widget.onSave(data));
      if (result && mounted) Navigator.pop(context);
    }),
    children: [
      Section(
        children: [
          InputRow(
            t('Name'),
            value: string(data['name']),
            onChanged: (value) => data['name'] = value,
          ),
          if (!widget.group)
            ItemRow(
              t('Tag Group'),
              value: recordName(app.tagGroups, data['groupId']),
              onTap: () async {
                final value = await choose(context, t('Tag Group'), {
                  '0': t('None'),
                  for (final item in app.tagGroups)
                    string(item['id']): string(item['name']),
                }, selected: string(data['groupId']));
                if (value != null && mounted) {
                  setState(() => data['groupId'] = value);
                }
              },
            ),
        ],
      ),
    ],
  );
}

class CategoryAllPage extends ConsumerWidget {
  const CategoryAllPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    return NativePage(
      title: app.t('Transaction Categories'),
      children: [
        Section(
          children: [
            for (final entry in {
              2: 'Expense Categories',
              1: 'Income Categories',
              3: 'Transfer Categories',
            }.entries)
              ItemRow(
                app.t(entry.value),
                onTap: () => context.push('/category/list?type=${entry.key}'),
              ),
          ],
        ),
      ],
    );
  }
}

class CategoryEditPage extends ConsumerStatefulWidget {
  const CategoryEditPage({super.key, this.query = const {}});
  final Map<String, String> query;
  @override
  ConsumerState<CategoryEditPage> createState() => _CategoryEditState();
}

class _CategoryEditState extends NativeState<CategoryEditPage> {
  late final data = <String, dynamic>{
    'name': '',
    'type': number(widget.query['type'] ?? 2),
    'parentId': widget.query['parentId'] ?? '0',
    'icon': string(widget.query['icon']).isEmpty ? '1' : widget.query['icon'],
    'iconType': number(widget.query['iconType']),
    'color': string(widget.query['color']).isEmpty
        ? '000000'
        : widget.query['color'],
    'comment': '',
    'hidden': false,
    ...lookup(flatten(app.categories, 'subCategories'), widget.query['id']),
  };
  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t(data['id'] == null ? 'Add Category' : 'Edit Category'),
    busy: busy,
    trailing: iconButton(CupertinoIcons.check_mark, t('Save'), () async {
      final result = await run(() async {
        if (string(data['name']).trim().isEmpty) {
          throw FormatException(t('Please enter a category name'));
        }
        await onlineMutation(
          'v1/transaction/categories/${data['id'] == null ? 'add' : 'modify'}.json',
          data,
        );
      });
      if (result && mounted) context.pop();
    }),
    children: [
      Section(
        children: [
          InputRow(
            t('Category Name'),
            value: string(data['name']),
            onChanged: (value) => data['name'] = value,
          ),
          if (data['id'] != null && string(data['parentId']) != '0')
            ItemRow(
              t('Primary Category'),
              value: recordName(app.categories, data['parentId']),
              onTap: () async {
                final value = await choose(context, t('Primary Category'), {
                  for (final item in app.categories.where(
                    (item) =>
                        item['type'] == data['type'] && item['hidden'] != true,
                  ))
                    string(item['id']): string(item['name']),
                }, selected: string(data['parentId']));
                if (value != null && mounted) {
                  setState(() => data['parentId'] = value);
                }
              },
            ),
          ItemRow(
            t('Icon'),
            leading: recordIcon(data),
            onTap: () async {
              final value = await chooseOriginalIcon(
                context,
                'category',
                string(data['icon']),
                iconType: number(data['iconType']),
                color: string(data['color']),
              );
              if (value != null && mounted) {
                setState(() => data.addAll(value));
              }
            },
          ),
          ItemRow(
            t('Color'),
            leading: Container(
              width: 24,
              height: 24,
              color: itemColor(data['color']),
            ),
            onTap: () async {
              final value = await chooseColor(context, string(data['color']));
              if (value != null && mounted) {
                setState(() => data['color'] = value);
              }
            },
          ),
          InputRow(
            t('Description'),
            value: string(data['comment']),
            lines: 3,
            onChanged: (value) => data['comment'] = value,
          ),
          if (data['id'] != null)
            toggleRow(
              t('Hidden'),
              data['hidden'] == true,
              (value) => setState(() => data['hidden'] = value),
            ),
        ],
      ),
    ],
  );
}

class CategoryPresetPage extends ConsumerStatefulWidget {
  const CategoryPresetPage({super.key, this.query = const {}});
  final Map<String, String> query;
  @override
  ConsumerState<CategoryPresetPage> createState() => _CategoryPresetState();
}

class _CategoryPresetState extends NativeState<CategoryPresetPage> {
  Map<String, dynamic> allPresets = {};
  Map<String, dynamic> localeMessages = {};
  Map<String, dynamic> englishMessages = {};
  List<RecordData> languages = [];
  late String currentLocale = app.languageTag.replaceAll('-', '_');
  List<RecordData> presets = [];
  final selected = <int, Set<int>>{};
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => run(() async {
        allPresets = Map<String, dynamic>.from(
          jsonDecode(
            await rootBundle.loadString(
              'assets/reference/category_presets.json',
            ),
          ),
        );
        languages = records(
          jsonDecode(
            await rootBundle.loadString('assets/reference/settings.json'),
          )['languages'],
        );
        englishMessages = Map<String, dynamic>.from(
          jsonDecode(await rootBundle.loadString('assets/locales/en.json')),
        );
        await loadLocale();
        for (var i = 0; i < presets.length; i++) {
          selected[i] = {
            for (
              var j = 0;
              j < records(presets[i]['subCategories']).length;
              j++
            )
              j,
          };
        }
      }),
    );
  }

  Future<void> loadLocale() async {
    localeMessages = Map<String, dynamic>.from(
      jsonDecode(
        await rootBundle.loadString(
          'assets/locales/${currentLocale.replaceAll('-', '_')}.json',
        ),
      ),
    );
    presets = registrationCategories({
      for (final entry in allPresets.entries)
        if (number(widget.query['type']) == 0 ||
            number(entry.key) == number(widget.query['type']))
          entry.key: entry.value,
    }, (key) => translateMessage(localeMessages, englishMessages, key));
  }

  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t('Preset Categories'),
    busy: busy,
    trailing: actionButton(t('Add'), () async {
      if (selected.isEmpty) return;
      final result = await run(
        () => onlineMutation('v1/transaction/categories/add_batch.json', {
          'categories': [
            for (final index in selected.keys)
              {
                'name': presets[index]['name'],
                'type': presets[index]['type'],
                'icon':
                    presets[index]['categoryIconId'] ?? presets[index]['icon'],
                'iconType': 0,
                'color': presets[index]['color'],
                'subCategories': [
                  for (final child in [
                    for (final childIndex in selected[index]!)
                      records(presets[index]['subCategories'])[childIndex],
                  ])
                    {
                      'name': child['name'],
                      'type': child['type'],
                      'icon': child['categoryIconId'] ?? child['icon'],
                      'iconType': 0,
                      'color': child['color'],
                      'parentId': '0',
                      'comment': '',
                    },
                ],
              },
          ],
        }),
      );
      if (result && mounted) context.pop();
    }),
    children: [
      Section(
        children: [
          ItemRow(
            t('Change Language'),
            value: string(lookup(languages, currentLocale)['name']),
            onTap: () async {
              final locale = await choose(context, t('Language'), {
                for (final language in languages)
                  string(language['id']): string(language['name']),
              }, selected: currentLocale);
              if (locale != null && mounted) {
                await run(() async {
                  currentLocale = locale;
                  await loadLocale();
                });
              }
            },
          ),
        ],
      ),
      for (var i = 0; i < presets.length; i++)
        Section(
          title: i == 0 || presets[i - 1]['type'] != presets[i]['type']
              ? t(
                  const {
                    1: 'Income Categories',
                    2: 'Expense Categories',
                    3: 'Transfer Categories',
                  }[number(presets[i]['type'])]!,
                )
              : null,
          children: [
            toggleRow(
              string(presets[i]['name']),
              selected.containsKey(i),
              (value) => setState(() {
                value
                    ? selected[i] = {
                        for (
                          var j = 0;
                          j < records(presets[i]['subCategories']).length;
                          j++
                        )
                          j,
                      }
                    : selected.remove(i);
              }),
            ),
            if (selected.containsKey(i))
              for (
                var j = 0;
                j < records(presets[i]['subCategories']).length;
                j++
              )
                toggleRow(
                  string(records(presets[i]['subCategories'])[j]['name']),
                  selected[i]!.contains(j),
                  (value) => setState(
                    () => value ? selected[i]!.add(j) : selected[i]!.remove(j),
                  ),
                ),
          ],
        ),
    ],
  );
}
