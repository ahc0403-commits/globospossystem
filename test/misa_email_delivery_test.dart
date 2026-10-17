import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/einvoice_misa_workbook.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/combined_sales_export.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';

import 'fixtures/misa_email_delivery_fixture.dart';

String _text(Data? cell) => cell?.value?.toString() ?? '';

Excel _workbook(List<Map<String, dynamic>> jobs) => Excel.decodeBytes(
  buildMisaPendingInvoiceWorkbook(jobs, generationId: 'email-test-generation'),
);

Map<String, dynamic> _withEmail(String? email) =>
    misaEmailDeliveryFixtureJobs()[2]..['buyer_snapshot'] = {'email': email};

Map<String, String> _contract(Excel book) => {
  for (final row in book.tables['Export Contract']!.rows)
    _text(row[0]): _text(row[1]),
};

Matcher _error(String code) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', startsWith(code)),
);

void main() {
  test('normalizes separators, whitespace and case-insensitive duplicates', () {
    expect(normalizeMisaEmailAddresses(null), isEmpty);
    expect(normalizeMisaEmailAddresses(' ; ;\t; '), isEmpty);
    expect(
      normalizeMisaEmailAddresses(
        ' A@example.com ; b@example.com; a@EXAMPLE.COM;; B@example.com ;c@example.com ',
      ),
      ['A@example.com', 'b@example.com', 'c@example.com'],
    );
    // Invalid tokens are retained for an explicit error, never dropped.
    expect(normalizeMisaEmailAddresses('a@example.com;bad-address'), [
      'a@example.com',
      'bad-address',
    ]);
  });

  test('omits the delivery sheet for zero or one unique address', () {
    for (final email in [
      null,
      '',
      ' ; ; ',
      ' solo@example.com;SOLO@EXAMPLE.COM;',
    ]) {
      final book = _workbook([_withEmail(email)]);
      expect(book.tables.containsKey('Email Delivery'), isFalse);
      final rows = book.tables['Hóa đơn GTGT']!.rows;
      expect(rows.length, 11);
      expect(
        _text(rows[8][6]),
        email?.contains('@') == true ? 'solo@example.com' : '',
      );
      for (final row in rows.skip(9)) {
        expect(row.sublist(1, 10).every((c) => c?.value == null), isTrue);
      }
      expect(() => validateMisaEmailDeliveryWorkbook(book), returnsNormally);
    }
  });

  test(
    'writes one delivery row per multi-email invoice, preserving all item rows',
    () {
      final jobs = misaEmailDeliveryFixtureJobs().reversed.toList();
      final original = jsonEncode(jobs);
      final book = _workbook(jobs);
      expect(
        jsonEncode(jobs),
        original,
        reason: 'Source snapshots stay immutable',
      );
      expect(book.tables.keys, [
        'Hóa đơn GTGT',
        'POS Ledger',
        'Invoice Mapping',
        'Export Contract',
        'Email Delivery',
      ]);
      final rows = book.tables['Hóa đơn GTGT']!.rows.skip(8).toList();
      expect(rows, hasLength(8));
      expect(rows.map((r) => _text(r[0])).toSet(), {'1', '2', '3', '4'});
      expect(rows.where((r) => r[1]?.value != null).map((r) => _text(r[6])), [
        '',
        'Solo@example.com',
        'Primary@example.com',
        'first@example.com',
      ]);
      for (final row in rows.where((r) => r[1]?.value == null)) {
        expect(row.sublist(1, 10).every((c) => c?.value == null), isTrue);
      }
      final delivery = book.tables['Email Delivery']!;
      expect(delivery.rows.map((r) => r.map(_text).toList()).toList(), [
        ['Invoice sequence', 'Import email', 'Delivery emails'],
        ['3', 'Primary@example.com', 'Primary@example.com;second@example.com'],
        [
          '4',
          'first@example.com',
          'first@example.com;second@example.com;third@example.com',
        ],
      ]);
      for (final row in delivery.rows.skip(1)) {
        expect(row[0]!.value, isA<TextCellValue>());
      }
      expect(book.tables['POS Ledger']!.maxRows, 9);
      expect(book.tables['Invoice Mapping']!.maxRows, 9);
      expect(() => validateMisaEmailDeliveryWorkbook(book), returnsNormally);
    },
  );

  test(
    'adding recipients preserves invoices, items, amounts and payment totals',
    () {
      final singleJobs = misaEmailDeliveryFixtureJobs();
      for (final job in singleJobs) {
        final buyer = job['buyer_snapshot'] as Map;
        final emails = normalizeMisaEmailAddresses(buyer['email']);
        buyer['email'] = emails.isEmpty ? '' : emails.first;
      }
      final single = _workbook(singleJobs);
      final multiple = _workbook(misaEmailDeliveryFixtureJobs());
      final before = single.tables['Hóa đơn GTGT']!.rows;
      final after = multiple.tables['Hóa đơn GTGT']!.rows;
      expect(
        after.map((r) => r.map(_text).toList()).toList(),
        before.map((r) => r.map(_text).toList()).toList(),
      );
      expect(after.length, 16);
      expect(_contract(multiple)['receipt_count'], '4');
      expect(_contract(multiple)['export_line_count'], '8');
      expect(_contract(multiple)['source_gross'], '1416000.00');
      double supply = 0, vat = 0;
      for (final row in after.skip(8)) {
        supply += double.parse(_text(row[14]));
        vat += double.parse(_text(row[16]));
      }
      expect(supply, 1300000);
      expect(vat, 116000);
      expect(
        multiple.tables['Invoice Mapping']!.rows
            .map((r) => r.map(_text).toList())
            .toList(),
        single.tables['Invoice Mapping']!.rows
            .map((r) => r.map(_text).toList())
            .toList(),
      );
      expect(
        multiple.tables['POS Ledger']!.rows.map((r) => _text(r[12])).toList(),
        single.tables['POS Ledger']!.rows.map((r) => _text(r[12])).toList(),
      );
    },
  );

  test('invalid addresses block export with receipt and address position', () {
    for (final invalid in [
      'bad-address',
      'a@@example.com',
      'a b@example.com',
      '.a@example.com',
      'a..b@example.com',
      'a@-example.com',
      'a@example-.com',
      'a@example..com',
      'a@example',
      'a@example.com,b@example.com',
      'Name <a@example.com>',
      'a@example.com\nb@example.com',
      '${'a' * 65}@example.com',
    ]) {
      final job = _withEmail('valid@example.com; $invalid;other@example.com');
      final issues = validateSalesExportJobs([job]);
      final issue = issues.singleWhere(
        (i) => i.code == 'MISA_EXPORT_INVALID_EMAIL',
      );
      expect(issue.receiptId, 'email-fixture-2');
      expect(issue.receiptNumber, 'EMAIL-3');
      expect(issue.source, 'restaurant_pos');
      expect(issue.field, 'buyer_snapshot.email[2]');
      expect(issue.toString(), isNot(contains(invalid)));
      expect(
        () => buildMisaPendingInvoiceWorkbook([job]),
        throwsA(isA<SalesExportValidationException>()),
      );
    }
    final jobs = [
      _withEmail('bad'),
      _withEmail('also-bad')..['receipt_id'] = 'other',
    ];
    try {
      buildMisaPendingInvoiceWorkbook(jobs);
      fail('invalid source saved');
    } on SalesExportValidationException catch (e) {
      expect(e.receiptCount, 2);
      expect(e.itemCount, 0);
    }
    for (final valid in [
      'a+b@example.com',
      "o'hara@example.com",
      'a_b@sub.example.com',
    ]) {
      expect(() => _workbook([_withEmail(valid)]), returnsNormally);
    }
    final unnumbered = _withEmail('invalid')..['receipt_number'] = ' ';
    expect(
      validateSalesExportJobs([unnumbered]).single.receiptNumber,
      'email-fixture-2',
    );
  });

  test(
    'allows 255 normalized characters and rejects 256 with receipt context',
    () {
      String address(int length, String prefix) =>
          '${prefix * 64}@${'d' * (length - 69)}.com';
      final first = address(127, 'a');
      final second = address(127, 'b');
      final email = '$first;$second';
      expect(email.length, 255);
      final book = _workbook([
        _withEmail(' $first ; $second ; ${first.toUpperCase()} ; '),
      ]);
      expect(_text(book.tables['Email Delivery']!.rows[1][2]), email);
      final invalid = _withEmail('$first;${address(128, 'b')}');
      expect(
        validateSalesExportJobs([invalid]).single.code,
        'MISA_EXPORT_DELIVERY_EMAILS_TOO_LONG_255',
      );
      expect(
        () => buildMisaPendingInvoiceWorkbook([invalid]),
        _error('MISA_EXPORT_DELIVERY_EMAILS_TOO_LONG_255'),
      );
    },
  );

  group('workbook cross-checks', () {
    late Excel book;
    setUp(() => book = _workbook(misaEmailDeliveryFixtureJobs()));
    void setCell(String sheet, String cell, String value) =>
        book.tables[sheet]!.cell(CellIndex.indexByString(cell)).value =
            TextCellValue(value);

    test('rejects repeated delivery sequences', () {
      book.tables['Email Delivery']!.appendRow(
        book.tables['Email Delivery']!.rows[1].map((c) => c?.value).toList(),
      );
      expect(
        () => validateMisaEmailDeliveryWorkbook(book),
        _error('MISA_EMAIL_DUPLICATE_DELIVERY_SEQUENCE'),
      );
    });
    test('rejects unknown sequences', () {
      setCell('Email Delivery', 'A2', '999');
      expect(
        () => validateMisaEmailDeliveryWorkbook(book),
        _error('MISA_EMAIL_UNKNOWN_INVOICE_SEQUENCE'),
      );
    });
    test('rejects a mismatch with G, including case and whitespace', () {
      for (final email in [
        'other@example.com',
        'primary@example.com',
        ' Primary@example.com ',
      ]) {
        setCell('Email Delivery', 'B2', email);
        expect(
          () => validateMisaEmailDeliveryWorkbook(book),
          _error('MISA_EMAIL_IMPORT_EMAIL_MISMATCH'),
        );
      }
    });
    test('rejects a missing representative', () {
      setCell('Email Delivery', 'C2', 'second@example.com;third@example.com');
      expect(
        () => validateMisaEmailDeliveryWorkbook(book),
        _error('MISA_EMAIL_IMPORT_EMAIL_MISSING_FROM_DELIVERY'),
      );
    });
    test('rejects duplicate invoice headers inside and outside a block', () {
      setCell('Hóa đơn GTGT', 'B10', '17/10/2026');
      expect(
        () => validateMisaEmailDeliveryWorkbook(book),
        _error('MISA_EMAIL_DUPLICATE_INVOICE_SEQUENCE'),
      );
      book = _workbook(misaEmailDeliveryFixtureJobs());
      setCell('Hóa đơn GTGT', 'A12', '1');
      expect(
        () => validateMisaEmailDeliveryWorkbook(book),
        _error('MISA_EMAIL_DUPLICATE_INVOICE_SEQUENCE'),
      );
    });
    test('rejects numeric sequence cells', () {
      book.tables['Email Delivery']!.cell(CellIndex.indexByString('A2')).value =
          IntCellValue(3);
      expect(
        () => validateMisaEmailDeliveryWorkbook(book),
        _error('MISA_EMAIL_INVOICE_SEQUENCE_TEXT_REQUIRED'),
      );
    });
    test('requires exact headers', () {
      setCell('Email Delivery', 'A1', 'Invoice sequence ');
      expect(
        () => validateMisaEmailDeliveryWorkbook(book),
        _error('MISA_EMAIL_DELIVERY_HEADERS_INVALID'),
      );
    });
    test(
      'rejects malformed, duplicate, spaced, single and overlong delivery lists',
      () {
        for (final list in [
          'Primary@example.com;bad',
          'Primary@example.com; PRIMARY@example.com',
          'Primary@example.com; second@example.com',
          'Primary@example.com',
        ]) {
          setCell('Email Delivery', 'C2', list);
          expect(
            () => validateMisaEmailDeliveryWorkbook(book),
            _error('MISA_EMAIL_DELIVERY_LIST_INVALID'),
          );
        }
        setCell('Email Delivery', 'C2', 'Primary@example.com;${'x' * 256}');
        expect(
          () => validateMisaEmailDeliveryWorkbook(book),
          _error('MISA_EXPORT_DELIVERY_EMAILS_TOO_LONG_255'),
        );
      },
    );
  });

  test(
    'preserves links and hash rules; changed source email changes content hash',
    () {
      final jobs = misaEmailDeliveryFixtureJobs();
      final book = _workbook(jobs);
      expect(
        _contract(book)['content_sha256'],
        sha256.convert(utf8.encode(jsonEncode(jobs))).toString(),
      );
      final ledger = book.tables['POS Ledger']!.rows.skip(1).toList();
      final mapping = book.tables['Invoice Mapping']!.rows.skip(1).toList();
      var row = 0;
      for (var i = 0; i < jobs.length; i++) {
        final job = jobs[i];
        for (final line in job['line_items_snapshot'] as List) {
          expect(_text(ledger[row][4]), job['receipt_id']);
          expect(_text(ledger[row][8]), '${i + 1}');
          expect(_text(ledger[row][9]), '${row + 9}');
          expect(_text(mapping[row][0]), '${i + 1}');
          expect(_text(mapping[row][1]), '${row + 9}');
          expect(
            _text(ledger[row][10]),
            job['source_hash'] ??
                sha256.convert(utf8.encode(jsonEncode(job))).toString(),
          );
          expect(
            _text(ledger[row][12]),
            sha256.convert(utf8.encode(jsonEncode(line))).toString(),
          );
          row++;
        }
      }
      final changed = misaEmailDeliveryFixtureJobs();
      (changed[2]['buyer_snapshot'] as Map)['email'] =
          'Primary@example.com;new@example.com';
      final updated = _workbook(changed);
      expect(
        _contract(updated)['content_sha256'],
        isNot(_contract(book)['content_sha256']),
      );
      expect(
        _text(updated.tables['POS Ledger']!.rows[4][10]),
        isNot(_text(book.tables['POS Ledger']!.rows[4][10])),
      );
      expect(
        updated.tables['POS Ledger']!.rows.map((r) => _text(r[12])).toList(),
        book.tables['POS Ledger']!.rows.map((r) => _text(r[12])).toList(),
      );
    },
  );

  test('artifact manifest hashes the final file containing Email Delivery', () {
    final receipt = RestaurantSalesReceipt(
      storeId: 'fixture-store',
      storeName: 'Fixture',
      receiptId: 'manifest',
      receiptSource: 'pos_payment',
      salesChannel: 'dine_in',
      grossSales: 108000,
      soldAt: DateTime.parse('2026-10-17T12:00:00+07:00'),
      paymentMethod: 'CASH',
      isRedInvoice: true,
      buyerTaxCode: '',
      buyerLegalName: 'Synthetic',
      buyerAddress: '',
      buyerEmail: 'one@example.com;two@example.com',
      buyerPhone: '',
      issues: [],
      lineItems: [
        RestaurantSalesLineItem(
          name: 'Synthetic',
          quantity: 1,
          unitPrice: 100000,
          invoiceUnitPrice: 100000,
          discountAmount: 0,
          supplyAmount: 100000,
          vatRate: 8,
          vatAmount: 8000,
          orderItemId: 'manifest-item',
          menuItemId: 'fixture-menu',
          invoiceName: 'Synthetic',
          unitName: 'Phần',
          approval:
              (misaEmailDeliveryFixtureJobs()[0]['line_items_snapshot'] as List)
                      .first
                  as Map<String, dynamic>,
        ),
      ],
    );
    final export = CombinedSalesExport(
      taxEntityId: 'fixture-entity',
      sellerTaxCode: 'FIXTURE',
      sellerLegalName: 'Fixture',
      photo: null,
      restaurant: RestaurantSalesExport(
        businessDate: '2026-10-17',
        taxEntityId: 'fixture-entity',
        sellerTaxCode: 'FIXTURE',
        sellerLegalName: 'Fixture',
        isSampleEntity: false,
        storeCount: 1,
        receiptCount: 1,
        grossSales: 108000,
        finalizedAt: DateTime.utc(2026, 10, 17),
        receipts: [receipt],
      ),
    );
    final artifact = buildCombinedSalesArtifact(export);
    final book = Excel.decodeBytes(artifact.bytes);
    expect(book.tables['Email Delivery']!.maxRows, 2);
    expect(
      artifact.manifest['file_sha256'],
      sha256.convert(artifact.bytes).toString(),
    );
    expect(
      artifact.manifest['generation_id'],
      _contract(book)['generation_id'],
    );
  });

  test('optionally writes the locally validated sample workbook', () {
    final directory = Platform.environment['MISA_EMAIL_SAMPLE_DIR'];
    if (directory == null) return;
    Directory(directory).createSync(recursive: true);
    File('$directory/MISA_EMAIL_SAMPLE_AFTER.xlsx').writeAsBytesSync(
      buildMisaPendingInvoiceWorkbook(
        misaEmailDeliveryFixtureJobs().reversed.toList(),
        generationId: 'email-validation-fixed-generation',
      ),
    );
  });
}
