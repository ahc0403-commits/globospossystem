import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    'supabase/migrations/20260722120000_cash_tender_and_protected_alcohol_vat.sql',
  ).readAsStringSync();
  final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();
  final paymentService = File(
    'lib/core/services/payment_service.dart',
  ).readAsStringSync();
  final cashier = File(
    'lib/features/cashier/cashier_screen.dart',
  ).readAsStringSync();

  test(
    'cash tender receipt RPC validates and stores received/change amounts',
    () {
      expect(migration, contains('enqueue_cash_receipt_print_job'));
      expect(migration, contains('CASH_RECEIVED_AMOUNT_INSUFFICIENT'));
      expect(
        migration,
        contains("'received_amount', ROUND(p_received_amount, 2)"),
      );
      expect(
        migration,
        contains(
          "'change_amount', ROUND(p_received_amount - v_total_amount, 2)",
        ),
      );
      expect(paymentService, contains("'enqueue_cash_receipt_print_job'"));
      expect(
        cashier,
        contains('CashTenderDialog(amountDue: order.remainingDue)'),
      );
    },
  );

  test('protected alcohol category drives server-authoritative VAT class', () {
    expect(migration, contains("system_key = 'alcohol'"));
    expect(migration, contains("name_ko = '주류'"));
    expect(migration, contains("name_vi = 'Đồ uống có cồn'"));
    expect(migration, contains("name_en = 'Alcohol'"));
    expect(migration, contains('MENU_ALCOHOL_CATEGORY_NAME_FIXED'));
    expect(migration, contains('sync_menu_item_vat_category_trigger'));
    expect(migration, contains("SET vat_pricing_mode = 'exclusive'"));
  });

  test(
    'production gate allowlists, preflights, and verifies the migration',
    () {
      expect(
        deploy,
        contains('20260722120000_cash_tender_and_protected_alcohol_vat.sql'),
      );
      expect(deploy, contains('preflight_cash_tender_and_alcohol_vat.sql'));
      expect(deploy, contains('verify_cash_tender_and_alcohol_vat.sql'));
    },
  );
}
