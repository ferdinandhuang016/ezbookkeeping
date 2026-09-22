import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart' hide Hmac;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../data/ledger_database.dart';
import '../data/ledger_repository.dart';
import 'aggregate_amount.dart';
import 'api_client.dart';
import 'formatting.dart';
import 'widget_summary.dart';
import 'transaction_permissions.dart';
import 'application_settings.dart';
import 'native_localization.dart';

final appControllerProvider = ChangeNotifierProvider<AppController>((ref) {
  final controller = AppController();
  unawaited(controller.initialize());
  return controller;
});

bool exchangeRatesCacheFresh(Map<String, dynamic> settings, int now) {
  final cached = settings['cachedExchangeRates'];
  if (cached is! Map) return false;
  int seconds(Object? value) => int.tryParse('$value') ?? 0;
  bool same(int left, int right, {required bool hour}) {
    if (left <= 0 || right <= 0) return false;
    final a = DateTime.fromMillisecondsSinceEpoch(left * 1000);
    final b = DateTime.fromMillisecondsSinceEpoch(right * 1000);
    return a.year == b.year &&
        a.month == b.month &&
        a.day == b.day &&
        (!hour || a.hour == b.hour);
  }

  return same(seconds(cached['updateTime']), now, hour: false) ||
      same(seconds(settings['exchangeRatesCachedAt']), now, hour: true);
}

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({FlutterSecureStorage? secure})
    : _secure = secure ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secure;
  final LocalAuthentication _localAuth = LocalAuthentication();
  final AppLinks _links = AppLinks();
  final MethodChannel _native = const MethodChannel('ezbookkeeping/native');
  StreamSubscription<dynamic>? _connectivity;
  StreamSubscription<Uri>? _deepLinks;
  ApiClient? _api;
  LedgerRepository? _repository;
  Future<void>? _refreshFuture;
  bool _closing = false;
  bool _disposed = false;
  String _storageId = '';
  String? _twoFactorToken;
  String? _oauthCallbackToken;
  int _authenticationAttempt = 0;
  bool _handlingOAuthCallback = false;
  bool _nativeLaunchPrepared = false;
  String? _pendingNativeRoute;
  int _homeLaunchId = 0;
  JsonMap _translations = {};
  JsonMap _englishTranslations = {};
  JsonMap _formattingReference = {};
  String _languageTag = 'en';
  JsonMap _settingsReference = {};
  final Set<String> _cloudKeys = {};
  final Map<String, String> _pendingCloud = {};
  final Set<String> _shownNotifications = {};
  final List<String> _notifications = [];
  Future<void>? _cloudWrite;
  JsonMap user = {};
  static const JsonMap _defaultSettings = {
    'theme': 'auto',
    'fontSize': 1,
    'timeZone': '',
    'swipeBack': true,
    'animate': true,
    'showAccountBalance': true,
    'showAmountInHomePage': true,
    'itemsCountInTransactionListPage': 15,
    'showTotalAmountInTransactionListPage': true,
    'showTagInTransactionListPage': true,
    'autoSaveTransactionDraft': 'disabled',
    'autoUpdateExchangeRatesData': true,
    'enabledCurrencies': {'CNY': true, 'USD': true},
    'alwaysRequireConfirmationOfClipboardContentBeforeSubmission': true,
  };
  JsonMap settings = Map.of(_defaultSettings);
  JsonMap config = {};
  String serverUrl = '';
  String? error;
  bool initialized = false;
  bool busy = false;
  bool locked = false;
  bool hasSharedPictures = false;
  bool needsReauthentication = false;
  bool reauthenticationDeferred = false;
  bool get authenticated => _repository != null;
  String? get pendingNativeRoute => _pendingNativeRoute;
  bool get nativeLaunchPrepared => _nativeLaunchPrepared;
  bool get pendingQuickAdd =>
      _pendingNativeRoute?.startsWith('/transaction/add?launcher=true') == true;
  String? get serverNotification => _notifications.firstOrNull;
  bool get needsTwoFactor => _twoFactorToken != null;
  bool get needsOAuthVerification => _oauthCallbackToken != null;
  bool get syncing => _repository?.syncing ?? false;
  bool get initialSyncComplete => _repository?.initialSyncComplete ?? false;
  int get downloadedCount => _repository?.downloadedCount ?? 0;
  int get pendingCount => _repository?.operations.length ?? 0;
  List<JsonMap> get conflicts => _repository?.conflicts ?? [];
  List<JsonMap> get transactions => _repository?.transactions ?? [];
  List<JsonMap> get accounts =>
      _tree(_repository?.metadata['accounts'] ?? [], 'subAccounts');
  List<JsonMap> get categories =>
      _tree(_repository?.metadata['categories'] ?? [], 'subCategories');
  List<JsonMap> get tags => _repository?.metadata['tags'] ?? [];
  List<JsonMap> get tagGroups => _repository?.metadata['tagGroups'] ?? [];
  List<JsonMap> get templates => _repository?.metadata['templates'] ?? [];
  ApiClient get api =>
      _api ?? (throw StateError('Set the server address first'));

  List<JsonMap> _tree(List<JsonMap> items, String childrenKey) {
    final byId = {
      for (final item in items)
        item['id'].toString(): <String, dynamic>{
          ...item,
          childrenKey: <JsonMap>[],
        },
    };
    final roots = <JsonMap>[];
    for (final item in byId.values) {
      final parent = byId[item['parentId']?.toString()];
      if (parent == null) {
        roots.add(item);
      } else {
        (parent[childrenKey] as List).add(item);
      }
    }
    void sort(List<JsonMap> group) {
      group.sort(
        (a, b) => (int.tryParse(a['displayOrder']?.toString() ?? '') ?? 0)
            .compareTo(int.tryParse(b['displayOrder']?.toString() ?? '') ?? 0),
      );
      for (final item in group) {
        sort((item[childrenKey] as List).cast<JsonMap>());
      }
    }

    sort(roots);
    return roots;
  }

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      await prepareNativeLaunch();
      _settingsReference = jsonDecode(
        await rootBundle.loadString('assets/reference/settings.json'),
      ) as JsonMap;
      settings = mergeSettings(
        Map<String, dynamic>.from(_settingsReference['defaults']),
        settings,
      );
      final saved = await _secure.read(key: 'activeSession');
      if (saved != null) {
        final session = jsonDecode(saved) as JsonMap;
        serverUrl = session['server'];
        _storageId = session['storageId'];
        _api = ApiClient(serverUrl);
        api.token = await _secure.read(key: 'token:$_storageId');
        if (api.token != null) {
          await _openLedger(_storageId);
          locked = await _secure.read(key: 'pin:$_storageId') != null;
        }
      }
      await _loadLanguage();
      if (_api != null) {
        await _restoreTimeZone();
      }
      _connectivity = Connectivity().onConnectivityChanged.listen((result) {
        if (authenticated &&
            !locked &&
            !result.contains(ConnectivityResult.none)) {
          unawaited(refresh());
        }
      });
      _deepLinks = _links.uriLinkStream.listen(
        (uri) => unawaited(_handleLink(uri)),
      );
      await _checkShares();
      final initialLink = await _links.getInitialLink();
      if (initialLink != null) await _handleLink(initialLink);
    } catch (e) {
      error = e.toString();
    }
    initialized = true;
    notifyListeners();
    unawaited(_updateHomeWidgets());
    if (authenticated && !locked) unawaited(refresh());
  }

  Future<void> prepareNativeLaunch() async {
    if (_nativeLaunchPrepared) return;
    _nativeLaunchPrepared = true;
    _native.setMethodCallHandler((call) async {
      if (call.method == 'sharedImages') await _checkShares();
      if (call.method == 'openRoute') {
        _queueNativeRoute(call.arguments);
        if (call.arguments == '/transaction/add') {
          await WidgetsBinding.instance.endOfFrame;
          await _native.invokeMethod<void>('revealQuickAdd');
        }
      }
    });
    try {
      _queueNativeRoute(
        await _native.invokeMethod<String>('consumeLaunchRoute'),
      );
    } on MissingPluginException {
      // Non-Android hosts do not expose launcher entries.
    }
    notifyListeners();
  }

  void _queueNativeRoute(dynamic route) {
    if (route == '/transaction/add') {
      _pendingNativeRoute =
          '/transaction/add?launcher=true&noTransactionDraft=true';
      notifyListeners();
    } else if (route == '/') {
      _pendingNativeRoute = '/?homeLaunch=${++_homeLaunchId}';
      notifyListeners();
    }
  }

  void updatePendingQuickAddAmount(int amount) {
    if (!pendingQuickAdd) {
      return;
    }
    _pendingNativeRoute =
        '/transaction/add?launcher=true&noTransactionDraft=true&amount=$amount&quickAmount=true';
  }

  String? takePendingNativeRoute() {
    final route = _pendingNativeRoute;
    _pendingNativeRoute = null;
    return route;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused &&
        settings['applicationLock'] == true) {
      locked = true;
      notifyListeners();
    }
    if (state == AppLifecycleState.resumed && authenticated && !locked) {
      unawaited(refresh());
    }
  }

  Future<void> connect(String address) async {
    final normalized = normalizeServerUrl(address);
    if (authenticated && normalized != serverUrl) {
      throw StateError('Sign out before connecting to another server');
    }
    final client = authenticated ? api : ApiClient(normalized);
    if (!authenticated) {
      client.timeZoneName =
          (await FlutterTimezone.getLocalTimezone()).identifier;
    }
    final result = await client.clientConfiguration();
    final pending = await _secure.read(key: 'oauthPending');
    if ((serverUrl.isNotEmpty && normalized != serverUrl) ||
        (pending != null && jsonDecode(pending)['server'] != normalized)) {
      await cancelAuthentication();
    }
    serverUrl = client.serverUrl;
    _api = client;
    config = result;
    error = null;
    await _secure.write(key: 'lastServer', value: serverUrl);
    notifyListeners();
  }

  Future<String?> lastServer() => _secure.read(key: 'lastServer');
  Future<void> cancelAuthentication() async {
    _authenticationAttempt++;
    _twoFactorToken = null;
    _oauthCallbackToken = null;
    if (!authenticated) _api?.token = null;
    error = null;
    await _secure.delete(key: 'oauthPending');
    notifyListeners();
  }

  void _checkAuthenticationAttempt(ApiClient client, int attempt) {
    if (!identical(client, _api) || attempt != _authenticationAttempt) {
      throw const ApiException('token is expired');
    }
  }

  Future<void> login(String loginName, String password) async {
    final client = api;
    await cancelAuthentication();
    final attempt = _authenticationAttempt;
    _checkAuthenticationAttempt(client, attempt);
    final result = Map<String, dynamic>.from(
      await client.post('authorize.json', {
        'loginName': loginName,
        'password': password,
      }),
    );
    _checkAuthenticationAttempt(client, attempt);
    await _acceptAuthentication(result);
  }

  Future<JsonMap> register(JsonMap data) async {
    final client = api;
    await cancelAuthentication();
    final attempt = _authenticationAttempt;
    _checkAuthenticationAttempt(client, attempt);
    final result = Map<String, dynamic>.from(
      await client.post('register.json', data),
    );
    _checkAuthenticationAttempt(client, attempt);
    if ((result['token'] as String?)?.isNotEmpty == true &&
        result['user'] is Map) {
      await _acceptAuthentication(result);
    }
    _receiveNotification(result['notificationContent']);
    notifyListeners();
    return result;
  }

  Future<void> completeTwoFactor(String code, {bool recovery = false}) async {
    if (_twoFactorToken == null) throw const ApiException('token is expired');
    final client = api, attempt = _authenticationAttempt;
    final old = client.token;
    client.token = _twoFactorToken;
    try {
      final data = await client.post(
        recovery ? '2fa/recovery.json' : '2fa/authorize.json',
        {recovery ? 'recoveryCode' : 'passcode': code},
      );
      client.token = old;
      _checkAuthenticationAttempt(client, attempt);
      await _acceptAuthentication(Map<String, dynamic>.from(data));
    } catch (_) {
      client.token = old;
      rethrow;
    }
  }

  Future<void> _acceptAuthentication(JsonMap result) async {
    if (result['need2FA'] == true) {
      _twoFactorToken = result['token'];
      notifyListeners();
      return;
    }
    final token = result['token']?.toString();
    if (token == null || result['user'] is! Map) {
      throw StateError('The server did not return a complete login session');
    }
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
    ) as JsonMap;
    final userId = claims['jti']?.toString();
    if (userId == null || userId == '0') {
      throw StateError('The login token does not identify a user');
    }
    final storageId = sha256
        .convert(utf8.encode('$serverUrl\n$userId'))
        .toString();
    if (_repository != null && _storageId != storageId) {
      _closing = true;
      try {
        await _refreshFuture;
        await _repository!.settle();
        if (pendingCount > 0) {
          throw StateError(
            'Synchronize or explicitly discard pending transactions before switching users',
          );
        }
        await _closeRepository();
        _repository = null;
        _shownNotifications.clear();
        _notifications.clear();
      } finally {
        _closing = false;
      }
    }
    _storageId = storageId;
    api.token = token;
    user = Map<String, dynamic>.from(result['user']);
    await _secure.write(key: 'token:$storageId', value: token);
    await _secure.write(
      key: 'activeSession',
      value: jsonEncode({'server': serverUrl, 'storageId': storageId}),
    );
    final currentConfig = Map<String, dynamic>.from(config);
    await _openLedger(storageId);
    if (result.containsKey('applicationCloudSettings')) {
      await applyCloudSettings(result['applicationCloudSettings']);
    }
    if (currentConfig.isNotEmpty) config = currentConfig;
    user = Map<String, dynamic>.from(result['user']);
    await _repository!.database.writeState('user', user);
    await _repository!.database.writeState('config', config);
    _twoFactorToken = null;
    _oauthCallbackToken = null;
    needsReauthentication = false;
    reauthenticationDeferred = false;
    locked = false;
    error = null;
    await _loadLanguage();
    _receiveNotification(result['notificationContent']);
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> _openLedger(String storageId) async {
    if (_repository != null) return;
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/ledgers/$storageId');
    await directory.create(recursive: true);
    var key = await _secure.read(key: 'database:$storageId');
    if (key == null) {
      key = List.generate(
        32,
        (_) => Random.secure().nextInt(256),
      ).map((n) => n.toRadixString(16).padLeft(2, '0')).join();
      await _secure.write(key: 'database:$storageId', value: key);
    }
    var deviceId = await _secure.read(key: 'deviceId');
    deviceId ??= const Uuid().v4();
    await _secure.write(key: 'deviceId', value: deviceId);
    final database = LedgerDatabase.encrypted(
      File('${directory.path}/ledger.sqlite'),
      key,
    );
    final repository = LedgerRepository(database, api, directory, deviceId)
      ..canEditTransaction = canEditTransaction
      ..changed = null;
    try {
      user = Map<String, dynamic>.from(
        await database.readState('user') ?? user,
      );
      settings = mergeSettings(
        Map<String, dynamic>.from(
          _settingsReference['defaults'] ?? _defaultSettings,
        ),
        Map<String, dynamic>.from(await database.readState('settings') ?? {}),
      );
      _cloudKeys
        ..clear()
        ..addAll(
          (await database.readState('cloudSyncKeys') as List? ?? [])
              .cast<String>(),
        );
      _pendingCloud
        ..clear()
        ..addAll(
          Map<String, String>.from(
            await database.readState('pendingCloudSettings') ?? {},
          ),
        );
      config = Map<String, dynamic>.from(
        await database.readState('config') ?? config,
      );
      settings['applicationLock'] =
          await _secure.read(key: 'pin:$storageId') != null;
      await repository.load();
      await _restoreTimeZone();
      repository.changed = _repositoryChanged;
      _repository = repository;
    } catch (_) {
      await repository.settle();
      await database.close();
      rethrow;
    }
  }

  Future<dynamic> get(String path, {JsonMap? query}) =>
      api.get(path, query: query);

  void _repositoryChanged() {
    notifyListeners();
    unawaited(_updateHomeWidgets());
  }

  Future<void> _updateHomeWidgets() async {
    try {
      if (_repository == null) {
        await _native.invokeMethod<void>('clearHomeWidgets');
        return;
      }
      Map<String, dynamic>? account(String id, List<JsonMap> rows) {
        for (final row in rows) {
          if ('${row['id']}' == id) return row;
          final found = account(
            id,
            (row['subAccounts'] as List? ?? []).cast<JsonMap>(),
          );
          if (found != null) return found;
        }
        return null;
      }

      BigInt amountOf(JsonMap item) {
        final amount = aggregateAmount(item['sourceAmount']);
        final from = account(
          '${item['sourceAccountId']}',
          accounts,
        )?['currency']?.toString();
        final to = formatter.defaultCurrency;
        if (amount == BigInt.zero || from == to) return amount;
        final cached = settings['cachedExchangeRates'];
        if (from == null || cached is! Map) {
          throw StateError('Exchange rate unavailable for home widget');
        }
        final table = Map<String, dynamic>.from(cached);
        final rates = <String, String>{
          '${table['baseCurrency']}': '1',
          for (final row in (table['exchangeRates'] as List? ?? []))
            if (row is Map) '${row['currency']}': '${row['rate']}',
        };
        if (!rates.containsKey(from) || !rates.containsKey(to)) {
          throw StateError('Exchange rate unavailable for home widget');
        }
        return BookkeepingFormatter.convertAggregate(
          amount,
          rates[from]!,
          rates[to]!,
          truncate: true,
        );
      }

      final originalTimezone =
          int.tryParse('${settings['timezoneUsedForStatisticsInHomePage']}') ==
          1;
      final now = formatter.localDate(DateTime.now().toUtc());
      final summary = buildWidgetMonthlySummary(
        transactions: transactions,
        now: now,
        dateOf: (item) =>
            formatter.transactionDate(item, originalTimezone: originalTimezone),
        amountOf: amountOf,
      );
      String amount(BigInt value) => formatter.amount(value);
      String yearOverYear(WidgetPeriodValues values) {
        final text = values.yearOverYear;
        if (text == null) return '—';
        return formatter.digits(
          text.replaceAll('.', formatter.decimalSeparator),
        );
      }

      await _native.invokeMethod<void>('updateHomeWidgets', {
        'year': now.year,
        'month': now.month,
        'incomeAmount': amount(summary.income.current),
        'incomeYearOverYear': yearOverYear(summary.income),
        'incomeYearOverYearAmount': amount(summary.income.difference.abs()),
        'incomeTrend': summary.income.trend,
        'expenseAmount': amount(summary.expense.current),
        'expenseYearOverYear': yearOverYear(summary.expense),
        'expenseYearOverYearAmount': amount(summary.expense.difference.abs()),
        'expenseTrend': summary.expense.trend,
        'totalAmount': amount(summary.total.current),
        'totalYearOverYear': yearOverYear(summary.total),
        'totalYearOverYearAmount': amount(summary.total.difference.abs()),
        'totalTrend': summary.total.trend,
      });
    } on MissingPluginException {
      // Controller business tests and non-Android hosts have no widget channel.
    } on PlatformException {
      // A launcher may be unavailable while the Flutter ledger stays usable.
    } on StateError {
      // Keep the last complete snapshot when a conversion rate is unavailable.
    } on FormatException {
      // Keep the last complete snapshot when cached rate data is malformed.
    }
  }

  Future<bool> refreshExchangeRates({
    bool force = false,
    bool automatic = false,
    int? now,
  }) async {
    if (automatic && settings['autoUpdateExchangeRatesData'] == false) {
      return false;
    }
    final current = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (!force && exchangeRatesCacheFresh(settings, current)) return false;
    final rates = await get('v1/exchange_rates/latest.json');
    settings['cachedExchangeRates'] = rates;
    settings['exchangeRatesCachedAt'] = current;
    await _persistSettings();
    notifyListeners();
    return true;
  }

  Future<void> updateSessionToken(String token) async {
    if (token.isEmpty || _repository == null) {
      throw StateError('No active session');
    }
    await _secure.write(key: 'token:$_storageId', value: token);
    api.token = token;
    notifyListeners();
  }

  Future<void> updateUser(JsonMap profile) async {
    user = Map.of(profile);
    await _repository?.database.writeState('user', user);
    await _loadLanguage();
    notifyListeners();
  }

  void _receiveNotification(dynamic content) {
    if (content is String &&
        content.trim().isNotEmpty &&
        _shownNotifications.add(content)) {
      _notifications.add(content);
    }
  }

  void dismissServerNotification() {
    if (_notifications.isNotEmpty) _notifications.removeAt(0);
    notifyListeners();
  }

  Future<dynamic> post(String path, JsonMap body) async {
    // Baseline-changing operations must not race queued account effects.
    if (authenticated &&
        RegExp(
          r'(accounts/|categories/|tags/|tag_groups/|templates/|clear|move_between|reconcile)',
        ).hasMatch(path)) {
      await _repository!.synchronize();
      if (pendingCount > 0) {
        throw StateError(
          'Resolve pending transactions before changing the ledger',
        );
      }
    }
    final result = await api.post(path, body);
    if (result is Map && result['user'] is Map) {
      user = Map<String, dynamic>.from(result['user']);
      await _repository?.database.writeState('user', user);
      if (result['newToken'] is String) {
        api.token = result['newToken'];
        await _secure.write(key: 'token:$_storageId', value: api.token);
      }
      await _loadLanguage();
      notifyListeners();
    }
    return result;
  }

  Future<void> refresh() =>
      _refreshFuture ??= _refresh().whenComplete(() => _refreshFuture = null);

  Future<void> refreshAfterMutation() async {
    // A refresh already in progress may have pulled the ledger before this
    // write. Finish it, then start a new pull that can observe the mutation.
    final active = _refreshFuture;
    if (active != null) await active;
    await refresh();
  }

  Future<void> _refresh() async {
    if (_repository == null || locked || needsReauthentication || _closing) {
      return;
    }
    try {
      final latestConfig = await api.clientConfiguration();
      config = latestConfig;
      final session = await api.refreshSession(saveToken: updateSessionToken);
      user = Map<String, dynamic>.from(session['user']);
      _receiveNotification(session['notificationContent']);
      await _repository!.database.writeState('config', config);
      await _repository!.database.writeState('user', user);
      await _loadLanguage();
      await _repository!.synchronize();
      error = null;
      await _flushCloudSettings();
      try {
        // The token response predates the upload above. Read current cloud
        // values so that it cannot overwrite the preference just acknowledged.
        await applyCloudSettings(
          await api.get('v1/users/settings/cloud/get.json'),
        );
      } catch (_) {
        /* Preserve local preferences if cloud settings are unavailable. */
      }
      try {
        final expiration =
            settings['exchangeRatesDataCacheExpiration'] as num? ?? 0;
        final storedAt = settings['exchangeRatesCachedAt'] as num? ?? 0;
        if (expiration > 0 &&
            DateTime.now().millisecondsSinceEpoch ~/ 1000 - storedAt >=
                expiration) {
          settings.remove('cachedExchangeRates');
        }
        await refreshExchangeRates(automatic: true);
        await _persistSettings();
      } catch (_) {
        /* Retain the last complete rate table for offline conversion. */
      }
    } catch (e) {
      error = e.toString();
      if (e is ApiException && e.unauthorized) needsReauthentication = true;
    }
    notifyListeners();
  }

  void continueOffline() {
    reauthenticationDeferred = true;
    notifyListeners();
  }

  void requestReauthentication() {
    reauthenticationDeferred = false;
    needsReauthentication = true;
    notifyListeners();
  }

  bool canEditTransaction(JsonMap data) => transactionCanBeEdited(
    transaction: data,
    user: user,
    accounts: accounts,
    formatter: formatter,
  );

  Future<void> saveTransaction(JsonMap data) async {
    if (_closing) throw StateError('Sign-out is in progress');
    await _repository!.saveTransaction(data);
    unawaited(refresh());
  }

  Future<void> deleteTransaction(String id) async {
    if (_closing) throw StateError('Sign-out is in progress');
    await _repository!.deleteTransaction(id);
    unawaited(refresh());
  }

  Future<void> resolveConflict(String id, bool useLocal) async {
    await _repository!.resolveConflict(id, useLocal);
    unawaited(refresh());
  }

  Future<JsonMap> stagePicture(String path) => _repository!.stagePicture(path);
  Future<String?> picturePath(String id) => _repository!.picturePath(id);
  Future<void> clearCache() => _repository!.clearCache();
  Future<JsonMap> cacheStatistics() async {
    final repository = _repository;
    if (repository == null) return {'pictureCount': 0, 'pictureBytes': 0};
    final cache = Directory('${repository.directory.path}/cache');
    var count = 0, bytes = 0;
    if (await cache.exists()) {
      await for (final entity in cache.list(followLinks: false)) {
        if (entity is File) {
          count++;
          bytes += await entity.length();
        }
      }
    }
    return {'pictureCount': count, 'pictureBytes': bytes};
  }

  Future<void> _checkShares() async {
    final files =
        await _native.invokeListMethod<String>('readShareFiles') ?? [];
    hasSharedPictures = files.isNotEmpty;
    final shareError = await _native.invokeMethod<String>('readShareError');
    _receiveNotification(shareError);
    notifyListeners();
  }

  Future<List<JsonMap>> takeSharedPictures({
    int maxCount = 10,
    Future<void> Function(List<JsonMap>)? beforeAcknowledge,
  }) async {
    if (!authenticated) return [];
    final inbox =
        await _native.invokeListMethod<String>('readShareFiles') ?? [];
    final files = inbox.take(max(0, maxCount)).toList();
    final results = <JsonMap>[];
    for (final path in files) {
      final key = 'shared:${sha256.convert(utf8.encode(path))}';
      var picture = await _repository!.database.readState(key);
      if (picture == null) {
        picture = await stagePicture(path);
        await _repository!.database.writeState(key, picture);
      }
      results.add(Map<String, dynamic>.from(picture));
    }
    if (beforeAcknowledge != null) await beforeAcknowledge(results);
    await _native.invokeMethod<void>('acknowledgeShareFiles', files);
    await _checkShares();
    return results;
  }

  Future<void> setPreference(String key, Object? value) async {
    if (key == 'applicationLock') {
      throw StateError('Use the application lock setup to change the PIN');
    }
    settings[key] = value;
    if (key == 'cachedExchangeRates') {
      settings['exchangeRatesCachedAt'] =
          DateTime.now().millisecondsSinceEpoch ~/ 1000;
    }
    for (final cloudKey in _cloudKeys) {
      if (cloudKey == key || cloudKey.startsWith('$key.')) {
        _pendingCloud[cloudKey] = encodeCloudValue(
          settingValue(settings, cloudKey),
        );
      }
    }
    await _repository?.database.writeState(
      'pendingCloudSettings',
      _pendingCloud,
    );
    await _persistSettings();
    if (key == 'language') await _loadLanguage();
    if (key == 'timeZone') {
      api.timeZoneName = (value as String?)?.isNotEmpty == true
          ? value as String
          : (await FlutterTimezone.getLocalTimezone()).identifier;
    }
    notifyListeners();
    unawaited(_flushCloudSettings());
  }

  Future<void> _persistSettings() async {
    final saved = Map<String, dynamic>.from(settings);
    if ((settings['exchangeRatesDataCacheExpiration'] as num? ?? 0) < 0) {
      saved.remove('cachedExchangeRates');
    }
    await _repository?.database.writeState('settings', saved);
    unawaited(_updateHomeWidgets());
  }

  Future<void> configureCloudSyncKeys(Iterable<String> keys) async {
    await _cloudWrite;
    _cloudKeys
      ..clear()
      ..addAll(
        keys.where(
          (key) =>
              (_settingsReference['cloudTypes'] as Map? ?? {}).containsKey(key),
        ),
      );
    _pendingCloud.removeWhere((key, _) => !_cloudKeys.contains(key));
    await _repository?.database.writeState(
      'cloudSyncKeys',
      _cloudKeys.toList(),
    );
    await _repository?.database.writeState(
      'pendingCloudSettings',
      _pendingCloud,
    );
  }

  Future<void> applyCloudSettings(dynamic rows, {Set<String>? selected}) async {
    if (rows is! List && rows != false) return;
    if (selected == null) {
      await configureCloudSyncKeys(
        rows is List
            ? rows.whereType<Map>().map((row) => row['settingKey'].toString())
            : [],
      );
    }
    for (final row in rows is List ? rows.whereType<Map>() : <Map>[]) {
      final key = row['settingKey'].toString();
      if (selected != null && !selected.contains(key)) continue;
      if (selected == null && _pendingCloud.containsKey(key)) continue;
      final type = _settingsReference['cloudTypes']?[key];
      if (type == null) continue;
      try {
        putSetting(
          settings,
          key,
          decodeCloudValue(row['settingValue'].toString(), type.toString()),
        );
        if (selected != null) _pendingCloud.remove(key);
      } on FormatException {
        continue;
      }
    }
    await _repository?.database.writeState(
      'pendingCloudSettings',
      _pendingCloud,
    );
    await _persistSettings();
    notifyListeners();
  }

  Future<void> _flushCloudSettings() => _cloudWrite ??= _writeCloudSettings()
      .whenComplete(() => _cloudWrite = null);
  Future<void> _writeCloudSettings() async {
    if (_repository == null || _closing || locked || needsReauthentication) {
      return;
    }
    try {
      while (_pendingCloud.isNotEmpty) {
        final pending = Map.of(_pendingCloud);
        await api.post('v1/users/settings/cloud/update.json', {
          'fullUpdate': false,
          'settings': [
            for (final item in pending.entries)
              {'settingKey': item.key, 'settingValue': item.value},
          ],
        });
        for (final item in pending.entries) {
          if (_pendingCloud[item.key] == item.value) {
            _pendingCloud.remove(item.key);
          }
        }
        await _repository?.database.writeState(
          'pendingCloudSettings',
          _pendingCloud,
        );
      }
    } catch (_) {
      /* Retry saved setting changes on the next foreground refresh. */
    }
  }

  Future<void> logout({bool discardPending = false}) async {
    _closing = true;
    await cancelAuthentication();
    await _refreshFuture;
    await _repository?.settle();
    if (pendingCount > 0 && !discardPending) {
      _closing = false;
      throw StateError(
        'Synchronize your pending transactions or explicitly discard them before signing out',
      );
    }
    if (discardPending) {
      await _repository?.database.customStatement('DELETE FROM operations');
    }
    try {
      await api.get('logout.json');
    } catch (_) {
      /* Local sign-out remains available offline. */
    }
    await _secure.delete(key: 'token:$_storageId');
    await _secure.delete(key: 'activeSession');
    await _closeRepository();
    _repository = null;
    api.token = null;
    user = {};
    settings = mergeSettings(
      Map<String, dynamic>.from(
        _settingsReference['defaults'] ?? _defaultSettings,
      ),
      {},
    );
    _cloudKeys.clear();
    _pendingCloud.clear();
    _shownNotifications.clear();
    _notifications.clear();
    locked = false;
    needsReauthentication = false;
    reauthenticationDeferred = false;
    _closing = false;
    notifyListeners();
    unawaited(_updateHomeWidgets());
  }

  Future<void> _restoreTimeZone() async {
    final selected = settings['timeZone']?.toString() ?? '';
    api.timeZoneName = selected.isNotEmpty
        ? selected
        : (await FlutterTimezone.getLocalTimezone()).identifier;
  }

  Future<void> _closeRepository() async {
    await _refreshFuture;
    await _cloudWrite;
    final repository = _repository;
    if (repository == null) return;
    repository.changed = null;
    await repository.settle();
    await repository.database.close();
  }

  Future<void> _loadLanguage() async {
    var language =
        ((authenticated ? user['language'] : settings['language']) ??
                user['language'] ??
                Platform.localeName)
            .toString()
            .replaceAll('-', '_');
    if (language.startsWith('zh')) {
      language =
          language.contains('Hant') ||
              language.contains('TW') ||
              language.contains('HK')
          ? 'zh_Hant'
          : 'zh_Hans';
    } else if (language.startsWith('pt')) {
      language = 'pt_BR';
    } else {
      language = language.split('_').first;
    }
    try {
      _translations = jsonDecode(
        await rootBundle.loadString('assets/locales/$language.json'),
      );
    } catch (_) {
      language = 'en';
      _translations = jsonDecode(
        await rootBundle.loadString('assets/locales/en.json'),
      );
    }
    _languageTag = language.replaceAll('_', '-');
    _translations.addAll(
      jsonDecode(
        await rootBundle.loadString('assets/native_locales/$language.json'),
      ) as JsonMap,
    );
    if (_englishTranslations.isEmpty) {
      _englishTranslations = jsonDecode(
        await rootBundle.loadString('assets/locales/en.json'),
      );
      _englishTranslations.addAll(
        jsonDecode(await rootBundle.loadString('assets/native_locales/en.json'))
            as JsonMap,
      );
    }
    if (_formattingReference.isEmpty) {
      _formattingReference = jsonDecode(
        await rootBundle.loadString('assets/reference/formatting.json'),
      );
    }
    if (_api != null) api.language = language.replaceAll('_', '-');
  }

  String get languageTag => _languageTag;
  String errorText(Object error) => localizedErrorText(error, (key) => t(key));
  Locale get locale {
    final parts = _languageTag.split('-');
    return parts.length == 1
        ? Locale(parts.first)
        : parts.last.length == 4
        ? Locale.fromSubtags(languageCode: parts.first, scriptCode: parts.last)
        : Locale(parts.first, parts.last);
  }

  BookkeepingFormatter get formatter => BookkeepingFormatter(
    user: user,
    settings: settings,
    messages: _translations,
    reference: _formattingReference,
    language: _languageTag,
  );
  String t(
    String key, {
    Map<String, dynamic> parameters = const {},
    int? plural,
  }) => translateMessage(
    _translations,
    _englishTranslations,
    key,
    parameters: parameters,
    plural: plural,
  );

  Future<void> startOAuth() async {
    final client = api;
    await cancelAuthentication();
    final attempt = _authenticationAttempt;
    _checkAuthenticationAttempt(client, attempt);
    final verifier = base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    final state = const Uuid().v4();
    await _secure.write(
      key: 'oauthPending',
      value: jsonEncode({
        'server': serverUrl,
        'verifier': verifier,
        'state': state,
        'created': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    _checkAuthenticationAttempt(client, attempt);
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final uri = Uri.parse('${serverUrl}api/oauth2/native/start').replace(
      queryParameters: {
        'client_session_id': state,
        'code_challenge': challenge,
      },
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Cannot open the authentication browser');
    }
  }

  Future<void> _handleLink(Uri uri) async {
    if (_handlingOAuthCallback ||
        uri.scheme != 'net.ezbookkeeping.app' ||
        uri.host != 'oauth2' ||
        uri.path != '/callback') {
      return;
    }
    final pending = await _secure.read(key: 'oauthPending');
    if (pending == null) return;
    final data = jsonDecode(pending) as JsonMap;
    if (serverUrl.isNotEmpty && serverUrl != data['server']) return;
    final attempt = _authenticationAttempt;
    if (uri.queryParameters['state'] != data['state'] ||
        DateTime.now().millisecondsSinceEpoch - (data['created'] as int) >
            600000) {
      error = 'The login callback has expired';
      notifyListeners();
      return;
    }
    _handlingOAuthCallback = true;
    try {
      if (serverUrl != data['server']) await connect(data['server']);
      final client = api;
      _checkAuthenticationAttempt(client, attempt);
      final result = await client.post('oauth2/native/exchange.json', {
        'code': uri.queryParameters['code'],
        'codeVerifier': data['verifier'],
      });
      _checkAuthenticationAttempt(client, attempt);
      await _secure.delete(key: 'oauthPending');
      if (result['error'] is Map) {
        _oauthCallbackToken = null;
        error =
            result['error']['message']?.toString() ?? 'Authorization cancelled';
        notifyListeners();
        return;
      }
      _oauthCallbackToken = result['token'];
      await completeOAuth();
    } catch (e) {
      if (attempt == _authenticationAttempt) {
        error = e.toString();
        notifyListeners();
      }
    } finally {
      _handlingOAuthCallback = false;
    }
  }

  Future<void> completeOAuth({String? password, String? passcode}) async {
    if (_oauthCallbackToken == null) {
      throw const ApiException('token is expired');
    }
    final client = api, attempt = _authenticationAttempt;
    final old = client.token;
    client.token = _oauthCallbackToken;
    try {
      final result = await client.post('oauth2/authorize.json', {
        'password': ?password,
        'passcode': ?passcode,
      });
      client.token = old;
      _checkAuthenticationAttempt(client, attempt);
      await _acceptAuthentication(Map<String, dynamic>.from(result));
    } catch (_) {
      client.token = old;
      rethrow;
    }
  }

  Future<void> configureLock(String pin, {bool biometrics = false}) async {
    if (!RegExp(r'^\d{6,12}$').hasMatch(pin)) {
      throw const FormatException('Use a PIN with 6 to 12 digits');
    }
    if (biometrics &&
        (!await _localAuth.canCheckBiometrics ||
            (await _localAuth.getAvailableBiometrics()).isEmpty ||
            !await _localAuth.authenticate(
              localizedReason: t('Enable Application Lock'),
              biometricOnly: true,
            ))) {
      throw StateError(
        'Biometric authentication is unavailable or was canceled',
      );
    }
    final salt = List.generate(32, (_) => Random.secure().nextInt(256));
    final hash = await _pinHash(pin, salt);
    await _secure.write(
      key: 'pin:$_storageId',
      value: jsonEncode({
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
        'failures': 0,
        'blockedUntil': 0,
      }),
    );
    settings['applicationLock'] = true;
    settings['applicationLockWebAuthn'] = biometrics;
    await _persistSettings();
    notifyListeners();
  }

  Future<List<int>> _pinHash(String pin, List<int> salt) async =>
      (await Pbkdf2(
            macAlgorithm: Hmac.sha256(),
            iterations: 210000,
            bits: 256,
          ).deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt))
          .extractBytes();
  Future<bool> unlock({String? pin, bool biometric = false}) async {
    final encoded = await _secure.read(key: 'pin:$_storageId');
    if (encoded == null) {
      locked = false;
      notifyListeners();
      return true;
    }
    final data = jsonDecode(encoded) as JsonMap;
    bool success = false;
    if (biometric && settings['applicationLockWebAuthn'] == true) {
      success = await _localAuth.authenticate(
        localizedReason: t('Unlock'),
        biometricOnly: true,
      );
    } else if (pin != null) {
      if (DateTime.now().millisecondsSinceEpoch <
          (data['blockedUntil'] as int)) {
        throw StateError('Too many attempts. Please wait before trying again');
      }
      final expected = base64Decode(data['hash']);
      final actual = await _pinHash(pin, base64Decode(data['salt']));
      var difference = 0;
      for (var i = 0; i < expected.length; i++) {
        difference |= expected[i] ^ actual[i];
      }
      success = difference == 0;
      data['failures'] = success ? 0 : (data['failures'] as int) + 1;
      data['blockedUntil'] = success
          ? 0
          : DateTime.now().millisecondsSinceEpoch +
                ((data['failures'] as int) >= 5
                    ? min(300, 30 * (data['failures'] as int)) * 1000
                    : 0);
      await _secure.write(key: 'pin:$_storageId', value: jsonEncode(data));
    }
    if (success) {
      locked = false;
      notifyListeners();
      unawaited(refresh());
    }
    return success;
  }

  Future<void> disableLock(String pin) async {
    if (!await unlock(pin: pin)) throw StateError('Incorrect PIN');
    await _secure.delete(key: 'pin:$_storageId');
    settings['applicationLock'] = false;
    await _persistSettings();
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _closing = true;
    WidgetsBinding.instance.removeObserver(this);
    _connectivity?.cancel();
    _deepLinks?.cancel();
    unawaited(_closeRepository());
    super.dispose();
  }
}
