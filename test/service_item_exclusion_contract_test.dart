import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migrationPath =
      'supabase/migrations/20260707010000_service_item_exclusion_v1.sql';
  const dbContractPath =
      'supabase/tests/service_item_exclusion_contract_test.sql';
  const planPath = 'docs/pos/SERVICE_ITEM_EXCLUSION_V1_PLAN_2026_07_07.md';
  const adrPath = 'docs/ADR-014-Brand-Store-Multi-Access-Model.md';

  test('migration adds service item state and manager-approved RPCs', () {
    final sql = readRepoFile(migrationPath);

    expect(
      sql,
      contains(
        'ADD COLUMN IF NOT EXISTS is_service_item boolean NOT NULL DEFAULT false',
      ),
    );
    expect(sql, contains('ADD COLUMN IF NOT EXISTS service_reason text'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS service_marked_by uuid'));
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.mark_order_item_service'),
    );
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.unmark_order_item_service'),
    );
    expect(sql, contains("v_item.item_type <> 'menu_item'"));
    expect(sql, contains("ARRAY['discount_apply']"));
    expect(sql, contains('verify_discount_manager_pin_or_raise'));
    expect(sql, contains('SERVICE_MARK_AFTER_PAYMENT'));
    expect(sql, contains('SERVICE_MARK_PURPOSE_UNSUPPORTED'));
    expect(sql, contains('SERVICE_MARK_ITEM_NOT_PROVIDED'));
    expect(sql, contains('FULL_SERVICE_NOT_ALLOWED'));
    expect(sql, contains('void_active_order_discount_for_item_change'));
  });

  test('payment math excludes service items and zeros VAT residues', () {
    final sql = readRepoFile(migrationPath);

    expect(
      sql,
      contains('COALESCE(oi.is_service_item, false) AS is_service_item'),
    );
    expect(sql, contains('IF v_item.is_service_item THEN'));
    expect(sql, contains('SET vat_rate = 0,'));
    expect(sql, contains('vat_amount = 0,'));
    expect(sql, contains('total_amount_ex_tax = 0,'));
    expect(sql, contains('paying_amount_inc_tax = 0'));
    expect(sql, contains('CONTINUE;'));
    expect(sql, contains('AND COALESCE(is_service_item, false) = false'));
    expect(sql, contains('AND COALESCE(oi.is_service_item, false) = false'));
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.calculate_order_discountable_total',
      ),
    );
  });

  test('inventory deduction loop still consumes real service food', () {
    final sql = readRepoFile(migrationPath);
    final inventoryStart = sql.indexOf('oi.id AS order_item_id');
    final inventoryEnd = sql.indexOf('INSERT INTO audit_logs', inventoryStart);

    expect(inventoryStart, isNonNegative);
    expect(inventoryEnd, greaterThan(inventoryStart));
    final inventoryLoop = sql.substring(inventoryStart, inventoryEnd);

    expect(inventoryLoop, contains("AND oi.item_type = 'menu_item'"));
    expect(inventoryLoop, isNot(contains('is_service_item')));
  });

  test('meInvoice snapshot excludes service item lines asynchronously', () {
    final sql = readRepoFile(migrationPath);

    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.enqueue_meinvoice_cash_register_job',
      ),
    );
    expect(sql, contains('line_items_snapshot'));
    expect(sql, contains('AND COALESCE(oi.is_service_item, false) = false'));
    expect(sql, contains('errors never block payment completion'));
  });

  test(
    'Flutter cashier, calculator, and receipts expose service item contract',
    () {
      final orderModel = readRepoFile('lib/features/order/order_model.dart');
      final calculator = readRepoFile(
        'lib/core/payments/payment_total_calculator.dart',
      );
      final paymentService = readRepoFile(
        'lib/core/services/payment_service.dart',
      );
      final provider = readRepoFile(
        'lib/features/payment/payment_provider.dart',
      );
      final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');
      final receipt = readRepoFile('lib/core/hardware/receipt_builder.dart');
      final paymentDetail = readRepoFile(
        'lib/features/payment/payment_detail_screen.dart',
      );

      expect(orderModel, contains('final bool isServiceItem;'));
      expect(orderModel, contains("json['is_service_item']"));
      expect(orderModel, contains('final String? serviceReason;'));
      expect(calculator, contains('required this.serviceItemTotal'));
      expect(
        calculator,
        contains('if (itemType == \'menu_item\' && line.isServiceItem)'),
      );
      expect(paymentService, contains("'mark_order_item_service'"));
      expect(paymentService, contains("'unmark_order_item_service'"));
      expect(paymentService, contains('is_service_item, service_reason'));
      expect(provider, contains('serviceItemTotal: quote.serviceItemTotal'));
      expect(provider, contains('int get serviceItemCount'));
      expect(provider, contains('final int paymentCount;'));
      expect(
        cashier,
        contains('final canManageServiceItems = isAdmin || canApplyDiscount'),
      );
      expect(cashier, contains('order.paymentCount == 0'));
      expect(cashier, contains('cashier_service_item_badge'));
      expect(cashier, contains('cashier_service_item_action_'));
      expect(cashier, contains('cashier_service_item_reason_input'));
      expect(cashier, contains('cashier_service_item_pin_input'));
      expect(receipt, contains('final serviceItemCount = items'));
      expect(receipt, contains('where((item) => !item.isServiceItem)'));
      expect(paymentDetail, contains('isServiceItem: _boolValue'));
    },
  );

  test('service item copy exists in every supported locale', () {
    for (final path in [
      'lib/l10n/app_en.arb',
      'lib/l10n/app_ko.arb',
      'lib/l10n/app_vi.arb',
    ]) {
      final arb = readRepoFile(path);
      expect(arb, contains('cashierServiceItemBadge'));
      expect(arb, contains('cashierServiceItemMarkTitle'));
      expect(arb, contains('cashierServiceItemUnmarkTitle'));
      expect(arb, contains('cashierServiceItemFooter'));
    }
  });

  test('runtime DB contract and design provenance are documented', () {
    final dbContract = readRepoFile(dbContractPath);
    final plan = readRepoFile(planPath);
    final adr = readRepoFile(adrPath);

    expect(dbContract, contains('SELECT plan(9)'));
    expect(dbContract, contains('public.mark_order_item_service'));
    expect(dbContract, contains('public.unmark_order_item_service'));
    expect(dbContract, contains('SERVICE_MARK_AFTER_PAYMENT'));
    expect(dbContract, contains('SERVICE_MARK_PURPOSE_UNSUPPORTED'));
    expect(dbContract, contains('SERVICE_MARK_ITEM_NOT_PROVIDED'));
    expect(dbContract, contains('FULL_SERVICE_NOT_ALLOWED'));
    expect(dbContract, contains('SERVICE_MARK_ITEM_TYPE'));
    expect(dbContract, contains('line_items_snapshot'));
    expect(dbContract, contains('current_stock'));
    expect(plan, contains('Service Item Exclusion V1'));
    expect(plan, contains(dbContractPath));
    expect(adr, contains('mark_order_item_service'));
    expect(adr, contains('unmark_order_item_service'));
  });
}
