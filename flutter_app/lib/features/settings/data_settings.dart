import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../ui/common.dart';
import '../../core/money.dart';
import '../../core/cache_policy.dart';
import '../catalogs/catalogs.dart' show SwipeActionsRow;
import 'settings_support.dart';

class CacheSettingsPage extends ConsumerStatefulWidget {
  const CacheSettingsPage({super.key});
  @override
  ConsumerState<CacheSettingsPage> createState() => _CacheState();
}

class _CacheState extends SettingsState<CacheSettingsPage> {
  RecordData cache = {};
  bool loaded = false;
  @override
  void initState() {
    super.initState();
    Future.microtask(() => run(load));
  }

  Future<void> load() async {
    cache = await app.cacheStatistics();
    loaded = true;
  }

  int get ratesBytes =>
      serializedCacheBytes(app.settings['cachedExchangeRates']);

  String volume(int bytes) {
    final divisor = bytes >= 1048576
        ? 1048576
        : bytes >= 1024
        ? 1024
        : 1;
    final unit = divisor == 1048576
        ? 'MiB'
        : divisor == 1024
        ? 'KiB'
        : 'B';
    return '${app.formatter.decimal((bytes / divisor).toStringAsFixed(2))} $unit';
  }

  String expirationName(int value) => value < 0
      ? t('Disable Cache')
      : value == 0
      ? t('No Expiration')
      : app.t(
          'format.misc.nDays',
          parameters: {'n': app.formatter.digits('${value ~/ 86400}')},
        );

  Future<void> clear(AppCache selected) => clearAppCaches(
    selected,
    clearPictures: app.clearCache,
    clearWebView: () => WebViewController().clearCache(),
    writePreference: app.setPreference,
    clearDecodedImages: () {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    },
  );

  Future<void> clearConfirmed(AppCache selected) async {
    final message = switch (selected) {
      AppCache.pictures => 'Clear Cached Pictures',
      AppCache.map => 'Are you sure you want to clear map data cache?',
      AppCache.customIcons =>
        'Are you sure you want to clear custom icon cache?',
      AppCache.files => 'Are you sure you want to clear all file cache?',
      AppCache.exchangeRates =>
        'Are you sure you want to clear exchange rates data cache?',
      AppCache.all => 'Clear All Caches?',
    };
    if (busy || !await confirm(context, t(message))) return;
    if (!mounted) return;
    await run(() async {
      try {
        await clear(selected);
      } finally {
        await load();
      }
    }, success: true);
  }

  Future<void> more() async {
    final selected = await showCupertinoModalPopup<AppCache>(
      context: context,
      builder: (sheet) {
        Widget group(List<Widget> children) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
              sheet,
            ),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Container(
                    height: .5,
                    color: CupertinoColors.separator.resolveFrom(sheet),
                  ),
                children[i],
              ],
            ],
          ),
        );
        Widget button(String label, AppCache? value, {bool enabled = true}) =>
            CupertinoButton(
              minimumSize: const Size(double.infinity, 57),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              onPressed: enabled ? () => Navigator.pop(sheet, value) : null,
              child: Text(
                t(label),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: value == null ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            );
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  group([
                    button('Clear Cached Pictures', AppCache.pictures),
                    button('Clear Map Data Cache', AppCache.map),
                    button('Clear Custom Icon Cache', AppCache.customIcons),
                    button('Clear All File Cache', AppCache.files),
                  ]),
                  group([
                    button(
                      'Clear Exchange Rates Data Cache',
                      AppCache.exchangeRates,
                      enabled: ratesBytes > 0,
                    ),
                  ]),
                  group([button('Clear All Caches', AppCache.all)]),
                  group([button('Cancel', null)]),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (selected != null && mounted) await clearConfirmed(selected);
  }

  Future<void> expiration(bool map) async {
    final key = map ? 'mapCacheExpiration' : 'exchangeRatesDataCacheExpiration';
    final values = map ? mapCacheExpirations : exchangeRatesCacheExpirations;
    final current = number(preference(app, key));
    var query = '';
    final selected = await showCupertinoModalPopup<int>(
      context: context,
      builder: (sheet) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .82,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: StatefulBuilder(
            builder: (context, update) {
              final visible = values
                  .where(
                    (value) =>
                        expirationName(value)
                            .toLowerCase()
                            .contains(query.toLowerCase()),
                  )
                  .toList();
              return NativePage(
                title: t(
                  map
                      ? 'Cache Expiration for Map Data'
                      : 'Cache Expiration for Exchange Rates Data',
                ),
                subnavbar: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: CupertinoSearchTextField(
                    placeholder: t('Expiration Time'),
                    onChanged: (value) => update(() => query = value),
                  ),
                ),
                children: [
                  if (visible.isEmpty) emptyState(t('No results')),
                  if (visible.isNotEmpty)
                    Section(
                      children: [
                        for (final value in visible)
                          ItemRow(
                            expirationName(value),
                            trailing: value == current
                                ? const Icon(
                                    CupertinoIcons.check_mark,
                                    color: brand,
                                  )
                                : null,
                            onTap: () => Navigator.pop(sheet, value),
                          ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    if (selected == null || !mounted || selected == current) return;
    await run(() async {
      await writePreference(app, key, selected);
      final stamp = number(
        app.settings[map ? 'nativeMapCacheUpdated' : 'exchangeRatesCachedAt'],
      );
      if (cacheExpired(
        selected,
        stamp,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      )) {
        await clear(map ? AppCache.map : AppCache.exchangeRates);
      }
      await load();
    });
  }

  @override
  Widget buildPage(BuildContext context) => PopScope(
    canPop: !busy,
    child: NativePage(
      title: t('App Cache Management'),
      busy: busy,
      trailing: iconButton(
        CupertinoIcons.ellipsis,
        t('More'),
        loaded && !busy ? more : null,
      ),
      onRefresh: () async {
        await run(load);
      },
      children: [
        Section(
          title: t('File Cache'),
          children: [
            // WebView does not expose HTTP-cache size. Do not imply that the sum
            // of picture/icon bytes accounts for all native file caches.
            ItemRow(t('Used storage'), value: '-'),
            ItemRow(
              t('Pictures'),
              value: loaded ? volume(number(cache['pictureBytes'])) : '-',
            ),
            ItemRow(t('Map Data'), value: '-'),
            ItemRow(
              t('Custom Icons'),
              value: loaded
                  ? volume(
                      serializedCacheBytes(
                        app.settings['cachedCustomIconImages'],
                      ),
                    )
                  : '-',
            ),
          ],
        ),
        Section(
          title: t('Exchange Rates Data'),
          children: [ItemRow(t('Used storage'), value: volume(ratesBytes))],
        ),
        Section(
          title: t('Cache Expiration Time'),
          footer: t(
            'Clearing caches keeps your ledger, pending transactions and pictures awaiting upload.',
          ),
          children: [
            if (string(app.config['mapProvider']).isNotEmpty)
              ItemRow(
                t('Map Data'),
                value: expirationName(
                  number(preference(app, 'mapCacheExpiration')),
                ),
                onTap: loaded && !busy && canSetMapCacheExpiration(app.config)
                    ? () => expiration(true)
                    : null,
              ),
            ItemRow(
              t('Exchange Rates Data'),
              value: expirationName(
                number(preference(app, 'exchangeRatesDataCacheExpiration')),
              ),
              onTap: !busy ? () => expiration(false) : null,
            ),
          ],
        ),
      ],
    ),
  );
}

class DataManagementPage extends ConsumerStatefulWidget {
  const DataManagementPage({super.key});
  @override
  ConsumerState<DataManagementPage> createState() => _DataManagementState();
}

class _DataManagementState extends NativeState<DataManagementPage> {
  RecordData stats = {};
  @override
  void initState() {
    super.initState();
    Future.microtask(() => run(load));
  }

  Future<void> load() async {
    stats = Map<String, dynamic>.from(await app.get('v1/data/statistics.json'));
  }

  Future<void> clear(bool all) async {
    if (!await confirm(
      context,
      t(
        all
            ? 'Are you sure you want to clear all data?'
            : 'Are you sure you want to clear all transactions?',
      ),
      message: t(
        all
            ? 'You CANNOT undo this action. This will clear your accounts, categories, tags and transactions data.'
            : 'You CANNOT undo this action. This will clear your transactions data.',
      ),
      destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    final password = await prompt(
      context,
      t('Please enter your current password to confirm.'),
      secret: true,
    );
    if (password == null) return;
    await run(() async {
      await onlineMutation(
        all ? 'v1/data/clear/all.json' : 'v1/data/clear/transactions.json',
        {'password': password},
      );
      await load();
    }, success: true);
  }

  Future<void> export() async {
    final format = await choose<String>(context, t('Export Data'), {
      'csv': 'CSV',
      'tsv': 'TSV',
    });
    if (format == null) return;
    await run(() async {
      if (app.pendingCount > 0) {
        await app.refresh();
        if (app.pendingCount > 0) {
          throw StateError(t('Please synchronize pending transactions first'));
        }
      }
      final bytes = await app.api.download(
        'v1/data/export.$format',
        query: {
          'max_time': 0,
          'min_time': 0,
          'type': 0,
          'category_ids': '',
          'account_ids': '',
          'tag_filter': '',
          'amount_filter': '',
          'keyword': '',
          'match_mode': 0,
        },
      );
      final saved = await FilePicker.saveFile(
        dialogTitle: t('Save Data'),
        fileName:
            'ezBookkeeping-${DateTime.now().toIso8601String().substring(0, 10)}.$format',
        type: FileType.custom,
        allowedExtensions: [format],
        bytes: Uint8List.fromList(bytes),
      );
      if (saved != null && mounted) await inform(context, t('Data saved'));
    });
  }

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Data Management'),
    busy: busy,
    onRefresh: () async {
      await run(load);
    },
    children: [
      Section(
        children: [
          for (final e in const {
            'totalTransactionCount': 'Transactions',
            'totalTransactionPictureCount': 'Transaction Pictures',
            'totalAccountCount': 'Accounts',
            'totalExplorationCount': 'Explorations',
            'totalTransactionCategoryCount': 'Transaction Categories',
            'totalTransactionTagCount': 'Transaction Tags',
            'totalTransactionTemplateCount': 'Transaction Templates',
            'totalScheduledTransactionCount': 'Scheduled Transactions',
            'totalCustomIconCount': 'Custom Icons',
          }.entries)
            ItemRow(t(e.value), value: string(stats[e.key])),
        ],
      ),
      Section(
        children: [
          if (app.config['enableDataExport'] == true)
            actionButton(t('Export Data'), export),
          actionButton(
            t('Clear All Transactions'),
            () => clear(false),
            destructive: true,
          ),
          actionButton(
            t('Clear All Data'),
            () => clear(true),
            destructive: true,
          ),
        ],
      ),
    ],
  );
}

class ExchangeRatesPage extends ConsumerStatefulWidget {
  const ExchangeRatesPage({super.key});
  @override
  ConsumerState<ExchangeRatesPage> createState() => _ExchangeRatesState();
}

class _ExchangeRatesState extends SettingsState<ExchangeRatesPage> {
  late String base = string(app.user['defaultCurrency']);
  int baseAmount = 100;
  List<RecordData> currencies = [];
  Map<String, int> currencyNameOrder = {};
  RecordData get table =>
      Map<String, dynamic>.from(app.settings['cachedExchangeRates'] ?? {});
  bool get custom => table['dataSource'] == 'user_custom';
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => run(() async {
        currencies = records(
          jsonDecode(
            await rootBundle.loadString('assets/reference/currencies.json'),
          ),
        );
        final order = await const MethodChannel('ezbookkeeping/native')
            .invokeListMethod<int>('sortStrings', {
              'values': [
                for (final currency in currencies)
                  currencyName(string(currency['code'])),
              ],
              'localeCompare': true,
            });
        currencyNameOrder = {
          for (var i = 0; i < (order?.length ?? 0); i++)
            string(currencies[order![i]]['code']): i,
        };
        final hadCache = table.isNotEmpty;
        try {
          await load(force: false);
        } catch (_) {
          if (!hadCache) rethrow;
        }
        if (rows.isNotEmpty &&
            !rows.any((row) => row['currency'] == base) &&
            mounted) {
          settingsNotice(
            context,
            t('There is no exchange rates data for your default currency'),
          );
        }
      }),
    );
  }

  Future<void> load({required bool force}) async =>
      app.refreshExchangeRates(force: force);

  Future<void> refresh() async {
    await run(() async {
      await load(force: true);
      if (mounted) {
        settingsNotice(context, t('Exchange rates data has been updated'));
      }
    });
  }

  String currencyName(String code) => t(
    string(
      currencies.where((e) => e['code'] == code).firstOrNull?['name'] ?? code,
    ),
  );
  List<RecordData> get rows {
    final result = records(table['exchangeRates']);
    final sort = number(preference(app, 'currencySortByInExchangeRatesPage'));
    result.sort(
      (a, b) => sort == 2
          ? compareDecimal(string(a['rate']), string(b['rate']))
          : sort == 1
          ? string(a['currency']).compareTo(string(b['currency']))
          : (currencyNameOrder[string(a['currency'])] ?? 999999).compareTo(
              currencyNameOrder[string(b['currency'])] ?? 999999,
            ),
    );
    return result;
  }

  String converted(RecordData row) {
    final baseRate = records(table['exchangeRates'])
        .where((e) => e['currency'] == base)
        .firstOrNull?['rate'];
    if (baseRate == null) return '0';
    return convertedRateAmount(
      baseAmount,
      string(baseRate),
      string(row['rate']),
    );
  }

  Future<void> more() async {
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        actions: [
          if (custom)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheet, 'update'),
              child: Text(t('Update')),
            ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheet, 'refresh'),
            child: Text(t('Refresh')),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          isDefaultAction: true,
          child: Text(t('Cancel')),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'update') {
      await context.push('/exchange_rates/update');
      if (mounted) await run(() => load(force: true));
    } else if (action == 'refresh') {
      await refresh();
    }
  }

  Future<void> remove(RecordData row) async {
    if (!custom || row['currency'] == app.user['defaultCurrency']) return;
    final accepted = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(
          t('Are you sure you want to delete this user custom exchange rate?'),
        ),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(sheet, true),
            child: Text(t('Delete')),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet, false),
          isDefaultAction: true,
          child: Text(t('Cancel')),
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    await run(() async {
      await app.post('v1/exchange_rates/user_custom/delete.json', {
        'currency': row['currency'],
      });
      if (base == row['currency']) base = string(app.user['defaultCurrency']);
      await app.refreshAfterMutation();
      await load(force: true);
    });
  }

  Widget currencyLabel(String code) => Text.rich(
    TextSpan(
      children: [
        TextSpan(text: currencyName(code)),
        TextSpan(text: '  $code', style: const TextStyle(fontSize: 13)),
      ],
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
  @override
  Widget buildPage(BuildContext context) {
    final available = rows;
    return NativePage(
      title: t('Exchange Rates Data'),
      busy: busy,
      onRefresh: refresh,
      trailing: iconButton(CupertinoIcons.ellipsis, t('More'), more),
      children: [
        if (available.isEmpty)
          Section(children: [ItemRow(t('No exchange rates data'))]),
        if (available.isNotEmpty) ...[
          Section(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            children: [
              CupertinoListTile.notched(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('Base Currency'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    currencyLabel(base),
                  ],
                ),
                trailing: const CupertinoListTileChevron(),
                onTap: () async {
                  final code = await choose<String>(context, t('Base Currency'), {
                    for (final row in available)
                      string(
                        row['currency'],
                      ): '${currencyName(string(row['currency']))}  ${row['currency']}',
                  }, selected: base);
                  if (code != null && mounted) setState(() => base = code);
                },
              ),
              CupertinoListTile.notched(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('Base Amount'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      exchangeRateBaseAmount(app, baseAmount, base),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: baseAmount.abs() >= 10000000000
                            ? 26
                            : baseAmount.abs() >= 100000000
                            ? 32
                            : baseAmount.abs() >= 1000000
                            ? 36
                            : 40,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
                onTap: () async {
                  final value = await amountPad(context, baseAmount);
                  if (value != null && mounted) {
                    setState(() => baseAmount = value);
                  }
                },
              ),
            ],
          ),
          Section(
            children: [
              for (final row in available)
                SwipeActionsRow(
                  key: ValueKey('${row['currency']}:$base'),
                  actions: {
                    if (row['currency'] != base)
                      t('Set as Base'): () {
                        final value = exchangeRateBaselineAmount(
                          converted(row),
                        );
                        setState(() {
                          base = string(row['currency']);
                          baseAmount = value;
                        });
                      },
                    if (custom &&
                        row['currency'] != app.user['defaultCurrency'])
                      t('Delete'): () => remove(row),
                  },
                  child: CupertinoListTile.notched(
                    title: currencyLabel(string(row['currency'])),
                    trailing: Text(
                      app.formatter.decimal(converted(row)),
                      style: TextStyle(
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Section(
            children: [
              if (number(table['updateTime']) > 0)
                CupertinoListTile.notched(
                  title: Text(
                    t('Last Updated'),
                    style: const TextStyle(fontSize: 14),
                  ),
                  trailing: Text(
                    app.formatter.date(
                      app.formatter.localDate(
                        DateTime.fromMillisecondsSinceEpoch(
                          number(table['updateTime']) * 1000,
                          isUtc: true,
                        ),
                      ),
                      long: true,
                    ),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              CupertinoListTile.notched(
                title: Text(
                  t('Data source'),
                  style: const TextStyle(fontSize: 14),
                ),
                trailing: Text(
                  custom ? t('User Custom') : string(table['dataSource']),
                  style: TextStyle(
                    fontSize: 14,
                    color:
                        !custom && externalWebUri(table['referenceUrl']) != null
                        ? brand
                        : CupertinoColors.label.resolveFrom(context),
                  ),
                ),
                onTap: !custom && externalWebUri(table['referenceUrl']) != null
                    ? () => launchUrl(
                        externalWebUri(table['referenceUrl'])!,
                        mode: LaunchMode.externalApplication,
                      )
                    : null,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

Uri? externalWebUri(dynamic value) {
  final uri = Uri.tryParse(string(value));
  return uri != null &&
          ['http', 'https'].contains(uri.scheme) &&
          uri.host.isNotEmpty
      ? uri
      : null;
}

void settingsNotice(BuildContext context, String message) {
  final entry = OverlayEntry(
    builder: (context) => Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.paddingOf(context).bottom + 24,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xe6333333),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: CupertinoColors.white,
                fontSize: 14,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
  Future<void>.delayed(const Duration(seconds: 3), entry.remove);
}

/// The original exchange-rate page clamps a selected baseline to amount limits.
String exchangeRateBaseAmount(AppController app, int cents, String currency) =>
    app.formatter.amount(cents, currency: currency, showCurrency: false);

int exchangeRateBaselineAmount(String value) {
  final negative = value.startsWith('-');
  final unsigned = negative ? value.substring(1) : value;
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(unsigned)) {
    throw const FormatException('Invalid exchange rate');
  }
  final parts = unsigned.split('.');
  final decimals = parts.length > 1 ? parts[1] : '';
  var cents =
      BigInt.parse(parts[0]) * BigInt.from(100) +
      BigInt.parse(decimals.padRight(2, '0').substring(0, 2));
  final maximum = BigInt.from(Money.maxAmount);
  if (cents > maximum) cents = maximum;
  return cents.toInt() * (negative ? -1 : 1);
}

class ExchangeRatesEditPage extends ConsumerStatefulWidget {
  const ExchangeRatesEditPage({super.key, this.currency});
  final String? currency;
  @override
  ConsumerState<ExchangeRatesEditPage> createState() =>
      _ExchangeRatesEditState();
}

class _ExchangeRatesEditState extends NativeState<ExchangeRatesEditPage> {
  late String currency = widget.currency ?? string(app.user['defaultCurrency']);
  late String source = app.formatter.digits('1');
  late String target = app.formatter.digits('1');
  List<RecordData> currencies = [];
  bool get canSave {
    try {
      divideRate(
        app.formatter.normalizeAmountInput(target),
        app.formatter.normalizeAmountInput(source),
      );
      return currency.isNotEmpty;
    } on FormatException {
      return false;
    }
  }

  String currencyName(String code) =>
      '${t(string(currencies.where((e) => e['code'] == code).firstOrNull?['name'] ?? code))}  $code';
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => run(() async {
        currencies = records(
          jsonDecode(
            await rootBundle.loadString('assets/reference/currencies.json'),
          ),
        );
      }),
    );
  }

  Future<void> save() async {
    if (!canSave || busy) return;
    await run(() async {
      final rate = divideRate(
        app.formatter.normalizeAmountInput(target),
        app.formatter.normalizeAmountInput(source),
      );
      await app.post('v1/exchange_rates/user_custom/update.json', {
        'currency': currency,
        'rate': rate,
      });
      await app.refreshAfterMutation();
      await app.setPreference(
        'cachedExchangeRates',
        await app.get('v1/exchange_rates/latest.json'),
      );
      if (mounted) {
        settingsNotice(context, t('You have updated exchange rate'));
        context.pop();
      }
    });
  }

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Update User Custom Exchange Rate'),
    busy: busy,
    trailing: iconButton(
      CupertinoIcons.check_mark,
      t('Save'),
      canSave && !busy ? save : null,
    ),
    children: [
      Section(
        children: [
          InputRow(
            t('Amount'),
            value: source,
            readOnly: busy,
            keyboard: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) => setState(() => source = v),
          ),
          ItemRow(
            t('Currency'),
            value: currencyName(string(app.user['defaultCurrency'])),
          ),
        ],
      ),
      const Center(child: Icon(CupertinoIcons.arrow_up_arrow_down)),
      Section(
        children: [
          InputRow(
            t('Amount'),
            value: target,
            readOnly: busy,
            keyboard: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) => setState(() => target = v),
          ),
          ItemRow(
            t('Currency'),
            value: currencyName(currency),
            onTap: busy
                ? null
                : () async {
                    final value = await choose<String>(context, t('Currency'), {
                      for (final e in currencies)
                        string(e['code']):
                            '${e['code']} · ${t(string(e['name']))}',
                    }, selected: currency);
                    if (value != null) setState(() => currency = value);
                  },
          ),
        ],
      ),
    ],
  );
}

BigInt _decimal(String value, int scale) {
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(value)) {
    throw const FormatException('Invalid exchange rate');
  }
  final parts = value.split('.');
  if (parts.length > 1 && parts[1].length > scale) {
    throw const FormatException('Too many decimal places');
  }
  return BigInt.parse(parts[0]) * BigInt.from(10).pow(scale) +
      BigInt.parse(parts.length > 1 ? parts[1].padRight(scale, '0') : '0');
}

int compareDecimal(String a, String b) {
  final sa = a.contains('.') ? a.split('.').last.length : 0;
  final sb = b.contains('.') ? b.split('.').last.length : 0;
  final scale = sa > sb ? sa : sb;
  return _decimal(a, scale).compareTo(_decimal(b, scale));
}

String divideRate(String numerator, String denominator) {
  final n = _decimal(numerator, 4), d = _decimal(denominator, 4);
  final maximum = BigInt.parse('9999999999999');
  if (n <= BigInt.zero || d <= BigInt.zero || n > maximum || d > maximum) {
    throw const FormatException(
      'Exchange rate amounts must be positive and at most 999999999.9999',
    );
  }
  // The server applies the stored base-currency rate before truncating to its
  // integer unit. Rounding to eight places here changes that final value.
  final scale = BigInt.from(10).pow(20);
  final result = n * scale ~/ d;
  return '${result ~/ scale}.${(result % scale).toString().padLeft(20, '0')}'
      .replaceFirst(RegExp(r'\.?0+$'), '');
}

/// The rates screen preserves small fractional values instead of rounding to cents.
String convertedRateAmount(int cents, String fromRate, String toRate) {
  final fromScale = fromRate.contains('.')
      ? fromRate.split('.').last.length
      : 0;
  final toScale = toRate.contains('.') ? toRate.split('.').last.length : 0;
  final scale = fromScale > toScale ? fromScale : toScale;
  final from = _decimal(fromRate, scale), to = _decimal(toRate, scale);
  if (from <= BigInt.zero) throw const FormatException('Invalid exchange rate');
  final decimalScale = BigInt.from(10).pow(20);
  final scaled =
      BigInt.from(cents.abs()) * to * decimalScale ~/ (from * BigInt.from(100));
  var result =
      '${cents < 0 ? '-' : ''}${scaled ~/ decimalScale}.${(scaled % decimalScale).toString().padLeft(20, '0')}';
  result = result.replaceFirst(RegExp(r'\.?0+$'), '');
  if (!result.contains('.')) return result;
  var firstNonZero = 0;
  for (var index = 0; index < result.length; index++) {
    if (result[index] != '.' && result[index] != '0') {
      firstNonZero = index + 4;
      break;
    }
  }
  final decimalIndex = result.indexOf('.');
  var end = firstNonZero > 6 ? firstNonZero : 6;
  if (decimalIndex + 2 > end) end = decimalIndex + 2;
  result = result.substring(0, end.clamp(0, result.length));
  return result;
}
