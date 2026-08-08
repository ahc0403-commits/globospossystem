import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';

void main() {
  test('manual closing persists note counts and server-calculated variance', () {
    final migration = File(
      'supabase/migrations/20260808200000_daily_closing_cash_reconciliation.sql',
    ).readAsStringSync();
    final screen = File(
      'lib/features/admin/tabs/reports_tab.dart',
    ).readAsStringSync();

    expect(
      migration,
      contains('p_opening_cash_amount numeric DEFAULT 5000000'),
    );
    expect(migration, contains('cash_denominations jsonb'));
    expect(migration, contains('COALESCE(amount_portion, amount)'));
    expect(
      migration,
      contains('v_expected_cash := p_opening_cash_amount + v_payments_cash'),
    );
    expect(
      migration,
      contains('v_cash_variance := v_counted_cash - v_expected_cash'),
    );
    expect(screen, contains("Key('daily_closing_cash_dialog')"));
    expect(
      screen,
      contains('static const double _defaultOpeningCash = 5000000'),
    );
    expect(screen, contains("Key('daily_closing_note_\$denomination')"));
  });

  test('QR combo drink choices are exact-count and server validated', () {
    final migration = File(
      'supabase/migrations/20260808210000_qr_combo_drink_choices.sql',
    ).readAsStringSync();
    final screen = File(
      'lib/features/qr_order/qr_order_screen.dart',
    ).readAsStringSync();

    expect(migration, contains('combo_drink_choice_count'));
    expect(migration, contains('combo_drink_options'));
    expect(migration, contains("system_key IN ('alcohol', 'drink')"));
    expect(
      migration,
      contains(
        'public.admin_set_menu_combo(\n  p_item_id uuid,\n  p_is_combo boolean,\n  p_components jsonb,\n  p_drink_choice_count integer',
      ),
    );
    expect(migration, contains('JOIN public.menu_categories drink_category'));
    expect(migration, contains("drink_category.system_key = 'drink'"));
    expect(migration, contains('QR_COMBO_DRINK_CHOICES_INVALID'));
    expect(migration, contains("set_config('pos.qr_combo_payload'"));
    expect(migration, contains('NEW.combo_components := v_fixed || v_drinks'));
    expect(migration, contains("'is_total_quantity', true"));
    expect(screen, contains("Key('qr_combo_drink_progress')"));
    expect(screen, contains("Key('qr_combo_drink_confirm')"));
    expect(screen, contains('_selectedCount != requiredCount'));
  });

  test('combo editor stores count and uses the drink category', () {
    final screen = File(
      'lib/features/admin/tabs/menu_tab.dart',
    ).readAsStringSync();
    final service = File(
      'lib/core/services/menu_service.dart',
    ).readAsStringSync();

    expect(screen, contains("Key('admin_menu_combo_drink_count')"));
    expect(screen, isNot(contains('admin_menu_combo_drink_option_')));
    expect(screen, isNot(contains('_isComboDrinkChoiceSlot')));
    expect(service, contains("'p_drink_choice_count': drinkChoiceCount"));
    expect(service, isNot(contains("'p_drink_option_ids'")));
  });

  test('QR order line serializes selected combo drinks', () {
    const line = QrOrderLine(
      menuItemId: 'combo-1',
      quantity: 1,
      comboDrinkChoices: ['cola', 'water'],
    );

    expect(line.toJson(), {
      'menu_item_id': 'combo-1',
      'quantity': 1,
      'combo_drink_choices': ['cola', 'water'],
    });
  });

  test('combined checkout shows every non-cancelled item grouped by table', () {
    final screen = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();

    expect(screen, contains('cashier_combined_item_'));
    expect(screen, contains("item.status.toLowerCase() != 'cancelled'"));
    expect(
      screen,
      contains(
        "'\${item.label ?? l10n.cashierItemFallback} × \${item.quantity}'",
      ),
    );
    expect(screen, contains('item.unitPrice * item.quantity'));
  });
}
