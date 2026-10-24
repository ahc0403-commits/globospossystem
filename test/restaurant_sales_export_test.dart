import 'package:excel/excel.dart';
import 'fixtures/sales_invoice_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';

void main() {
  for (final contact in [
    {'email': 'fixture@example.com', 'phone': '0123456789'},
    {'email': 'fixture@example.com', 'phone': ''},
    {'email': '', 'phone': '0123456789'},
    {'email': '', 'phone': ''},
  ]) {
    test('ordinary receipt preserves optional contacts $contact', () {
      final payload = _validPayload();
      final general =
          (payload['receipts'] as List).first as Map<String, Object?>;
      general['buyer_email'] = contact['email'];
      general['buyer_phone'] = contact['phone'];
      final export = _fixtureExport(payload);
      expect(export.isReadyForDownload, isTrue);
      final job = buildRestaurantMisaJob(export.receipts.first);
      final buyer = job['buyer_snapshot'] as Map;
      expect(buyer['email'], contact['email']);
      expect(buyer['phone'], contact['phone']);
      final rows = Excel.decodeBytes(
        buildRestaurantSalesWorkbook(export),
      ).tables['Hóa đơn GTGT']!.rows;
      for (final row in rows.skip(8).take(1)) {
        expect(row[6]?.value.toString() ?? '', contact['email']);
        expect(row[7]?.value.toString() ?? '', contact['phone']);
        expect(row[7]?.value, isA<TextCellValue>());
      }
      expect(rows[9].sublist(1, 10).every((c) => c?.value == null), isTrue);
    });
  }
  test('preserves every approved menu line under its receipt number', () {
    final export = _fixtureExport(_validPayload());

    expect(export.businessDate, '2026-08-16');
    expect(export.taxEntityId, 'entity-production');
    expect(export.sellerTaxCode, '0318453298');
    expect(export.sellerLegalName, 'CÔNG TY TNHH AKJ INTERNATIONAL');
    expect(export.isSampleEntity, isFalse);
    expect(export.receiptCount, 2);
    expect(export.generalReceiptCount, 1);
    expect(export.redInvoiceCount, 1);
    expect(export.lineCount, 3);
    expect(export.supplyAmount, 200000);
    expect(export.vatAmount, 16000);
    expect(export.grossSales, 216000);
    expect(export.isReadyForDownload, isTrue);

    final workbook = Excel.decodeBytes(buildRestaurantSalesWorkbook(export));
    expect(workbook.tables.keys, [
      'Hóa đơn GTGT',
      'POS Ledger',
      'Invoice Mapping',
      'Store Reconciliation',
      'Export Contract',
    ]);
    final rows = workbook.tables['Hóa đơn GTGT']!.rows;
    expect(rows, hasLength(11));
    expect(rows[7][0]!.value.toString(), 'Số thứ tự hóa đơn (*)');
    expect(rows[7][16]!.value.toString(), 'Tiền thuế GTGT');

    // The ordinary receipt follows the attached anonymous-customer example.
    expect(rows[8][0]!.value.toString(), '1');
    expect(rows[8][1]!.value.toString(), '16/08/2026');
    expect(rows[8][2]!.value.toString(), 'Bán cho người tiêu dùng');
    expect(rows[8][3]!.value.toString(), '');
    expect(rows[8][5]!.value.toString(), 'Bán cho người tiêu dùng');
    expect(rows[8][9]!.value.toString(), 'TM');
    expect(rows[8][10]!.value.toString(), 'Kimbap');
    expect(rows[8][11]!.value.toString(), 'Phần');
    expect(rows[8][12]!.value.toString(), '1');
    expect(rows[8][13]!.value.toString(), '60000');
    expect(rows[8][14]!.value.toString(), '60000');
    expect(rows[8][15]!.value.toString(), '8');
    expect(rows[8][16]!.value.toString(), '4800');

    // Both ordinary menu lines precede the next invoice.
    expect(rows[10][0]!.value.toString(), '2');
    expect(rows[10][2]!.value.toString(), 'Công ty ABC');
    expect(rows[10][3]!.value.toString(), '0312345678');
    expect(rows[10][4]!.value.toString(), '1 Nguyễn Huệ, Quận 1');
    expect(rows[10][5]!.value.toString(), '');
    expect(rows[10][6]!.value.toString(), 'invoice@abc.vn');
    expect(rows[10][7]!.value.toString(), '0901234567');
    expect(rows[10][8]!.value.toString(), '');
    expect(rows[10][9]!.value.toString(), 'Thẻ quốc tế');
    expect(rows[10][10]!.value.toString(), 'Set menu');
    expect(rows[10][13]!.value.toString(), '100000');

    final exportedText = rows
        .expand((row) => row)
        .map((cell) => cell?.value.toString() ?? '')
        .join('\n');
    expect(exportedText, contains('Kimbap'));
    expect(exportedText, contains('Ramen'));
  });

  test('refuses pending and integrity-failed finalizations', () {
    expect(
      () => _fixtureExport({
        'business_date': '2026-08-16',
        'status': 'pending',
        'receipts': const [],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'RESTAURANT_EXPORT_NOT_READY',
        ),
      ),
    );
    expect(
      () => _fixtureExport({
        'business_date': '2026-08-16',
        'status': 'data_integrity_failed',
        'receipts': const [],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'RESTAURANT_EXPORT_DATA_INTEGRITY_FAILED',
        ),
      ),
    );
  });

  test('accepts an anytime report without a finalization marker', () {
    final payload = _validPayload()
      ..['status'] = 'ready'
      ..['report_ready_at'] = '2026-08-16T00:00:00+07:00'
      ..remove('finalized_at');

    final export = _fixtureExport(payload);
    final grouped = createRestaurantSalesExportsByTaxEntity({
      'business_date': '2026-08-16',
      'status': 'ready',
      'report_ready_at': '2026-08-16T00:00:00+07:00',
      'entity_count': 1,
      'entities': [payload],
    });
    final restaurantEmpty = createRestaurantSalesExportsByTaxEntity({
      'business_date': '2026-08-16',
      'status': 'ready',
      'report_ready_at': '2026-08-16T00:00:00+07:00',
      'entity_count': 0,
      'entities': const [],
    });

    expect(export.finalizedAt, isNull);
    expect(export.isReadyForDownload, isTrue);
    expect(grouped, hasLength(1));
    expect(grouped.single.finalizedAt, isNull);
    expect(grouped.single.isReadyForDownload, isTrue);
    expect(restaurantEmpty, isEmpty);
  });

  test('rejects Photo source and altered receipt totals', () {
    final photo = _validPayload();
    final photoReceipts = photo['receipts']! as List<Map<String, Object?>>;
    photoReceipts.first['source_system'] = 'photo_objet_moers';
    expect(
      () => _fixtureExport(photo),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'RESTAURANT_EXPORT_PHOTO_SOURCE:receipt-general',
        ),
      ),
    );

    final altered = _validPayload()..['receipt_count'] = 3;
    expect(
      () => _fixtureExport(altered),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'RESTAURANT_EXPORT_RECEIPT_COUNT_MISMATCH',
        ),
      ),
    );
  });

  test('blocks download when a Red Invoice lacks required MISA data', () {
    final payload = _validPayload();
    final receipts = payload['receipts']! as List<Map<String, Object?>>;
    receipts.last['buyer_address'] = '';

    final export = _fixtureExport(payload);
    expect(export.isReadyForDownload, isFalse);
    expect(export.blockingIssueCount, 1);
    expect(export.receipts.last.issues, ['MISSING_BUYER_ADDRESS']);
    expect(
      () => buildRestaurantSalesWorkbook(export),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'MISSING_BUYER_ADDRESS',
        ),
      ),
    );

    final awaitingPayload = _validPayload();
    final awaitingReceipts =
        awaitingPayload['receipts']! as List<Map<String, Object?>>;
    awaitingReceipts.last['red_invoice_status'] = 'awaiting_information';
    final awaiting = _fixtureExport(awaitingPayload);
    expect(awaiting.isReadyForDownload, isFalse);
    expect(awaiting.receipts.last.issues, ['RED_INVOICE_NOT_READY']);
  });

  test('requires the delivery email while allowing a blank buyer phone', () {
    final payload = _validPayload();
    final receipts = payload['receipts']! as List<Map<String, Object?>>;
    receipts.last['buyer_phone'] = '';

    final phoneFree = _fixtureExport(payload);
    expect(phoneFree.isReadyForDownload, isTrue);
    expect(phoneFree.receipts.last.issues, isEmpty);

    receipts.last['buyer_email'] = '';

    final export = _fixtureExport(payload);
    expect(export.isReadyForDownload, isFalse);
    expect(export.receipts.last.issues, ['MISSING_BUYER_EMAIL']);
  });

  test('keeps separate tax rows under one receipt number', () {
    final payload = _validPayload();
    final receipts = payload['receipts']! as List<Map<String, Object?>>;
    final lines = receipts.first['line_items']! as List<Map<String, Object?>>;
    lines.last['vat_rate'] = 0;
    lines.last['vat_amount'] = 0;
    receipts.first['gross_sales'] = 104800;
    payload['gross_sales'] = 212800;

    final export = _fixtureExport(payload);
    expect(export.receipts.first.issues, isEmpty);

    final workbook = Excel.decodeBytes(buildRestaurantSalesWorkbook(export));
    final rows = workbook.tables['Hóa đơn GTGT']!.rows;
    expect(rows, hasLength(11));
    expect(rows[8][10]!.value.toString(), 'Kimbap');
    expect(rows[8][14]!.value.toString(), '60000');
    expect(rows[8][15]!.value.toString(), '8');
    expect(rows[8][16]!.value.toString(), '4800');
    expect(rows[9][0]!.value.toString(), '1');
    expect(rows[9][14]!.value.toString(), '40000');
    expect(rows[9][15]!.value.toString(), '0');
    expect(rows[9][16]!.value.toString(), '0');
    expect(rows[10][0]!.value.toString(), '2');
  });

  test('keeps different seller tax codes in separate export groups', () {
    final production = _validPayload();
    final sample = _validPayload()
      ..['tax_entity_id'] = 'entity-sample'
      ..['seller_tax_code'] = 'PENDING_SAMPLE_STORE_TAX_PROFILE'
      ..['seller_legal_name'] = 'BunsikClub SAMPLE (non-fiscal test entity)'
      ..['is_sample_entity'] = true;
    final sampleReceipts = sample['receipts']! as List<Map<String, Object?>>;
    for (final receipt in sampleReceipts) {
      receipt['receipt_id'] = 'sample-${receipt['receipt_id']}';
      receipt['store_id'] = 'store-sample';
      receipt['store_name'] = 'BunsikClub SAMPLE';
    }

    final exports = createRestaurantSalesExportsByTaxEntity({
      'business_date': '2026-08-16',
      'status': 'finalized',
      'finalized_at': '2026-08-16T22:20:00+07:00',
      'entity_count': 2,
      'entities': [production, sample],
    });

    expect(exports, hasLength(2));
    expect(exports.first.sellerTaxCode, '0318453298');
    expect(exports.first.grossSales, 216000);
    expect(exports.last.isSampleEntity, isTrue);
    expect(
      exports.last.receipts.every((row) => row.storeName.contains('SAMPLE')),
      isTrue,
    );
  });
}

Map<String, dynamic> _validPayload() => {
  'business_date': '2026-08-16',
  'status': 'finalized',
  'tax_entity_id': 'entity-production',
  'seller_tax_code': '0318453298',
  'seller_legal_name': 'CÔNG TY TNHH AKJ INTERNATIONAL',
  'is_sample_entity': false,
  'store_count': 1,
  'receipt_count': 2,
  'gross_sales': 216000,
  'finalized_at': '2026-08-16T22:20:00+07:00',
  'receipts': <Map<String, Object?>>[
    {
      'store_id': 'store-a',
      'store_name': 'Restaurant A',
      'receipt_id': 'receipt-general',
      'receipt_source': 'pos_payment',
      'source_system': 'restaurant_pos',
      'sales_channel': 'dine_in',
      'gross_sales': 108000,
      'sold_at': '2026-08-16T10:10:00+07:00',
      'payment_method': 'cash',
      'is_red_invoice': false,
      'buyer_tax_code': '',
      'buyer_legal_name': '',
      'buyer_address': '',
      'line_items': [
        {
          'order_item_id': 'item-Kimbap',
          'menu_item_id': 'sku-Kimbap',
          'invoice_name_vi': 'Kimbap',
          'misa_unit_name': 'Phần',
          'display_name': 'Kimbap',
          'quantity': 1,
          'unit_price': 60000,
          'total_amount_ex_tax': 60000,
          'vat_rate': 8,
          'vat_amount': 4800,
        },
        {
          'order_item_id': 'item-Ramen',
          'menu_item_id': 'sku-Ramen',
          'invoice_name_vi': 'Ramen',
          'misa_unit_name': 'Phần',
          'display_name': 'Ramen',
          'quantity': 1,
          'unit_price': 40000,
          'total_amount_ex_tax': 40000,
          'vat_rate': 8,
          'vat_amount': 3200,
        },
      ],
    },
    {
      'store_id': 'store-a',
      'store_name': 'Restaurant A',
      'receipt_id': 'receipt-red',
      'receipt_source': 'pos_payment',
      'source_system': 'restaurant_pos',
      'sales_channel': 'dine_in',
      'gross_sales': 108000,
      'sold_at': '2026-08-16T11:10:00+07:00',
      'payment_method': 'card',
      'is_red_invoice': true,
      'red_invoice_status': 'ready',
      'buyer_tax_code': '0312345678',
      'buyer_legal_name': 'Công ty ABC',
      'buyer_address': '1 Nguyễn Huệ, Quận 1',
      'buyer_email': 'invoice@abc.vn',
      'buyer_phone': '0901234567',
      'line_items': [
        {
          'order_item_id': 'item-Set menu',
          'menu_item_id': 'sku-Set menu',
          'invoice_name_vi': 'Set menu',
          'misa_unit_name': 'Phần',
          'display_name': 'Set menu',
          'quantity': 1,
          // Inclusive menu pricing is normalized to the MISA pre-tax unit price.
          'unit_price': 108000,
          'total_amount_ex_tax': 100000,
          'vat_rate': 8,
          'vat_amount': 8000,
        },
      ],
    },
  ],
};

RestaurantSalesExport _fixtureExport(Map<String, dynamic> p) =>
    createRestaurantSalesExport(approvedSalesFixturePayload(p));
