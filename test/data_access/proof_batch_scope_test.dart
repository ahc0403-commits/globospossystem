import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payment_proof_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _session(String actor, {int expiresIn = 3600}) {
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'sub': actor,
            'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresIn,
          }),
        ),
      )
      .replaceAll('=', '');
  return {
    'access_token': 'e30.$payload.fixture',
    'refresh_token': 'fixture',
    'expires_in': expiresIn,
    'token_type': 'bearer',
    'user': {
      'id': actor,
      'aud': 'authenticated',
      'created_at': '2026-11-01T00:00:00Z',
      'app_metadata': {},
      'user_metadata': {},
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late PaymentProofService service;
  final calls = <http.Request>[];
  Completer<void>? metadataGate, metadataStarted, uploadGate, uploadStarted;
  String? missingStore;
  var invalidMetadata = false;
  var activeRequests = 0, maxActiveRequests = 0;

  Future<void> seed(int count, {bool sameStore = false}) async {
    SharedPreferences.setMockInitialValues({
      'payment_proof_upload_queue_v1': jsonEncode([
        for (var i = 0; i < count; i++)
          {
            'payment_id': 'payment-$i',
            'store_id': sameStore ? 'store-0' : 'store-$i',
            'owner_id': 'actor-a',
            'taken_at_iso': '2026-11-01T00:00:00Z',
            'image_bytes_base64': base64Encode([1, 2, 3]),
          },
      ]),
    });
    await client.auth.setInitialSession(jsonEncode(_session('actor-a')));
  }

  Future<List<dynamic>> queue() async =>
      jsonDecode(
            (await SharedPreferences.getInstance()).getString(
              'payment_proof_upload_queue_v1',
            )!,
          )
          as List;

  setUp(() {
    calls.clear();
    metadataGate = metadataStarted = uploadGate = uploadStarted = null;
    missingStore = null;
    invalidMetadata = false;
    activeRequests = maxActiveRequests = 0;
    client = SupabaseClient(
      'https://proof-fixture.invalid',
      'fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        activeRequests++;
        if (activeRequests > maxActiveRequests) {
          maxActiveRequests = activeRequests;
        }
        try {
          calls.add(request);
          Object? body;
          if (request.url.path.endsWith('/restaurants')) {
            metadataStarted?.complete();
            await metadataGate?.future;
            final filter = request.url.queryParameters['id']!;
            final ids = filter
                .substring(4, filter.length - 1)
                .split(',')
                .map((id) => id.startsWith('"') ? jsonDecode(id) as String : id)
                .toList();
            body = [
              for (final id in ids)
                if (id != missingStore) {'id': id, 'tax_entity_id': 'tax-$id'},
              if (invalidMetadata)
                {'id': 'another-store', 'tax_entity_id': 'another-tax'},
            ];
          } else if (request.url.path.contains('/storage/v1/object/sign/')) {
            body = {
              'signedURL': '/object/sign/payment-proofs/fixture?token=fixture',
            };
          } else if (request.url.path.contains('/storage/v1/object/')) {
            if (!(uploadStarted?.isCompleted ?? true)) {
              uploadStarted!.complete();
            }
            await uploadGate?.future;
            body = {'Key': 'fixture'};
          } else if (request.url.path.endsWith('/attach_payment_proof')) {
            body = null;
          } else {
            fail('Unexpected fixture request ${request.url.path}');
          }
          return http.Response(
            jsonEncode(body),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        } finally {
          activeRequests--;
        }
      }),
    );
    service = PaymentProofService(client: client);
  });
  tearDown(() async {
    for (final gate in [metadataGate, uploadGate]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await client.dispose();
  });

  test(
    'ten files use one bounded store lookup and serialized file effects',
    () async {
      await seed(10);
      expect(await service.flushPendingUploads(), 10);
      final metadata = calls
          .where((r) => r.url.path.endsWith('/restaurants'))
          .toList();
      expect(metadata, hasLength(1));
      expect(metadata.single.url.queryParameters['select'], 'id,tax_entity_id');
      expect(metadata.single.url.queryParameters['limit'], '10');
      expect(
        calls,
        hasLength(31),
      ); // One metadata read + upload/sign/attach per file.
      expect(maxActiveRequests, 1);
      expect(await queue(), isEmpty);
    },
  );

  test(
    'eleven files drain in bounded batches without loading other stores',
    () async {
      await seed(11);
      expect(await service.flushPendingUploads(), 10);
      expect(await queue(), hasLength(1));
      expect(await service.flushPendingUploads(), 1);
      final metadata = calls
          .where((r) => r.url.path.endsWith('/restaurants'))
          .toList();
      expect(metadata.map((r) => r.url.queryParameters['limit']), ['10', '1']);
      expect(await queue(), isEmpty);
    },
  );

  test(
    'twenty simultaneous flushes share the original pending operation',
    () async {
      await seed(10, sameStore: true);
      metadataGate = Completer<void>();
      final started = metadataStarted = Completer<void>();
      final first = service.flushPendingUploads();
      final duplicates = [
        for (var i = 0; i < 20; i++) service.flushPendingUploads(),
      ];
      expect(duplicates.every((f) => identical(f, first)), isTrue);
      await started.future.timeout(const Duration(seconds: 3));
      expect(calls, hasLength(1));
      metadataGate!.complete();
      expect(await first, 10);
      expect(await Future.wait(duplicates), everyElement(10));
      expect(calls, hasLength(31));
    },
  );

  test(
    'account change during metadata prevents every subsequent file request',
    () async {
      await seed(2);
      metadataGate = Completer<void>();
      final started = metadataStarted = Completer<void>();
      final pending = service.flushPendingUploads();
      await started.future.timeout(const Duration(seconds: 3));
      await client.auth.setInitialSession(jsonEncode(_session('actor-b')));
      metadataGate!.complete();
      expect(await pending, 0);
      expect(calls, hasLength(1));
      expect(await queue(), hasLength(2));
      expect(await service.flushPendingUploads(), 0);
      expect(calls, hasLength(1));
    },
  );

  test(
    'original upload survives actor change and resumes without reupload',
    () async {
      await seed(1);
      uploadGate = Completer<void>();
      final started = uploadStarted = Completer<void>();
      final pending = service.flushPendingUploads();
      await started.future.timeout(const Duration(seconds: 3));
      await client.auth.setInitialSession(jsonEncode(_session('actor-b')));
      uploadGate!.complete();
      expect(await pending, 0);
      expect(calls, hasLength(2));
      final saved = (await queue()).single as Map;
      expect(saved['uploaded'], isTrue);
      expect(saved['owner_id'], 'actor-a');
      expect(saved['blocked'], isTrue);
      expect(await service.flushPendingUploads(), 0);
      await client.auth.setInitialSession(jsonEncode(_session('actor-a')));
      await service.resumePendingUploads(storeId: 'store-0');
      expect(await service.flushPendingUploads(), 1);
      expect(calls, hasLength(4)); // Existing upload + sign/attach only.
      expect(await queue(), isEmpty);
    },
  );

  test(
    'one missing tax entity blocks only that file without an invented path',
    () async {
      await seed(2);
      missingStore = 'store-1';
      expect(await service.flushPendingUploads(), 1);
      expect(calls, hasLength(4));
      final pending = (await queue()).single as Map;
      expect(pending['store_id'], 'store-1');
      expect(pending['storage_path'], isNull);
      expect(pending['blocked'], isTrue);
    },
  );

  test(
    'same actor token refresh preserves the original upload authorization',
    () async {
      await seed(1);
      uploadGate = Completer<void>();
      final started = uploadStarted = Completer<void>();
      final pending = service.flushPendingUploads();
      await started.future.timeout(const Duration(seconds: 3));
      final original = calls.last.headers['Authorization'];
      expect(original, startsWith('Bearer '));
      await client.auth.setInitialSession(
        jsonEncode(_session('actor-a', expiresIn: 7200)),
      );
      uploadGate!.complete();
      expect(await pending, 1);
      expect(calls, hasLength(4));
      expect(
        calls.skip(1).map((r) => r.headers['Authorization']),
        everyElement(original),
      );
    },
  );

  test('unexpected metadata identity cannot supply an upload path', () async {
    await seed(2);
    invalidMetadata = true;
    expect(await service.flushPendingUploads(), 0);
    expect(calls, hasLength(1));
    expect((await queue()).every((r) => r['blocked'] == true), isTrue);
  });
}
