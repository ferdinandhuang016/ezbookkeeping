import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/api_client.dart';
import '../core/money.dart';
import '../core/transaction_ordering.dart';
import 'ledger_database.dart';

class LedgerRepository {
  LedgerRepository(this.database, this.api, this.directory, this.deviceId);
  final LedgerDatabase database;
  final ApiClient api;
  final Directory directory;
  final String deviceId;
  Future<void>? _sync;
  Future<void>? _pictureCacheReady;
  final _pictureDownloads = <String, Future<String?>>{};
  static const _uuid = Uuid();
  static const _entities = {
    'transactions': 'transaction',
    'accounts': 'account',
    'categories': 'category',
    'tags': 'tag',
    'tagGroups': 'tagGroup',
    'templates': 'template',
  };
  void Function()? changed;
  bool Function(JsonMap)? canEditTransaction;
  String? error;
  bool syncing = false;
  bool initialSyncComplete = false;
  int downloadedCount = 0;
  List<JsonMap> operations = [];
  List<JsonMap> transactions = [];
  Map<String, List<JsonMap>> metadata = {};
  List<JsonMap> get conflicts {
    final entries = <String, JsonMap>{};
    for (final operation in operations) {
      final id = operation['entityId'].toString();
      if (['conflict', 'rejected'].contains(operation['status'])) {
        entries.putIfAbsent(id, () => Map<String, dynamic>.from(operation));
      }
      if (entries.containsKey(id)) {
        entries[id]!['localData'] = operation['request']['data'];
        entries[id]!['localAction'] = operation['request']['action'];
        entries[id]!['canUseLocal'] = ![
          'deleted',
          'generation',
        ].contains(entries[id]!['response']?['reason']);
      }
    }
    return entries.values.toList();
  }

  Future<void> load() async {
    initialSyncComplete =
        await database.readState('initialSyncComplete') == true;
    operations = await database.operations();
    final remote = await database.entities('transaction');
    transactions = projectTransactions(remote, operations);
    metadata = {};
    for (final entry in _entities.entries.where(
      (e) => e.value != 'transaction',
    )) {
      metadata[entry.key] = await database.entities(entry.value);
    }
    // Apply pending transaction deltas to the last confirmed account balances.
    final deltas = <String, int>{};
    void apply(JsonMap t, int direction) {
      final type = t['type'];
      final source = t['sourceAccountId']?.toString() ?? '';
      final destination = t['destinationAccountId']?.toString() ?? '';
      final amount = (t['sourceAmount'] as num? ?? 0).toInt();
      if (type == 2) {
        deltas.update(
          source,
          (v) => v + direction * amount,
          ifAbsent: () => direction * amount,
        );
      }
      if (type == 3 || type == 4) {
        deltas.update(
          source,
          (v) => v - direction * amount,
          ifAbsent: () => -direction * amount,
        );
      }
      if (type == 4) {
        final target = (t['destinationAmount'] as num? ?? 0).toInt();
        deltas.update(
          destination,
          (v) => v + direction * target,
          ifAbsent: () => direction * target,
        );
      }
    }

    for (final t in remote) {
      apply(t, -1);
    }
    for (final t in transactions) {
      apply(t, 1);
    }
    JsonMap applyBalance(JsonMap account) => {
      ...account,
      'balance':
          (int.tryParse(account['balance']?.toString() ?? '') ?? 0) +
          (deltas[account['id']] ?? 0),
      if (account['subAccounts'] is List)
        'subAccounts': (account['subAccounts'] as List)
            .map((a) => applyBalance(Map<String, dynamic>.from(a)))
            .toList(),
    };
    metadata['accounts'] = metadata['accounts']!.map(applyBalance).toList();
    for (final account in metadata['accounts']!) {
      final children = metadata['accounts']!
          .where((child) => child['parentId'] == account['id'])
          .toList();
      if (children.isNotEmpty &&
          children.every((child) => child['currency'] == account['currency'])) {
        account['balance'] = children.fold<int>(
          0,
          (sum, child) => sum + (child['balance'] as int),
        );
      }
    }
    changed?.call();
  }

  static List<JsonMap> projectTransactions(
    List<JsonMap> remote,
    List<JsonMap> queued,
  ) {
    final byId = {
      for (final t in remote) t['id'].toString(): Map<String, dynamic>.from(t),
    };
    final invalidChains = queued
        .where(
          (operation) =>
              operation['status'] == 'conflict' &&
              [
                'deleted',
                'generation',
              ].contains(operation['response']?['reason']),
        )
        .map((operation) => operation['entityId'].toString())
        .toSet();
    for (final operation in queued) {
      final request = Map<String, dynamic>.from(operation['request']);
      final id = operation['entityId'].toString();
      // Keep invalidated input in the conflict queue, outside the effective
      // ledger. A server deletion/clear must not reappear in balances or charts.
      if (invalidChains.contains(id)) continue;
      if (request['action'] == 'delete') {
        byId.remove(id);
        continue;
      }
      byId[id] = {
        ...?byId[id],
        ...Map<String, dynamic>.from(request['data']),
        'id': id,
        'syncStatus': operation['status'],
        'editable': true,
      };
    }
    final result = byId.values.toList();
    result.sort(compareTransactionsNewestFirst);
    return result;
  }

  Future<void> saveTransaction(JsonMap data) async {
    if (!initialSyncComplete) {
      throw StateError(
        'Complete the initial synchronization before recording offline',
      );
    }
    final type = data['type'];
    if (![2, 3, 4].contains(type)) {
      throw const FormatException(
        'Balance adjustments require an online account operation',
      );
    }
    for (final key in ['sourceAmount', if (type == 4) 'destinationAmount']) {
      if (data[key] is! int || (data[key] as int).abs() > Money.maxAmount) {
        throw const FormatException('Amount value exceeds limitation');
      }
    }
    if ((data['sourceAccountId']?.toString() ?? '').isEmpty ||
        data['sourceAccountId'] == '0') {
      throw const FormatException('Choose an account');
    }
    if (type == 4 &&
        (data['destinationAccountId'] == data['sourceAccountId'] ||
            data['destinationAccountId'] == null ||
            data['destinationAccountId'] == '0')) {
      throw const FormatException('Choose a different destination account');
    }
    if ((data['comment']?.toString().length ?? 0) > 255) {
      throw const FormatException('Description is too long');
    }
    if ((data['tagIds'] as List? ?? []).length > 10 ||
        (data['pictureIds'] as List? ?? data['pictures'] as List? ?? [])
                .length >
            10) {
      throw const FormatException('At most 10 tags or pictures are allowed');
    }
    final id = data['id']?.toString() ?? 'local:${_uuid.v4()}';
    final existing = transactions.where((t) => t['id'] == id).firstOrNull;
    if (existing != null &&
        !(canEditTransaction?.call(existing) ??
            existing['editable'] != false)) {
      throw StateError('This transaction is not editable');
    }
    if (canEditTransaction != null && !canEditTransaction!(data)) {
      throw StateError(
        'The selected time or account is outside the transaction edit scope',
      );
    }
    final operationId = _uuid.v4();
    final body = <String, dynamic>{...data};
    body.remove('syncStatus');
    body.remove('version');
    body.remove('editable');
    body.remove('timeSequenceId');
    body['pictureIds'] ??= (body['pictures'] as List? ?? [])
        .map((p) => p['pictureId'])
        .toList();
    body.remove('pictures');
    body['tagIds'] ??= <String>[];
    body['comment'] ??= '';
    body['utcOffset'] ??= DateTime.now().timeZoneOffset.inMinutes;
    body['time'] ??= DateTime.now().millisecondsSinceEpoch ~/ 1000;
    body['destinationAccountId'] ??= '0';
    body['destinationAmount'] ??= 0;
    body['categoryId'] ??= '0';
    final request = <String, dynamic>{
      'deviceId': deviceId,
      'operationId': operationId,
      'generation': await database.readState('generation'),
      'baseVersion': existing?['version']?.toString() ?? '0',
      'action': existing == null ? 'create' : 'modify',
      if (existing != null) 'transactionId': id,
      'data': body,
    };
    await database.transaction(() async {
      final head = (await database.operations())
          .where((op) => op['entityId'] == id)
          .firstOrNull;
      if (head?['status'] == 'rejected') {
        await _replaceBlockedOperation(head!, data: body);
      } else {
        await database.enqueue(operationId, id, request);
      }
    });
    await load();
  }

  Future<void> deleteTransaction(String id) async {
    final existing = transactions.where((t) => t['id'] == id).firstOrNull;
    if (existing == null) return;
    if (!(canEditTransaction?.call(existing) ??
        existing['editable'] != false)) {
      throw StateError('This transaction is not editable');
    }
    final operationId = _uuid.v4();
    final request = <String, dynamic>{
      'deviceId': deviceId,
      'operationId': operationId,
      'generation': await database.readState('generation'),
      'baseVersion': existing['version']?.toString() ?? '0',
      'action': 'delete',
      'transactionId': id,
      'data': {'id': id},
    };
    await database.transaction(() async {
      final head = (await database.operations())
          .where((op) => op['entityId'] == id)
          .firstOrNull;
      if (head?['status'] == 'rejected') {
        await _replaceBlockedOperation(head!, delete: true);
      } else {
        await database.enqueue(operationId, id, request);
      }
    });
    await load();
  }

  Future<void> synchronize() =>
      _sync ??= _synchronize().whenComplete(() => _sync = null);
  Future<void> settle() async {
    try {
      await _sync;
    } catch (_) {
      /* Durable operations remain available for retry. */
    }
  }

  Future<void> _synchronize() async {
    syncing = true;
    error = null;
    changed?.call();
    try {
      while (true) {
        if (await database.readState('snapshotComplete') != true) {
          await _snapshot();
        }
        await _pull();
        if (await database.readState('snapshotComplete') == true) break;
      }
      await database.writeState('initialSyncComplete', true);
      await _push();
      await _pull();
    } catch (e) {
      error = e.toString();
      rethrow;
    } finally {
      syncing = false;
      await load();
    }
  }

  Future<void> _snapshot() async {
    String? page = await database.readState('snapshotPage') as String?;
    do {
      final result = Map<String, dynamic>.from(
        await api.get(
          'v1/sync/snapshot.json',
          query: {'count': 200, 'page_token': ?page},
        ),
      );
      if (result['resetRequired'] == true) {
        await _resetRemote(result['generation'].toString());
        page = null;
        continue;
      }
      await database.transaction(() async {
        for (final entry in _entities.entries) {
          for (final data in result[entry.key] as List? ?? []) {
            await database.upsert(entry.value, Map<String, dynamic>.from(data));
            downloadedCount++;
          }
        }
        await database.writeState(
          'generation',
          result['generation'].toString(),
        );
        await database.writeState('cursor', result['cursor'].toString());
        await database.writeState('userId', result['userId'].toString());
        page = result['nextPage'] as String?;
        await database.writeState('snapshotPage', page);
        await database.writeState(
          'snapshotComplete',
          result['hasMore'] != true,
        );
      });
      await load();
      if (result['hasMore'] != true) break;
      if (page == null) {
        throw StateError('Server omitted the snapshot continuation token');
      }
    } while (true);
  }

  Future<void> _resetRemote(String generation) async {
    await database.transaction(() async {
      for (final op in await database.operations()) {
        await database.updateOperation(
          op['id'],
          'conflict',
          response: {
            'status': 'conflict',
            'reason': 'generation',
            'generation': generation,
          },
        );
      }
      await database.customStatement('DELETE FROM entities');
      await database.writeState('snapshotComplete', false);
      await database.writeState('initialSyncComplete', false);
      await database.writeState('snapshotPage', null);
    });
  }

  Future<void> _pull() async {
    while (true) {
      final result = Map<String, dynamic>.from(
        await api.get(
          'v1/sync/changes.json',
          query: {
            'cursor': await database.readState('cursor') ?? '0',
            'generation': await database.readState('generation'),
            'count': 200,
          },
        ),
      );
      if (result['resetRequired'] == true) {
        await _resetRemote(result['generation'].toString());
        return;
      }
      await database.transaction(() async {
        for (final change in result['changes'] as List? ?? []) {
          if (change['deleted'] == true) {
            await database.remove(
              change['entity'],
              change['id'].toString(),
              version: change['version'].toString(),
            );
          } else {
            await database.upsert(
              change['entity'],
              Map<String, dynamic>.from(change['data']),
              version: change['version'].toString(),
            );
          }
        }
        await database.writeState('cursor', result['cursor'].toString());
      });
      if (result['hasMore'] != true) break;
    }
  }

  Future<void> _push() async {
    final blocked = <String>{};
    // Re-read after each acknowledgement: dependent operations acquire its version.
    while (true) {
      final queued = await database.operations();
      final candidate = queued
          .where((op) => !blocked.contains(op['entityId']))
          .firstOrNull;
      if (candidate == null) break;
      final id = candidate['entityId'].toString();
      if (!['pending', 'sending'].contains(candidate['status'])) {
        blocked.add(id);
        continue;
      }
      final request = Map<String, dynamic>.from(candidate['request']);
      if (candidate['status'] == 'pending') {
        final body = Map<String, dynamic>.from(request['data']);
        body['pictureIds'] = await _uploadPictures(
          (body['pictureIds'] as List? ?? []).cast<String>(),
        );
        request['data'] = body;
        // Freeze the exact wire request durably before the first network attempt.
        await database.updateOperation(
          candidate['id'],
          'sending',
          request: request,
        );
      }
      final result = Map<String, dynamic>.from(
        await api.post('v1/sync/push.json', request),
      );
      if (result['status'] == 'applied') {
        await database.transaction(() async {
          String remoteId = id;
          if (result['transaction'] is Map) {
            final remote = Map<String, dynamic>.from(result['transaction']);
            remoteId = remote['id'].toString();
            await database.upsert(
              'transaction',
              remote,
              version: result['version'].toString(),
            );
          } else if (request['action'] == 'delete') {
            await database.remove(
              'transaction',
              id,
              version: result['version'].toString(),
            );
          }
          await database.removeOperation(candidate['id']);
          for (final account in result['accounts'] as List? ?? []) {
            await database.upsert(
              'account',
              Map<String, dynamic>.from(account),
            );
          }
          await database.remapOperations(
            id,
            remoteId,
            result['version'].toString(),
          );
        });
      } else {
        await database.updateOperation(
          candidate['id'],
          result['status'] == 'conflict' ? 'conflict' : 'rejected',
          response: result,
        );
        blocked.add(id);
      }
      await load();
    }
  }

  Future<void> resolveConflict(String operationId, bool useLocal) async {
    await database.transaction(() async {
      final op = (await database.operations())
          .where((o) => o['id'] == operationId)
          .firstOrNull;
      if (op == null) return;
      if (!['conflict', 'rejected'].contains(op['status'])) {
        throw StateError('This operation is still awaiting acknowledgement');
      }
      final response = Map<String, dynamic>.from(op['response'] ?? {});
      if (response['transaction'] is Map) {
        await database.upsert(
          'transaction',
          Map<String, dynamic>.from(response['transaction']),
          version: response['version']?.toString(),
        );
      } else if (response['reason'] == 'deleted') {
        await database.remove(
          'transaction',
          op['entityId'],
          version:
              response['version']?.toString() ??
              op['request']['baseVersion'].toString(),
        );
      }
      if (useLocal) {
        await _replaceBlockedOperation(op);
      } else {
        // Discard the dependent local chain too; it was built on this version.
        await database.customStatement(
          'DELETE FROM operations WHERE entity_id=?',
          [op['entityId']],
        );
      }
    });
    await load();
  }

  // A rejected request is a durable server receipt and cannot be edited/reused.
  // Replace its blocked chain with the latest complete local input, in the head's
  // original queue position. Other transactions retain their relative order.
  Future<void> _replaceBlockedOperation(
    JsonMap op, {
    JsonMap? data,
    bool delete = false,
  }) async {
    final response = Map<String, dynamic>.from(op['response'] ?? {});
    final original = Map<String, dynamic>.from(op['request']);
    if (['deleted', 'generation'].contains(response['reason']) ||
        original['generation'] != await database.readState('generation')) {
      throw StateError(
        'This record was removed on the server; retain your notes and explicitly create a new transaction if needed',
      );
    }
    final chain = (await database.operations())
        .where((item) => item['entityId'] == op['entityId'])
        .toList();
    if (chain.first['id'] != op['id'] ||
        chain.skip(1).any((item) => item['status'] != 'pending')) {
      throw StateError(
        'Resolve the earlier operation for this transaction first',
      );
    }
    final latest = Map<String, dynamic>.from(chain.last['request']);
    final deleting = delete || (data == null && latest['action'] == 'delete');
    if (original['action'] == 'create' && deleting) {
      await database.customStatement(
        'DELETE FROM operations WHERE entity_id=?',
        [op['entityId']],
      );
      return;
    }
    final newId = _uuid.v4();
    final request = <String, dynamic>{
      ...original,
      'operationId': newId,
      // Rejections may omit a version. Retain the original precondition then;
      // a concurrent server edit must still cause a new conflict on retry.
      'baseVersion': response['version']?.toString() ?? original['baseVersion'],
      'action': deleting
          ? 'delete'
          : original['action'] == 'create'
          ? 'create'
          : 'modify',
      'data': deleting
          ? {'id': op['entityId']}
          : Map<String, dynamic>.from(data ?? latest['data']),
    };
    if (request['action'] == 'create') {
      request['baseVersion'] = '0';
      request.remove('transactionId');
      (request['data'] as JsonMap).remove('id');
    }
    await database.customStatement(
      'DELETE FROM operations WHERE entity_id=? AND id<>?',
      [op['entityId'], op['id']],
    );
    await database.customStatement(
      'UPDATE operations SET id=?,status=?,request=?,response=NULL WHERE id=?',
      [newId, 'pending', jsonEncode(request), op['id']],
    );
  }

  Future<JsonMap> stagePicture(String sourcePath) async {
    final id = 'local:${_uuid.v4()}';
    final pictures = Directory('${directory.path}/pictures');
    await pictures.create(recursive: true);
    final extension = await _pictureExtension(sourcePath);
    final target = '${pictures.path}/${id.substring(6)}.$extension';
    final partial = await File(sourcePath).copy('$target.partial');
    final handle = await partial.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
    await partial.rename(target);
    await database.customStatement(
      'INSERT INTO pictures(id,path) VALUES (?,?)',
      [id, target],
    );
    return {'pictureId': id, 'localPath': target};
  }

  Future<String> _pictureExtension(String path) async {
    final file = await File(path).open();
    late final List<int> bytes;
    try {
      bytes = await file.read(12);
    } finally {
      await file.close();
    }
    bool starts(List<int> signature) =>
        bytes.length >= signature.length &&
        List.generate(
          signature.length,
          (i) => bytes[i] == signature[i],
        ).every((v) => v);
    if (starts([0xff, 0xd8, 0xff])) return 'jpg';
    if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return 'png';
    if (starts(ascii.encode('GIF87a')) || starts(ascii.encode('GIF89a'))) {
      return 'gif';
    }
    if (starts(ascii.encode('RIFF')) &&
        bytes.length >= 12 &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'webp';
    }
    throw const FormatException(
      'Unsupported image format. Use JPEG, PNG, GIF or WebP',
    );
  }

  Future<List<String>> _uploadPictures(List<String> ids) async {
    final result = <String>[];
    for (final id in ids) {
      if (!id.startsWith('local:')) {
        result.add(id);
        continue;
      }
      final row = await database
          .customSelect(
            'SELECT path,remote_id FROM pictures WHERE id=?',
            variables: [Variable(id)],
          )
          .getSingle();
      var remoteId = row.readNullable<String>('remote_id');
      if (remoteId == null) {
        final path = row.read<String>('path');
        final extension = await _pictureExtension(path);
        final data = await api.post(
          'v1/transaction/pictures/upload.json',
          FormData.fromMap({
            'upload_id': id.substring(6),
            'picture': await MultipartFile.fromFile(
              path,
              filename: 'receipt.$extension',
              contentType: DioMediaType(
                'image',
                extension == 'jpg' ? 'jpeg' : extension,
              ),
            ),
          }),
        );
        remoteId = data['pictureId'].toString();
        await database.customStatement(
          'UPDATE pictures SET remote_id=? WHERE id=?',
          [remoteId, id],
        );
      }
      result.add(remoteId);
    }
    return result;
  }

  Future<String?> picturePath(String id) {
    final active = _pictureDownloads[id];
    if (active != null) return active;
    final download = _picturePath(id);
    _pictureDownloads[id] = download;
    return download.whenComplete(() {
      if (identical(_pictureDownloads[id], download)) {
        _pictureDownloads.remove(id);
      }
    });
  }

  Future<void> _preparePictureCache(Directory cache) async {
    // No download in this repository starts until the startup sweep completes.
    // A previous process can leave temporary files, but never a published image.
    await for (final entry in cache.list(followLinks: false)) {
      if (entry is File && entry.path.endsWith('.partial')) {
        await entry.delete();
      }
    }
  }

  Future<String?> _picturePath(String id) async {
    final row = await database
        .customSelect(
          'SELECT path FROM pictures WHERE id=? OR remote_id=?',
          variables: [Variable(id), Variable(id)],
        )
        .getSingleOrNull();
    if (row != null && await File(row.read<String>('path')).exists()) {
      return row.read<String>('path');
    }
    if (id.startsWith('local:')) return null;
    final cache = Directory('${directory.path}/cache');
    await cache.create(recursive: true);
    await (_pictureCacheReady ??= _preparePictureCache(cache));
    // Legacy unmarked paths may contain a killed streaming download. Only this
    // completed-file format can be reused without contacting the server.
    final legacy = '${cache.path}/${Uri.encodeComponent(id)}';
    final path = '$legacy.complete';
    if (await File(path).exists()) return path;
    String? original;
    for (final t in transactions) {
      for (final picture in t['pictures'] as List? ?? []) {
        if (picture['pictureId'] == id) {
          original = picture['originalUrl']?.toString();
        }
      }
    }
    if (original == null) return null;
    final server = Uri.parse(api.serverUrl);
    final uri = original.startsWith('http')
        ? Uri.parse(original)
        : server.resolve(original);
    if (uri.origin != server.origin) {
      throw StateError('The picture URL is outside the configured server');
    }
    final partial = File('${cache.path}/${_uuid.v4()}.partial');
    try {
      final bytes = await api.download(
        uri
            .replace(
              queryParameters: {...uri.queryParameters, 'token': api.token},
            )
            .toString(),
      );
      final handle = await partial.open(mode: FileMode.writeOnly);
      try {
        await handle.writeFrom(bytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
      await _pictureExtension(partial.path);
      await partial.rename(path);
      if (await File(legacy).exists()) await File(legacy).delete();
    } finally {
      if (await partial.exists()) await partial.delete();
    }
    return path;
  }

  Future<void> clearCache() async {
    final cache = Directory('${directory.path}/cache');
    if (await cache.exists()) await cache.delete(recursive: true);
    _pictureCacheReady = null;
  }
}
