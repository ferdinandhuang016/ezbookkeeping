import '../ui/common.dart';
import 'catalogs/catalogs.dart';
import 'overview/home.dart';
import 'settings/mobile_settings.dart';
import 'statistics/statistics.dart';
import 'transactions/transactions.dart';

Widget mobilePage(String route, Map<String, String> query) => switch (route) {
  '/' => const HomePage(),
  '/transaction/list' => TransactionListPage(query: query),
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
  '/account/list' => const AccountListPage(),
  '/account/add' || '/account/edit' => AccountEditPage(query: query),
  '/account/reconciliation_statements' => ReconciliationPage(query: query),
  '/account/move_all_transactions' => MoveTransactionsPage(query: query),
  '/statistic/transaction' => const StatisticsPage(),
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
  _ => settingsPage(route, query),
};
