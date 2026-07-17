import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('attendance kiosk records employee number without biometrics', () {
    final kioskScreen = readRepoFile(
      'lib/features/attendance/attendance_kiosk_screen.dart',
    );
    final service = readRepoFile('lib/core/services/attendance_service.dart');

    expect(service, contains("'record_employee_attendance'"));
    expect(service, contains("'p_employee_number'"));
    expect(kioskScreen, contains("Key('attendance_employee_number_field')"));
    expect(kioskScreen, contains("Key('attendance_employee_clock_in')"));
    expect(kioskScreen, contains("Key('attendance_employee_clock_out')"));
    expect(kioskScreen, isNot(contains("package:camera/camera.dart")));
    expect(kioskScreen, isNot(contains('CameraController')));
    expect(kioskScreen, isNot(contains('fingerprint')));
    expect(kioskScreen, isNot(contains('pin')));
  });
}
