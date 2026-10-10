// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/core/services/payment_proof_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'permanent attach failure keeps completed upload without auto retry',
    () async {
      SharedPreferences.setMockInitialValues({
        'payment_proof_upload_queue_v1': jsonEncode([
          {
            'payment_id': 'audit-payment',
            'store_id': 'audit-store',
            'taken_at_iso': '2026-10-10T01:00:00Z',
            'image_bytes_base64': base64Encode(List<int>.filled(16 * 1024, 42)),
          },
        ]),
      });
      final calls = <String>[];
      final uploads = <String>[];
      var uploadedBytes = 0;
      var permissionRestored = false;
      await Supabase.initialize(
        url: 'http://127.0.0.1:54321',
        anonKey: 'audit-fixture',
        httpClient: MockClient((r) async {
          calls.add('${r.method} ${r.url.path}');
          Object? body;
          var status = 200;
          if (r.url.path.endsWith('/restaurants')) {
            body = {'tax_entity_id': 'audit-tax'};
          } else if (r.url.path.contains('/storage/v1/object/sign/')) {
            body = {
              'signedURL': '/object/sign/payment-proofs/audit?token=fixture',
            };
          } else if (r.url.path.contains('/storage/v1/object/')) {
            uploads.add(r.url.path);
            uploadedBytes += r.bodyBytes.length;
            body = {'Key': 'audit-key'};
          } else if (r.url.path.endsWith('/attach_payment_proof')) {
            status = permissionRestored ? 200 : 403;
            body = permissionRestored
                ? null
                : {'code': '42501', 'message': 'Permanent fixture denial'};
          } else {
            fail('unexpected request ${r.url.path}');
          }
          return http.Response(
            jsonEncode(body),
            status,
            request: r,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final service = PaymentProofService();
      expect(await service.flushPendingUploads(), 0);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(await service.flushPendingUploads(), 0);
      expect(uploads.length, 1);
      expect(uploads.toSet().length, 1);
      expect(calls.length, 4);
      final prefs = await SharedPreferences.getInstance();
      expect(
        (jsonDecode(prefs.getString('payment_proof_upload_queue_v1')!) as List)
            .length,
        1,
      );
      print(
        'AUDIT_MEASUREMENT ' +
            jsonEncode({
              'flush_calls': 2,
              'http_calls': calls.length,
              'uploads': uploads.length,
              'distinct_storage_paths': uploads.toSet().length,
              'uploaded_bytes': uploadedBytes,
              'failure_code': '42501',
              'network': 'mock_only',
            }),
      );
      final persisted =
          (jsonDecode(prefs.getString('payment_proof_upload_queue_v1')!)
                      as List)
                  .single
              as Map;
      expect(
        persisted['blocked'],
        true,
        reason: '${persisted["last_error"]} ${persisted["attempts"]}',
      );
      final restarted = PaymentProofService();
      expect(await restarted.pendingActionCount('audit-store'), 1);
      await restarted.resumePendingUploads(storeId: 'other-store');
      expect(await restarted.flushPendingUploads(), 0);
      permissionRestored = true;
      await restarted.resumePendingUploads(storeId: 'audit-store');
      expect(await restarted.flushPendingUploads(), 1);
      expect(uploads.length, 1);
      expect(
        calls.length,
        5,
      ); // Only attach resumes after persisted upload/sign.
      expect(
        jsonDecode(prefs.getString('payment_proof_upload_queue_v1')!),
        isEmpty,
      );
      await Supabase.instance.dispose();
    },
  );
}
