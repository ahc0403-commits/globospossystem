import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('attendance kiosk requires a captured photo with employee number', () {
    final kioskScreen = readRepoFile(
      'lib/features/attendance/attendance_kiosk_screen.dart',
    );
    final service = readRepoFile('lib/core/services/attendance_service.dart');
    final migration = readRepoFile(
      'supabase/migrations/20260723010000_employee_attendance_required_photo.sql',
    );

    expect(service, contains("'record_employee_attendance_with_photo'"));
    expect(service, contains("'p_employee_number'"));
    expect(service, contains('required XFile originalFile'));
    expect(kioskScreen, contains("Key('attendance_employee_number_field')"));
    expect(kioskScreen, contains("Key('attendance_employee_clock_in')"));
    expect(kioskScreen, contains("Key('attendance_employee_clock_out')"));
    expect(kioskScreen, contains('ImageSource.camera'));
    expect(kioskScreen, contains("Key('attendance_photo_preview')"));
    expect(kioskScreen, contains("Key('attendance_confirm_photo')"));
    expect(migration, contains('ATTENDANCE_PHOTO_REQUIRED'));
    expect(migration, contains('photo_url = v_photo_url'));
    expect(kioskScreen, isNot(contains('fingerprint')));
    expect(kioskScreen, isNot(contains('pin')));
  });
}
