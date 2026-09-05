import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260807200000_cancellation_restore_and_live_sales.sql';

  test('cancellation undo stays append-only and supports repeat cycles', () {
    final migration = File(migrationPath).readAsStringSync();
    final preflight = File(
      'scripts/preflight_cancellation_restore_and_live_sales.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_cancellation_restore_and_live_sales.sql',
    ).readAsStringSync();

    expect(migration, contains('order_cancellation_reversals'));
    expect(migration, contains('BEFORE UPDATE OR DELETE'));
    expect(migration, contains('restore_cancelled_order('));
    expect(migration, contains('restore_cancelled_order_item('));
    expect(
      migration,
      contains(
        'DROP INDEX IF EXISTS public.order_cancellation_ledger_order_once_idx',
      ),
    );
    expect(migration, contains("'brand_admin'"));
    expect(migration, contains('TABLE_ALREADY_OCCUPIED'));
    expect(preflight, contains('CANCELLATION_RESTORE_REQUIRED_OBJECT_MISSING'));
    expect(verification, contains('CANCELLATION_RESTORE_RLS_DISABLED'));
    expect(verification, contains('CANCELLATION_RESTORE_PRIVILEGE_INVALID'));
  });

  test('manager report exposes gross, cancellation, net, and payment mix', () {
    final migration = File(migrationPath).readAsStringSync();
    final provider = File(
      'lib/features/report/report_provider.dart',
    ).readAsStringSync();
    final reports = File(
      'lib/features/admin/tabs/reports_tab.dart',
    ).readAsStringSync();

    expect(migration, contains('get_store_sales_cancellation_total'));
    expect(
      provider,
      contains('grossOrderAmount => totalRevenue + cancelledAmount'),
    );
    expect(provider, contains("'get_store_report_summary'"));
    expect(
      File(
        'supabase/migrations/20260905060000_store_report_summary.sql',
      ).readAsStringSync(),
      contains(
        'public.get_store_sales_cancellation_total(p_store_id,v_from,v_to',
      ),
    );
    expect(reports, contains('reportsGrossOrderAmount'));
    expect(reports, contains('reportsCanceledAmount'));
    expect(reports, contains('reportsNetSales'));
    expect(reports, contains('paymentMethodBreakdown'));
  });

  test(
    'cashier tablet item actions stay visible and cancellations expose undo',
    () {
      final cashier = File(
        'lib/features/cashier/cashier_screen.dart',
      ).readAsStringSync();
      final waiter = File(
        'lib/features/waiter/waiter_screen.dart',
      ).readAsStringSync();

      expect(cashier, contains("'cashier_cancel_order_item_\${item.id}'"));
      expect(cashier, contains('OutlinedButton.icon'));
      expect(cashier, contains('cancellationUndoAction'));
      expect(cashier, contains('restoreCancelledOrderItem'));
      expect(cashier, contains('restoreCancelledOrder'));
      expect(waiter, contains('cancellationUndoAction'));
      expect(waiter, contains('restoreCancelledOrderItem'));
      expect(waiter, contains('restoreCancelledOrder'));
    },
  );

  test('receipt uses the supplied Woori account QR image asset', () {
    final receipt = File(
      'lib/core/hardware/receipt_builder.dart',
    ).readAsStringSync();

    expect(
      File('assets/images/woori_bank_account_qr.jpg').existsSync(),
      isTrue,
    );
    expect(receipt, contains('assets/images/woori_bank_account_qr.jpg'));
    expect(receipt, contains('generator.imageRaster'));
    expect(receipt, contains('WOORI BANK - 100202042976'));
    expect(receipt, isNot(contains('_bankTransferQrPayload')));
  });
}
