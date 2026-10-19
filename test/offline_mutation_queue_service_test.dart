import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/offline_mutation_queue_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _primaryKey = 'pos_offline_mutation_queue_v1';
const _backupKey = 'pos_offline_mutation_queue_backup_v2';

QueuedMutation mutation(int index) => QueuedMutation(
  id: 'mutation-$index',
  type: OfflineMutationQueueService.createOrderType,
  storeId: 'store-1',
  payload: {
    'tableId': 'table-$index',
    'items': [
      {'menu_item_id': 'menu-1', 'quantity': 1},
    ],
  },
  createdAt: DateTime.utc(2026, 9, 19, 1, index),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('serializes concurrent enqueues without losing mutations', () async {
    final preferences = await SharedPreferences.getInstance();
    final queue = OfflineMutationQueueService(preferences: preferences);

    await Future.wait([
      for (var index = 0; index < 50; index++) queue.enqueue(mutation(index)),
    ]);

    final records = await queue.list();
    expect(records, hasLength(50));
    expect(records.map((entry) => entry.id).toSet(), hasLength(50));
  });

  test('migrates a valid legacy list on the next write', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _primaryKey,
      jsonEncode([mutation(1).toJson()]),
    );
    final queue = OfflineMutationQueueService(preferences: preferences);

    expect((await queue.list()).single.id, 'mutation-1');
    await queue.enqueue(mutation(2));

    final primary = jsonDecode(preferences.getString(_primaryKey)!);
    final backup = jsonDecode(preferences.getString(_backupKey)!);
    expect(primary['version'], 2);
    expect(primary['generation'], 1);
    expect(primary['records'], hasLength(2));
    expect(backup, primary);
  });

  test(
    'recovers from a damaged primary copy without dropping records',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final queue = OfflineMutationQueueService(preferences: preferences);
      await queue.enqueue(mutation(1));
      await preferences.setString(_primaryKey, '{damaged');

      final records = await queue.list();

      expect(records.single.id, 'mutation-1');
      expect(queue.lastRecoveryWarning, contains('primary'));

      await queue.enqueue(mutation(2));
      expect(
        preferences.getString(_primaryKey),
        preferences.getString(_backupKey),
      );
      expect(queue.lastRecoveryWarning, isNull);
    },
  );

  test(
    'throws instead of treating two damaged copies as an empty queue',
    () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_primaryKey, '{damaged');
      await preferences.setString(_backupKey, 'not-json');
      final queue = OfflineMutationQueueService(preferences: preferences);

      await expectLater(
        queue.list(),
        throwsA(isA<OfflineQueueCorruptionException>()),
      );
    },
  );

  test('detects checksum tampering in both durable copies', () async {
    final preferences = await SharedPreferences.getInstance();
    final queue = OfflineMutationQueueService(preferences: preferences);
    await queue.enqueue(mutation(1));

    final envelope = Map<String, dynamic>.from(
      jsonDecode(preferences.getString(_primaryKey)!) as Map,
    );
    final records = List<dynamic>.from(envelope['records'] as List);
    final record = Map<String, dynamic>.from(records.single as Map);
    record['storeId'] = 'tampered-store';
    records[0] = record;
    envelope['records'] = records;
    final tampered = jsonEncode(envelope);
    await preferences.setString(_primaryKey, tampered);
    await preferences.setString(_backupKey, tampered);

    await expectLater(
      queue.list(),
      throwsA(isA<OfflineQueueCorruptionException>()),
    );
  });

  test('a failed operation does not block later valid queue access', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_primaryKey, '{damaged');
    final queue = OfflineMutationQueueService(preferences: preferences);

    await expectLater(
      queue.list(),
      throwsA(isA<OfflineQueueCorruptionException>()),
    );
    await preferences.remove(_primaryKey);

    await queue.enqueue(mutation(1));
    expect((await queue.list()).single.id, 'mutation-1');
  });
}
