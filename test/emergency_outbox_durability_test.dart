import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/emergency_web_bridge.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/kds_progress_journal.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _primaryKey = 'kds_command_outbox_v2';
const _backupKey = 'kds_command_outbox_backup_v2';

String payload(int index) => jsonEncode({
  'kind': 'complete_order',
  'queue_id': 'queue-$index',
  'action_id': 'action-$index',
});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'progress journal stays invisible to older outbox readers and keeps its intent time',
    () async {
      final store = KdsOutboxStore();
      final intent = {
        '_outbox_progress_journal': 1,
        '_outbox_actor_id': 'fixture-auth',
        'event_id': 'progress-1',
        'item_id': 'item-1',
        'queue_id': 'queue-1',
        'stage': 'floor_served',
        'delta': 1,
        '_outbox_store_id': 'store-1',
        '_outbox_session_id': 'session-1',
        '_outbox_created_at': 100,
      };
      await store.put(
        'progress-1',
        jsonEncode({...intent, '_outbox_phase': 'prepared'}),
      );
      expect(await EmergencyWebBridge.readOutbox(), isEmpty);
      await EmergencyWebBridge.putOutbox('legacy-1', payload(1));
      await store.put(
        'progress-1',
        jsonEncode({...intent, '_outbox_phase': 'queued'}),
      );
      final rows = await store.read();
      expect(rows.map((r) => r.id), ['progress-1', 'legacy-1']);
      expect(rows.first.createdAtEpochMs, 100);
      await store.delete('progress-1');
      expect((await EmergencyWebBridge.readOutbox()).single.id, 'legacy-1');
      expect(await EmergencyWebBridge.readProgressJournal(), isEmpty);
    },
  );

  test(
    'native progress capacity rejects a new command but allows updating an existing one',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final records = [
        for (var i = 0; i < 1000; i++)
          {'id': 'event-$i', 'payload': '{}', 'createdAt': i + 1},
      ];
      final unsigned = {'version': 2, 'generation': 1, 'records': records};
      final encoded = jsonEncode({
        ...unsigned,
        'checksum': sha256
            .convert(utf8.encode(jsonEncode(unsigned)))
            .toString(),
      });
      await preferences.setString('kds_progress_journal_v1', encoded);
      await preferences.setString('kds_progress_journal_backup_v1', encoded);
      await expectLater(
        EmergencyWebBridge.putProgressJournal('overflow', '{}'),
        throwsStateError,
      );
      await EmergencyWebBridge.putProgressJournal(
        'event-0',
        jsonEncode({'_outbox_created_at': 1, 'updated': true}),
      );
      expect(await EmergencyWebBridge.readProgressJournal(), hasLength(1000));
      expect(await EmergencyWebBridge.readOutbox(), isEmpty);
    },
  );

  test('native KDS outbox serializes concurrent durable writes', () async {
    await Future.wait([
      for (var index = 0; index < 50; index++)
        EmergencyWebBridge.putOutbox('action-$index', payload(index)),
    ]);

    final records = await EmergencyWebBridge.readOutbox();
    expect(records, hasLength(50));
    expect(records.map((record) => record.id).toSet(), hasLength(50));

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(_primaryKey), isNotNull);
    expect(
      preferences.getString(_primaryKey),
      preferences.getString(_backupKey),
    );
  });

  test(
    'a corrupt progress protocol cannot fall through to the legacy sender',
    () async {
      await EmergencyWebBridge.putProgressJournal('malformed', '{}');
      await expectLater(KdsOutboxStore().read(), throwsFormatException);
      expect(await EmergencyWebBridge.readProgressJournal(), hasLength(1));
    },
  );

  test('newer backup wins after interruption between durable copies', () async {
    final preferences = await SharedPreferences.getInstance();
    await EmergencyWebBridge.putOutbox('action-1', payload(1));
    final olderPrimary = preferences.getString(_primaryKey)!;
    await EmergencyWebBridge.putOutbox('action-2', payload(2));
    await preferences.setString(_primaryKey, olderPrimary);

    final records = await EmergencyWebBridge.readOutbox();
    expect(records.map((record) => record.id), ['action-1', 'action-2']);
  });

  test('corruption is surfaced instead of becoming an empty queue', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_primaryKey, '{broken');
    await preferences.setString(_backupKey, '{broken');

    await expectLater(
      EmergencyWebBridge.readOutbox(),
      throwsA(isA<FormatException>()),
    );
  });

  test('delete is persisted in both durable copies', () async {
    await EmergencyWebBridge.putOutbox('action-1', payload(1));
    await EmergencyWebBridge.deleteOutbox('action-1');

    expect(await EmergencyWebBridge.readOutbox(), isEmpty);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(_primaryKey),
      preferences.getString(_backupKey),
    );
  });

  test('pending commands remain isolated to their owning store', () {
    final records = [
      EmergencyOutboxRecord(
        id: 'store-1-action',
        payload: jsonEncode({
          'queue_id': 'queue-1',
          '_outbox_store_id': 'store-1',
        }),
      ),
      EmergencyOutboxRecord(
        id: 'store-2-action',
        payload: jsonEncode({
          'queue_id': 'queue-2',
          '_outbox_store_id': 'store-2',
        }),
      ),
      EmergencyOutboxRecord(
        id: 'legacy-action',
        payload: jsonEncode({'queue_id': 'legacy-queue'}),
      ),
    ];

    expect(
      emergencyOutboxRecordsForStore(
        records,
        'store-1',
      ).map((record) => record.id),
      ['store-1-action', 'legacy-action'],
    );
    expect(emergencyOutboxRecordsForStore(records, null), isEmpty);
  });

  test('web IndexedDB waits for commit and validates checksums', () {
    final source = File('web/index.html').readAsStringSync();

    expect(source, contains('transaction.oncomplete'));
    expect(source, contains("schemaVersion: 2"));
    expect(source, contains("window.crypto.subtle.digest('SHA-256'"));
    expect(source, contains('KDS_OUTBOX_CHECKSUM_MISMATCH'));
    expect(source, contains('validateEmergencyOutboxRecord(record)'));
  });
}
