import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows print station build is native, secret-safe, and exact-SHA', () {
    final cmake = File('windows/CMakeLists.txt').readAsStringSync();
    final script = File(
      'scripts/build_windows_print_station.ps1',
    ).readAsStringSync();
    final workflow = File(
      '.github/workflows/windows_print_station_build.yml',
    ).readAsStringSync();

    expect(cmake, contains('set(BINARY_NAME "globos_print_station")'));
    expect(script, contains('flutter build windows --release'));
    expect(script, contains('SUPABASE_ANON_KEY'));
    expect(script, isNot(contains('SUPABASE_SERVICE_KEY')));
    expect(workflow, contains('runs-on: windows-2025'));
    expect(
      workflow,
      contains('globos-print-station-windows-x64-\${{ github.sha }}'),
    );
  });
}
