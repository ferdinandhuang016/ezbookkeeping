import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../core/app_controller.dart';
import '../../core/api_client.dart';
import '../../ui/common.dart' show RecordData;
import 'recognition_contract.dart';

RecordData mergeRecognitionDraft(
  RecordData draft,
  RecordData recognized,
  Iterable<String> editedFields,
) {
  final edited = editedFields.toSet();
  final merged = {...draft};
  for (final entry in recognized.entries) {
    if (!edited.contains(entry.key) &&
        !{'id', 'version', 'syncStatus'}.contains(entry.key)) {
      merged[entry.key] = entry.value;
    }
  }
  return merged;
}

class RecognitionDraft {
  RecognitionDraft({
    required this.app,
    required this.imageRecognition,
    required this.text,
    this.imagePath,
  }) : id = DateTime.now().microsecondsSinceEpoch.toString(),
       api = app.api,
       accountId = app.user['id']?.toString() ?? '',
       serverUrl = app.serverUrl;

  static final active = <String, RecognitionDraft>{};
  static String dataKey(String id) => 'aiRecognitionDraft:$id';
  static String metaKey(String id) => 'aiRecognitionMeta:$id';
  static Iterable<String> savedIds(AppController app) sync* {
    for (final entry in app.settings.entries) {
      if (!entry.key.startsWith('aiRecognitionMeta:') || entry.value is! Map) {
        continue;
      }
      final id = entry.key.substring('aiRecognitionMeta:'.length);
      if (app.settings[dataKey(id)] case final String data
          when data.isNotEmpty) {
        yield id;
      }
    }
  }

  final AppController app;
  final ApiClient api;
  final String accountId;
  final String serverUrl;
  final String id;
  final bool imageRecognition;
  final String text;
  final String? imagePath;
  final Completer<void> _draftReady = Completer<void>();
  Future<void> _writes = Future<void>.value();
  Future<void>? _running;
  CancelToken? _cancel;
  bool _stopped = false;

  String get draftKey => dataKey(id);
  String get metadataKey => metaKey(id);

  void start() {
    active[id] = this;
    unawaited(_running = _process());
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.catchError((_) {});
    return next;
  }

  Future<void> initialize(RecordData data, String route) async {
    try {
      await _enqueue(() async {
        await app.setPreference(draftKey, jsonEncode(data));
        await app.setPreference(metadataKey, {
          'status': 'recognizing',
          'kind': imageRecognition ? 'image' : 'text',
          'route': route,
          'editedFields': <String>[],
        });
      });
      _draftReady.complete();
    } catch (error) {
      _draftReady.completeError(error);
      rethrow;
    }
  }

  Future<void> recordEdit(String field, dynamic value) {
    final encoded = jsonEncode(value);
    return _enqueue(() async {
      final meta = Map<String, dynamic>.from(app.settings[metadataKey] as Map);
      final edited =
          (meta['editedFields'] as List? ?? []).cast<String>().toSet()
            ..add(field);
      final draft = Map<String, dynamic>.from(
        jsonDecode(app.settings[draftKey] as String),
      );
      draft[field] = jsonDecode(encoded);
      await app.setPreference(metadataKey, {
        ...meta,
        'editedFields': edited.toList(),
      });
      await app.setPreference(draftKey, jsonEncode(draft));
    });
  }

  Future<void> persistEdited(RecordData data) {
    final snapshot = Map<String, dynamic>.from(jsonDecode(jsonEncode(data)));
    return _enqueue(() async {
      final meta = Map<String, dynamic>.from(app.settings[metadataKey] as Map);
      final edited = (meta['editedFields'] as List? ?? []).cast<String>();
      final saved = Map<String, dynamic>.from(
        jsonDecode(app.settings[draftKey] as String),
      );
      for (final field in edited) {
        saved[field] = snapshot[field];
      }
      await app.setPreference(draftKey, jsonEncode(saved));
    });
  }

  bool get _sameSession {
    try {
      return app.authenticated &&
          identical(app.api, api) &&
          app.user['id']?.toString() == accountId &&
          app.serverUrl == serverUrl;
    } catch (_) {
      return false;
    }
  }

  Future<void> _process() async {
    final cancel = _cancel = CancelToken();
    try {
      final timeZone = api.timeZone;
      final response = await api.post(
        imageRecognition
            ? 'v1/llm/transactions/recognize_receipt_image.json'
            : 'v1/llm/transactions/recognize_text.json',
        imageRecognition
            ? FormData.fromMap({
                'image': await MultipartFile.fromFile(imagePath!),
              })
            : {'text': text},
        receiveTimeout: const Duration(minutes: 5),
        cancelToken: cancel,
      );
      var recognized = recognizedTransaction(
        Map<String, dynamic>.from(response),
        timeZone,
      );
      await _draftReady.future;
      if (_stopped) return;
      if (!_sameSession || app.settings[metadataKey] == null) {
        dispose();
        return;
      }
      if (imagePath != null &&
          app.config['enableTransactionPictures'] == true &&
          app.settings['autoUploadTransactionPictureForAIRecognition'] ==
              true) {
        final picture = await app.stagePicture(imagePath!);
        recognized = {
          ...recognized,
          'pictures': [picture],
          'pictureIds': [picture['pictureId']],
        };
      }
      if (!_sameSession || app.settings[metadataKey] == null) {
        dispose();
        return;
      }
      await _enqueue(() async {
        if (_stopped || !_sameSession || app.settings[metadataKey] == null) {
          return;
        }
        final draft = Map<String, dynamic>.from(
          jsonDecode(app.settings[draftKey] as String),
        );
        final meta = Map<String, dynamic>.from(
          app.settings[metadataKey] as Map,
        );
        await app.setPreference(
          draftKey,
          jsonEncode(
            mergeRecognitionDraft(
              draft,
              recognized,
              (meta['editedFields'] as List? ?? []).cast<String>(),
            ),
          ),
        );
        await app.setPreference(metadataKey, {...meta, 'status': 'ready'});
      });
      dispose();
    } catch (error) {
      try {
        await _draftReady.future;
      } catch (_) {
        return;
      }
      if (_stopped) return;
      if (_sameSession && app.settings[metadataKey] != null) {
        await _enqueue(() async {
          final meta = Map<String, dynamic>.from(
            app.settings[metadataKey] as Map,
          );
          await app.setPreference(metadataKey, {
            ...meta,
            'status': 'failed',
            'error': app.errorText(error),
          });
        });
      } else {
        dispose();
      }
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }

  Future<void> retry() async {
    await _running;
    if (_stopped || _cancel != null) return;
    await _enqueue(() async {
      final meta = Map<String, dynamic>.from(app.settings[metadataKey] as Map);
      await app.setPreference(metadataKey, {
        ...meta,
        'status': 'recognizing',
        'error': null,
      });
    });
    unawaited(_running = _process());
  }

  Future<void> cancelRecognition() async {
    _stopped = true;
    _cancel?.cancel();
    await _enqueue(() async {
      final meta = Map<String, dynamic>.from(app.settings[metadataKey] as Map);
      await app.setPreference(metadataKey, {
        ...meta,
        'status': 'failed',
        'error': app.t('User Canceled'),
      });
    });
    dispose();
  }

  void dispose() {
    _stopped = true;
    if (!_draftReady.isCompleted) _draftReady.complete();
    _cancel?.cancel();
    active.remove(id);
    if (imagePath != null) {
      unawaited(File(imagePath!).delete().catchError((_) => File(imagePath!)));
    }
  }
}
