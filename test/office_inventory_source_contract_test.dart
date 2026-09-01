import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/'
      '20260901010000_office_inventory_source_contract.sql';

  late String migration;

  setUpAll(() {
    migration = File(migrationPath).readAsStringSync();
  });

  test('publishes the complete Office inventory event contract', () {
    expect(migration, contains('v_office_inventory_source_events'));
    for (final eventType in [
      'purchase_order',
      'receipt',
      'issue',
      'stock_count',
      'adjustment',
    ]) {
      expect(migration, contains("'$eventType'"));
    }
    for (final column in [
      'source_event_id',
      'event_date',
      'quantity_in',
      'quantity_out',
      'system_quantity',
      'counted_quantity',
      'variance_quantity',
      'evidence_count',
      'occurred_at',
      'updated_at',
    ]) {
      expect(migration, contains(column));
    }
  });

  test('reconstructs a balanced per-store NXT snapshot', () {
    expect(migration, contains('office_get_inventory_nxt_snapshot'));
    expect(migration, contains('period_net'));
    expect(migration, contains('future_net'));
    expect(migration, contains('opening_quantity'));
    expect(migration, contains('receipt_quantity'));
    expect(migration, contains('issue_quantity'));
    expect(migration, contains('closing_quantity'));
    expect(migration, contains('p_period_end - p_period_start > 366'));
  });

  test('keeps both contracts service-role-only and security-invoker', () {
    expect(migration, contains('with (security_invoker = true)'));
    expect(migration, contains('security invoker'));
    expect(migration, contains('from public, anon, authenticated;'));
    expect(migration, contains('to service_role;'));
    expect(
      migration,
      isNot(
        contains(
          'grant select on public.'
          'v_office_inventory_source_events to authenticated',
        ),
      ),
    );
    expect(
      migration,
      isNot(
        contains(
          'grant execute on function\n  public.'
          'office_get_inventory_nxt_snapshot(uuid, date, date)\n  '
          'to authenticated',
        ),
      ),
    );
  });

  test('ships production preflight verification and rollback', () {
    final preflight = File(
      'scripts/preflight_office_inventory_source_contract.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_office_inventory_source_contract.sql',
    ).readAsStringSync();
    final rollback = File(
      'scripts/rollback_office_inventory_source_contract.sql',
    ).readAsStringSync();

    expect(preflight, contains('OFFICE_INVENTORY_PREFLIGHT_MISSING_OBJECTS'));
    expect(verification, contains('security_invoker=true'));
    expect(verification, contains('OFFICE_INVENTORY_VERIFY_NXT_BALANCE'));
    expect(rollback, contains('drop view if exists'));
    expect(rollback, contains('drop function if exists'));
  });
}
