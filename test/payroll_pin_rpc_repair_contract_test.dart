import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260723050000_payroll_pin_rpc_repair.sql';

  test('payroll PIN RPCs restore the app contract without exposing hashes', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('CREATE FUNCTION public.set_payroll_pin'));
    expect(sql, contains('CREATE FUNCTION public.clear_payroll_pin'));
    expect(sql, contains('RETURNS boolean'));
    expect(sql, contains('PAYROLL_PIN_HASH_INVALID'));
    expect(sql, contains('public.require_admin_actor_for_restaurant'));
    expect(sql, contains("'set_payroll_pin'"));
    expect(sql, contains("'clear_payroll_pin'"));
    expect(sql, contains('FROM PUBLIC, anon'));
    expect(sql, contains('TO authenticated, service_role'));
    expect(sql, isNot(contains('RETURNS public.restaurant_settings')));
  });

  test('production deployment gates the payroll PIN repair', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();
    final preflight = File(
      'scripts/preflight_payroll_pin_rpc_repair.sql',
    ).readAsStringSync();
    final verify = File(
      'scripts/verify_payroll_pin_rpc_repair.sql',
    ).readAsStringSync();

    expect(deploy, contains('20260723050000_payroll_pin_rpc_repair.sql'));
    expect(deploy, contains('preflight_payroll_pin_rpc_repair.sql'));
    expect(deploy, contains('verify_payroll_pin_rpc_repair.sql'));
    expect(
      preflight,
      contains('PAYROLL_PIN_REPAIR_PREFLIGHT_ADMIN_HELPER_MISSING'),
    );
    expect(verify, contains('PAYROLL_PIN_REPAIR_FUNCTION_MISSING'));
    expect(verify, contains('PAYROLL_PIN_REPAIR_ANON_EXECUTE_NOT_REVOKED'));
  });

  test('Flutter sends the exact payroll PIN RPC parameter contract', () {
    final service = File(
      'lib/core/services/pin_service.dart',
    ).readAsStringSync();

    expect(service, contains("'set_payroll_pin'"));
    expect(service, contains("'p_store_id': storeId"));
    expect(service, contains("'p_payroll_pin': hashPin(pin)"));
    expect(service, contains("'clear_payroll_pin'"));
  });
}
