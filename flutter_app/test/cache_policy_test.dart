import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/core/api_client.dart';
import 'package:ezbookkeeping/core/cache_policy.dart';
import 'package:ezbookkeeping/data/ledger_database.dart';
import 'package:ezbookkeeping/data/ledger_repository.dart';

void main() {
  test('Original expiration options and exact-second boundaries', () {
    expect(mapCacheExpirations, [
      -1,
      86400,
      604800,
      2592000,
      7776000,
      15552000,
      31536000,
      0,
    ]);
    expect(exchangeRatesCacheExpirations, [-1, 86400, 604800, 2592000, 0]);
    for (final seconds in mapCacheExpirations.where((value) => value > 0)) {
      expect(cacheExpired(seconds, 1000, 1000 + seconds - 1), false);
      expect(cacheExpired(seconds, 1000, 1000 + seconds), true);
      expect(cacheExpired(seconds, 1000, 1000 + seconds + 1), true);
    }
    expect(cacheExpired(-1, 1000, 1000), true);
    expect(cacheExpired(0, 1000, 100000000), false);
    expect(cacheExpired(86400, 1000, 999), false);
  });

  test('Map expiration is available only for configured proxied tile maps', () {
    expect(canSetMapCacheExpiration({}), false);
    for (final provider in ['googlemap', 'amap', 'baidumap']) {
      expect(
        canSetMapCacheExpiration({
          'mapProvider': provider,
          'enableMapDataFetchProxy': true,
        }),
        false,
      );
    }
    expect(
      canSetMapCacheExpiration({
        'mapProvider': 'custom',
        'enableMapDataFetchProxy': true,
      }),
      true,
    );
    expect(
      canSetMapCacheExpiration({
        'mapProvider': 'openstreetmap',
        'enableMapDataFetchProxy': false,
      }),
      false,
    );
  });

  test('Absent caches are zero bytes and non-ASCII storage uses UTF-8', () {
    expect(serializedCacheBytes(null), 0);
    expect(serializedCacheBytes({}), 0);
    const cache = {'name': '汇率', 'rate': '7.123456789123456789'};
    expect(serializedCacheBytes(cache), utf8.encode(jsonEncode(cache)).length);
  });

  test(
    'Individual and file clear operations isolate their deletion targets',
    () async {
      const expected = {
        AppCache.pictures: {'pictures', 'decoded'},
        AppCache.map: {'webview', 'nativeMapCacheUpdated'},
        AppCache.customIcons: {'cachedCustomIconImages', 'decoded'},
        AppCache.files: {
          'pictures',
          'webview',
          'nativeMapCacheUpdated',
          'cachedCustomIconImages',
          'decoded',
        },
        AppCache.exchangeRates: {
          'cachedExchangeRates',
          'exchangeRatesCachedAt',
        },
        AppCache.all: {
          'pictures',
          'webview',
          'nativeMapCacheUpdated',
          'cachedCustomIconImages',
          'cachedExchangeRates',
          'exchangeRatesCachedAt',
          'decoded',
        },
      };
      for (final entry in expected.entries) {
        final touched = <String>[];
        await clearAppCaches(
          entry.key,
          clearPictures: () async {
            touched.add('pictures');
          },
          clearWebView: () async {
            touched.add('webview');
          },
          writePreference: (key, value) async {
            touched.add(key);
          },
          clearDecodedImages: () {
            touched.add('decoded');
          },
        );
        expect(touched.toSet(), entry.value, reason: entry.key.name);
        expect(
          touched.length,
          entry.value.length,
          reason: 'No duplicated clears',
        );
      }
    },
  );

  test(
    'Failed platform clear is reported and does not attempt unrelated deletion',
    () async {
      final touched = <String>[];
      await expectLater(
        clearAppCaches(
          AppCache.all,
          clearPictures: () async {
            touched.add('pictures');
          },
          clearWebView: () async {
            throw const FileSystemException('cache unavailable');
          },
          writePreference: (key, value) async {
            touched.add(key);
          },
          clearDecodedImages: () {
            touched.add('decoded');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(touched, isEmpty);
    },
  );

  test('All-cache clearing offline preserves persisted ledger, queue, staged images and preferences', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ezbookkeeping-cache-policy',
    );
    final databaseFile = File('${directory.path}/ledger.sqlite');
    var database = LedgerDatabase(NativeDatabase(databaseFile));
    final api = _OfflineApi();
    var repository = LedgerRepository(database, api, directory, 'offline-test');
    try {
      final settings = <String, dynamic>{
        'language': 'zh-Hans',
        'overviewAccountFilter': {'9223372036854775807': true},
        'cloudKeys': ['language'],
        'cachedExchangeRates': {
          'currency': 'USD',
          'exchangeRates': [
            {'currency': 'CNY', 'rate': '7.2'},
          ],
        },
        'exchangeRatesCachedAt': 1000,
        'cachedCustomIconImages': {
          '123': base64Encode([1, 2, 3]),
        },
        'nativeMapCacheUpdated': 1000,
      };
      await database.writeState('settings', settings);
      await database.writeState('user', {
        'id': '9',
        'nickname': 'Offline ledger',
      });
      await database.upsert('account', {
        'id': '1',
        'version': '1',
        'balance': '1000',
      });
      await database.upsert('transaction', {
        'id': '10',
        'version': '1',
        'time': 1700000000,
        'type': 3,
        'sourceAccountId': '1',
        'sourceAmount': 100,
      });
      await database.writeState('initialSyncComplete', true);
      await repository.load();
      final source = File('${directory.path}/receipt.jpg');
      const image = [0xff, 0xd8, 0xff, 0xe0];
      await source.writeAsBytes(image);
      final picture = await repository.stagePicture(source.path);
      await repository.saveTransaction({
        'time': 1700000001,
        'type': 3,
        'sourceAccountId': '1',
        'sourceAmount': 200,
        'categoryId': '3',
        'comment': '待上传',
        'pictureIds': [picture['pictureId']],
      });
      final beforeQueue = await database.operations();
      final beforeTransactions = await database.entities('transaction');
      final beforeAccounts = await database.entities('account');
      final remoteCache = Directory('${directory.path}/cache');
      await remoteCache.create();
      await File('${remoteCache.path}/downloaded-thumbnail').writeAsBytes([0]);
      final cleared = <String>[];
      await clearAppCaches(
        AppCache.all,
        clearPictures: repository.clearCache,
        clearWebView: () async {
          cleared.add('webview');
        },
        writePreference: (key, value) async {
          settings[key] = value;
          await database.writeState('settings', settings);
        },
        clearDecodedImages: () {
          cleared.add('decoded');
        },
      );
      expect(await remoteCache.exists(), false);
      expect(cleared, ['webview', 'decoded']);
      await database.close();
      database = LedgerDatabase(NativeDatabase(databaseFile));
      repository = LedgerRepository(database, api, directory, 'offline-test');
      await repository.load();
      expect(await database.operations(), beforeQueue);
      expect(await database.entities('transaction'), beforeTransactions);
      expect(await database.entities('account'), beforeAccounts);
      expect(repository.transactions, hasLength(2));
      expect(
        await repository.picturePath(picture['pictureId']),
        picture['localPath'],
      );
      expect(await File(picture['localPath']).readAsBytes(), image);
      expect(await database.readState('user'), {
        'id': '9',
        'nickname': 'Offline ledger',
      });
      final restored = await database.readState('settings') as Map;
      expect(restored['language'], 'zh-Hans');
      expect(restored['overviewAccountFilter'], {'9223372036854775807': true});
      expect(restored['cloudKeys'], ['language']);
      expect(restored['cachedExchangeRates'], isNull);
      expect(restored['cachedCustomIconImages'], isNull);
      expect(restored['nativeMapCacheUpdated'], 0);
      expect(restored['exchangeRatesCachedAt'], 0);
      expect(api.requests, 0);
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}

class _OfflineApi extends ApiClient {
  _OfflineApi() : super('https://example.invalid/');
  int requests = 0;
  @override
  Future<dynamic> get(String path, {JsonMap? query}) async {
    requests++;
    throw const SocketException('Offline');
  }
}
