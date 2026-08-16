import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';

void main() {
  test('builds one MISA sheet for general receipts and Red Invoices', () {
    final export = createRestaurantSalesExport(_validPayload());

    expect(export.businessDate, '2026-08-16');
    expect(export.receiptCount, 2);
    expect(export.generalReceiptCount, 1);
    expect(export.redInvoiceCount, 1);
    expect(export.lineCount, 3);
    expect(export.supplyAmount, 200000);
    expect(export.vatAmount, 16000);
    expect(export.grossSales, 216000);
    expect(export.isReadyForDownload, isTrue);

    final workbook = Excel.decodeBytes(buildRestaurantSalesWorkbook(export));
    expect(workbook.tables.keys, ['Hóa đơn GTGT']);
    final rows = workbook.tables['Hóa đơn GTGT']!.rows;
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

    // Two item rows remain one receipt, then the Red Invoice starts at 2.
    expect(rows[9][0]!.value.toString(), '1');
    expect(rows[10][0]!.value.toString(), '2');
    expect(rows[10][2]!.value.toString(), 'Công ty ABC');
    expect(rows[10][3]!.value.toString(), '0312345678');
    expect(rows[10][4]!.value.toString(), '1 Nguyễn Huệ, Quận 1');
    expect(rows[10][5]!.value.toString(), '');
    expect(rows[10][6]!.value.toString(), '');
    expect(rows[10][7]!.value.toString(), '');
    expect(rows[10][8]!.value.toString(), '');
    expect(rows[10][9]!.value.toString(), 'CK');
    expect(rows[10][13]!.value.toString(), '100000');
  });

  test('refuses pending and integrity-failed finalizations', () {
    expect(
      () => createRestaurantSalesExport({
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
      () => createRestaurantSalesExport({
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

  test('rejects Photo source and altered receipt totals', () {
    final photo = _validPayload();
    final photoReceipts = photo['receipts']! as List<Map<String, Object?>>;
    photoReceipts.first['source_system'] = 'photo_objet_moers';
    expect(
      () => createRestaurantSalesExport(photo),
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
      () => createRestaurantSalesExport(altered),
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

    final export = createRestaurantSalesExport(payload);
    expect(export.isReadyForDownload, isFalse);
    expect(export.blockingIssueCount, 1);
    expect(export.receipts.last.issues, ['MISSING_BUYER_ADDRESS']);
    expect(
      () => buildRestaurantSalesWorkbook(export),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'RESTAURANT_EXPORT_BLOCKING_ISSUES',
        ),
      ),
    );

    final awaitingPayload = _validPayload();
    final awaitingReceipts =
        awaitingPayload['receipts']! as List<Map<String, Object?>>;
    awaitingReceipts.last['red_invoice_status'] = 'awaiting_information';
    final awaiting = createRestaurantSalesExport(awaitingPayload);
    expect(awaiting.isReadyForDownload, isFalse);
    expect(awaiting.receipts.last.issues, ['RED_INVOICE_NOT_READY']);
  });
}

Map<String, dynamic> _validPayload() => {
  'business_date': '2026-08-16',
  'status': 'finalized',
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
          'display_name': 'Kimbap',
          'quantity': 1,
          'unit_price': 60000,
          'total_amount_ex_tax': 60000,
          'vat_rate': 8,
          'vat_amount': 4800,
        },
        {
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
      'line_items': [
        {
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
