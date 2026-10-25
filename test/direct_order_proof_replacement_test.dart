import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';

void main() {
  final session = DirectOrderSession(
    id: 'session',
    secret: 'fixture-secret',
    expiresAt: DateTime.utc(2099),
  );
  const reservation = {
    'path': 'store/request/photo.png',
    'token': 'token',
    'signed_url': 'https://fixture.invalid/upload',
    'max_bytes': 5242880,
    'mime_type': 'image/png',
  };
  DirectOrderProofAttempt photo() => DirectOrderProofAttempt(
    requestId: 'request',
    quoteId: 'quote',
    expectedMessageId: 'previous-photo',
    bytes: Uint8List.fromList([1, 2, 3]),
    mimeType: 'image/png',
  );
  Map<String, dynamic> receipt(Map<String, dynamic> body) => {
    'message_id': 'replacement',
    'state': 'awaiting_payment_review',
    'review_request_id': body['review_request_id'],
    'idempotent': false,
  };

  for (final stage in ['reservation', 'storage', 'commit']) {
    testWidgets(
      '$stage timeout retains identity and safely ignores late response',
      (tester) async {
        final apiGate = Completer<Map<String, dynamic>>();
        final storageGate = Completer<void>();
        var stalled = true;
        final bodies = <Map<String, dynamic>>[];
        var uploads = 0;
        final service = DirectOrderService(
          invoker: (body) async {
            bodies.add(body);
            final reserve = body['action'] == 'proof_upload_url_v3';
            if (stalled &&
                ((reserve && stage == 'reservation') ||
                    (!reserve && stage == 'commit'))) {
              return apiGate.future;
            }
            return reserve ? reservation : receipt(body);
          },
          proofUploader: (_, _, _, _) async {
            uploads++;
            if (stalled && stage == 'storage') await storageGate.future;
          },
        );
        final attempt = photo();
        Object? failure;
        final pending = service
            .resumePaymentProof(session: session, attempt: attempt)
            .then<void>(
              (_) {},
              onError: (Object error) {
                failure = error;
              },
            );
        await tester.pump();
        await tester.pump(const Duration(seconds: 61));
        await pending;
        expect(
          failure,
          isA<DirectOrderException>().having(
            (e) => e.code,
            'code',
            'DIRECT_ORDER_PROOF_TIMEOUT',
          ),
        );
        expect(attempt.complete, isFalse);
        expect(attempt.outcomeUncertain, stage != 'reservation');
        final count = bodies.length;
        stalled = false;
        apiGate.complete(
          stage == 'reservation' ? reservation : receipt(bodies.last),
        );
        storageGate.complete();
        await tester.pump();
        expect(
          bodies.length,
          count,
          reason: 'A late response must not start another write',
        );
        expect(attempt.complete, isFalse);
        await service.resumePaymentProof(session: session, attempt: attempt);
        expect(attempt.complete, isTrue);
        expect(attempt.messageId, 'replacement');
        expect(uploads, 1);
        expect(
          bodies.every(
            (body) => body['expected_message_id'] == 'previous-photo',
          ),
          isTrue,
        );
      },
    );
  }

  test(
    'concurrent retries share one write and an expired signature keeps the path',
    () async {
      final gate = Completer<void>();
      var uploads = 0;
      final bodies = <Map<String, dynamic>>[];
      final service = DirectOrderService(
        invoker: (body) async {
          bodies.add(body);
          return body['action'] == 'proof_upload_url_v3'
              ? reservation
              : receipt(body);
        },
        proofUploader: (_, _, _, _) async {
          uploads++;
          await gate.future;
        },
      );
      final attempt = photo();
      final a = service.resumePaymentProof(session: session, attempt: attempt);
      final b = service.resumePaymentProof(session: session, attempt: attempt);
      expect(identical(a, b), isTrue);
      gate.complete();
      await Future.wait([a, b]);
      expect(uploads, 1);
      expect(bodies.map((b) => b['action']), [
        'proof_upload_url_v3',
        'proof_commit_v3',
      ]);
    },
  );

  test(
    'expired signature is renewed only after absence is established',
    () async {
      final bodies = <Map<String, dynamic>>[];
      var commits = 0;
      final service = DirectOrderService(
        invoker: (body) async {
          bodies.add(body);
          if (body['action'] == 'proof_upload_url_v3') return reservation;
          if (++commits == 1) {
            throw const DirectOrderException('PROOF_UPLOAD_INCOMPLETE');
          }
          return receipt(body);
        },
        proofUploader: (_, _, _, _) async {},
      );
      final attempt = photo()
        ..path = reservation['path'] as String
        ..token = 'expired'
        ..tokenIssuedAt = DateTime.utc(2000)
        ..storageAttempted = true
        ..outcomeUncertain = true;
      await service.resumePaymentProof(session: session, attempt: attempt);
      expect(bodies.map((b) => b['action']), [
        'proof_commit_v3',
        'proof_upload_url_v3',
        'proof_commit_v3',
      ]);
      expect(bodies[1]['path'], attempt.path);
      expect(attempt.complete, isTrue);
    },
  );

  testWidgets(
    'a stalled general attachment releases after the commit deadline',
    (tester) async {
      final gate = Completer<Map<String, dynamic>>();
      final service = DirectOrderService(invoker: (_) => gate.future);
      Object? failure;
      final pending = service
          .uploadSupportAttachment(
            session: session,
            requestId: 'request',
            path: 'store/request/photo.png',
            filename: 'photo.png',
            mimeType: 'image/png',
            bytes: Uint8List(1),
          )
          .then<void>(
            (_) {},
            onError: (Object error) {
              failure = error;
            },
          );
      await tester.pump();
      await tester.pump(const Duration(seconds: 21));
      await pending;
      expect(failure, isA<DirectOrderException>());
      gate.complete({'message_id': 'attachment'});
      await tester.pump();
    },
  );
}
