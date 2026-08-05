import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'Photo Objet daily rows contribute revenue and completed transactions',
    () {
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

      expect(totals.totalRevenue, 8290000);
      expect(totals.serviceTotal, 100000);
      expect(totals.transactionCount, 95);
      expect(totals.dailyBreakdown, hasLength(2));
      expect(totals.dailyBreakdown.first.date, DateTime(2026, 7, 18));
      expect(totals.dailyBreakdown.first.total, 3130000);
      expect(totals.dailyBreakdown.last.total, 5160000);
    },
  );

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
}
