import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/production_gate_test_support.dart';

void main() {
  test('attendance names use a scoped database function', () {
    final service = File(
      'lib/core/services/attendance_service.dart',
    ).readAsStringSync();
    final migration = File(
      'supabase/migrations/20260724025456_attendance_logs_with_names.sql',
    ).readAsStringSync();
    final deployScript = readProductionGateContract();
    final verification = File(
      'scripts/verify_attendance_logs_with_names.sql',
    ).readAsStringSync();

    expect(service, contains("'get_attendance_logs_with_names'"));
    expect(migration, contains('SECURITY DEFINER'));
    expect(migration, contains('actor.auth_id = auth.uid()'));
    expect(migration, contains('public.user_accessible_stores(auth.uid())'));
    expect(
      migration,
      contains('REVOKE ALL ON FUNCTION public.get_attendance_logs_with_names'),
    );
    expect(
      migration,
      contains(
        'GRANT EXECUTE ON FUNCTION public.get_attendance_logs_with_names',
      ),
    );
    expect(migration, contains('attendance_logs_store_logged_at_idx'));
    expect(
      deployScript,
      contains('20260724025456_attendance_logs_with_names.sql'),
    );
    expect(deployScript, contains('verify_attendance_logs_with_names.sql'));
    expect(verification, contains('ATTENDANCE_NAMES_VERIFY_RPC_MISSING'));
    expect(verification, contains('ATTENDANCE_NAMES_VERIFY_INDEX_MISSING'));
  });
}
