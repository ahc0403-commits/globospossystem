import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';

void main() {
  final session = DirectOrderSession(
    id: 'session',
    secret: 'fixture-secret',
    expiresAt: DateTime.utc(2099),
  );
  DirectOrderProofAttempt attempt({String? review}) => DirectOrderProofAttempt(
    requestId: 'request',
    quoteId: 'quote',
    reviewRequestId: review,
    bytes: Uint8List.fromList([1, 2, 3]),
    mimeType: 'image/png',
  );
  const upload = {
    'path': 'store/request/photo.png',
    'token': 'token',
    'signed_url': 'https://fixture.test/upload',
    'max_bytes': 5242880,
    'mime_type': 'image/png',
  };
  Map<String, dynamic> committed(
    Map<String, dynamic> body, {
    bool replay = false,
  }) => {
    'message_id': 'message-1',
    'state': 'awaiting_payment_review',
    'review_request_id': body['review_request_id'],
    'idempotent': replay,
  };

  test(
    'URL failure keeps the same photo and retries only the failed stage',
    () async {
      final actions = <String>[];
      var urls = 0;
      var uploads = 0;
      final service = DirectOrderService(
        invoker: (body) async {
          actions.add(body['action'] as String);
          if (body['action'] == 'proof_upload_url_v2') {
            if (++urls == 1) {
              throw const DirectOrderException(
                'PROOF_UPLOAD_TEMPORARILY_UNAVAILABLE',
              );
            }
            return upload;
          }
          return committed(body);
        },
        proofUploader: (_, _, _, _) async {
          uploads++;
        },
      );
      final photo = attempt();
      await expectLater(
        service.resumePaymentProof(session: session, attempt: photo),
        throwsA(isA<DirectOrderException>()),
      );
      expect(photo.path, isNull);
      expect(photo.outcomeUncertain, isFalse);
      await service.resumePaymentProof(session: session, attempt: photo);
      expect(photo.complete, isTrue);
      expect(uploads, 1);
      expect(actions, [
        'proof_upload_url_v2',
        'proof_upload_url_v2',
        'proof_commit_v2',
      ]);
    },
  );

  test(
    'lost Storage response commits the saved path without uploading twice',
    () async {
      var uploads = 0;
      final bodies = <Map<String, dynamic>>[];
      final service = DirectOrderService(
        invoker: (body) async {
          bodies.add(body);
          return body['action'] == 'proof_upload_url_v2'
              ? upload
              : committed(body);
        },
        proofUploader: (_, _, _, _) async {
          uploads++;
          throw StateError('response lost after saving bytes');
        },
      );
      final photo = attempt();
      await expectLater(
        service.resumePaymentProof(session: session, attempt: photo),
        throwsStateError,
      );
      expect(photo.outcomeUncertain, isTrue);
      await service.resumePaymentProof(session: session, attempt: photo);
      expect(uploads, 1);
      expect(bodies.map((b) => b['action']), [
        'proof_upload_url_v2',
        'proof_commit_v2',
      ]);
      expect(bodies.last['path'], photo.path);
      expect(photo.complete, isTrue);
    },
  );

  test(
    'definitely missing Storage object retries the same signed path',
    () async {
      final paths = <String>[];
      var commits = 0;
      var urls = 0;
      final service = DirectOrderService(
        invoker: (body) async {
          if (body['action'] == 'proof_upload_url_v2') {
            urls++;
            return upload;
          }
          if (++commits == 1) {
            throw const FunctionException(
              status: 409,
              details: {'error': 'PROOF_UPLOAD_INCOMPLETE'},
            );
          }
          return committed(body);
        },
        proofUploader: (path, _, _, _) async {
          paths.add(path);
          if (paths.length == 1) throw StateError('network interrupted');
        },
      );
      final photo = attempt();
      await expectLater(
        service.resumePaymentProof(session: session, attempt: photo),
        throwsStateError,
      );
      await service.resumePaymentProof(session: session, attempt: photo);
      expect(urls, 1);
      expect(paths, [photo.path, photo.path]);
      expect(commits, 2);
      expect(photo.complete, isTrue);
    },
  );

  test(
    'lost commit response recovers one message with the original quote/review',
    () async {
      final commits = <Map<String, dynamic>>[];
      var messages = 0;
      var uploads = 0;
      final service = DirectOrderService(
        invoker: (body) async {
          if (body['action'] == 'proof_upload_url_v2') return upload;
          commits.add(body);
          if (commits.length == 1) {
            messages++;
            throw StateError('lost commit response');
          }
          return committed(body, replay: true);
        },
        proofUploader: (_, _, _, _) async {
          uploads++;
        },
      );
      final photo = attempt(review: 'locked-review');
      await expectLater(
        service.resumePaymentProof(session: session, attempt: photo),
        throwsStateError,
      );
      await service.resumePaymentProof(
        session: session,
        attempt: photo,
        allowUpload: false,
      );
      expect(commits.last, commits.first);
      expect(commits.last['quote_id'], 'quote');
      expect(commits.last['review_request_id'], 'locked-review');
      expect(messages, 1);
      expect(uploads, 1);
      expect(photo.complete, isTrue);
    },
  );

  test(
    'a changed/expired order may reconcile but cannot upload new bytes',
    () async {
      var uploads = 0;
      final service = DirectOrderService(
        invoker: (_) async =>
            throw const DirectOrderException('PROOF_UPLOAD_INCOMPLETE'),
        proofUploader: (_, _, _, _) async {
          uploads++;
        },
      );
      final photo = attempt()
        ..path = upload['path'] as String
        ..token = 'token'
        ..storageAttempted = true
        ..outcomeUncertain = true;
      await expectLater(
        service.resumePaymentProof(
          session: session,
          attempt: photo,
          allowUpload: false,
        ),
        throwsA(
          isA<DirectOrderException>().having(
            (e) => e.code,
            'code',
            'DIRECT_ORDER_PROOF_NOT_ALLOWED',
          ),
        ),
      );
      expect(uploads, 0);
      expect(photo.outcomeUncertain, isFalse);
    },
  );

  test('malformed reservation cannot leave a path without a token', () async {
    var urls = 0;
    var uploads = 0;
    final service = DirectOrderService(
      invoker: (body) async {
        if (body['action'] == 'proof_upload_url_v2') {
          urls++;
          return urls == 1 ? {...upload, 'token': ''} : upload;
        }
        return committed(body);
      },
      proofUploader: (_, _, _, _) async {
        uploads++;
      },
    );
    final photo = attempt();
    await expectLater(
      service.resumePaymentProof(session: session, attempt: photo),
      throwsA(isA<DirectOrderException>()),
    );
    expect(photo.path, isNull);
    await service.resumePaymentProof(session: session, attempt: photo);
    expect(photo.complete, isTrue);
    expect(uploads, 1);
  });

  test(
    'oversized or unsupported photos call neither API nor Storage',
    () async {
      var calls = 0;
      final service = DirectOrderService(
        invoker: (_) async {
          calls++;
          return {};
        },
        proofUploader: (_, _, _, _) async {
          calls++;
        },
      );
      for (final invalid in [
        DirectOrderProofAttempt(
          requestId: 'r',
          quoteId: 'q',
          bytes: Uint8List(5242881),
          mimeType: 'image/png',
        ),
        DirectOrderProofAttempt(
          requestId: 'r',
          quoteId: 'q',
          bytes: Uint8List(1),
          mimeType: 'image/gif',
        ),
      ]) {
        await expectLater(
          service.resumePaymentProof(session: session, attempt: invalid),
          throwsA(isA<DirectOrderException>()),
        );
      }
      expect(calls, 0);
    },
  );
}
