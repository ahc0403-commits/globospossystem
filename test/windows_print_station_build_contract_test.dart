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
    expect(script, contains('function Invoke-NativeCommand'));
    expect(script, contains(r'$exitCode = $LASTEXITCODE'));
    expect(script, contains(r'if ($exitCode -ne 0)'));
    expect(script, contains(r'throw "$FilePath exited with code $exitCode."'));
    expect(
      RegExp(r'^\s*(flutter|dart)\s+', multiLine: true).allMatches(script),
      isEmpty,
      reason: 'Every native build command must use the checked wrapper.',
    );
    expect(
      script,
      contains(
        'Invoke-NativeCommand -FilePath "flutter" -Arguments @('
        '"pub", "get")',
      ),
    );
    expect(
      script,
      contains('Invoke-NativeCommand -FilePath "dart" -Arguments @('),
    );
    expect(
      RegExp(
        r'Invoke-NativeCommand -FilePath "flutter" -Arguments @\('
        r'[\s\S]*?"build",\s*"windows",\s*"--release",',
      ).hasMatch(script),
      isTrue,
    );
    expect(script, contains('SUPABASE_ANON_KEY'));
    expect(script, isNot(contains('SUPABASE_SERVICE_KEY')));
    expect(script, contains('function Find-VisualCppRuntimeDirectory'));
    for (final runtimeFile in <String>[
      'msvcp140.dll',
      'vcruntime140.dll',
      'vcruntime140_1.dll',
    ]) {
      expect(
        script,
        contains(runtimeFile),
        reason: '$runtimeFile must be bundled for clean Windows installs.',
      );
    }
    expect(script, contains('Copy-Item -LiteralPath'));
    expect(script, contains('Required Visual C++ runtime was not bundled'));
    expect(
      script,
      contains('test/windows_print_station_build_contract_test.dart'),
    );
    expect(workflow, contains('runs-on: windows-2025'));
    expect(
      workflow,
      contains('globos-print-station-windows-x64-\${{ github.sha }}'),
    );
  });

  test(
    'Windows build runner propagates native nonzero exit codes',
    () async {
      final probeDirectory = Directory.systemTemp.createTempSync(
        'globos-native-exit-probe-',
      );
      try {
        final flutterProbe = File('${probeDirectory.path}/flutter.cmd');
        flutterProbe.writeAsStringSync('@exit /b 23\r\n');

        final parentPath = Platform.environment['PATH'] ?? '';
        final result = await Process.run(
          'pwsh',
          <String>[
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-File',
            File('scripts/build_windows_print_station.ps1').absolute.path,
            '-ArtifactDirectory',
            '${probeDirectory.path}/artifacts',
          ],
          environment: <String, String>{
            ...Platform.environment,
            'PATH': '${probeDirectory.path};$parentPath',
            'SUPABASE_URL': 'https://native-exit-probe.invalid',
            'SUPABASE_ANON_KEY': 'native-exit-probe-only',
          },
        );
        final output = '${result.stdout}\n${result.stderr}';

        expect(result.exitCode, isNot(0));
        expect(output, contains('flutter exited with code 23.'));
      } finally {
        probeDirectory.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isWindows
        ? 'The native exit probe runs in the exact-head Windows check.'
        : false,
  );
}
