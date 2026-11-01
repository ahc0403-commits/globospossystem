import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payment_proof_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SupabaseClient client;
  late PaymentProofService service;
  late XFile photo;
  final calls = <String>[];
  var denyCleanup = false, attachFails = false;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    denyCleanup = false;
    attachFails = false;
    directory = await Directory.systemTemp.createTemp('owned-proof-cleanup-');
    photo = XFile.fromData(
      Uint8List.fromList(img.encodePng(img.Image(width: 24, height: 16))),
    );
    client = SupabaseClient(
      'https://proof-fixture.invalid',
      'fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        calls.add(request.url.path);
        Object result;
        var status = 200;
        if (request.url.path.endsWith('/restaurants')) {
          result = [
            {'id': 'store-a', 'tax_entity_id': 'tax-a'},
          ];
        } else if (request.url.path.contains('/object/sign/')) {
          result = {
            'signedURL':
                '/object/sign/payment-proofs/tax-a/store-a/photo.jpg?token=synthetic',
          };
        } else if (request.url.path.contains('/rpc/attach_payment_proof')) {
          if (denyCleanup) {
            final changed = await Process.run('chmod', ['555', directory.path]);
            if (changed.exitCode != 0) {
              throw StateError('Owned cleanup fault setup failed');
            }
          }
          if (attachFails) {
            status = 503;
            result = {'code': 'PGRST000', 'message': 'synthetic unavailable'};
          } else {
            result = {'ok': true, 'payment_id': 'payment-a'};
          }
        } else {
          result = {'id': 'fixture', 'Key': 'fixture.jpg'};
        }
        return http.Response(
          jsonEncode(result),
          status,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    service = PaymentProofService(
      client: client,
      localQueueDirectory: directory,
    );
  });
  tearDown(() async {
    await Process.run('chmod', ['755', directory.path]);
    await client.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'server-confirmed proof remains uploaded when local deletion fails',
    () async {
      denyCleanup = true;
      final result = await service.saveProof(
        paymentId: 'payment-a',
        storeId: 'store-a',
        originalFile: photo,
      );
      expect(
        calls.where((p) => p.endsWith('/rpc/attach_payment_proof')),
        hasLength(1),
      );
      expect(result.uploaded, isTrue);
      expect(result.queued, isFalse);
      expect(result.cleanupPending, isTrue);
      final prefs = await SharedPreferences.getInstance();
      final queue =
          jsonDecode(prefs.getString('payment_proof_upload_queue_v1')!) as List;
      expect(queue, hasLength(1));
      expect(queue.single['attached'], isTrue);
      final before = calls.length;
      final restored = PaymentProofService(
        client: client,
        localQueueDirectory: directory,
      );
      expect(await restored.flushPendingUploads(), 0);
      expect(await restored.pendingActionCount('store-a'), 1);
      expect(calls.length, before);
      await Process.run('chmod', ['755', directory.path]);
      expect(await restored.flushPendingUploads(), 1);
      expect(
        calls.length,
        before,
        reason:
            'Confirmed cleanup recovery sends no upload/sign/attach request',
      );
      expect(
        jsonDecode(prefs.getString('payment_proof_upload_queue_v1')!),
        isEmpty,
      );
    },
    skip: Platform.isWindows ? 'Requires Unix directory permissions' : false,
  );
  test(
    'unconfirmed attachment preserves uploaded object and resumes only attachment',
    () async {
      attachFails = true;
      final original = await service.saveProof(
        paymentId: 'payment-a',
        storeId: 'store-a',
        originalFile: photo,
      );
      expect(original.queued, isTrue);
      expect(original.uploaded, isFalse);
      final prefs = await SharedPreferences.getInstance();
      final pending =
          jsonDecode(prefs.getString('payment_proof_upload_queue_v1')!) as List;
      expect(pending.single['attached'], isFalse);
      expect(pending.single['uploaded'], isTrue);
      final before = calls.length;
      attachFails = false;
      await service.resumePendingUploads(storeId: 'store-a');
      expect(await service.flushPendingUploads(), 1);
      expect(calls.skip(before).toList(), [
        '/rest/v1/rpc/attach_payment_proof',
      ]);
    },
  );
  test(
    'corrupt confirmation without signed URL is preserved for review',
    () async {
      SharedPreferences.setMockInitialValues({
        'payment_proof_upload_queue_v1': jsonEncode([
          {
            'payment_id': 'payment-a',
            'store_id': 'store-a',
            'taken_at_iso': '2026-11-01T00:00:00Z',
            'attached': true,
          },
        ]),
      });
      expect(await service.flushPendingUploads(), 0);
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString('payment_proof_upload_queue_v1')!) as List,
        hasLength(1),
      );
      expect(calls, isEmpty);
    },
  );
  test('wrong queue envelope is preserved and blocks a new capture', () async {
    const original = '{"unexpected":"preserve this pending evidence"}';
    SharedPreferences.setMockInitialValues({
      'payment_proof_upload_queue_v1': original,
    });
    await expectLater(
      service.saveProof(
        paymentId: 'new-payment',
        storeId: 'store-a',
        originalFile: photo,
      ),
      throwsFormatException,
    );
    expect(calls, isEmpty);
    expect((await directory.list().toList()), isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'payment_proof_upload_queue_v1',
      ),
      original,
    );
  });
  test('one malformed queue member cannot be silently discarded', () async {
    final original = jsonEncode([
      {
        'payment_id': 'payment-a',
        'store_id': 'store-a',
        'taken_at_iso': '2026-11-01T00:00:00Z',
        'attached': true,
      },
      'preserve malformed member for recovery',
    ]);
    SharedPreferences.setMockInitialValues({
      'payment_proof_upload_queue_v1': original,
    });
    await expectLater(service.flushPendingUploads(), throwsFormatException);
    expect(calls, isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'payment_proof_upload_queue_v1',
      ),
      original,
    );
  });
  test('missing queue identity cannot become a literal null payment', () async {
    final original = jsonEncode([
      {'store_id': 'store-a', 'taken_at_iso': '2026-11-01T00:00:00Z'},
    ]);
    SharedPreferences.setMockInitialValues({
      'payment_proof_upload_queue_v1': original,
    });
    await expectLater(service.flushPendingUploads(), throwsFormatException);
    expect(calls, isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'payment_proof_upload_queue_v1',
      ),
      original,
    );
  });
}
