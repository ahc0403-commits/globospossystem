import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/menu_import/menu_excel_import.dart';

const _headers = <String>[
  '매장코드',
  '카테고리명',
  '카테고리순서',
  '메뉴명',
  '설명',
  '가격(VND)',
  '판매가능',
  'QR메뉴노출',
  '메뉴순서',
];

void main() {
  test('parses valid menu rows and normalizes optional values', () {
    final bytes = _workbookBytes([
      ['BT', '분식', 1, '떡볶이', '매운맛', 50000, true, true, 1],
      ['BT', '음료', 2, '콜라', '', '20,000', 'TRUE', 'FALSE', 0],
    ]);

    final workbook = parseMenuImportWorkbook(bytes);

    expect(workbook.itemCount, 2);
    expect(workbook.categoryCount, 2);
    expect(workbook.storeCodes, {'BT'});
    expect(workbook.rows.first.price, 50000);
    expect(workbook.rows.first.isVisiblePublic, isTrue);
    expect(workbook.rows.last.description, isNull);
    expect(workbook.rows.last.price, 20000);
    expect(workbook.rows.last.isVisiblePublic, isFalse);
  });

  test('ignores the untouched template example row', () {
    final bytes = _workbookBytes([
      [
        'BT',
        '분식',
        1,
        '떡볶이 (예시)',
        '예시 행입니다. 실제 메뉴로 교체하세요.',
        50000,
        true,
        true,
        1,
      ],
      ['BT', '분식', 1, '라볶이', '', 60000, true, true, 2],
    ]);

    final workbook = parseMenuImportWorkbook(bytes);

    expect(workbook.itemCount, 1);
    expect(workbook.rows.single.name, '라볶이');
  });

  test('rejects duplicate menu names within the same category', () {
    final bytes = _workbookBytes([
      ['BT', '분식', 1, '떡볶이', '', 50000, true, true, 1],
      ['BT', '분식', 1, '떡볶이', '', 55000, true, true, 2],
    ]);

    expect(
      () => parseMenuImportWorkbook(bytes),
      throwsA(
        isA<MenuImportValidationException>().having(
          (error) => error.issues.join(' '),
          'issues',
          contains('중복'),
        ),
      ),
    );
  });

  test('rejects invalid price and boolean values before upload', () {
    final bytes = _workbookBytes([
      ['BT', '분식', 1, '떡볶이', '', 0, 'MAYBE', true, 1],
    ]);

    expect(
      () => parseMenuImportWorkbook(bytes),
      throwsA(
        isA<MenuImportValidationException>()
            .having(
              (error) => error.issues.join(' '),
              'price issue',
              contains('가격'),
            )
            .having(
              (error) => error.issues.join(' '),
              'boolean issue',
              contains('판매가능'),
            ),
      ),
    );
  });

  test('rejects workbooks without the required sheet', () {
    final excel = Excel.createExcel();
    final bytes = Uint8List.fromList(excel.encode()!);

    expect(
      () => parseMenuImportWorkbook(bytes),
      throwsA(
        isA<MenuImportValidationException>().having(
          (error) => error.issues.single,
          'issue',
          contains('메뉴등록'),
        ),
      ),
    );
  });
}

Uint8List _workbookBytes(List<List<Object?>> rows) {
  final excel = Excel.createExcel();
  final sheet = excel[menuImportSheetName];
  sheet.appendRow(_headers.map(_cellValue).toList());
  for (final row in rows) {
    sheet.appendRow(row.map(_cellValue).toList());
  }
  return Uint8List.fromList(excel.encode()!);
}

CellValue? _cellValue(Object? value) => switch (value) {
  null => null,
  String value => TextCellValue(value),
  int value => IntCellValue(value),
  double value => DoubleCellValue(value),
  bool value => BoolCellValue(value),
  _ => TextCellValue(value.toString()),
};
