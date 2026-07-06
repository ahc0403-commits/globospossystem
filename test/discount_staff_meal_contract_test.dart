import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final schemaMigration = File(
    'supabase/migrations/20260706010000_discount_staff_meal_v1_schema.sql',
  );
  final paymentMigration = File(
    'supabase/migrations/20260706011000_discount_staff_meal_v1_payment_math.sql',
  );
  final storageMigration = File(
    'supabase/migrations/20260706012000_discount_staff_meal_v1_storage.sql',
  );
  final meinvoiceGuardMigration = File(
    'supabase/migrations/20260706013000_discount_staff_meal_v1_meinvoice_guard.sql',
  );
  final photoObjetContractMigration = File(
    'supabase/migrations/301_photo_objet_sales_pos_contract_closure.sql',
  );
  final pinService = File('lib/core/services/pin_service.dart');
  final settingsTab = File('lib/features/admin/tabs/settings_tab.dart');
  final waiterScreen = File('lib/features/waiter/waiter_screen.dart');

  test(
    'discount and staff meal migration exposes the pinned schema and RPCs',
    () {
      final sql = schemaMigration.readAsStringSync();

      expect(sql, contains("order_purpose IN ('customer', 'staff_meal')"));
      expect(
        sql,
        contains('CREATE TABLE IF NOT EXISTS public.order_discounts'),
      );
      expect(
        sql,
        contains(
          'CREATE UNIQUE INDEX IF NOT EXISTS order_discounts_one_active',
        ),
      );
      expect(
        sql,
        contains('CREATE OR REPLACE FUNCTION public.apply_order_discount'),
      );
      expect(
        sql,
        contains('CREATE OR REPLACE FUNCTION public.create_staff_meal_order'),
      );
      expect(sql, contains("'staff_meal'"));
      expect(
        sql,
        contains('public.void_active_order_discount_for_item_change'),
      );
      expect(
        sql,
        contains("COALESCE(o.order_purpose, 'customer') = 'staff_meal'"),
      );
    },
  );

  test('new RPCs are explicitly revoked and granted', () {
    final sql = schemaMigration.readAsStringSync();

    for (final fn in [
      'set_discount_manager_pin',
      'clear_discount_manager_pin',
      'has_discount_manager_pin',
      'apply_order_discount',
      'void_order_discount',
      'create_staff_meal_order',
      'get_cashier_today_summary',
    ]) {
      expect(sql, contains('REVOKE ALL ON FUNCTION public.$fn'));
      expect(sql, contains('GRANT EXECUTE ON FUNCTION public.$fn'));
    }

    expect(
      sql,
      contains(
        'REVOKE ALL ON FUNCTION public.calculate_order_discountable_total(uuid, uuid) FROM PUBLIC, anon, authenticated',
      ),
    );
    expect(
      sql,
      isNot(
        contains(
          'GRANT EXECUTE ON FUNCTION public.calculate_order_discountable_total(uuid, uuid) TO authenticated',
        ),
      ),
    );
  });

  test('process payment preserves lifecycle and service invariants', () {
    final sql = paymentMigration.readAsStringSync();

    expect(sql, contains('Contract invariant I3'));
    expect(sql, contains("oi.status NOT IN ('ready', 'served', 'cancelled')"));
    expect(sql, contains("IF p_method = 'SERVICE' THEN"));
    expect(sql, contains("v_payment_method_storage := 'OTHER'"));
    expect(
      sql,
      contains("COALESCE(v_order.order_purpose, 'customer') = 'staff_meal'"),
    );
    expect(sql, contains("RAISE EXCEPTION 'STAFF_MEAL_SERVICE_REQUIRED'"));
    expect(sql, contains("RAISE EXCEPTION 'PAYMENT_AMOUNT_EXCEEDS_REMAINING'"));
    expect(sql, contains("RAISE EXCEPTION 'PAYMENT_AMOUNT_INVALID'"));
    expect(sql, contains('IF v_has_discount AND v_should_complete THEN'));
    expect(sql, contains("status = 'consumed'"));
    expect(sql, isNot(contains('INSERT INTO einvoice_jobs')));
    expect(sql, isNot(contains('send_order_payload')));
    expect(sql, isNot(contains('dc_rate')));
    expect(sql, isNot(contains('dc_amt')));
  });

  test('meinvoice enqueue skips staff meals and non-revenue completions', () {
    final sql = meinvoiceGuardMigration.readAsStringSync();

    expect(
      sql,
      contains("COALESCE(NEW.order_purpose, 'customer') = 'staff_meal'"),
    );
    expect(sql, contains('p.is_revenue = true'));
    expect(sql, contains('INSERT INTO public.meinvoice_jobs'));
    expect(sql, isNot(contains('INSERT INTO public.einvoice_jobs')));
  });

  test('discount allocation and zero-payment constraints are present', () {
    final sql = paymentMigration.readAsStringSync();

    expect(sql, contains('payments_amount_portion_non_negative'));
    expect(sql, contains('CHECK (amount >= 0)'));
    expect(sql, contains('payment_discount_lines'));
    expect(sql, contains('base_discount_cents'));
    expect(sql, contains('discount_fraction DESC'));
    expect(sql, contains('allocated_discount_cents'));
  });

  test('discount proof storage is store-scoped and immutable to clients', () {
    final sql = storageMigration.readAsStringSync();

    expect(sql, contains("'discount-proofs'"));
    expect(sql, contains('storage_discount_proofs_select'));
    expect(sql, contains('storage_discount_proofs_insert'));
    expect(sql, contains('FOR SELECT TO authenticated'));
    expect(sql, contains('FOR INSERT TO authenticated'));
    expect(sql, isNot(contains('FOR ALL TO authenticated')));
    expect(sql, contains('(storage.foldername(name))[2]'));
    expect(sql, contains('public.user_accessible_stores(auth.uid())'));
    expect(sql, contains('No authenticated UPDATE/DELETE policies'));

    final schemaSql = schemaMigration.readAsStringSync();
    expect(schemaSql, contains('FROM storage.objects obj'));
    expect(schemaSql, contains("obj.bucket_id = 'discount-proofs'"));
    expect(schemaSql, contains("RAISE EXCEPTION 'DISCOUNT_PROOF_NOT_FOUND'"));
  });

  test('cashier today summary uses the HCMC business day window', () {
    final sql = schemaMigration.readAsStringSync();

    expect(
      sql,
      contains(
        "v_today_start := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'",
      ),
    );
    expect(sql, contains("v_today_end := v_today_start + interval '1 day'"));
    expect(sql, contains('created_at < v_today_end'));
    expect(sql, contains('updated_at < v_today_end'));
  });

  test('photo objet sales contract is closed after legacy 251 migration', () {
    final sql = photoObjetContractMigration.readAsStringSync();

    expect(sql, contains('JOIN public.restaurants r ON r.id = pos.store_id'));
    expect(sql, contains('DROP POLICY IF EXISTS "po_sales_master"'));
    expect(sql, contains('DROP POLICY IF EXISTS "po_sales_store"'));
    expect(sql, contains('photo_objet_sales_select_scope'));
    expect(sql, contains('public.user_accessible_stores(auth.uid())'));
  });

  test('admin settings exposes discount manager PIN setup path', () {
    final serviceSource = pinService.readAsStringSync();
    final settingsSource = settingsTab.readAsStringSync();

    expect(serviceSource, contains('hasDiscountManagerPin'));
    expect(serviceSource, contains("'has_discount_manager_pin'"));
    expect(serviceSource, contains('setDiscountManagerPin'));
    expect(serviceSource, contains("'set_discount_manager_pin'"));
    expect(serviceSource, contains("'p_pin': pin"));
    expect(serviceSource, contains('clearDiscountManagerPin'));
    expect(serviceSource, contains("'clear_discount_manager_pin'"));
    expect(serviceSource, isNot(contains('fetchDiscountManagerPinHash')));

    expect(settingsSource, contains('_loadDiscountManagerPinStatus'));
    expect(settingsSource, contains('_showSetDiscountManagerPinDialog'));
    expect(settingsSource, contains('_clearDiscountManagerPin'));
    expect(settingsSource, contains('settingsDiscountManagerPinTitle'));
    expect(settingsSource, contains('settingsDiscountManagerPinSetMessage'));
  });

  test('discount manager PIN RPCs do not return settings rows', () {
    final sql = schemaMigration.readAsStringSync();

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.set_discount_manager_pin'),
    );
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.clear_discount_manager_pin'),
    );
    expect(sql, contains(') RETURNS boolean'));
    expect(sql, isNot(contains('RETURN v_updated;')));
    expect(sql, isNot(contains(') RETURNS public.restaurant_settings')));
  });

  test('cashier split payment path remains wired in payment execution', () {
    final cashier = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();
    final provider = File(
      'lib/features/payment/payment_provider.dart',
    ).readAsStringSync();
    final service = File(
      'lib/core/services/payment_service.dart',
    ).readAsStringSync();

    expect(cashier, contains("Key('cashier_split_payment_button')"));
    expect(cashier, contains('cashierSplitPaymentTitle'));
    expect(cashier, contains('processPaymentSplits('));
    expect(cashier, contains('selectedOrder.remainingDue'));
    expect(cashier, contains('canProcessSplit: !order.isStaffMeal'));
    expect(
      provider,
      contains('Future<List<Map<String, dynamic>>?> processPaymentSplits'),
    );
    expect(provider, contains('payments(amount_portion)'));
    expect(provider, contains('paidTotal'));
    expect(provider, contains('remainingDue'));
    expect(
      service,
      contains('Future<List<Map<String, dynamic>>> processPaymentSplits'),
    );
  });

  test('discount modal previews subtotal discount and payment due', () {
    final cashier = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();
    final modal = File(
      'lib/features/cashier/discount_modal.dart',
    ).readAsStringSync();

    expect(cashier, contains('menuSubtotal: selectedOrder.menuSubtotal'));
    expect(
      cashier,
      contains('serviceChargeTotal: selectedOrder.serviceChargeTotal'),
    );
    expect(modal, contains('required this.menuSubtotal'));
    expect(modal, contains('required this.serviceChargeTotal'));
    expect(modal, contains('_previewDiscountAmount'));
    expect(modal, contains('l10n.cashierSubtotal'));
    expect(modal, contains('l10n.cashierDiscountSummary'));
    expect(modal, contains('l10n.cashierPaymentDue'));
  });

  test('waiter staff meal action is online-only', () {
    final waiter = waiterScreen.readAsStringSync();

    expect(
      waiter,
      contains("import '../../core/services/connectivity_service.dart';"),
    );
    expect(waiter, contains('ref.watch(connectivityProvider)'));
    expect(waiter, contains('storeId == null || !isOnline'));
    expect(waiter, contains("key: const Key('waiter_staff_meal_action')"));
    expect(waiter, contains("key: const Key('waiter_staff_meal_submit')"));
    expect(waiter, contains('selectedCount == 0 || !isOnline'));
    expect(waiter, contains('l10n.posDisabledOffline'));
  });
}
