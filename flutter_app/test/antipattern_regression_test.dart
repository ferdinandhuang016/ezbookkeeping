import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ezbookkeeping/core/api_client.dart';
import 'package:ezbookkeeping/core/app_controller.dart';
import 'package:ezbookkeeping/core/money.dart';
import 'package:ezbookkeeping/data/ledger_database.dart';
import 'package:ezbookkeeping/data/ledger_repository.dart';
import 'package:ezbookkeeping/features/statistics/statistics.dart';

final receiptBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9XcAAAAASUVORK5CYII=',
);

class _StatisticsApp extends AppController {
  @override
  List<JsonMap> get accounts => [
    {'id': '1', 'type': 1, 'currency': 'USD', 'balance': Money.maxAmount},
  ];
}

class _RatesApp extends AppController {
  int requests = 0;
  bool fail = false;
  JsonMap response = {
    'dataSource': 'fixture',
    'updateTime': 0,
    'baseCurrency': 'USD',
    'exchangeRates': <JsonMap>[],
  };

  @override
  Future<dynamic> get(String path, {JsonMap? query}) async {
    requests++;
    if (fail) throw StateError('offline');
    return Map<String, dynamic>.from(response);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'secure-storage failure cannot publish a partially opened ledger',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ebk-failed-ledger-test-',
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => directory.path,
      );
      final app = AppController(
        secure: _PinReadFailure({
          'activeSession': jsonEncode({
            'server': 'https://example.invalid/books/',
            'storageId': 'failed-ledger',
          }),
          'token:failed-ledger': 'token',
          'database:failed-ledger': List.filled(64, '0').join(),
          'deviceId': 'device',
        }),
      );
      try {
        await app.initialize();
        expect(app.initialized, true);
        expect(app.authenticated, false);
        expect(app.error, contains('secure storage unavailable'));
      } finally {
        app.dispose();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'large aggregate conversions retain exact positive and negative amounts',
    () {
      final app = _StatisticsApp();
      app.user = {'defaultCurrency': 'VND'};
      app.settings['cachedExchangeRates'] = {
        'baseCurrency': 'USD',
        'exchangeRates': [
          {'currency': 'VND', 'rate': '20000'},
        ],
      };
      final statistics = LedgerStatistics(app);
      expect(
        statistics.convert(Money.maxAmount, 'USD').toString(),
        '19999999999999980000',
      );
      expect(
        statistics.convert(-Money.maxAmount, 'USD').toString(),
        '-19999999999999980000',
      );
      final transactions = List.generate(
        3,
        (_) => <String, dynamic>{
          'type': 3,
          'sourceAccountId': '1',
          'categoryId': '2',
          'sourceAmount': Money.maxAmount,
        },
      );
      expect(
        statistics.sum(transactions, 3).toString(),
        '59999999999999940000',
      );
      expect(
        statistics.categorical(transactions, 2)['2'].toString(),
        '59999999999999940000',
      );
    },
  );

  test(
    'exchange-rate refresh honors freshness, automatic and force rules',
    () async {
      int at(int day, int hour) =>
          DateTime(2026, 9, day, hour).millisecondsSinceEpoch ~/ 1000;
      final now = at(15, 10);
      final app = _RatesApp();
      JsonMap table(int updateTime) => {
        'dataSource': 'old',
        'updateTime': updateTime,
        'baseCurrency': 'USD',
        'exchangeRates': <JsonMap>[],
      };

      app.settings['cachedExchangeRates'] = table(at(15, 1));
      app.settings['exchangeRatesCachedAt'] = at(14, 1);
      expect(await app.refreshExchangeRates(now: now), false);
      expect(app.requests, 0);

      app.settings['cachedExchangeRates'] = table(at(14, 1));
      app.settings['exchangeRatesCachedAt'] = at(15, 10);
      expect(await app.refreshExchangeRates(now: now), false);
      expect(app.requests, 0);

      app.settings['exchangeRatesCachedAt'] = at(14, 1);
      app.settings['autoUpdateExchangeRatesData'] = false;
      final retained = app.settings['cachedExchangeRates'];
      expect(await app.refreshExchangeRates(automatic: true, now: now), false);
      expect(app.requests, 0);
      expect(identical(app.settings['cachedExchangeRates'], retained), true);

      app.response['updateTime'] = now;
      expect(await app.refreshExchangeRates(now: now), true);
      expect(app.requests, 1);
      expect(app.settings['cachedExchangeRates']['dataSource'], 'fixture');
      expect(app.settings['exchangeRatesCachedAt'], now);

      expect(await app.refreshExchangeRates(force: true, now: now), true);
      expect(app.requests, 2);

      app.settings['cachedExchangeRates'] = table(at(14, 1));
      app.settings['exchangeRatesCachedAt'] = at(14, 1);
      app.fail = true;
      await expectLater(app.refreshExchangeRates(now: now), throwsStateError);
      expect(app.settings['cachedExchangeRates']['dataSource'], 'old');
    },
  );

  group('remote picture cache', () {
    late Directory directory;
    late LedgerDatabase database;
    late LedgerRepository repository;
    late _PictureTransport transport;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'ebk-picture-cache-test-',
      );
      database = LedgerDatabase(NativeDatabase.memory());
      transport = _PictureTransport();
      final dio = Dio()..httpClientAdapter = transport;
      repository = LedgerRepository(
        database,
        ApiClient('https://example.invalid/books/', transport: dio),
        directory,
        'test',
      );
      repository.transactions = [
        {
          'pictures': [
            {'pictureId': '123', 'originalUrl': 'pictures/123.png'},
          ],
        },
      ];
    });
    tearDown(() async {
      await database.close();
      final resolved = await directory.resolveSymbolicLinks();
      final temporary = await Directory.systemTemp.resolveSymbolicLinks();
      if (!resolved.startsWith(
        '$temporary${Platform.pathSeparator}ebk-picture-cache-test-',
      )) {
        throw StateError('Unexpected cache test cleanup path');
      }
      await directory.delete(recursive: true);
    });
    test(
      'an interrupted legacy download is never treated as a complete picture',
      () async {
        final partial = File('${directory.path}/cache/123');
        await partial.parent.create();
        await partial.writeAsBytes([0xff]);
        final result = await repository.picturePath('123');
        expect(await File(result!).readAsBytes(), receiptBytes);
        expect(transport.requests, 1);
      },
    );
    test('concurrent reads share one atomic picture download', () async {
      transport.release = Completer<void>();
      final first = repository.picturePath('123');
      final second = repository.picturePath('123');
      for (var i = 0; i < 100 && transport.requests == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(transport.requests, 1);
      transport.release!.complete();
      final results = await Future.wait([first, second]);
      expect(results[0], results[1]);
      expect(await File(results.first!).readAsBytes(), receiptBytes);
      expect(
        await Directory('${directory.path}/cache')
            .list()
            .where((entry) => entry.path.endsWith('.partial'))
            .isEmpty,
        true,
      );
    });
    test('failed downloads leave no reusable file and can retry', () async {
      transport.failure = StateError('interrupted');
      await expectLater(
        repository.picturePath('123'),
        throwsA(isA<ApiException>()),
      );
      final cache = Directory('${directory.path}/cache');
      expect(await cache.list().where((entry) => entry is File).isEmpty, true);
      transport.failure = null;
      final result = await repository.picturePath('123');
      expect(await File(result!).readAsBytes(), receiptBytes);
      expect(transport.requests, 2);
    });
  });
}

class _PictureTransport implements HttpClientAdapter {
  int requests = 0;
  Completer<void>? release;
  Object? failure;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (failure != null) throw failure!;
    if (release != null) await release!.future;
    return ResponseBody.fromBytes(
      receiptBytes,
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _PinReadFailure extends FlutterSecureStorage {
  const _PinReadFailure(this.values);

  final Map<String, String> values;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key.startsWith('pin:')) {
      throw StateError('secure storage unavailable');
    }
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
}
