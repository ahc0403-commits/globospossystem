import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/einvoice_misa_workbook.dart';

void main() {
  test('exports the exact 17-column MISA desktop upload layout', () {
    final bytes = buildMisaPendingInvoiceWorkbook([
      {
        'id': 'restaurant-job',
        'source_system': 'globos_pos',
        'created_at': '2026-08-04T03:00:00Z',
        'payment_method_snapshot': 'bank_transfer',
        'buyer_snapshot': {'unit_name': 'Restaurant customer'},
        'line_items_snapshot': [
          {
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
    expect(workbook.tables.keys, ['Hóa đơn GTGT']);
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
    expect(_text(restaurant[11]), 'Lần');
    expect(_number(restaurant[12]), 1);
    expect(_number(restaurant[13]), 100000);
    expect(_number(restaurant[14]), 100000);
    expect(_number(restaurant[16]), 8000);
  });

  test('combines equal-rate lines into one warning-free invoice row', () {
    final bytes = buildMisaPendingInvoiceWorkbook([
      {
        'source_system': 'globos_pos',
        'created_at': '2026-08-04T02:00:00Z',
        'line_items_snapshot': [
          {'display_name': 'A', 'quantity': 1, 'total_amount_ex_tax': 100},
          {'display_name': 'B', 'quantity': 1, 'total_amount_ex_tax': 200},
        ],
      },
    ]);
    final rows = Excel.decodeBytes(bytes).tables['Hóa đơn GTGT']!.rows;
    expect(rows, hasLength(9));
    expect(_number(rows[8][0]), 1);
    expect(_number(rows[8][12]), 1);
    expect(_number(rows[8][13]), 300);
    expect(_number(rows[8][14]), 300);
    expect(_number(rows[8][15]), 0);
    expect(_number(rows[8][16]), 0);
  });

  test('keeps the reported 290000 VND Photo receipt arithmetically exact', () {
    final bytes = buildMisaPendingInvoiceWorkbook([
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
    final bytes = buildMisaPendingInvoiceWorkbook([
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

  test('repairs quantity, line VAT, and same-rate total mismatches', () {
    final bytes = buildMisaPendingInvoiceWorkbook([
      {
        'source_system': 'restaurant_pos',
        'line_items_snapshot': [
          for (var index = 0; index < 4; index++)
            {
              'display_name': 'Food',
              'quantity': 2,
              'unit_price': 100,
              'total_amount_ex_tax': 10,
              'vat_rate': 8,
              'vat_amount': 1.3,
            },
        ],
      },
    ]);

    final rows = Excel.decodeBytes(bytes).tables['Hóa đơn GTGT']!.rows;
    expect(rows, hasLength(9));
    final row = rows[8];
    final quantity = _number(row[12]).toDouble();
    final unitPrice = _number(row[13]).toDouble();
    final supply = _number(row[14]).toDouble();
    final rate = _number(row[15]).toDouble();
    final vat = _number(row[16]).toDouble();
    expect(quantity, 1);
    expect(supply + vat, closeTo(45.2, 0.000001));
    expect(isMisaLineTotalConsistent(quantity, unitPrice, supply), isTrue);
    expect(isMisaVatConsistent(supply, rate, vat), isTrue);
  });

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

String _text(Data? cell) => cell?.value.toString() ?? '';

num _number(Data? cell) => num.parse(_text(cell));
