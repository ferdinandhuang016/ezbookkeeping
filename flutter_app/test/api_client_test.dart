import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ezbookkeeping/core/api_client.dart';
import 'package:ezbookkeeping/core/formatting.dart';
import 'package:flutter_test/flutter_test.dart';

class TestAdapter implements HttpClientAdapter {
  TestAdapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => respond(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody response(Object? result, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(
        status == 200
            ? {'success': true, 'result': result}
            : {
                'success': false,
                'errorCode': 100001,
                'errorMessage': 'api not found',
              },
      ),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  test('email activation error preserves contextual resend fields for 400 and 200 envelopes', () async {
    final api = ApiClient('https://example.org/books/');
    for (final status in [400, 200]) {
      api.dio.httpClientAdapter = TestAdapter(
        (_) async => ResponseBody.fromString(
          jsonEncode({
            'success': false,
            'errorCode': 201020,
            'errorMessage': 'email is not verified',
            'context': {
              'email': 'fixture@example.test',
              'hasValidEmailVerifyToken': true,
            },
          }),
          status,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await expectLater(
        api.post('authorize.json', {
          'loginName': 'fixture',
          'password': 'fixture',
        }),
        throwsA(
          isA<ApiException>()
              .having((error) => error.code, 'code', 201020)
              .having((error) => error.context, 'context', {
                'email': 'fixture@example.test',
                'hasValidEmailVerifyToken': true,
              }),
        ),
      );
    }
  });
  test('cancelable recognition decodes non-2xx and failed envelopes without transport diagnostics', () async {
    final api = ApiClient('https://example.org/books/')
      ..token = 'fixture-token';
    final messages = jsonDecode(
      File('assets/locales/zh_Hans.json').readAsStringSync(),
    ) as Map;
    for (final status in [400, 200]) {
      api.dio.httpClientAdapter = TestAdapter((options) async {
        expect(
          options.uri.path,
          '/books/api/v1/llm/transactions/recognize_text.json',
        );
        expect(options.headers['Authorization'], 'Bearer fixture-token');
        expect(options.receiveTimeout, const Duration(minutes: 5));
        return ResponseBody.fromString(
          jsonEncode({
            'success': false,
            'errorCode': 200005,
            'errorMessage': 'failed to request third party api',
          }),
          status,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });
      try {
        await api.post(
          'v1/llm/transactions/recognize_text.json',
          {'text': 'fixture'},
          cancelToken: CancelToken(),
          receiveTimeout: const Duration(minutes: 5),
        );
        fail('Recognition must report the failed envelope');
      } on ApiException catch (error) {
        expect(error.status, status);
        expect(error.code, 200005);
        expect(error.message, 'failed to request third party api');
        expect(translateMessage(messages, {}, error.message), '请求第三方接口失败');
        expect(error.toString(), isNot(contains('DioException')));
      }
    }
    final cancel = CancelToken()..cancel('fixture cancellation');
    await expectLater(
      api.post('v1/llm/transactions/recognize_text.json', {
        'text': 'fixture',
      }, cancelToken: cancel),
      throwsA(
        isA<DioException>().having(CancelToken.isCancel, 'cancelled', true),
      ),
    );
  });
  test('export preserves CSV/TSV bytes and translates JSON errors delivered as bytes', () async {
    final api = ApiClient('https://example.org/books/')
      ..token = 'fixture-token';
    for (final format in ['csv', 'tsv']) {
      final exported = utf8.encode(
        format == 'csv'
            ? 'amount,comment\r\n100,午餐\r\n'
            : 'amount\tcomment\r\n100\t午餐\r\n',
      );
      api.dio.httpClientAdapter = TestAdapter((options) async {
        expect(options.uri.path, '/books/api/v1/data/export.$format');
        expect(options.headers['Authorization'], 'Bearer fixture-token');
        expect(options.queryParameters['max_time'], 0);
        return ResponseBody.fromBytes(
          exported,
          200,
          headers: {
            Headers.contentTypeHeader: [
              format == 'csv' ? 'text/csv' : 'text/tab-separated-values',
            ],
          },
        );
      });
      expect(
        await api.download('v1/data/export.$format', query: {'max_time': 0}),
        exported,
      );
    }
    for (final status in [400, 200]) {
      api.dio.httpClientAdapter = TestAdapter(
        (_) async => ResponseBody.fromString(
          jsonEncode({
            'success': false,
            'errorCode': 202001,
            'errorMessage': 'token is expired',
          }),
          status,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await expectLater(
        api.download('v1/data/export.csv'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.message, 'message', 'token is expired')
              .having((error) => error.unauthorized, 'unauthorized', true),
        ),
      );
    }
  });
  test('missing protocol endpoint has upgrade guidance, auth and network errors retain their cause', () async {
    final api = ApiClient('https://example.org/books/');
    api.dio.httpClientAdapter = TestAdapter(
      (_) async => response(null, status: 404),
    );
    await expectLater(
      api.clientConfiguration(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Upgrade the server'),
        ),
      ),
    );
    api.dio.httpClientAdapter = TestAdapter(
      (_) async => response(null, status: 401),
    );
    await expectLater(
      api.clientConfiguration(),
      throwsA(
        isA<ApiException>().having(
          (error) => error.unauthorized,
          'unauthorized',
          true,
        ),
      ),
    );
    api.dio.httpClientAdapter = TestAdapter(
      (options) async => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      ),
    );
    await expectLater(
      api.clientConfiguration(),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          'Cannot connect to the server',
        ),
      ),
    );
  });
  test(
    'protocol version is mandatory and deployment prefix is retained',
    () async {
      final api = ApiClient('https://example.org/books/');
      api.dio.httpClientAdapter = TestAdapter((options) async {
        expect(options.uri.path, '/books/api/client/config.json');
        return response({'syncProtocolVersion': 0});
      });
      await expectLater(api.clientConfiguration(), throwsStateError);
      api.dio.httpClientAdapter = TestAdapter(
        (_) async => response({'syncProtocolVersion': 1}),
      );
      expect((await api.clientConfiguration())['syncProtocolVersion'], 1);
    },
  );
  test(
    'token rotation waits for old requests and durable storage before revoking',
    () async {
      final api = ApiClient('https://example.org/books/')..token = 'old-token';
      final oldRequestStarted = Completer<void>();
      final finishOldRequest = Completer<void>();
      final saveStarted = Completer<void>();
      final finishSave = Completer<void>();
      final calls = <String>[];
      api.dio.httpClientAdapter = TestAdapter((options) async {
        calls.add(options.path);
        if (options.path == 'v1/old-request.json') {
          expect(options.headers['Authorization'], 'Bearer old-token');
          oldRequestStarted.complete();
          await finishOldRequest.future;
        } else if (options.path == 'v1/tokens/refresh.json') {
          expect(options.headers['Authorization'], 'Bearer old-token');
          return response({
            'newToken': 'new-token',
            'oldTokenId': 'old-id',
            'user': {'id': '9'},
            'notificationContent': 'server notice',
          });
        } else {
          expect(options.headers['Authorization'], 'Bearer new-token');
        }
        return response(true);
      });
      final old = api.get('v1/old-request.json');
      await oldRequestStarted.future;
      final refresh = api.refreshSession(
        saveToken: (token) async {
          expect(token, 'new-token');
          saveStarted.complete();
          await finishSave.future;
        },
      );
      final waiting = api.get('v1/new-request.json');
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['v1/old-request.json']);
      finishOldRequest.complete();
      await saveStarted.future;
      expect(calls, ['v1/old-request.json', 'v1/tokens/refresh.json']);
      expect(api.token, 'old-token');
      finishSave.complete();
      expect((await refresh)['notificationContent'], 'server notice');
      await Future.wait([old, waiting]);
      expect(calls, [
        'v1/old-request.json',
        'v1/tokens/refresh.json',
        'v1/tokens/revoke.json',
        'v1/new-request.json',
      ]);
    },
  );
  test('failed secure token storage leaves the old session usable', () async {
    final api = ApiClient('https://example.org/')..token = 'old-token';
    final calls = <String>[];
    api.dio.httpClientAdapter = TestAdapter((options) async {
      calls.add(options.path);
      return response({'newToken': 'new-token', 'oldTokenId': 'old-id'});
    });
    await expectLater(
      api.refreshSession(
        saveToken: (_) async => throw StateError('storage unavailable'),
      ),
      throwsStateError,
    );
    expect(api.token, 'old-token');
    expect(calls, ['v1/tokens/refresh.json']);
  });
}
