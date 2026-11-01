import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _DelayedFile extends XFile {
  _DelayedFile(this.bytes) : super('synthetic-photo');
  final Uint8List bytes;
  final started = Completer<void>(), release = Completer<void>();
  @override
  Future<int> length() async {
    started.complete();
    await release.future;
    return bytes.length;
  }

  @override
  Stream<Uint8List> openRead([int? start, int? end]) => Stream.value(bytes);
}

Map<String, dynamic> _session(String actor) {
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'sub': actor,
            'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          }),
        ),
      )
      .replaceAll('=', '');
  return {
    'access_token': 'e30.$payload.fixture',
    'refresh_token': 'fixture-$actor',
    'expires_in': 3600,
    'token_type': 'bearer',
    'user': {
      'id': actor,
      'aud': 'authenticated',
      'created_at': '2026-11-01T00:00:00Z',
      'app_metadata': {},
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late AttendanceService service;
  late Uint8List bytes;
  final calls = <http.Request>[];
  Completer<void>? uploadStarted, uploadRelease;
  setUp(() async {
    calls.clear();
    uploadStarted = uploadRelease = null;
    bytes = Uint8List.fromList(img.encodeJpg(img.Image(width: 96, height: 72)));
    client = SupabaseClient(
      'https://attendance-fixture.invalid',
      'fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        calls.add(request);
        if (request.url.path.contains('/object/sign/')) {
          return http.Response(
            jsonEncode({
              'signedURL':
                  '/object/sign/attendance-photos/fixture.jpg?token=synthetic',
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (request.url.path.contains('/object/attendance-photos/')) {
          uploadStarted?.complete();
          await uploadRelease?.future;
          return http.Response(
            '{"id":"fixture","Key":"fixture.jpg"}',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        return http.Response('ok', 200, request: request);
      }),
    );
    await client.auth.setInitialSession(jsonEncode(_session('actor-a')));
    service = AttendanceService(client: client);
  });
  tearDown(() async => client.dispose());
  Future<String?> upload(XFile file) => service.uploadEmployeeAttendancePhoto(
    storeId: 'store-a',
    employeeNumber: 'A001',
    originalFile: file,
    type: 'clock_in',
  );

  test(
    'actor change during file processing prevents all upload HTTP',
    () async {
      final file = _DelayedFile(bytes);
      final work = upload(file);
      await file.started.future;
      await client.auth.setInitialSession(jsonEncode(_session('actor-b')));
      file.release.complete();
      await expectLater(work, throwsStateError);
      expect(calls, isEmpty);
    },
  );
  test(
    'original upload cannot sign using a later actor and shared Auth survives',
    () async {
      uploadStarted = Completer<void>();
      uploadRelease = Completer<void>();
      final originalToken = client.auth.currentSession!.accessToken;
      final work = upload(XFile.fromData(bytes));
      await uploadStarted!.future;
      await client.auth.setInitialSession(jsonEncode(_session('actor-b')));
      uploadRelease!.complete();
      await expectLater(work, throwsA(isA<AttendancePhotoSigningException>()));
      expect(calls, hasLength(1));
      expect(calls.single.headers['authorization'], 'Bearer $originalToken');
      final health = await client.rest.httpClient!.get(
        Uri.parse('https://attendance-fixture.invalid/health'),
      );
      expect(health.body, 'ok');
    },
  );
  test(
    'ordinary photo uses one upload and one ten-year sign request',
    () async {
      expect(
        await upload(XFile.fromData(bytes)),
        contains('/object/sign/attendance-photos/'),
      );
      expect(calls, hasLength(2));
      expect(jsonDecode(calls.last.body), {'expiresIn': 315360000});
      expect(img.decodeJpg(calls.first.bodyBytes), isNotNull);
    },
  );
}
