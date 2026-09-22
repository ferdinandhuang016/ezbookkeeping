import 'package:flutter/services.dart';

import '../ui/common.dart';
import 'catalogs/catalogs.dart';
import 'overview/home.dart';
import 'settings/mobile_settings.dart';
import 'statistics/statistics.dart';
import 'transactions/transactions.dart';

Widget mobilePage(String route, Map<String, String> query) => switch (route) {
  '/' => const PrimaryShell(initialIndex: 2),
  '/transaction/list' =>
    query.isEmpty
        ? const PrimaryShell(initialIndex: 0)
        : TransactionListPage(query: query),
  '/transaction/filter/amount' => TransactionFilterPage(
    filter: TransactionFilter.fromAmountQuery(query),
    amountOnly: true,
    returnAmountFilter: true,
  ),
  '/transaction/add' ||
  '/transaction/edit' ||
  '/transaction/detail' ||
  '/template/add' ||
  '/template/edit' => TransactionEditPage(route: route, query: query),
  '/account/list' => const PrimaryShell(initialIndex: 1),
  '/account/add' || '/account/edit' => AccountEditPage(query: query),
  '/account/reconciliation_statements' => ReconciliationPage(query: query),
  '/account/move_all_transactions' => MoveTransactionsPage(query: query),
  '/statistic/transaction' => const PrimaryShell(initialIndex: 3),
  '/statistic/settings' => const StatisticsSettingsPage(),
  '/settings/overview_layout' => const OverviewLayoutPage(),
  '/category/all' => const CategoryAllPage(),
  '/category/list' => CatalogListPage(
    kind: CatalogKind.categories,
    query: query,
  ),
  '/category/add' || '/category/edit' => CategoryEditPage(query: query),
  '/category/preset' => CategoryPresetPage(query: query),
  '/tag/list' => const CatalogListPage(kind: CatalogKind.tags),
  '/tag/group/list' => const CatalogListPage(kind: CatalogKind.groups),
  '/template/list' => const CatalogListPage(kind: CatalogKind.templates),
  '/schedule/list' => const CatalogListPage(kind: CatalogKind.schedules),
  '/settings' => const PrimaryShell(initialIndex: 4),
  _ => settingsPage(route, query),
};

class PrimaryShell extends StatefulWidget {
  const PrimaryShell({super.key, required this.initialIndex});

  final int initialIndex;

  @override
  State<PrimaryShell> createState() => _PrimaryShellState();
}

class _PrimaryShellState extends State<PrimaryShell> {
  late int index = widget.initialIndex;

  static const pages = <Widget>[
    TransactionListPage(showAddAction: false),
    AccountListPage(),
    HomePage(),
    StatisticsPage(),
    SettingsPage(),
  ];

  Widget tab(IconData icon, String title, int value) => Expanded(
    child: Semantics(
      label: tr(context, title),
      button: true,
      selected: index == value,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size.fromHeight(64),
        onPressed: () => setState(() => index = value),
        child: ExcludeSemantics(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (value == 2)
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: index == value
                        ? brand
                        : CupertinoColors.tertiarySystemFill.resolveFrom(
                            context,
                          ),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 30,
                    color: index == value
                        ? CupertinoColors.white
                        : CupertinoColors.label.resolveFrom(context),
                  ),
                )
              else
                Icon(
                  icon,
                  size: 22,
                  color: index == value
                      ? brand
                      : CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              if (value != 2) const SizedBox(height: 3),
              if (value != 2)
                Text(
                  tr(context, title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: index == value
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: index == value
                        ? brand
                        : CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    void openTemplates() {
      HapticFeedback.vibrate();
      openTransactionTemplates(context);
    }

    return PopScope<void>(
      canPop: index == 2,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && index != 2) setState(() => index = 2);
      },
      child: ColoredBox(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: MediaQuery.removePadding(
                    context: context,
                    removeBottom: true,
                    child: IndexedStack(index: index, children: pages),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemBackground.resolveFrom(
                      context,
                    ),
                    border: const Border(
                      top: BorderSide(
                        color: CupertinoColors.separator,
                        width: .5,
                      ),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      height: 64,
                      child: Row(
                        children: [
                          tab(CupertinoIcons.list_bullet, 'Details', 0),
                          tab(CupertinoIcons.creditcard, 'Accounts', 1),
                          tab(CupertinoIcons.house_fill, 'Home', 2),
                          tab(CupertinoIcons.chart_pie, 'Statistics', 3),
                          tab(CupertinoIcons.gear_alt, 'Settings', 4),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            PositionedDirectional(
              end: 16,
              bottom: bottomInset + 76,
              child: Semantics(
                label: tr(context, 'Add Transaction'),
                button: true,
                onLongPress: openTemplates,
                child: GestureDetector(
                  onLongPress: openTemplates,
                  child: CupertinoButton(
                    minimumSize: const Size(56, 56),
                    padding: EdgeInsets.zero,
                    color: brand,
                    borderRadius: BorderRadius.circular(28),
                    onPressed: () => context.push('/transaction/add'),
                    child: const ExcludeSemantics(
                      child: Icon(
                        CupertinoIcons.plus,
                        size: 26,
                        color: CupertinoColors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
