import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('printer destination deletion is permanent and audited', () {
    final migration = readRepoFile(
      'supabase/migrations/20260805010000_printer_destination_hard_delete.sql',
    );

    expect(migration, contains('DELETE FROM public.printer_destinations'));
    expect(migration, contains('ON DELETE SET NULL'));
    expect(migration, contains("status = 'cancelled'"));
    expect(migration, contains("last_error = 'PRINTER_DESTINATION_DELETED'"));
    expect(migration, contains("'hard_deleted', true"));
    expect(migration, contains("'retained_print_job_count'"));
    expect(migration, isNot(contains('SET is_active = false')));
  });

  test('production gate includes hard-delete preflight and verification', () {
    final preflight = readRepoFile(
      'scripts/preflight_printer_destination_hard_delete.sql',
    );
    final verify = readRepoFile(
      'scripts/verify_printer_destination_hard_delete.sql',
    );

    expect(preflight, contains('PRINTER_HARD_DELETE_RPC_MISSING'));
    expect(verify, contains('PRINTER_HARD_DELETE_SET_NULL_MISSING'));
    expect(verify, contains('PRINTER_HARD_DELETE_RPC_INVALID'));
  });
}
