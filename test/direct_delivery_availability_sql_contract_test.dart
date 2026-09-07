import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260907150000_cashier_direct_delivery_availability.sql';
  const runtimePath =
      'supabase/tests/direct_delivery_availability_contract_test.sql';

  test('cashier availability migration is additive and least privilege', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('direct_order_staff_get_availability'));
    expect(sql, contains('direct_order_staff_set_paused'));
    expect(
      sql,
      contains(
        "ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']",
      ),
    );
    expect(sql, contains('FOR UPDATE'));
    expect(sql, contains('IF v_previous IS DISTINCT FROM p_is_paused'));
    expect(sql, contains("'direct_order_intake_availability_changed'"));
    expect(sql, contains("'previous_paused', v_previous"));
    expect(sql, contains("'paused', v_storefront.is_paused"));
    expect(sql, contains('FROM PUBLIC, anon'));
    expect(sql, contains('TO authenticated, service_role'));
    expect(sql, isNot(contains('direct_order_admin_upsert_storefront(')));
  });

  test('CLOSED keeps the server guard only on new public intake', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(
      sql,
      contains("'public.direct_order_public_submit(uuid,text,uuid,jsonb)'"),
    );
    expect(
      sql,
      contains("'public.direct_order_staff_quote(uuid,uuid,numeric,text)'"),
    );
    expect(
      sql,
      contains("'public.direct_order_approve_payment(uuid,uuid,numeric,text)'"),
    );
    expect(
      sql,
      contains(
        "v_guard constant text := E'\\n    AND storefront.is_paused = false'",
      ),
    );
    expect(sql, contains("position('v_storefront.is_paused' IN v_definition)"));
    expect(sql, contains('submit pause guard missing'));
  });

  test('runtime and catalog contracts cover availability boundaries', () {
    final runtime = File(runtimePath).readAsStringSync();
    final schema = File(
      'supabase/tests/direct_delivery_schema_contract_test.sql',
    ).readAsStringSync();
    final preconditions = File(
      'supabase/tests/direct_delivery_precondition_contract_test.sql',
    ).readAsStringSync();

    for (final marker in [
      'AVAILABILITY_IDEMPOTENCY_FAILED',
      'AVAILABILITY_NEW_INTAKE_GUARD_FAILED',
      'AVAILABILITY_EXISTING_QUOTE_BLOCKED',
      'AVAILABILITY_EXISTING_APPROVAL_FAILED',
      'AVAILABILITY_DISABLED_SET_FAILED',
      'AVAILABILITY_UNCONFIGURED_SET_FAILED',
      'AVAILABILITY_FORBIDDEN_READ_NOT_BLOCKED',
      'AVAILABILITY_CROSS_STORE_SET_FAILED',
    ]) {
      expect(runtime, contains(marker), reason: marker);
    }
    expect(
      schema,
      contains('public.direct_order_staff_get_availability(uuid)'),
    );
    expect(
      schema,
      contains('public.direct_order_staff_set_paused(uuid,boolean)'),
    );
    expect(
      preconditions,
      contains('paused storefront keeps existing approval operational'),
    );
  });
}
