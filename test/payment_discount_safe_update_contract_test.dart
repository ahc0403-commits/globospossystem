import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260807190000_payment_discount_safe_update.sql';

  test('discounted checkout scopes its allocation update', () {
    final migration = File(migrationPath).readAsStringSync();

    expect(
      migration,
      contains('UPDATE payment_discount_lines\n      SET base_discount_cents'),
    );
    expect(migration, contains('WHERE line_inc_cents > 0;'));
    expect(
      migration,
      contains("public.process_payment(uuid,uuid,numeric,text)"),
    );
    expect(migration, contains('v_occurrences <> 1'));
  });
}
