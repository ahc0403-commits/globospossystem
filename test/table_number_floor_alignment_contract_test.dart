import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const slug = 'bunsik_binh_thanh_table_number_floor_alignment';

  test('Binh Thanh table names align with displayed floors by stable ID', () {
    final migration = File(
      'supabase/migrations/20260810150000_$slug.sql',
    ).readAsStringSync();
    final preflight = File('scripts/preflight_$slug.sql').readAsStringSync();
    final verification = File('scripts/verify_$slug.sql').readAsStringSync();
    final rollback = File('scripts/rollback_$slug.sql').readAsStringSync();

    for (final sql in [migration, preflight, verification, rollback]) {
      expect(sql, contains('8bc9eef5-dcd5-46b1-b931-23f77132322c'));
    }

    expect(migration, contains("WHEN '2F' THEN '1' || substr"));
    expect(migration, contains("WHEN '3F' THEN '2' || substr"));
    expect(migration, contains('target.id = desired.id'));
    expect(migration, contains("'table_id', id"));
    expect(migration, contains("'qr_identity', 'table_id preserved'"));
    expect(migration, contains('BINH_THANH_TABLE_NUMBER_TARGET_COLLISION'));

    expect(migration, isNot(contains('UPDATE public.table_qr_tokens')));
    expect(migration, isNot(contains('DELETE FROM public.table_qr_tokens')));
    expect(migration, isNot(contains('UPDATE public.printer_destinations')));
    expect(
      migration,
      isNot(contains('DELETE FROM public.printer_destinations')),
    );

    expect(verification, contains("details->>'migration' = '20260810150000'"));
    expect(verification, contains("renamed.value->>'table_id'"));
    expect(rollback, contains("renamed.value->>'old_table_number'"));
    expect(rollback, contains('BINH_THANH_TABLE_NUMBER_ROLLBACK_COLLISION'));
  });
}
