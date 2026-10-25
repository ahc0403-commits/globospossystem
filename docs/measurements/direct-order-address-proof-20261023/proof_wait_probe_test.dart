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
    'token': 'fixture-token',
    'signed_url': 'https://fixture.invalid/upload',
    'max_bytes': 5242880,
    'mime_type': 'image/png',
  };
  for (final stalledStage in ['storage', 'commit']) {
    testWidgets('$stalledStage has no recovery after five simulated minutes', (
      tester,
    ) async {
      final gate = Completer<void>();
      final service = DirectOrderService(
        invoker: (body) async {
          if (body['action'] == 'proof_upload_url_v2') return reservation;
          if (stalledStage == 'commit') await gate.future;
          return {
            'message_id': 'fixture-message',
            'state': 'awaiting_payment_review',
            'review_request_id': null,
            'idempotent': false,
          };
        },
        proofUploader: (_, _, _, _) async {
          if (stalledStage == 'storage') await gate.future;
        },
      );
      final attempt = DirectOrderProofAttempt(
        requestId: 'request',
        quoteId: 'quote',
        bytes: Uint8List.fromList([1, 2, 3]),
        mimeType: 'image/png',
      );
      var completed = false;
      var failed = false;
      final pending = service
          .resumePaymentProof(session: session, attempt: attempt)
          .then(
            (_) {
              completed = true;
            },
            onError: (Object error) {
              failed = true;
            },
          );
      await tester.pump();
      await tester.pump(const Duration(minutes: 5));
      expect(completed, isFalse);
      expect(failed, isFalse);
      expect(attempt.complete, isFalse);
      expect(attempt.outcomeUncertain, isTrue);
      expect(
        attempt.stage,
        stalledStage == 'storage'
            ? DirectOrderProofStage.uploading
            : DirectOrderProofStage.confirming,
      );
      gate.complete();
      await tester.pump();
      await pending;
      expect(completed, isTrue);
    });
  }
}
