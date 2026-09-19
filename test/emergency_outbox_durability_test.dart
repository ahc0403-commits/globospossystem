import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/emergency_web_bridge.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
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
