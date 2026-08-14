import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('payroll PIN status and verification use protected RPCs', () {
    final migration = File(
      'supabase/migrations/20260814173000_payroll_pin_status_verification_rpc.sql',
    ).readAsStringSync();
    final service = File(
      'lib/core/services/pin_service.dart',
    ).readAsStringSync();

    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.has_payroll_pin'),
    );
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.verify_payroll_pin'),
    );
    expect(
      migration,
      contains('PERFORM public.require_admin_actor_for_restaurant(p_store_id)'),
    );
    expect(migration, contains('FROM PUBLIC, anon'));
    expect(migration, contains('-- production-gate: self-verifying'));
    expect(service, contains("'has_payroll_pin'"));
    expect(service, contains("'verify_payroll_pin'"));
    expect(service, isNot(contains(".select('payroll_pin')")));
  });
}
