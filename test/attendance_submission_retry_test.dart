import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/auth/operation_scope_provider.dart';
import 'package:globos_pos_system/core/utils/operation_contract.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';
import 'package:globos_pos_system/features/attendance/attendance_kiosk_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Service extends AttendanceService {
  int uploads = 0;
  int signatures = 0;
  int writes = 0;
  int reads = 0;
  Object? uploadError;
  Object? recordError;
  Completer<String?>? uploadWait;
  Completer<Map<String, dynamic>>? recordWait;
  Completer<void>? recordStarted;
  final records = <Map<String, dynamic>>[];

  @override
  Future<String?> uploadEmployeeAttendancePhoto({
    required String storeId,
    required String employeeNumber,
    required XFile originalFile,
    required String type,
  }) async {
    uploads++;
    if (uploadError != null) throw uploadError!;
    return uploadWait?.future ?? 'https://example.test/photo-$uploads.jpg';
  }

  @override
  Future<String> signEmployeeAttendancePhoto(String path) async {
    signatures++;
    return 'https://example.test/signed.jpg';
  }

  @override
  Future<Map<String, dynamic>> recordEmployeeAttendance({
    required String storeId,
    required String employeeNumber,
    required String type,
    String? photoUrl,
  }) async {
    writes++;
    recordStarted?.complete();
    if (recordError != null) throw recordError!;
    if (recordWait != null) return recordWait!.future;
    return {'id': 'saved'};
  }

  @override
  Future<List<Map<String, dynamic>>> fetchLogs({
    required String storeId,
    required DateTime from,
    required DateTime to,
    int limit = 500,
  }) async {
    reads++;
    expect(storeId, 'store-1');
    expect(limit, attendanceScreenRecordLimit);
    return records;
  }
}

void main() {
  late _Service service;
  late AttendanceKioskNotifier notifier;
  late XFile photo;

  setUp(() {
    service = _Service();
    notifier = AttendanceKioskNotifier(service: service);
    photo = XFile.fromData(Uint8List.fromList([1, 2, 3]));
  });
  tearDown(() {
    if (notifier.mounted) notifier.dispose();
  });

  Future<bool> submit({String employee = ' bt1 ', XFile? file}) =>
      notifier.recordAttendance(
        storeId: 'store-1',
        employeeNumber: employee,
        type: 'clock_in',
        photoFile: file ?? photo,
      );

  test(
    'normal submission uploads and saves once without a status read',
    () async {
      expect(await submit(), isTrue);
      expect(notifier.state.lastEmployeeNumber, 'BT1');
      expect((service.uploads, service.writes, service.reads), (1, 1, 0));
    },
  );

  test(
    'real service retries signing without reuploading the photograph',
    () async {
      final requests = <String>[];
      var signingFailed = false;
      final client = SupabaseClient(
        'https://example.test',
        'test-anon',
        httpClient: MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path.contains('/object/sign/')) {
            if (!signingFailed) {
              signingFailed = true;
              return http.Response(
                jsonEncode({'message': 'temporary signing failure'}),
                503,
                headers: {'content-type': 'application/json'},
                request: request,
              );
            }
            return http.Response(
              jsonEncode({
                'signedURL':
                    '/object/sign/attendance-photos/photo.jpg?token=test',
              }),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          return http.Response(
            jsonEncode({'id': 'saved', 'Key': 'photo.jpg'}),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final actual = AttendanceKioskNotifier(
        service: AttendanceService(client: client),
      );
      addTearDown(actual.dispose);
      final file = XFile.fromData(
        Uint8List.fromList(img.encodePng(img.Image(width: 1, height: 1))),
      );
      Future<bool> send() => actual.recordAttendance(
        storeId: 'store-1',
        employeeNumber: 'BT1',
        type: 'clock_in',
        photoFile: file,
      );
      expect(await send(), isFalse);
      expect(actual.state.errorCode, 'ATTENDANCE_PHOTO_LINK_FAILED');
      final retried = await send();
      expect(retried, isTrue, reason: '${actual.state.errorCode}: $requests');
      expect(
        requests.where((p) => p.contains('/object/attendance-photos/')).length,
        1,
      );
      expect(requests.where((p) => p.contains('/object/sign/')).length, 2);
      expect(
        requests
            .where(
              (p) => p.contains('/rpc/record_employee_attendance_with_photo'),
            )
            .length,
        1,
      );
      expect(requests.length, 4);
    },
  );

  test('storage failure never calls the attendance RPC or leaks SQL', () async {
    service.uploadError = const StorageException(
      'permission denied for function procurement_pre_inbox_can_create_order',
      statusCode: '400',
    );
    expect(await submit(), isFalse);
    expect(notifier.state.errorCode, 'ATTENDANCE_PHOTO_FAILED');
    expect(service.writes, 0);
    service.uploadError = null;
    expect(await submit(), isTrue);
    expect(service.writes, 1);
  });

  test('signature retry reuses the uploaded path', () async {
    service.uploadError = const AttendancePhotoSigningException(
      'store-1/a.jpg',
    );
    expect(await submit(), isFalse);
    expect(notifier.state.errorCode, 'ATTENDANCE_PHOTO_LINK_FAILED');
    expect(await submit(), isTrue);
    expect((service.uploads, service.signatures, service.writes), (1, 1, 1));
  });

  test(
    'known RPC rejection reuses the signed photo on explicit retry',
    () async {
      service.recordError = const PostgrestException(
        message: 'EMPLOYEE_NUMBER_NOT_FOUND',
        code: 'P0001',
      );
      expect(await submit(), isFalse);
      expect(notifier.state.errorCode, 'EMPLOYEE_NOT_FOUND');
      service.recordError = null;
      expect(await submit(), isTrue);
      expect((service.uploads, service.writes, service.reads), (1, 2, 0));
    },
  );

  test(
    'employee, photo and reset changes discard previous upload reuse',
    () async {
      service.recordError = const PostgrestException(
        message: 'EMPLOYEE_NUMBER_NOT_FOUND',
        code: 'P0001',
      );
      await submit();
      await submit(employee: 'BT2');
      await submit(
        employee: 'BT2',
        file: XFile.fromData(Uint8List.fromList([4])),
      );
      notifier.clearResult();
      await submit();
      expect(service.uploads, 4);
    },
  );

  test('double submission cannot duplicate upload or save', () async {
    service.uploadWait = Completer<String?>();
    final first = submit();
    expect(await submit(), isFalse);
    service.uploadWait!.complete('https://example.test/photo.jpg');
    expect(await first, isTrue);
    expect((service.uploads, service.writes), (1, 1));
  });

  test(
    'disposal during photo upload prevents a later attendance write',
    () async {
      final upload = service.uploadWait = Completer<String?>();
      final pending = submit();
      notifier.dispose();
      upload.complete('https://example.test/photo.jpg');
      expect(await pending, isFalse);
      expect(service.writes, 0);
    },
  );

  test(
    'confirmed attendance survives disposal without updating a new view',
    () async {
      final write = service.recordWait = Completer<Map<String, dynamic>>();
      final started = service.recordStarted = Completer<void>();
      final pending = submit();
      await started.future;
      notifier.dispose();
      write.complete({'id': 'original-event'});
      expect(await pending, isTrue);
      expect(service.writes, 1);
    },
  );

  test(
    'actual provider invalidates original actor scope and blocks other stores',
    () async {
      OperationScope actor(String id) => OperationScope(
        actorId: id,
        storeId: 'store-1',
        role: 'attendance',
        authorizationRevision: 'fixture-v1',
      );
      final scope = OperationScopeNotifier(isBound: true)..publish(actor('a'));
      final c = ProviderContainer(
        overrides: [
          operationScopeProvider.overrideWith((ref) => scope),
          attendanceKioskServiceProvider.overrideWithValue(service),
        ],
      );
      final sub = c.listen(attendanceKioskProvider, (_, _) {});
      addTearDown(() {
        sub.close();
        c.dispose();
      });
      final old = c.read(attendanceKioskProvider.notifier);
      final upload = service.uploadWait = Completer<String?>();
      final pending = old.recordAttendance(
        employeeNumber: 'BT1',
        storeId: 'store-1',
        type: 'clock_in',
        photoFile: photo,
      );
      scope.publish(actor('b'));
      final current = c.read(attendanceKioskProvider.notifier);
      expect(identical(old, current), isFalse);
      expect(old.mounted, isFalse);
      upload.complete('https://example.test/photo.jpg');
      expect(await pending, isFalse);
      expect(service.writes, 0);
      expect(current.state.lastAction, isNull);
      expect(
        await current.recordAttendance(
          employeeNumber: 'BT1',
          storeId: 'store-2',
          type: 'clock_in',
          photoFile: photo,
        ),
        isFalse,
      );
      scope.publish(null);
      expect(
        await c
            .read(attendanceKioskProvider.notifier)
            .recordAttendance(
              employeeNumber: 'BT1',
              storeId: 'store-1',
              type: 'clock_in',
              photoFile: photo,
            ),
        isFalse,
      );
      expect(service.uploads, 1);
    },
  );

  test(
    'lost write response verifies the result without repeating the write',
    () async {
      service.recordError = TimeoutException('response interrupted');
      expect(await submit(), isFalse);
      expect(notifier.state.needsVerification, isTrue);
      expect(await submit(), isFalse);
      expect((service.uploads, service.writes, service.reads), (1, 1, 1));
      service.records.add({
        'photo_url': 'https://example.test/photo-1.jpg',
        'employee_number': 'BT1',
        'type': 'clock_in',
      });
      expect(await submit(), isTrue);
      expect(notifier.state.needsVerification, isFalse);
      expect((service.uploads, service.writes, service.reads), (1, 1, 2));
    },
  );

  test(
    'verification cannot mistake another employee or action for success',
    () async {
      service.recordError = TimeoutException('response interrupted');
      await submit();
      service.records.add({
        'photo_url': 'https://example.test/photo-1.jpg',
        'employee_number': 'BT2',
        'type': 'clock_out',
      });
      expect(await submit(), isFalse);
      expect(service.writes, 1);
      expect(notifier.state.needsVerification, isTrue);
    },
  );
}
