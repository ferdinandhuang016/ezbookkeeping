import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/data/ledger_database.dart';

void main() {
  test(
    'encrypted database survives restart and rejects a different key',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ezbookkeeping-encrypted-',
      );
      final file = File('${directory.path}/ledger.sqlite');
      final key = List.filled(64, 'a').join();
      var database = LedgerDatabase.encrypted(file, key);
      await database.writeState('generation', '12');
      await database.enqueue('persistent-operation', 'local:1', {
        'operationId': 'persistent-operation',
        'action': 'create',
        'data': {'comment': 'private-financial-description'},
      });
      await database.close();
      final bytes = await file.readAsBytes();
      expect(
        String.fromCharCodes(bytes.take(16)),
        isNot(startsWith('SQLite format 3')),
      );
      expect(
        String.fromCharCodes(bytes).contains('private-financial-description'),
        false,
      );
      database = LedgerDatabase.encrypted(file, key);
      expect(await database.readState('generation'), '12');
      expect(
        (await database.operations()).single['id'],
        'persistent-operation',
      );
      await database.close();
      final wrongKey = LedgerDatabase.encrypted(
        file,
        List.filled(64, 'b').join(),
      );
      await expectLater(wrongKey.readState('generation'), throwsA(anything));
      await wrongKey.close();
      await directory.delete(recursive: true);
    },
  );
}
