import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('attendance kiosk submits staff directory user_id', () {
    final kioskScreen = readRepoFile(
      'lib/features/attendance/attendance_kiosk_screen.dart',
    );
    final schema = readRepoFile('supabase/schema.sql');

    expect(
      schema,
      contains(
        'RETURNS TABLE("user_id" "uuid", "full_name" "text", "role" "text")',
      ),
    );
    expect(kioskScreen, contains("selected?['user_id']?.toString()"));
    expect(kioskScreen, isNot(contains("userId: selected['id'].toString()")));
  });
}
