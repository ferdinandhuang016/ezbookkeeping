import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/core/api_client.dart';
import 'package:ezbookkeeping/core/app_controller.dart';
import 'package:ezbookkeeping/features/system/recognition_draft.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super('https://example.test/');

  Completer<dynamic> response = Completer<dynamic>();

  @override
  Future<dynamic> post(
    String path,
    dynamic data, {
    CancelToken? cancelToken,
    Duration? receiveTimeout,
  }) => response.future;
}

class _FakeApp extends AppController {
  _FakeApp() {
    user = {'id': 'test-user'};
    serverUrl = 'https://example.test/';
  }

  final fakeApi = _FakeApi();

  @override
  ApiClient get api => fakeApi;

  @override
  bool get authenticated => true;

  @override
  Future<void> setPreference(String key, Object? value) async {
    settings[key] = value;
    notifyListeners();
  }
}

void main() {
  test(
    'AI result fills untouched draft fields without replacing manual edits',
    () {
      final draft = {
        'id': 'existing-transaction',
        'sourceAmount': 2500,
        'comment': 'Edited while recognizing',
        'categoryId': '0',
      };
      final recognized = {
        'id': 'unexpected-id',
        'sourceAmount': 1800,
        'comment': 'Receipt text',
        'categoryId': 'food',
      };

      expect(
        mergeRecognitionDraft(draft, recognized, {'sourceAmount', 'comment'}),
        {
          'id': 'existing-transaction',
          'sourceAmount': 2500,
          'comment': 'Edited while recognizing',
          'categoryId': 'food',
        },
      );
    },
  );

  test('recognition completes into saved draft after editor leaves', () async {
    final app = _FakeApp();
    final task = RecognitionDraft(
      app: app,
      imageRecognition: false,
      text: 'Lunch 18.50',
    );
    final ready = Completer<void>();
    app.addListener(() {
      if (app.settings[task.metadataKey] case {'status': 'ready'}) {
        if (!ready.isCompleted) ready.complete();
      }
    });

    task.start();
    await task.initialize({
      'sourceAmount': 0,
      'comment': '',
      'categoryId': '0',
    }, '/transaction/add');
    await task.recordEdit('comment', 'My note');
    await task.persistEdited({'comment': 'My note'});
    app.fakeApi.response.complete({
      'time': 1700000000,
      'sourceAmount': 1850,
      'comment': 'AI text',
      'categoryId': 'food',
    });

    await ready.future.timeout(const Duration(seconds: 5));
    expect(jsonDecode(app.settings[task.draftKey] as String), {
      'sourceAmount': 1850,
      'comment': 'My note',
      'categoryId': 'food',
      'time': 1700000000,
      'timeZone': 'Etc/UTC',
      'utcOffset': 0,
    });
  });

  test('failed recognition keeps draft and can retry', () async {
    final app = _FakeApp();
    final task = RecognitionDraft(
      app: app,
      imageRecognition: false,
      text: 'Lunch 18.50',
    );
    final failed = Completer<void>();
    final ready = Completer<void>();
    app.addListener(() {
      final status = (app.settings[task.metadataKey] as Map?)?['status'];
      if (status == 'failed' && !failed.isCompleted) failed.complete();
      if (status == 'ready' && !ready.isCompleted) ready.complete();
    });

    task.start();
    await task.initialize({'comment': 'Keep this'}, '/transaction/add');
    app.fakeApi.response.completeError(const ApiException('Temporary failure'));
    await failed.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('failed status not observed'),
    );
    expect(
      jsonDecode(app.settings[task.draftKey] as String)['comment'],
      'Keep this',
    );

    app.fakeApi.response = Completer<dynamic>();
    await task.retry();
    app.fakeApi.response.complete({'time': 1700000000, 'sourceAmount': 1850});
    await ready.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('ready status not observed'),
    );
    expect(
      jsonDecode(app.settings[task.draftKey] as String)['sourceAmount'],
      1850,
    );
  });
}
