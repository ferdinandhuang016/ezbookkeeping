import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/core/api_client.dart';
import 'package:ezbookkeeping/data/ledger_database.dart';
import 'package:ezbookkeeping/data/ledger_repository.dart';

JsonMap transaction({
  String id = '10',
  String version = '1',
  int amount = 100,
  int type = 3,
}) => {
  'id': id,
  'version': version,
  'time': 1700000000,
  'type': type,
  'sourceAccountId': '1',
  'destinationAccountId': type == 4 ? '2' : '0',
  'sourceAmount': amount,
  'destinationAmount': type == 4 ? amount * 2 : 0,
  'categoryId': '3',
  'tagIds': <String>[],
  'comment': '',
  'editable': true,
};

class FakeApi extends ApiClient {
  FakeApi() : super('https://example.org/prefix/');
  final requests = <JsonMap>[];
  final changes = <JsonMap>[];
  bool dropResponse = false;
  bool conflict = false;
  bool rejectInvalidCategory = false;
  bool pagedSnapshot = false;
  bool failSnapshotPage = false;
  bool dropPictureResponse = false;
  final snapshotPages = <String?>[];
  final pictureRequests = <String>[];
  final pictureReceipts = <String, String>{};
  bool failPullAfterPush = false;
  int resetPulls = 0;
  String generation = '1';
  int sequence = 1;
  final receipts = <String, JsonMap>{};
  final remote = <String, JsonMap>{'10': transaction()};
  final balances = <String, int>{'1': 1000, '2': 3000};
  @override
  Future<dynamic> get(String path, {JsonMap? query}) async {
    if (path.contains('snapshot')) {
      snapshotPages.add(query?['page_token'] as String?);
      if (failSnapshotPage && query?['page_token'] == 'page-2') {
        failSnapshotPage = false;
        throw const ApiException('Snapshot connection lost');
      }
      final result = <String, dynamic>{
        'userId': '9',
        'generation': generation,
        'cursor': '1',
        'hasMore': false,
        'nextPage': null,
        'transactions': [transaction()],
        'accounts': [
          {'id': '1', 'balance': '1000', 'parentId': '0'},
          {'id': '2', 'balance': '3000', 'parentId': '0'},
        ],
        'categories': [
          {'id': '3', 'parentId': '0'},
        ],
        'tags': [],
        'tagGroups': [],
        'templates': [],
      };
      if (pagedSnapshot && query?['page_token'] == null) {
        result['transactions'] = [];
        result['hasMore'] = true;
        result['nextPage'] = 'page-2';
      }
      return result;
    }
    if (path.contains('changes')) {
      if (failPullAfterPush && requests.isNotEmpty) {
        throw const ApiException('Pull interrupted');
      }
      if (resetPulls > 0) {
        resetPulls--;
        generation = (int.parse(generation) + 1).toString();
      }
      return {
        'generation': generation,
        'cursor': sequence.toString(),
        'hasMore': false,
        'resetRequired': query?['generation'] != generation,
        'changes': changes,
      };
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<dynamic> post(
    String path,
    dynamic body, {
    CancelToken? cancelToken,
    Duration? receiveTimeout,
  }) async {
    if (path.contains('pictures/upload')) {
      final form = body as FormData;
      final uploadId = form.fields
          .firstWhere((item) => item.key == 'upload_id')
          .value;
      final picture = form.files.single.value;
      expect(picture.filename, 'receipt.png');
      expect(picture.contentType.toString(), 'image/png');
      pictureRequests.add(uploadId);
      final remoteId = pictureReceipts.putIfAbsent(uploadId, () => 'photo-1');
      if (dropPictureResponse) {
        dropPictureResponse = false;
        throw const ApiException('Picture receipt response lost');
      }
      return {'pictureId': remoteId};
    }
    if (!path.contains('push')) throw StateError('Unexpected POST $path');
    requests.add(jsonDecode(jsonEncode(body)) as JsonMap);
    if (rejectInvalidCategory && body['data']['categoryId'] == 'invalid') {
      return receipts.putIfAbsent(
        body['operationId'],
        () => {
          'status': 'rejected',
          'generation': generation,
          'error': {'message': 'Category is unavailable'},
        },
      );
    }
    if (conflict) {
      return {
        'status': 'conflict',
        'reason': 'modified',
        'generation': generation,
        'version': '9',
        'transaction': transaction(version: '9', amount: 500),
      };
    }
    final response = receipts.putIfAbsent(body['operationId'], () {
      sequence++;
      final id = body['transactionId'] ?? '100';
      void apply(JsonMap data, int direction) {
        final sign = data['type'] == 2 ? 1 : -1;
        balances.update(
          data['sourceAccountId'],
          (value) => value + direction * sign * (data['sourceAmount'] as int),
        );
        if (data['type'] == 4) {
          balances.update(
            data['destinationAccountId'],
            (value) => value + direction * (data['destinationAmount'] as int),
          );
        }
      }

      if (remote[id] != null) apply(remote[id]!, -1);
      if (body['action'] == 'delete') {
        remote.remove(id);
      } else {
        remote[id] = Map<String, dynamic>.from(body['data']);
        apply(remote[id]!, 1);
      }
      return {
        'status': 'applied',
        'generation': generation,
        'version': sequence.toString(),
        'accounts': [
          for (final account in balances.entries)
            {
              'id': account.key,
              'balance': account.value.toString(),
              'version': sequence.toString(),
              'parentId': '0',
            },
        ],
        if (body['action'] != 'delete')
          'transaction': {
            ...body['data'] as JsonMap,
            'id': body['transactionId'] ?? '100',
            'version': sequence.toString(),
          },
      };
    });
    if (dropResponse) {
      dropResponse = false;
      throw const ApiException('Response lost after commit');
    }
    return response;
  }
}

void main() {
  late LedgerDatabase db;
  late FakeApi api;
  late LedgerRepository repo;
  late Directory directory;
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    api = FakeApi();
    directory = await Directory.systemTemp.createTemp('ezbookkeeping-test-');
    repo = LedgerRepository(db, api, directory, 'device-1');
    await repo.synchronize();
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });
  test('loads server string balances and all snapshot metadata', () {
    expect(repo.initialSyncComplete, true);
    expect(repo.metadata['accounts']!.first['balance'], 1000);
    expect(repo.transactions.single['id'], '10');
  });
  test('new offline transactions enforce the current edit scope', () async {
    repo.canEditTransaction = (_) => false;
    await expectLater(
      repo.saveTransaction(transaction()..remove('id')),
      throwsStateError,
    );
    expect(await db.operations(), isEmpty);
  });
  test('snapshot resumes its durable page after interruption then catches up changes', () async {
    await db.customStatement('DELETE FROM state');
    await db.customStatement('DELETE FROM entities');
    api.pagedSnapshot = true;
    api.failSnapshotPage = true;
    api.snapshotPages.clear();
    api.changes.add({
      'entity': 'transaction',
      'id': '10',
      'version': '5',
      'data': transaction(version: '5', amount: 500),
      'deleted': false,
    });
    await expectLater(repo.synchronize(), throwsA(isA<ApiException>()));
    expect(repo.initialSyncComplete, false);
    await expectLater(
      repo.saveTransaction(transaction()..remove('id')),
      throwsStateError,
    );
    final restarted = LedgerRepository(db, api, directory, 'device-1');
    await restarted.synchronize();
    expect(api.snapshotPages, [null, 'page-2', 'page-2']);
    expect(restarted.initialSyncComplete, true);
    expect(restarted.transactions.single['sourceAmount'], 500);
    expect(restarted.transactions.single['version'], '5');
  });
  test('picture response loss retries its stable upload id after repository restart', () async {
    final source = File('${directory.path}/share');
    await source.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);
    final picture = await repo.stagePicture(source.path);
    await repo.saveTransaction({
      ...transaction()..remove('id'),
      'pictureIds': [picture['pictureId']],
    });
    api.dropPictureResponse = true;
    await expectLater(repo.synchronize(), throwsA(isA<ApiException>()));
    expect((await db.operations()).single['status'], 'pending');
    final restarted = LedgerRepository(db, api, directory, 'device-1');
    await restarted.synchronize();
    expect(api.pictureRequests.length, 2);
    expect(api.pictureRequests.first, api.pictureRequests.last);
    expect(api.pictureReceipts.length, 1);
    expect(api.requests.single['data']['pictureIds'], ['photo-1']);
    expect(await db.operations(), isEmpty);
    expect(await File(picture['localPath']).exists(), true);
  });
  test('acknowledged balances remain correct when pull fails then process restarts', () async {
    await repo.saveTransaction(transaction()..remove('id'));
    api.failPullAfterPush = true;
    await expectLater(repo.synchronize(), throwsA(isA<ApiException>()));
    final restarted = LedgerRepository(db, api, directory, 'device-1');
    await restarted.load();
    expect(restarted.operations, isEmpty);
    expect(restarted.metadata['accounts']!.first['balance'], 900);
    expect(restarted.transactions.length, 2);
  });
  test(
    'repeated generation changes never mark an incomplete snapshot complete',
    () async {
      api.resetPulls = 3;
      await repo.synchronize();
      expect(await db.readState('snapshotComplete'), true);
      expect(await db.readState('initialSyncComplete'), true);
      expect(await db.readState('generation'), '4');
    },
  );
  test(
    'local expense and cross currency transfer affect cached balances',
    () async {
      await repo.saveTransaction({
        ...transaction(id: 'local:x', type: 4, amount: 250)..remove('id'),
      });
      expect(repo.metadata['accounts']!.first['balance'], 750);
      expect(repo.metadata['accounts']!.last['balance'], 3500);
      expect(repo.transactions.length, 2);
      expect((await db.operations()).length, 1);
    },
  );
  test(
    'editing and deleting an existing transaction projects the difference only',
    () async {
      await repo.saveTransaction(transaction(amount: 400));
      expect(repo.metadata['accounts']!.first['balance'], 700);
      await repo.deleteTransaction('10');
      expect(repo.transactions, isEmpty);
      expect(repo.metadata['accounts']!.first['balance'], 1100);
    },
  );
  test('lost response retries the identical durable operation', () async {
    final item = transaction()..remove('id');
    await repo.saveTransaction(item);
    api.dropResponse = true;
    await expectLater(repo.synchronize(), throwsA(isA<ApiException>()));
    expect((await db.operations()).single['status'], 'sending');
    await repo.synchronize();
    expect(api.requests.length, 2);
    expect(api.requests[0], api.requests[1]);
    expect(api.receipts.length, 1);
    expect(await db.operations(), isEmpty);
  });
  test(
    'queued create then modify uses server id and acknowledged version',
    () async {
      await repo.saveTransaction(transaction()..remove('id'));
      final created = repo.transactions.firstWhere(
        (t) => t['id'].toString().startsWith('local:'),
      );
      await repo.saveTransaction({...created, 'sourceAmount': 250});
      await repo.synchronize();
      expect(api.requests[0]['action'], 'create');
      expect(api.requests[1]['transactionId'], '100');
      expect(api.requests[1]['baseVersion'], '2');
      expect(api.requests[1]['data']['sourceAmount'], 250);
    },
  );
  test(
    'conflict preserves local transaction and blocks dependent edits',
    () async {
      await repo.saveTransaction(transaction(amount: 200));
      await repo.saveTransaction(transaction(amount: 300));
      api.conflict = true;
      await repo.synchronize();
      expect(api.requests.length, 1);
      expect(repo.transactions.single['sourceAmount'], 300);
      final operations = await db.operations();
      expect(operations.first['status'], 'conflict');
      await repo.resolveConflict(operations.first['id'], false);
      expect(await db.operations(), isEmpty);
      expect(repo.transactions.single['sourceAmount'], 500);
    },
  );
  test('using local conflict resolution creates a new operation id', () async {
    await repo.saveTransaction(transaction(amount: 200));
    api.conflict = true;
    await repo.synchronize();
    final before = (await db.operations()).single;
    await repo.resolveConflict(before['id'], true);
    final after = (await db.operations()).single;
    expect(after['id'], isNot(before['id']));
    expect(after['request']['baseVersion'], '9');
    expect(after['request']['data']['sourceAmount'], 200);
  });
  test(
    'correcting a rejected edit replaces its blocked chain in original order',
    () async {
      api.rejectInvalidCategory = true;
      await repo.saveTransaction({
        ...transaction(amount: 200),
        'categoryId': 'invalid',
      });
      await repo.saveTransaction(transaction()..remove('id'));
      await repo.saveTransaction({
        ...transaction(amount: 300),
        'categoryId': 'invalid',
        'comment': 'latest note',
      });
      await repo.synchronize();
      final rejected = (await db.operations()).first;
      final latest = repo.transactions.firstWhere((t) => t['id'] == '10');
      await repo.saveTransaction({...latest, 'categoryId': '3'});
      final corrected = (await db.operations()).single;
      expect(corrected['id'], isNot(rejected['id']));
      expect(corrected['status'], 'pending');
      expect(corrected['request']['baseVersion'], '1');
      expect(corrected['request']['data']['sourceAmount'], 300);
      expect(corrected['request']['data']['comment'], 'latest note');
      await repo.synchronize();
      expect(await db.operations(), isEmpty);
      expect(api.remote['10']!['sourceAmount'], 300);
    },
  );
  test(
    'correcting a rejected create remains a create and keeps queue position',
    () async {
      api.rejectInvalidCategory = true;
      await repo.saveTransaction({
        ...transaction()..remove('id'),
        'categoryId': 'invalid',
      });
      await repo.synchronize();
      final rejected = (await db.operations()).single;
      await repo.saveTransaction(transaction(amount: 150));
      final local = repo.transactions.firstWhere(
        (t) => t['id'].toString().startsWith('local:'),
      );
      await repo.saveTransaction({
        ...local,
        'categoryId': '3',
        'sourceAmount': 250,
      });
      final queued = await db.operations();
      expect(queued.first['id'], isNot(rejected['id']));
      expect(queued.first['request']['action'], 'create');
      expect(queued.first['request']['baseVersion'], '0');
      expect(queued.first['request'].containsKey('transactionId'), false);
      expect(queued.last['entityId'], '10');
      await repo.synchronize();
      expect(await db.operations(), isEmpty);
      expect(api.remote['100']!['sourceAmount'], 250);
    },
  );
  test(
    'retrying a rejected edit without a response version preserves its base',
    () async {
      api.rejectInvalidCategory = true;
      await repo.saveTransaction({...transaction(), 'categoryId': 'invalid'});
      await repo.synchronize();
      final rejected = (await db.operations()).single;
      await repo.resolveConflict(rejected['id'], true);
      expect((await db.operations()).single['request']['baseVersion'], '1');
    },
  );
  test('local conflict resolution retains the latest dependent edit', () async {
    await repo.saveTransaction(transaction(amount: 200));
    await repo.saveTransaction({
      ...transaction(amount: 350),
      'comment': 'newest input',
    });
    api.conflict = true;
    await repo.synchronize();
    final conflict = (await db.operations()).first;
    expect(repo.conflicts.single['localData']['comment'], 'newest input');
    await repo.resolveConflict(conflict['id'], true);
    final resolved = (await db.operations()).single;
    expect(resolved['request']['baseVersion'], '9');
    expect(resolved['request']['data']['sourceAmount'], 350);
    expect(resolved['request']['data']['comment'], 'newest input');
  });
  test('deleting a rejected create cancels its whole local chain', () async {
    api.rejectInvalidCategory = true;
    await repo.saveTransaction({
      ...transaction()..remove('id'),
      'categoryId': 'invalid',
    });
    await repo.synchronize();
    final local = repo.transactions.firstWhere(
      (t) => t['id'].toString().startsWith('local:'),
    );
    await repo.deleteTransaction(local['id']);
    expect(await db.operations(), isEmpty);
    expect(repo.transactions.length, 1);
  });
  test('adopting a remote deletion records a tombstone', () async {
    await repo.saveTransaction(transaction(amount: 200));
    final op = (await db.operations()).single;
    await db.updateOperation(
      op['id'],
      'conflict',
      response: {
        'status': 'conflict',
        'reason': 'deleted',
        'version': '3',
        'generation': '1',
      },
    );
    await repo.resolveConflict(op['id'], false);
    expect(repo.transactions, isEmpty);
    await db.upsert('transaction', transaction(version: '2'));
    expect(await db.entities('transaction'), isEmpty);
  });
  test('generation reset retains pending content as conflict', () async {
    await repo.saveTransaction(transaction(amount: 200));
    api.generation = '2';
    await repo.synchronize();
    expect((await db.operations()).single['status'], 'conflict');
    expect((await db.operations()).single['response']['reason'], 'generation');
    expect(api.requests, isEmpty);
    expect(repo.transactions.single['sourceAmount'], 100);
    expect(repo.metadata['accounts']!.first['balance'], 1000);
    expect(repo.conflicts.single['localData']['sourceAmount'], 200);
  });
  test('old upserts and old tombstones cannot replace a newer state', () async {
    await db.upsert('transaction', transaction(version: '10', amount: 1000));
    await db.upsert('transaction', transaction(version: '2', amount: 200));
    await db.remove('transaction', '10', version: '3');
    expect((await db.entities('transaction')).single['sourceAmount'], 1000);
    await db.remove('transaction', '10', version: '11');
    await db.upsert('transaction', transaction(version: '9'));
    expect(await db.entities('transaction'), isEmpty);
  });
  test('database transaction rolls back an incomplete enqueue', () async {
    await expectLater(
      db.transaction(() async {
        await db.enqueue('rolled-back', '10', {'data': transaction()});
        throw StateError('Interrupted before commit');
      }),
      throwsStateError,
    );
    expect(await db.operations(), isEmpty);
  });
  test(
    'freezing a wire request is atomic if SQLite rejects the update',
    () async {
      await repo.saveTransaction(transaction(amount: 200));
      final before = (await db.operations()).single;
      await db.customStatement('''CREATE TRIGGER reject_freeze
      BEFORE UPDATE OF request ON operations
      BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END''');
      await expectLater(
        db.updateOperation(
          before['id'],
          'sending',
          request: {
            ...before['request'] as JsonMap,
            'data': transaction(amount: 250),
          },
        ),
        throwsA(anything),
      );
      final after = (await db.operations()).single;
      expect(after['status'], 'pending');
      expect(after['request'], before['request']);
    },
  );
  test(
    'cache clearing preserves pending ledger and staged image bytes',
    () async {
      final source = File('${directory.path}/receipt.jpg');
      await source.writeAsBytes([0xff, 0xd8, 0xff, 0xe0]);
      final picture = await repo.stagePicture(source.path);
      await repo.saveTransaction({
        ...transaction()..remove('id'),
        'pictureIds': [picture['pictureId']],
      });
      final cache = Directory('${directory.path}/cache');
      await cache.create();
      await File('${cache.path}/thumbnail').writeAsBytes([0]);
      await repo.clearCache();
      expect(await File(picture['localPath']).exists(), true);
      expect((await db.operations()).length, 1);
      expect(await cache.exists(), false);
    },
  );
  test(
    'staged files preserve their actual format independent of source filename',
    () async {
      final source = File('${directory.path}/shared-file');
      await source.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);
      final picture = await repo.stagePicture(source.path);
      expect(picture['localPath'], endsWith('.png'));
      await source.writeAsString('not an image');
      await expectLater(repo.stagePicture(source.path), throwsFormatException);
    },
  );
}
