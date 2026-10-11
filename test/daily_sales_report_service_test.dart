import 'package:flutter_test/flutter_test.dart';
import 'fixtures/sales_invoice_fixture.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_report_service.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_summary.dart';

void main() {
  test(
    'summary uses one RPC and distinguishes missing Photo from zero',
    () async {
      var calls = 0;
      final service = DailySalesReportService(
        rpc: (name, params) async {
          calls++;
          expect(name, 'get_pos_daily_sales_summary');
          return {
            'business_date': '2026-10-08',
            'entities': [row()],
          };
        },
      );
      final result = (await service.summaries('2026-10-08')).single;
      expect(calls, 1);
      expect(result.nextDeposit, 308000);
      expect(result.restaurantBankTransfer, 439560);
      expect(result.depositDate, '2026-10-09');
      expect(
        DailySalesSummary.fromJson(
          '2026-10-08',
          row()..['photo_complete'] = false,
        ).nextDeposit,
        isNull,
      );
      expect(
        DailySalesSummary.fromJson(
          '2026-10-08',
          row()..['photo_gross'] = 0,
        ).nextDeposit,
        200000,
      );
    },
  );
  test(
    'restaurant receipts use bounded keysets without per-receipt calls',
    () async {
      var calls = 0;
      final service = DailySalesReportService(
        rpc: (name, params) async {
          calls++;
          expect(name, 'get_pos_daily_sales_export_page');
          expect(params['p_limit'], 100);
          expect(params['p_source_system'], 'restaurant_pos');
          final offset = params['p_after_id'] == null
              ? 0
              : int.parse(params['p_after_id'] as String) + 1;
          return {
            ...params.map((k, v) => MapEntry(k.replaceFirst('p_', ''), v)),
            'rows': [
              for (var i = offset; i < 205 && i < offset + 100; i++) receipt(i),
            ],
          };
        },
      );
      final summary = DailySalesSummary.fromJson(
        '2026-10-08',
        row()..addAll({
          'restaurant_receipt_count': 205,
          'restaurant_gross': 205 * 10800,
          'photo_receipt_count': 0,
          'photo_gross': 0,
        }),
      );
      final export = await service.loadExport(summary);
      expect(calls, 3);
      expect(export.restaurant!.receipts.length, 205);
      expect(export.grossSales, 205 * 10800);
    },
  );
  test('counted deposit differences stay provisional', () {
    final source = row()
      ..addAll({'closing_complete': true, 'closing_deposit': 200000});
    expect(
      DailySalesSummary.fromJson('2026-10-08', source).depositConfirmed,
      isTrue,
    );
    source['closing_deposit'] = 195000;
    expect(
      DailySalesSummary.fromJson('2026-10-08', source).depositConfirmed,
      isFalse,
    );
  });
  test('changed receipt count requires refresh', () async {
    final service = DailySalesReportService(
      rpc: (_, p) async => {
        'business_date': '2026-10-08',
        'tax_entity_id': 'entity',
        'source_system': 'restaurant_pos',
        'rows': [],
      },
    );
    final summary = DailySalesSummary.fromJson(
      '2026-10-08',
      row()..addAll({
        'restaurant_receipt_count': 1,
        'photo_receipt_count': 0,
        'photo_gross': 0,
      }),
    );
    await expectLater(service.loadExport(summary), throwsFormatException);
  });
}

Map<String, dynamic> row() => {
  'tax_entity_id': 'entity',
  'seller_tax_code': '0318453298',
  'seller_legal_name': 'AKJ',
  'restaurant_receipt_count': 1,
  'photo_receipt_count': 1,
  'general_count': 1,
  'red_count': 0,
  'restaurant_gross': 439560,
  'photo_gross': 108000,
  'supply': 506000,
  'vat': 41560,
  'restaurant_cash': 200000,
  'restaurant_bank_transfer': 439560,
  'photo_complete': true,
  'closing_complete': false,
  'cash_variance': 0,
  'cash_refunds': 0,
  'delivery_cash_paid': 0,
  'delivery_cash_recovered': 0,
};
Map<String, dynamic> receipt(int i) => {
  'receipt_id': i.toString().padLeft(4, '0'),
  'receipt_source': 'pos_payment',
  'source_system': 'restaurant_pos',
  'store_id': 'store',
  'store_name': 'Restaurant',
  'sold_at': '2026-10-08T12:00:00+07:00',
  'gross_sales': 10800,
  'payment_method': 'TM',
  'line_items': [
    approvedSalesFixtureLine({
      'order_item_id': 'line-$i',
      'menu_item_id': 'menu',
      'invoice_name_vi': 'Food',
      'misa_unit_name': 'Phần',
      'display_name': 'Food',
      'quantity': 1,
      'unit_price': 10000,
      'total_amount_ex_tax': 10000,
      'vat_rate': 8,
      'vat_amount': 800,
    }, storeId: 'store'),
  ],
};
