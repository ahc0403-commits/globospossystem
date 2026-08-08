import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/kitchen/kitchen_provider.dart';

void main() {
  test('combo migration is store-scoped, snapshotted, and print-visible', () {
    final migration = File(
      'supabase/migrations/'
      '20260727005957_category_reordering_and_combo_menu.sql',
    ).readAsStringSync();

    expect(
      migration,
      contains('CREATE TABLE IF NOT EXISTS public.menu_combo_components'),
    );
    expect(
      migration,
      contains(
        'ALTER TABLE public.menu_combo_components ENABLE ROW LEVEL SECURITY',
      ),
    );
    expect(migration, contains('public.user_accessible_stores(auth.uid())'));
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.admin_set_menu_combo'),
    );
    expect(
      migration,
      contains(
        'CREATE OR REPLACE FUNCTION public.admin_reorder_menu_categories',
      ),
    );
    expect(migration, contains('snapshot_order_item_combo_components'));
    expect(migration, contains("'components', COALESCE("));
    expect(
      migration,
      contains(
        'REVOKE ALL ON FUNCTION public.enqueue_print_jobs'
        '(uuid, text[], jsonb, text)',
      ),
    );
  });

  test('kitchen item reads combo snapshot quantities', () {
    final item = KitchenItem.fromJson({
      'id': 'order-item-1',
      'label': 'Lunch Combo',
      'quantity': 2,
      'status': 'pending',
      'created_at': '2026-07-27T08:00:00Z',
      'combo_components': [
        {'label': 'Kimbap', 'quantity': 1},
        {'label': 'Ramen', 'quantity': 2},
      ],
    });

    expect(item.comboComponents, hasLength(2));
    expect(item.comboComponents.first.label, 'Kimbap');
    expect(item.comboComponents.last.quantity * item.quantity, 4);
  });

  test('selected QR drink quantities stay absolute for multi-combo lines', () {
    final item = KitchenItem.fromJson({
      'id': 'order-item-2',
      'label': 'Combo 3',
      'quantity': 2,
      'status': 'pending',
      'created_at': '2026-08-08T08:00:00Z',
      'combo_components': [
        {'label': 'Kimbap', 'quantity': 1},
        {'label': 'Cola', 'quantity': 1, 'is_total_quantity': true},
        {'label': 'Water', 'quantity': 1, 'is_total_quantity': true},
      ],
    });

    expect(item.comboComponents.first.displayQuantity(item.quantity), 2);
    expect(item.comboComponents[1].displayQuantity(item.quantity), 1);
    expect(item.comboComponents[2].displayQuantity(item.quantity), 1);
  });
}
