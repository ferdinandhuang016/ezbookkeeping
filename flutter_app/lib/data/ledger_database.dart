import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../core/api_client.dart';

/// Explicit SQL keeps the journal schema and its atomic boundaries reviewable.
class LedgerDatabase extends GeneratedDatabase {
  LedgerDatabase(super.executor);

  factory LedgerDatabase.encrypted(File file, String key) => LedgerDatabase(
    NativeDatabase.createInBackground(
      file,
      setup: (db) {
        // Fail closed in release too: an ignored PRAGMA must never create plaintext.
        if (db.select('PRAGMA cipher').isEmpty) {
          throw StateError('Encrypted SQLite is unavailable');
        }
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
          throw StateError('Invalid database key');
        }
        db.execute("PRAGMA key = '$key'");
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );

  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement(
        'CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE entities (kind TEXT NOT NULL, id TEXT NOT NULL, version TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(kind,id))',
      );
      await customStatement(
        'CREATE TABLE operations (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, entity_id TEXT NOT NULL, status TEXT NOT NULL, request TEXT NOT NULL, response TEXT)',
      );
      await customStatement(
        'CREATE INDEX operations_entity ON operations(entity_id,seq)',
      );
      await customStatement(
        'CREATE TABLE pictures (id TEXT PRIMARY KEY, path TEXT NOT NULL, remote_id TEXT)',
      );
    },
  );

  Future<dynamic> readState(String key) async {
    final row = await customSelect(
      'SELECT value FROM state WHERE key=?',
      variables: [Variable(key)],
    ).getSingleOrNull();
    return row == null ? null : jsonDecode(row.read<String>('value'));
  }

  Future<void> writeState(String key, dynamic value) => customStatement(
    'INSERT OR REPLACE INTO state(key,value) VALUES (?,?)',
    [key, jsonEncode(value)],
  );
  Future<List<JsonMap>> entities(String kind) async =>
      (await customSelect(
            'SELECT data,version FROM entities WHERE kind=?',
            variables: [Variable(kind)],
          ).get())
          .map(
            (row) => <String, dynamic>{
              ...jsonDecode(row.read<String>('data')) as JsonMap,
              'version': row.read<String>('version'),
            },
          )
          .where((row) => row['_deleted'] != true)
          .toList();
  Future<void> upsert(String kind, JsonMap data, {String? version}) async {
    final id = (data['id'] ?? data['pictureId']).toString();
    final incoming = version ?? data['version']?.toString() ?? '0';
    final previous = await customSelect(
      'SELECT version FROM entities WHERE kind=? AND id=?',
      variables: [Variable(kind), Variable(id)],
    ).getSingleOrNull();
    if (previous != null &&
        BigInt.parse(previous.read<String>('version')) >=
            BigInt.parse(incoming)) {
      return;
    }
    await customStatement(
      'INSERT OR REPLACE INTO entities(kind,id,version,data) VALUES (?,?,?,?)',
      [kind, id, incoming, jsonEncode(data)],
    );
  }

  Future<void> remove(String kind, String id, {required String version}) =>
      upsert(kind, {'id': id, '_deleted': true}, version: version);
  Future<List<JsonMap>> operations() async =>
      (await customSelect('SELECT * FROM operations ORDER BY seq').get())
          .map(
            (row) => <String, dynamic>{
              'id': row.read<String>('id'),
              'entityId': row.read<String>('entity_id'),
              'status': row.read<String>('status'),
              'request': jsonDecode(row.read<String>('request')),
              'response': row.readNullable<String>('response') == null
                  ? null
                  : jsonDecode(row.read<String>('response')),
            },
          )
          .toList();
  Future<void> enqueue(String id, String entityId, JsonMap request) =>
      customStatement(
        'INSERT INTO operations(id,entity_id,status,request) VALUES (?,?,?,?)',
        [id, entityId, 'pending', jsonEncode(request)],
      );
  Future<void> updateOperation(
    String id,
    String status, {
    JsonMap? response,
    JsonMap? request,
  }) async {
    await customStatement(
      'UPDATE operations SET status=?,response=?${request == null ? '' : ',request=?'} WHERE id=?',
      [
        status,
        response == null ? null : jsonEncode(response),
        if (request != null) jsonEncode(request),
        id,
      ],
    );
  }

  Future<void> removeOperation(String id) =>
      customStatement('DELETE FROM operations WHERE id=?', [id]);
  Future<void> remapOperations(
    String localId,
    String remoteId,
    String version,
  ) async {
    final queued = await operations();
    for (final op in queued.where(
      (op) => op['entityId'] == localId && op['status'] == 'pending',
    )) {
      final request = Map<String, dynamic>.from(op['request']);
      request['transactionId'] = remoteId;
      request['baseVersion'] = version;
      if (request['data'] is Map) {
        request['data'] = {...request['data'] as Map, 'id': remoteId};
      }
      await customStatement(
        'UPDATE operations SET entity_id=?,request=? WHERE id=?',
        [remoteId, jsonEncode(request), op['id']],
      );
    }
  }
}
