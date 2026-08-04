import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/einvoice_misa_workbook.dart';

void main() {
  test('exports pending jobs using MISA invoice and detail field order', () {
    final bytes = buildMisaPendingInvoiceWorkbook([
      {
        'id': 'job-1',
        'misa_ref_id': 'ref-1',
        'invoice_series': '1C26MAJ',
        'created_at': '2026-08-04T02:00:00Z',
        'payment_method_snapshot': 'Tiền mặt',
        'buyer_snapshot': {
          'tax_code': '0318453298',
          'unit_name': 'CÔNG TY TNHH BUYER',
          'buyer_full_name': 'Nguyen Van A',
          'address': 'Ho Chi Minh City',
          'email': 'buyer@example.com',
          'phone': '0900000000',
        },
        'line_items_snapshot': [
          {
            'order_item_id': 'line-1',
            'display_name': 'Tteokbokki',
            'quantity': 2,
            'total_amount_ex_tax': 100000,
            'vat_rate': 8,
            'vat_amount': 8000,
            'paying_amount_inc_tax': 108000,
          },
        ],
      },
    ]);

    final workbook = Excel.decodeBytes(bytes);
    expect(
      workbook.tables.keys,
      containsAll(['InvoiceData', 'OriginalInvoiceDetail']),
    );

    final invoices = workbook.tables['InvoiceData']!;
    final headers = invoices.rows.first
        .map((cell) => cell?.value.toString())
        .toList();
    expect(headers.take(7), [
      'RefID',
      'InvSeries',
      'InvoiceName',
      'InvDate',
      'CurrencyCode',
      'ExchangeRate',
      'PaymentMethodName',
    ]);
    expect(invoices.rows[1][0]?.value.toString(), 'ref-1');
    expect(invoices.rows[1][1]?.value.toString(), '1C26MAJ');
    expect(invoices.rows[1][8]?.value.toString(), '0318453298');
    expect(invoices.rows[1][20]?.value.toString(), '108000');

    final details = workbook.tables['OriginalInvoiceDetail']!;
    expect(details.rows[1][0]?.value.toString(), 'ref-1');
    expect(details.rows[1][5]?.value.toString(), 'Tteokbokki');
    expect(details.rows[1][13]?.value.toString(), '8%');
  });

  test('refuses an empty pending queue export', () {
    expect(
      () => buildMisaPendingInvoiceWorkbook(const []),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'MISA_PENDING_EXPORT_EMPTY',
        ),
      ),
    );
  });
}
