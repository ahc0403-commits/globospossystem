import 'dart:convert';
import 'dart:io';
import 'fixtures/sales_invoice_fixture.dart';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/payment_method_contract.dart';
import 'package:globos_pos_system/features/admin/einvoice_misa_workbook.dart';

void main() {
  test('all selectable revenue methods have an explicit invoice mapping', () {
    final contract =
        jsonDecode(
              File(
                'test/fixtures/invoice_payment_contract.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final methods = contract['methods'] as Map<String, dynamic>;
    expect(methods.keys.toSet().containsAll(revenuePaymentMethods), isTrue);
    for (final entry in methods.entries) {
      final label = (entry.value as Map)['label'] as String;
      expect(misaPaymentCode(entry.key), label, reason: entry.key);
      expect(misaPaymentCode(label), label, reason: entry.key);
    }
    final keys = methods.keys.toList()..sort();
    for (var i = 0; i < keys.length; i++) {
      for (var j = i + 1; j < keys.length; j++) {
        final labels = {
          methods[keys[i]]['label'] as String,
          methods[keys[j]]['label'] as String,
        }.toList()..sort();
        final expected = keys[i] == 'BANKTRANSFER' && keys[j] == 'CASH'
            ? 'TM/CK'
            : labels.join('/');
        expect(misaPaymentCode('${keys[i]}/${keys[j]}'), expected);
        expect(misaPaymentCode('${keys[j]}/${keys[i]}'), expected);
      }
    }
    for (final unknown in ['QR', 'SERVICE', 'CASH/QR', '']) {
      expect(() => misaPaymentCode(unknown), throwsFormatException);
    }
  });
  test(
    'mixed payment labels retain actual methods without treating QR as a wallet',
    () {
      expect(
        misaPaymentCode('Thẻ quốc tế/Ví điện tử'),
        'Thẻ quốc tế/Ví điện tử',
      );
      expect(misaPaymentCode('ATM'), 'Thẻ ATM');
      expect(() => misaPaymentCode('Ví điện tử/QR'), throwsFormatException);
    },
  );
  test('exports the exact 17-column MISA desktop upload layout', () {
    final bytes = _fixtureWorkbook([
      {
        'id': 'restaurant-job',
        'source_system': 'globos_pos',
        'created_at': '2026-08-04T03:00:00Z',
        'payment_method_snapshot': 'bank_transfer',
        'buyer_snapshot': {'unit_name': 'Restaurant customer'},
        'line_items_snapshot': [
          {
            'order_item_id': 'tteok-line',
            'invoice_name_vi': 'Tteokbokki',
            'misa_unit_name': 'Phần',
            'display_name': 'Tteokbokki',
            'quantity': 2,
            'total_amount_ex_tax': 100000,
            'vat_rate': 8,
            'vat_amount': 8000,
          },
        ],
      },
      {
        'id': 'photo-job',
        'source_system': 'photo_objet_moers',
        'created_at': '2026-08-04T02:00:00Z',
        'payment_method_snapshot': 'Tiền mặt',
        'buyer_snapshot': {
          'tax_code': '0318453298',
          'unit_name': 'Photo customer',
        },
        'line_items_snapshot': [
          {
            'display_name': 'Photo booth',
            'quantity': 1,
            'paying_amount_inc_tax': 120000,
          },
        ],
      },
    ]);

    final workbook = Excel.decodeBytes(bytes);
    expect(workbook.tables.keys, [
      'Hóa đơn GTGT',
      'POS Ledger',
      'Invoice Mapping',
      'Export Contract',
    ]);
    final sheet = workbook.tables['Hóa đơn GTGT']!;

    expect(sheet.rows[7].map(_text).toList(), const [
      'Số thứ tự hóa đơn (*)',
      'Ngày hóa đơn',
      'Tên đơn vị mua hàng',
      'Mã số thuế',
      'Địa chỉ',
      'Người mua hàng',
      'Email',
      'Số điện thoại',
      'Căn cước công dân',
      'Hình thức thanh toán (*)',
      'Tên hàng hóa/dịch vụ (*)',
      'ĐVT',
      'Số lượng',
      'Đơn giá',
      'Thành tiền',
      'Thuế suất GTGT (%)',
      'Tiền thuế GTGT',
    ]);

    final photo = sheet.rows[8];
    expect(_number(photo[0]), 1);
    expect(_text(photo[1]), '04/08/2026');
    expect(_text(photo[9]), 'TM');
    expect(_text(photo[10]), 'Photo booth');
    expect(_text(photo[11]), 'Lần');
    expect(_number(photo[13]), 111111.11);
    expect(_number(photo[14]), 111111.11);
    expect(_number(photo[15]), 8);
    expect(_number(photo[16]), 8888.89);
    expect(_number(photo[14]) + _number(photo[16]), 120000);
    expect(
      (_number(photo[14]) * _number(photo[15]) / 100 * 100).round() / 100,
      _number(photo[16]),
    );

    final restaurant = sheet.rows[9];
    expect(_number(restaurant[0]), 2);
    expect(_text(restaurant[9]), 'CK');
    expect(_text(restaurant[11]), 'Phần');
    expect(_number(restaurant[12]), 2);
    expect(_number(restaurant[13]), 50000);
    expect(_number(restaurant[14]), 100000);
    expect(_number(restaurant[16]), 8000);
  });

  test('preserves equal-rate menu lines and stable IDs', () {
    final bytes = _fixtureWorkbook([
      {
        'source_system': 'globos_pos',
        'payment_method_snapshot': 'TM',
        'created_at': '2026-08-04T02:00:00Z',
        'line_items_snapshot': [
          {
            'order_item_id': 'a',
            'invoice_name_vi': 'A',
            'misa_unit_name': 'Phần',
            'display_name': 'A',
            'quantity': 1,
            'total_amount_ex_tax': 100,
          },
          {
            'order_item_id': 'b',
            'invoice_name_vi': 'B',
            'misa_unit_name': 'Phần',
            'display_name': 'B',
            'quantity': 1,
            'total_amount_ex_tax': 200,
          },
        ],
      },
    ]);
    final rows = Excel.decodeBytes(bytes).tables['Hóa đơn GTGT']!.rows;
    expect(rows, hasLength(10));
    expect(_number(rows[8][0]), 1);
    expect(_number(rows[8][12]), 1);
    expect(_number(rows[8][13]), 100);
    expect(_number(rows[8][14]), 100);
    expect(_text(rows[9][10]), 'B');
    expect(_number(rows[9][14]), 200);
    expect(_number(rows[9][0]), 1);
    expect(_number(rows[8][15]), 0);
    expect(_number(rows[8][16]), 0);
  });

  test('keeps the reported 290000 VND Photo receipt arithmetically exact', () {
    final bytes = _fixtureWorkbook([
      {
        'source_system': 'photo_objet_moers',
        'created_at': '2026-09-11T13:54:59Z',
        'payment_method_snapshot': 'CASH',
        'line_items_snapshot': [
          {
            'display_name': 'Dịch vụ chụp ảnh',
            'quantity': 1,
            'paying_amount_inc_tax': 290000,
          },
        ],
      },
    ]);

    final row = Excel.decodeBytes(bytes).tables['Hóa đơn GTGT']!.rows[8];
    expect(_number(row[13]), 268518.52);
    expect(_number(row[14]), 268518.52);
    expect(_number(row[15]), 8);
    expect(_number(row[16]), 21481.48);
    expect(_number(row[14]) + _number(row[16]), 290000);
    expect(
      (_number(row[14]) * _number(row[15]) / 100 * 100).round() / 100,
      _number(row[16]),
    );
  });

  test('matches every MISA arithmetic check used by the Photo workbook', () {
    final bytes = _fixtureWorkbook([
      for (final gross in [70000, 200000, 290000, 340000])
        {
          'source_system': 'photo_objet_moers',
          'created_at': '2026-09-11T13:54:59Z',
          'line_items_snapshot': [
            {
              'display_name': 'Dịch vụ chụp ảnh',
              'quantity': 1,
              'paying_amount_inc_tax': gross,
            },
          ],
        },
    ]);

    final rows = Excel.decodeBytes(bytes).tables['Hóa đơn GTGT']!.rows.skip(8);
    for (final row in rows) {
      final quantity = _number(row[12]).toDouble();
      final unitPrice = _number(row[13]).toDouble();
      final totalAmount = _number(row[14]).toDouble();
      final vatRate = _number(row[15]).toDouble();
      final vatAmount = _number(row[16]).toDouble();
      expect(
        isMisaLineTotalConsistent(quantity, unitPrice, totalAmount),
        isTrue,
      );
      expect(isMisaVatConsistent(totalAmount, vatRate, vatAmount), isTrue);
    }

    final headers = Excel.decodeBytes(bytes).tables['Hóa đơn GTGT']!.rows[7];
    expect(
      headers.map(_text).where((value) => value.contains('chiết khấu')),
      isEmpty,
    );
  });

  test('rejects the original whole-dong VAT mismatch', () {
    expect(isMisaVatConsistent(268519, 8, 21481), isFalse);
  });

  test('rejects a quantity times unit-price mismatch', () {
    expect(isMisaLineTotalConsistent(2, 100, 199), isFalse);
  });

  test(
    'blocks invalid source VAT rather than recalculating historical amounts',
    () {
      expect(
        () => _fixtureWorkbook([
          {
            'source_system': 'restaurant_pos',
            'payment_method_snapshot': 'TM',
            'line_items_snapshot': [
              {
                'order_item_id': 'invalid',
                'invoice_name_vi': 'Food',
                'misa_unit_name': 'Phần',
                'quantity': 2,
                'total_amount_ex_tax': 10,
                'vat_rate': 8,
                'vat_amount': 5.3,
              },
            ],
          },
        ]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'MISA_EXPORT_SOURCE_AMOUNT_MISMATCH',
          ),
        ),
      );
    },
  );

  test('preserves VND gross amounts while producing MISA-consistent VAT', () {
    for (final rate in [0.0, 5.0, 8.0, 10.0]) {
      final maxGross = rate == 8 ? 1000000 : 100000;
      for (var gross = 1; gross <= maxGross; gross++) {
        final split = splitMisaGrossAmount(gross.toDouble(), rate);
        if ((split.supplyAmount + split.vatAmount - gross).abs() > 0.000001 ||
            !isMisaVatConsistent(split.supplyAmount, rate, split.vatAmount)) {
          fail('MISA split failed for gross=$gross rate=$rate');
        }
      }
    }
  });

  test('refuses an empty pending queue export', () {
    expect(
      () => _fixtureWorkbook(const []),
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

String _text(Data? cell) => cell?.value.toString() ?? '';

num _number(Data? cell) => num.parse(_text(cell));

List<int> _fixtureWorkbook(List<Map<String, dynamic>> jobs) =>
    buildMisaPendingInvoiceWorkbook(approvedSalesFixtureJobs(jobs));
