import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ezbookkeeping/core/app_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('changing server discards temporary login credentials before any verification request', () async {
    FlutterSecureStorage.setMockInitialValues({});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_timezone'),
      (_) async => 'UTC',
    );
    final a = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final b = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final foreignAuthorization = <String?>[];
    final subscriptions = [
      for (final server in [a, b])
        server.listen((request) async {
          await request.drain<void>();
          Object? result;
          var success = true;
          if (request.uri.path.endsWith('config.json')) {
            result = {'syncProtocolVersion': 1};
          } else if (request.uri.path.endsWith('/2fa/authorize.json')) {
            foreignAuthorization.add(request.headers.value('authorization'));
            success = false;
          } else if (request.uri.path.endsWith('/authorize.json')) {
            result = {'token': 'temporary-server-a-token', 'need2FA': true};
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(
              success
                  ? {'success': true, 'result': result}
                  : {'success': false, 'errorMessage': 'token is invalid'},
            ),
          );
          await request.response.close();
        }),
    ];
    final app = AppController();
    try {
      await app.connect('http://127.0.0.1:${a.port}/books/');
      await app.login('fixture', 'fixture-password');
      expect(app.needsTwoFactor, true);
      await app.connect('http://127.0.0.1:${b.port}/books/');
      await expectLater(app.completeTwoFactor('123456'), throwsA(anything));
      expect(foreignAuthorization, isEmpty);
      expect(app.needsTwoFactor, false);
      expect(app.api.token, isNull);
    } finally {
      app.dispose();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await a.close(force: true);
      await b.close(force: true);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter_timezone'),
        null,
      );
    }
  });
  test('cancellation clears pending OAuth and rejects a late login response after server switch', () async {
    FlutterSecureStorage.setMockInitialValues({});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_timezone'),
      (_) async => 'UTC',
    );
    final a = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final b = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final loginStarted = Completer<void>();
    final releaseLogin = Completer<void>();
    final subscriptions = [
      for (final server in [a, b])
        server.listen((request) async {
          await request.drain<void>();
          Object result = {'syncProtocolVersion': 1};
          if (request.uri.path.endsWith('/authorize.json')) {
            loginStarted.complete();
            await releaseLogin.future;
            result = {'token': 'late-server-a-token', 'need2FA': true};
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'success': true, 'result': result}),
          );
          await request.response.close();
        }),
    ];
    final app = AppController();
    const secure = FlutterSecureStorage();
    try {
      await app.connect('http://127.0.0.1:${a.port}/books/');
      final pendingLogin = expectLater(
        app.login('fixture', 'fixture-password'),
        throwsA(anything),
      );
      await loginStarted.future;
      await secure.write(
        key: 'oauthPending',
        value: jsonEncode({
          'server': app.serverUrl,
          'state': 'fixture-pending-state',
        }),
      );
      await app.connect('http://127.0.0.1:${b.port}/books/');
      expect(await secure.read(key: 'oauthPending'), isNull);
      releaseLogin.complete();
      await pendingLogin;
      expect(app.needsTwoFactor, false);
      expect(app.needsOAuthVerification, false);
      expect(app.api.token, isNull);
      await secure.write(key: 'oauthPending', value: 'pending');
      await app.cancelAuthentication();
      expect(await secure.read(key: 'oauthPending'), isNull);
      await expectLater(
        app.completeOAuth(password: 'fixture'),
        throwsA(anything),
      );
    } finally {
      if (!releaseLogin.isCompleted) releaseLogin.complete();
      app.dispose();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await a.close(force: true);
      await b.close(force: true);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter_timezone'),
        null,
      );
    }
  });
}
