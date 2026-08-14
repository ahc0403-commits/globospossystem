import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';
import 'package:globos_pos_system/features/receipt_ledger/receipt_ledger_model.dart';

void main() {
  test('today receipt ledger route is limited to sales operators', () {
    for (final role in const [
      'cashier',
      'admin',
      'store_admin',
      'brand_admin',
      'super_admin',
    ]) {
      expect(canAccessRouteForRole(role, '/receipts/today'), isTrue);
    }
    for (final role in const ['waiter', 'kitchen', 'print_station']) {
      expect(canAccessRouteForRole(role, '/receipts/today'), isFalse);
    }
  });

  test('ledger model keeps split payments under one receipt', () {
    final page = ReceiptLedgerPage.fromJson({
      'business_date': '2026-08-14',
      'generated_at': '2026-08-14T05:00:00Z',
      'summary': {
        'receipt_count': 1,
        'gross_amount': 150000,
        'adjusted_amount': 0,
        'net_amount': 150000,
      },
      'receipts': [
        {
          'receipt_id': 'receipt-1',
          'receipt_number': 'BC-20260814-000001',
          'order_id': 'order-1',
          'store_id': 'store-1',
          'store_name': 'Store 1',
          'sold_at': '2026-08-14T04:00:00Z',
          'table_number': 'A1',
          'sales_channel': 'dine_in',
          'cashier_name': 'CASHIER-01',
          'payments': [
            {'method': 'CASH', 'amount': 50000},
            {'method': 'CREDITCARD', 'amount': 100000},
          ],
          'gross_amount': 150000,
          'adjusted_amount': 0,
          'net_amount': 150000,
          'receipt_status': 'paid',
          'receipt_source': 'pos',
          'printable': true,
          'digital_receipt_ready': true,
        },
      ],
      'has_more': false,
    });

    expect(page.receipts, hasLength(1));
    expect(page.receipts.single.payments, hasLength(2));
    expect(page.receipts.single.printable, isTrue);
  });

  test('SQL groups POS payments and hardens ledger access', () {
    final sql = File(
      'supabase/migrations/20260814130000_today_receipt_ledger.sql',
    ).readAsStringSync();

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.get_today_receipt_ledger'),
    );
    expect(sql, contains("AT TIME ZONE 'Asia/Ho_Chi_Minh'"));
    expect(sql, contains('GROUP BY payment.order_id, payment.restaurant_id'));
    expect(sql, contains('adjusted_payment.is_revenue = true'));
    expect(sql, contains('public.user_accessible_stores(auth.uid())'));
    expect(
      sql,
      contains(
        "'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'",
      ),
    );
    expect(
      sql,
      contains('REVOKE ALL ON FUNCTION public.get_today_receipt_ledger'),
    );
  });

  test('all three role surfaces expose the common ledger', () {
    final cashier = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();
    final reports = File(
      'lib/features/admin/tabs/reports_tab.dart',
    ).readAsStringSync();
    final superAdmin = File(
      'lib/features/super_admin/super_admin_screen.dart',
    ).readAsStringSync();
    final screen = File(
      'lib/features/receipt_ledger/receipt_ledger_screen.dart',
    ).readAsStringSync();

    expect(cashier, contains("Key('cashier_today_receipt_ledger_entry')"));
    expect(reports, contains("Key('admin_today_receipt_ledger_entry')"));
    expect(
      superAdmin,
      contains("Key('super_admin_today_receipt_ledger_entry')"),
    );
    expect(screen, contains("Key('receipt_ledger_detail_dialog')"));
    expect(screen, contains("Key('receipt_ledger_reprint_confirm')"));
    expect(screen, contains('receiptLedgerService.reprint'));
  });
}
