import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/bounded_xlsx.dart';
import 'package:globos_pos_system/core/utils/xlsx_rows.dart';

Uint8List zip(Map<String, String> files) {
  final archive = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  test('compressed bytes, worksheet count and sparse extent reject early', () {
    expect(
      () => readBoundedXlsxArchive(Uint8List(excelMaxCompressedBytes + 1)),
      throwsA(isA<ExcelInputLimitException>()),
    );
    expect(
      () => readBoundedXlsxArchive(
        zip({
          'xl/workbook.xml': '<workbook/>',
          for (var i = 0; i < 11; i++)
            'xl/worksheets/sheet$i.xml': '<worksheet/>',
        }),
      ),
      throwsA(isA<ExcelInputLimitException>()),
    );
    expect(
      () => readBoundedXlsxArchive(
        zip({
          'xl/workbook.xml': '<workbook/>',
          'xl/worksheets/sheet1.xml':
              '<worksheet><row r="200001"><c r="A200001"/></row></worksheet>',
        }),
      ),
      throwsA(isA<ExcelInputLimitException>()),
    );
  });
  test('actual inflation obeys byte budget even when declared size lies', () {
    final bytes = zip({'xl/workbook.xml': 'x' * (excelMaxExpandedBytes + 1)});
    final data = ByteData.sublistView(bytes);
    // The local and central ZIP size both lie; bounded inflater must stop.
    for (var i = 0; i < bytes.length - 30; i++) {
      final signature = data.getUint32(i, Endian.little);
      if (signature == 0x04034b50) data.setUint32(i + 22, 1, Endian.little);
      if (signature == 0x02014b50) data.setUint32(i + 24, 1, Endian.little);
    }
    expect(
      () => readBoundedXlsxArchive(bytes),
      throwsA(isA<ExcelInputLimitException>()),
    );
  });
  test(
    'saved Excel date-time keeps date validation rather than dropping date',
    () {
      final book = Excel.createExcel();
      final cell = book['Sheet1'].cell(CellIndex.indexByString('A1'));
      cell.value = DateTimeCellValue(
        year: 2026,
        month: 10,
        day: 11,
        hour: 9,
        minute: 30,
      );
      cell.cellStyle = CellStyle(numberFormat: NumFormat.standard_22);
      final rows = readXlsxRows(Uint8List.fromList(book.encode()!)).first.rows;
      expect(rows.first.first, '2026-10-11 09:30:00');
    },
  );
}
