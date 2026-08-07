import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260807180000_wet_tissue_price_2000.sql';

  test('cashier wet-tissue display and combined total use 2,000 VND', () {
    final cashier = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();
    final vietnamese = File('lib/l10n/app_vi.arb').readAsStringSync();
    final korean = File('lib/l10n/app_ko.arb').readAsStringSync();
    final english = File('lib/l10n/app_en.arb').readAsStringSync();

    expect(cashier, contains('const _wetTissueUnitPrice = 2000;'));
    expect(cashier, contains('quantity * _wetTissueUnitPrice'));
    expect(cashier, contains('wetTissueDifference * _wetTissueUnitPrice'));
    expect(vietnamese, contains('2.000 VND / khăn'));
    expect(korean, contains('1개당 2,000동'));
    expect(english, contains('2,000 VND each'));
  });

  test('server price changes without rewriting completed history', () {
    final migration = File(migrationPath).readAsStringSync();

    expect(migration, contains('v_total := 2000 * p_quantity'));
    expect(migration, contains("'unit_price', 2000"));
    expect(
      migration,
      contains("order_row.status NOT IN ('completed', 'cancelled')"),
    );
    expect(migration, contains('unit_price IN (2000, 3000)'));
    expect(migration, contains('NOT EXISTS ('));
  });
}
