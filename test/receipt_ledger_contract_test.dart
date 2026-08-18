import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';
import 'package:globos_pos_system/features/receipt_ledger/receipt_ledger_model.dart';

void main() {
  test('receipt ledger route is limited to sales operators', () {
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
          'items': [
            {'name': 'Tteokbokki', 'quantity': 2, 'unit_price': 50000},
            {'name': 'Kimbap', 'quantity': 1, 'unit_price': 50000},
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
    expect(page.receipts.single.items, hasLength(2));
    expect(page.receipts.single.items.first.name, 'Tteokbokki');
    expect(page.receipts.single.items.first.quantity, 2);
    expect(page.receipts.single.items.first.lineTotal, 100000);
    expect(page.receipts.single.printable, isTrue);
  });

  test('combined payment is one ledger entry with order allocations', () {
    final page = ReceiptLedgerPage.fromJson({
      'business_date': '2026-08-18',
      'generated_at': '2026-08-18T05:00:00Z',
      'summary': {
        'receipt_count': 1,
        'gross_amount': 230000,
        'adjusted_amount': 0,
        'net_amount': 230000,
      },
      'receipts': [
        {
          'receipt_id': 'receipt-combined',
          'receipt_number': 'BC-20260818-100001',
          'order_id': null,
          'combined_payment_group_id': 'group-1',
          'order_ids': ['order-a', 'order-b'],
          'store_id': 'store-1',
          'store_name': 'Store 1',
          'sold_at': '2026-08-18T04:00:00Z',
          'table_number': 'A1, B2',
          'sales_channel': 'combined',
          'cashier_name': 'CASHIER-01',
          'payments': [
            {'method': 'CREDITCARD', 'amount': 230000},
          ],
          'allocations': [
            {'order_id': 'order-a', 'table_number': 'A1', 'amount': 150000},
            {'order_id': 'order-b', 'table_number': 'B2', 'amount': 80000},
          ],
          'items': [],
          'gross_amount': 230000,
          'adjusted_amount': 0,
          'net_amount': 230000,
          'receipt_status': 'paid',
          'receipt_source': 'pos',
          'receipt_scope': 'combined',
          'printable': true,
          'digital_receipt_ready': true,
          'received_amount': 230000,
        },
      ],
      'has_more': false,
    });

    final receipt = page.receipts.single;
    expect(receipt.isCombined, isTrue);
    expect(receipt.orderId, isNull);
    expect(receipt.orderIds, ['order-a', 'order-b']);
    expect(receipt.payments, hasLength(1));
    expect(receipt.allocations, hasLength(2));
    expect(receipt.allocations.last.tableNumber, 'B2');
    expect(receipt.allocations.last.amount, 80000);
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

  test('date-selectable ledger sends the selected HCM business date', () {
    final screen = File(
      'lib/features/receipt_ledger/receipt_ledger_screen.dart',
    ).readAsStringSync();
    final service = File(
      'lib/features/receipt_ledger/receipt_ledger_service.dart',
    ).readAsStringSync();
    final sql = File(
      'supabase/migrations/20260814151000_receipt_ledger_business_date.sql',
    ).readAsStringSync();

    expect(screen, contains("Key('receipt_ledger_business_date_picker')"));
    expect(screen, contains('showDatePicker('));
    expect(screen, contains('lastDate: lastDate'));
    expect(service, contains("'get_receipt_ledger'"));
    expect(service, contains("'p_business_date': businessDate"));
    expect(sql, contains('p_business_date date'));
    expect(sql, contains('v_business_date date := p_business_date'));
    expect(sql, contains("AT TIME ZONE 'Asia/Ho_Chi_Minh'"));
  });

  test('receipt ledger includes non-cancelled ordered menu items', () {
    final sql = File(
      'supabase/migrations/20260816100000_receipt_ledger_menu_items.sql',
    ).readAsStringSync();

    expect(sql, contains('pos_order_items AS'));
    expect(sql, contains("'name', COALESCE("));
    expect(sql, contains("item.status <> 'cancelled'"));
    expect(sql, contains("COALESCE(order_items.items, '[]'::jsonb) AS items"));
  });

  test('combined tenders are grouped into one searchable ledger entry', () {
    final sql = File(
      'supabase/migrations/'
      '20260818120000_combined_payment_single_ledger_entry.sql',
    ).readAsStringSync();
    final service = File(
      'lib/features/receipt_ledger/receipt_ledger_service.dart',
    ).readAsStringSync();
    final screen = File(
      'lib/features/receipt_ledger/receipt_ledger_screen.dart',
    ).readAsStringSync();

    expect(sql, contains("'combined:' || payment.combined_payment_group_id"));
    expect(sql, contains('pos_allocation_summaries AS'));
    expect(sql, contains('receipt.combined_payment_group_id'));
    expect(sql, contains('receipt.order_ids::text ILIKE'));
    expect(service, contains('enqueueCombinedReceiptPrintJob'));
    expect(screen, contains("Key('receipt_ledger_order_allocations')"));
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
    expect(screen, contains("Key('receipt_ledger_ordered_items')"));
    expect(screen, contains("Key('receipt_ledger_reprint_confirm')"));
    expect(screen, contains('receiptLedgerService.reprint'));
  });
}
