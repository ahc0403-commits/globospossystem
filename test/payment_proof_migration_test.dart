import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payment_proof_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'legacy proof is retained until upload and v2 attach both succeed',
    () async {
      final root = await Directory.systemTemp.createTemp('proof-queue-test-');
      addTearDown(() => root.delete(recursive: true));
      final queue = Directory('${root.path}/payment_proof_queue')..createSync();
      final proof = File('${queue.path}/payment-a.jpg')
        ..writeAsBytesSync([1, 2, 3]);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        PaymentProofService.legacyQueueKey,
        jsonEncode([
          {
            'payment_id': 'payment-a',
            'store_id': 'store-a',
            'local_path': proof.path,
            'taken_at_iso': '2026-07-15T00:00:00Z',
          },
        ]),
      );
      var shouldFail = true;
      var calls = 0;
      final migrator = LegacyPaymentProofQueueMigrator(
        preferences: preferences,
        queueDirectory: queue,
        uploadAndAttach:
            ({
              required paymentId,
              required storeId,
              required file,
              required takenAt,
            }) async {
              calls += 1;
              if (shouldFail) throw StateError('attach denied');
              return 'tax/$storeId/2026-07-15/$paymentId.jpg';
            },
      );

      final failed = await migrator.migrate();
      expect(failed.migrated, 0);
      expect(failed.retained, 1);
      expect(proof.existsSync(), isTrue);
      expect(
        preferences.getString(PaymentProofService.legacyQueueKey),
        isNotNull,
      );

      shouldFail = false;
      final succeeded = await migrator.migrate();
      expect(succeeded.migrated, 1);
      expect(succeeded.retained, 0);
      expect(calls, 2);
      expect(proof.existsSync(), isFalse);
      expect(preferences.getString(PaymentProofService.legacyQueueKey), isNull);
    },
  );

  test(
    'malformed, missing, and outside-directory entries are quarantined',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'proof-boundary-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final queue = Directory('${root.path}/payment_proof_queue')..createSync();
      final outside = File('${root.path}/outside.jpg')..writeAsBytesSync([4]);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        PaymentProofService.legacyQueueKey,
        jsonEncode([
          {'unexpected': true},
          {
            'payment_id': 'payment-missing',
            'store_id': 'store-a',
            'local_path': '${queue.path}/missing.jpg',
            'taken_at_iso': '2026-07-15T00:00:00Z',
          },
          {
            'payment_id': 'payment-outside',
            'store_id': 'store-a',
            'local_path': outside.path,
            'taken_at_iso': '2026-07-15T00:00:00Z',
          },
        ]),
      );
      final migrator = LegacyPaymentProofQueueMigrator(
        preferences: preferences,
        queueDirectory: queue,
        uploadAndAttach:
            ({
              required paymentId,
              required storeId,
              required file,
              required takenAt,
            }) async => throw StateError('must not run'),
      );

      final result = await migrator.migrate();
      expect(result.quarantined, 3);
      expect(result.migrated, 0);
      expect(outside.existsSync(), isTrue);
      expect(
        preferences.getString(PaymentProofService.legacyQueueKey),
        isNotNull,
      );
    },
  );

  test('10x legacy proof batch migrates 250 files idempotently', () async {
    final root = await Directory.systemTemp.createTemp('proof-pressure-test-');
    addTearDown(() => root.delete(recursive: true));
    final queue = Directory('${root.path}/payment_proof_queue')..createSync();
    final preferences = await SharedPreferences.getInstance();
    final files = <File>[];
    final entries = <Map<String, String>>[];
    for (var index = 0; index < 250; index++) {
      final paymentId = 'payment-$index';
      final file = File('${queue.path}/$paymentId.jpg')
        ..writeAsBytesSync([index % 256]);
      files.add(file);
      entries.add({
        'payment_id': paymentId,
        'store_id': 'store-a',
        'local_path': file.path,
        'taken_at_iso': '2026-07-15T00:00:00Z',
      });
    }
    await preferences.setString(
      PaymentProofService.legacyQueueKey,
      jsonEncode(entries),
    );
    var calls = 0;
    final migrator = LegacyPaymentProofQueueMigrator(
      preferences: preferences,
      queueDirectory: queue,
      uploadAndAttach:
          ({
            required paymentId,
            required storeId,
            required file,
            required takenAt,
          }) async {
            calls += 1;
            return 'tax/$storeId/2026-07-15/$paymentId.jpg';
          },
    );

    final migrated = await migrator.migrate();
    expect(migrated.migrated, 250);
    expect(migrated.retained, 0);
    expect(migrated.quarantined, 0);
    expect(calls, 250);
    expect(files.every((file) => !file.existsSync()), isTrue);
    expect(preferences.getString(PaymentProofService.legacyQueueKey), isNull);

    final replay = await migrator.migrate();
    expect(replay.migrated, 0);
    expect(replay.retained, 0);
    expect(calls, 250);
  });

  test(
    'authenticated object download validates tenant path and falls back to legacy URL',
    () async {
      var downloadCalls = 0;
      final viewer = PaymentProofViewerService(
        downloadObject: (path) async {
          downloadCalls += 1;
          return Uint8List.fromList([9, 8, 7]);
        },
      );

      expect(
        await viewer.load(
          storeId: 'store-a',
          objectPath: null,
          legacyUrl: null,
        ),
        isNull,
      );
      final legacy = await viewer.load(
        storeId: 'store-a',
        objectPath: null,
        legacyUrl:
            'https://example.supabase.co/storage/v1/object/sign/payment-proofs/a',
      );
      expect(legacy?.legacyUri, isNotNull);
      expect(downloadCalls, 0);

      expect(
        () => viewer.load(
          storeId: 'store-b',
          objectPath: 'tax/store-a/2026-07-15/payment-a.jpg',
          legacyUrl: null,
        ),
        throwsArgumentError,
      );
      final downloaded = await viewer.load(
        storeId: 'store-a',
        objectPath: 'tax/store-a/2026-07-15/payment-a.jpg',
        legacyUrl: null,
      );
      expect(downloaded?.bytes, Uint8List.fromList([9, 8, 7]));
      expect(downloadCalls, 1);
    },
  );
}
