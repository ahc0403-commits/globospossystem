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
    expect(_number(photo[14]), 111111);
    expect(_number(photo[15]), 8);
    expect(_number(photo[16]), 8889);

    final restaurant = sheet.rows[9];
    expect(_number(restaurant[0]), 2);
    expect(_text(restaurant[9]), 'CK');
    expect(_text(restaurant[11]), 'Phần');
    expect(_number(restaurant[13]), 50000);
    expect(_number(restaurant[14]), 100000);
    expect(_number(restaurant[16]), 8000);
  });

  test('keeps all lines from one job under one invoice sequence', () {
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
    expect(_number(rows[8][0]), 1);
    expect(_number(rows[9][0]), 1);
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
