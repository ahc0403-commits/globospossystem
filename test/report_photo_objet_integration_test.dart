import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('Photo Objet daily rows separate sales and service revenue', () {
    final totals = aggregatePhotoObjetReportRows([
      {
        'sale_date': '2026-07-19',
        'total_gross_sales': '5160000',
        'total_transactions': 59,
        'total_service_amount': '100000',
      },
      {
        'sale_date': '2026-07-18',
        'total_gross_sales': 3130000,
        'total_transactions': '36',
        'total_service_amount': 0,
      },
    ]);

    expect(totals.totalRevenue, 8190000);
    expect(totals.serviceTotal, 100000);
    expect(totals.transactionCount, 95);
    expect(totals.dailyBreakdown, hasLength(2));
    expect(totals.dailyBreakdown.first.date, DateTime(2026, 7, 18));
    expect(totals.dailyBreakdown.first.total, 3130000);
    expect(totals.dailyBreakdown.first.teamCount, 36);
    expect(
      totals.dailyBreakdown.first.averageTableAmount,
      closeTo(3130000 / 36, 0.001),
    );
    expect(totals.dailyBreakdown.last.total, 5060000);
    expect(totals.dailyBreakdown.last.teamCount, 59);
  });

  test('Photo Objet service revenue cannot make sales revenue negative', () {
    final totals = aggregatePhotoObjetReportRows([
      {
        'sale_date': '2026-08-03',
        'total_gross_sales': 70000,
        'total_transactions': 1,
        'total_service_amount': 100000,
      },
    ]);

    expect(totals.totalRevenue, 0);
    expect(totals.serviceTotal, 100000);
    expect(totals.dailyBreakdown.single.total, 0);
  });

  test('Super Admin reports aggregate Photo Objet sales by store', () {
    final totals = aggregateSuperAdminPhotoObjetSalesByStore([
      {
        'store_id': 'thao-dien',
        'sale_date': '2026-08-14',
        'total_gross_sales': 5160000,
        'total_service_amount': 100000,
        'total_transactions': 59,
      },
      {
        'store_id': 'thao-dien',
        'sale_date': '2026-08-15',
        'total_gross_sales': 3130000,
        'total_service_amount': 0,
        'total_transactions': 36,
      },
      {
        'store_id': 'bien-hoa',
        'sale_date': '2026-08-15',
        'total_gross_sales': 2000000,
        'total_service_amount': 50000,
        'total_transactions': 20,
      },
      {
        'store_id': '',
        'sale_date': '2026-08-15',
        'total_gross_sales': 999999,
        'total_service_amount': 0,
        'total_transactions': 1,
      },
    ]);

    expect(totals, {'thao-dien': 8190000, 'bien-hoa': 1950000});
  });

  test('Super Admin report loads the Photo Objet daily summary', () {
    final provider = readRepoFile(
      'lib/features/super_admin/super_admin_provider.dart',
    );

    expect(provider, contains("FinancialInputSource.photoSales"));
    expect(provider, contains('aggregateSuperAdminPhotoObjetSalesByStore'));
  });

  test('report export keeps sales and service revenue separate', () {
    final provider = readRepoFile('lib/features/report/report_provider.dart');

    expect(provider, contains("TextCellValue('Net Sales Revenue')"));
    expect(
      provider,
      contains("TextCellValue('Service Revenue (Coin Payments)')"),
    );
    expect(provider, isNot(contains("TextCellValue('Total Revenue')")));
  });

  test('historical Photo Objet service amounts are repaired from raw types', () {
    final migration = readRepoFile(
      'supabase/migrations/20260815130000_photo_objet_service_revenue_backfill.sql',
    );

    expect(migration, contains('photo_objet_sales_raw'));
    expect(migration, contains('-- production-gate: self-verifying'));
    expect(migration, contains('raw_type'));
    expect(migration, contains("raw_payload #>> '{row,Type}'"));
    expect(migration, contains('classified_raw.amount > 0'));
    expect(migration, contains('service_amount = totals.service_amount'));
    expect(migration, contains('service_count = totals.service_count'));
  });

  test('invalid Photo Objet rows do not create report activity', () {
    final totals = aggregatePhotoObjetReportRows([
      {'sale_date': null, 'total_gross_sales': 999, 'total_transactions': 1},
    ]);

    expect(totals.totalRevenue, 0);
    expect(totals.transactionCount, 0);
    expect(totals.dailyBreakdown, isEmpty);
  });

  test('Super Admin reports prefer the route store override', () {
    final admin = readRepoFile('lib/features/admin/admin_screen.dart');
    final reports = readRepoFile('lib/features/admin/tabs/reports_tab.dart');

    expect(
      admin,
      contains('ReportsTab(overrideStoreId: widget.overrideRestaurantId)'),
    );
    expect(
      reports,
      contains('widget.overrideStoreId ?? ref.watch(authProvider).storeId'),
    );
  });

  test('missing proof details and headline count use the same rows', () {
    final issues = collectMissingProofIssues([
      {
        'id': 'pay-missing',
        'order_id': 'order-1',
        'amount': 120000,
        'method': 'BANK_TRANSFER',
        'created_at': '2026-08-14T05:00:00Z',
        'proof_required': true,
        'proof_photo_url': '',
      },
      {
        'id': 'pay-complete',
        'order_id': 'order-2',
        'amount': 80000,
        'method': 'CASH',
        'created_at': '2026-08-14T06:00:00Z',
        'proof_required': true,
        'proof_photo_url': 'https://example.test/proof.jpg',
      },
    ]);

    expect(issues, hasLength(1));
    expect(issues.single.paymentId, 'pay-missing');
    expect(issues.single.orderId, 'order-1');
  });

  test('MISA review details include only failed and manual jobs', () {
    final issues = collectEinvoiceReviewIssues(
      [
        {
          'id': 'job-failed',
          'order_id': 'order-1',
          'status': 'failed',
          'error_message': 'buyer tax code invalid',
          'created_at': '2026-08-14T05:00:00Z',
        },
        {
          'id': 'job-manual',
          'order_id': 'order-2',
          'status': 'manual_action_required',
          'manual_action_type': 'buyer_review',
          'created_at': '2026-08-14T06:00:00Z',
        },
        {
          'id': 'job-issued',
          'order_id': 'order-3',
          'status': 'issued',
          'created_at': '2026-08-14T07:00:00Z',
        },
      ],
      paymentIdByOrderId: const {'order-1': 'pay-1', 'order-2': 'pay-2'},
    );

    expect(issues.map((issue) => issue.jobId), ['job-failed', 'job-manual']);
    expect(issues.first.paymentId, 'pay-1');
    expect(issues.last.detail, 'buyer_review');
  });
}
