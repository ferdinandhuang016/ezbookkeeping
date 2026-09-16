import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ezbookkeeping/core/app_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  // This is a controller / SQLite / loopback API test, with no widget tree.
  HttpOverrides.global = null;

  test('clearing a ledger during an old refresh fetches the new generation before completing', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ebk-mutation-refresh-',
    );
    FlutterSecureStorage.setMockInitialValues({});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_timezone'),
      (_) async => 'UTC',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var generation = '1', blockRefresh = false, snapshotCount = 0;
    final refreshStarted = Completer<void>(), finishRefresh = Completer<void>();
    final user = {
      'uid': '7',
      'username': 'fixture',
      'language': 'en',
      'defaultCurrency': 'CNY',
      'transactionEditScope': 1,
    };
    final claims = base64Url
        .encode(utf8.encode(jsonEncode({'jti': '7'})))
        .replaceAll('=', '');
    final token = 'header.$claims.signature';
    final stream = server.listen((request) async {
      Object? result;
      final path = request.uri.path;
      await request.drain<void>();
      if (path.endsWith('client/config.json')) {
        if (blockRefresh) {
          blockRefresh = false;
          refreshStarted.complete();
          await finishRefresh.future;
        }
        result = {'syncProtocolVersion': 1};
      } else if (path.endsWith('/authorize.json')) {
        result = {'token': token, 'user': user};
      } else if (path.endsWith('/tokens/refresh.json')) {
        result = {'user': user};
      } else if (path.endsWith('/sync/snapshot.json')) {
        snapshotCount++;
        result = {
          'userId': '7',
          'generation': generation,
          'cursor': generation,
          'hasMore': false,
          'nextPage': null,
          'transactions': generation == '1'
              ? [
                  {
                    'id': '10',
                    'version': '1',
                    'type': 3,
                    'time': 1789434000,
                    'sourceAccountId': '1',
                    'sourceAmount': 100,
                    'categoryId': '3',
                    'tagIds': [],
                    'comment': 'Before clear',
                  },
                ]
              : [],
          'accounts': generation == '1'
              ? [
                  {
                    'id': '1',
                    'parentId': '0',
                    'balance': '900',
                    'currency': 'CNY',
                  },
                ]
              : [],
          'categories': [],
          'tags': [],
          'tagGroups': [],
          'templates': [],
        };
      } else if (path.endsWith('/sync/changes.json')) {
        result = {
          'generation': generation,
          'cursor': generation,
          'hasMore': false,
          'resetRequired':
              request.uri.queryParameters['generation'] != generation,
          'changes': [],
        };
      } else if (path.endsWith('/settings/cloud/get.json')) {
        result = false;
      } else if (path.endsWith('/exchange_rates/latest.json')) {
        result = {'baseCurrency': 'CNY', 'exchangeRates': []};
      } else if (path.endsWith('/data/clear/all.json')) {
        generation = '2';
        result = true;
      } else if (path.endsWith('/logout.json')) {
        result = true;
      } else {
        throw StateError('Unexpected API request $path');
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'success': true, 'result': result}));
      await request.response.close();
    });
    final controller = AppController();
    try {
      await controller.connect('http://127.0.0.1:${server.port}/books/');
      await controller.login('fixture', 'fixture-password');
      await controller.refresh();
      expect(controller.error, isNull);
      expect(controller.transactions, hasLength(1));
      blockRefresh = true;
      final oldRefresh = controller.refresh();
      await refreshStarted.future;
      await controller.post('v1/data/clear/all.json', {
        'password': 'fixture-password',
      });
      expect(controller.transactions, hasLength(1));
      final afterMutation = controller.refreshAfterMutation();
      finishRefresh.complete();
      await oldRefresh;
      await afterMutation;
      expect(controller.error, isNull);
      expect(controller.transactions, isEmpty);
      expect(controller.accounts, isEmpty);
      expect(snapshotCount, 2);
      controller.locked = true;
      await controller.refreshAfterMutation();
      expect(snapshotCount, 2);
      controller.locked = false;
    } finally {
      if (!finishRefresh.isCompleted) finishRefresh.complete();
      if (controller.authenticated) await controller.logout();
      controller.dispose();
      await stream.cancel();
      await server.close(force: true);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter_timezone'),
        null,
      );
      await directory.delete(recursive: true);
    }
  });
}
