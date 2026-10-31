import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/einvoice_misa_workbook.dart';
import 'fixtures/sales_invoice_fixture.dart';

List<Map<String, dynamic>> jobs({int receipts = 1}) =>
    approvedSalesFixtureJobs([
      for (var i = 0; i < receipts; i++)
        {
          'source_system': 'restaurant_pos',
          'receipt_id': 'synthetic-receipt-${i.toString().padLeft(3, '0')}',
          'receipt_number': 'SYNTHETIC-$i',
          'source_hash': 'independent-synthetic-source-$i',
          'snapshot_version': 7,
          'payment_method_snapshot': 'CASH',
          'buyer_snapshot': {'email': 'one@example.test;two@example.test'},
          'line_items_snapshot': [
            for (
              var j = 0;
              j <
                  (receipts == 464
                      ? (i == 0
                            ? 10
                            : i <= 407
                            ? 2
                            : 1)
                      : 3);
              j++
            )
              {
                'order_item_id': 'item-$i-$j',
                'invoice_name_vi': 'Synthetic food $j',
                'misa_unit_name': 'Phần',
                'quantity': j + 2,
                'unit_price': j == 0 ? 15006.21 / 2 : 10000.0,
                'total_amount_ex_tax': j == 0 ? 15006.21 : 10000.0 * (j + 2),
                'vat_rate': 8,
                'vat_amount': j == 0 ? 1200.50 : 800.0 * (j + 2),
              },
          ],
        },
    ]);

double amount(List<Data?> row, int col) => double.parse('${row[col]!.value}');

void main() {
  test(
    'HALF_UP first compares two-decimal source VAT at .496 and .495 ties',
    () {
      expect(misaSourceVatMatches(15006.20, 8, 1200.50), isTrue); // .496
      expect(misaSourceVatMatches(15006.1875, 8, 1200.50), isTrue); // .495
      expect(misaSourceVatMatches(15006.18, 8, 1200.50), isFalse); // .4944
      expect(misaSourceVatMatches(268519, 8, 21481), isFalse);
    },
  );
  test(
    'rate summary sums fractional VAT before the same precision comparison',
    () {
      expect(
        misaSourceVatSummaryMatches([
          (supply: 15006.20, rate: 8.0, vat: 1200.50),
          (supply: 18987.50, rate: 8.0, vat: 1519.00),
        ]),
        isTrue,
      );
      expect(
        misaSourceVatSummaryMatches(
          List.generate(4, (_) => (supply: 10.0, rate: 8.0, vat: 1.30)),
        ),
        isFalse,
      );
    },
  );
  test('464 receipts / 880 rows preserve source cells, hashes and schema', () {
    final source = jobs(receipts: 464);
    final before = jsonEncode(source);
    final book = Excel.decodeBytes(buildMisaPendingInvoiceWorkbook(source));
    validateMisaWorkbookSourceAmounts(book, source);
    expect(jsonEncode(source), before);
    expect(book.tables['Hóa đơn GTGT']!.maxRows, 888);
    expect(book.tables['Hóa đơn GTGT']!.rows[7], hasLength(17));
    expect(book.tables['Invoice Mapping']!.rows[0], hasLength(16));
    expect(book.tables['POS Ledger']!.rows[0], hasLength(18));
    final outputRows = book.tables['Hóa đơn GTGT']!.rows;
    final ledgerRows = book.tables['POS Ledger']!.rows;
    final mappingRows = book.tables['Invoice Mapping']!.rows;
    var row = 8, audit = 1;
    for (final job in source) {
      for (final line in job['line_items_snapshot'] as List) {
        final cells = outputRows[row];
        expect(amount(cells, 14), line['total_amount_ex_tax']);
        expect(amount(cells, 16), line['vat_amount']);
        expect(
          amount(cells, 13),
          line['total_amount_ex_tax'] / line['quantity'],
        );
        expect(amount(cells, 12), line['quantity']);
        expect(amount(cells, 15), line['vat_rate']);
        expect('${ledgerRows[audit][10]!.value}', job['source_hash']);
        expect(
          '${ledgerRows[audit][12]!.value}',
          sha256.convert(utf8.encode(jsonEncode(line))).toString(),
        );
        expect(amount(mappingRows[audit], 15), 0);
        row++;
        audit++;
      }
    }
    expect(
      '${book.tables['Hóa đơn GTGT']!.rows[8][6]!.value}',
      'one@example.test',
    );
    expect(
      '${book.tables['Email Delivery']!.rows[1][2]!.value}',
      'one@example.test;two@example.test',
    );
  });
  test(
    'independent source detects .07 even with balanced line and receipt totals',
    () {
      final source = jobs();
      final book = Excel.decodeBytes(buildMisaPendingInvoiceWorkbook(source));
      final sheet = book.tables['Hóa đơn GTGT']!;
      for (final (row, delta) in [(8, 0.07), (9, -0.07)]) {
        final cells = sheet.rows[row];
        final supply = amount(cells, 14) + delta;
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 14, rowIndex: row))
            .value = DoubleCellValue(
          supply,
        );
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 16, rowIndex: row))
            .value = DoubleCellValue(
          amount(cells, 16) - delta,
        );
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 13, rowIndex: row))
            .value = DoubleCellValue(
          supply / amount(cells, 12),
        );
      }
      expect(
        () => validateMisaWorkbookSourceAmounts(book, source),
        throwsFormatException,
      );
    },
  );
  for (final col in [13, 14, 15]) {
    test('rejects tampered audit column $col against independent source', () {
      final source = jobs();
      final book = Excel.decodeBytes(buildMisaPendingInvoiceWorkbook(source));
      final sheet = book.tables['Invoice Mapping']!;
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 1))
          .value = DoubleCellValue(
        amount(sheet.rows[1], col) + 0.07,
      );
      expect(
        () => validateMisaWorkbookSourceAmounts(book, source),
        throwsFormatException,
      );
    });
  }
  test(
    'forged audit amounts and line hash cannot authorize changed source cells',
    () {
      final source = jobs();
      final book = Excel.decodeBytes(buildMisaPendingInvoiceWorkbook(source));
      final data = book.tables['Hóa đơn GTGT']!;
      final audit = book.tables['Invoice Mapping']!;
      final supply = amount(data.rows[8], 14) + 0.07;
      data.cell(CellIndex.indexByString('O9')).value = DoubleCellValue(supply);
      audit.cell(CellIndex.indexByString('N2')).value = DoubleCellValue(supply);
      audit.cell(CellIndex.indexByString('P2')).value = const DoubleCellValue(
        -0.07,
      );
      book.tables['POS Ledger']!.cell(CellIndex.indexByString('M2')).value =
          TextCellValue('forged');
      expect(
        () => validateMisaWorkbookSourceAmounts(book, source),
        throwsFormatException,
      );
    },
  );
  for (final key in ['rounded_line_gross', 'rounding_difference']) {
    test('rejects Export Contract $key that differs from actual cells', () {
      final source = jobs();
      final book = Excel.decodeBytes(buildMisaPendingInvoiceWorkbook(source));
      final contract = book.tables['Export Contract']!;
      final row = contract.rows.indexWhere((r) => '${r[0]?.value}' == key);
      contract
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .value = TextCellValue(
        '99999',
      );
      expect(
        () => validateMisaWorkbookSourceAmounts(book, source),
        throwsFormatException,
      );
    });
  }
  for (final col in [13, 14, 16]) {
    test('rejects a .07 change in MISA column $col', () {
      final source = jobs();
      final book = Excel.decodeBytes(buildMisaPendingInvoiceWorkbook(source));
      final sheet = book.tables['Hóa đơn GTGT']!;
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 8))
          .value = DoubleCellValue(
        amount(sheet.rows[8], col) + 0.07,
      );
      expect(
        () => validateMisaWorkbookSourceAmounts(book, source),
        throwsFormatException,
      );
    });
  }
}
