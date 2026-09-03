import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/photo_sales_import/photo_sales_import.dart';
import 'package:globos_pos_system/features/photo_sales_import/photo_sales_import_screen.dart';

void main() {
  test('parses the Korean Moers layout and skips zero-amount rows', () {
    final source = parsePhotoSalesImportWorkbook(_sourceWorkbook());

    expect(source.sourceSheetName, 'Sales');
    expect(source.receiptCount, 2);
    expect(source.storeCount, 2);
    expect(source.totalAmount, 162000);
    expect(source.skippedZeroAmountCount, 1);
    expect(source.rows.first.deviceName, 'A-01');
    expect(source.rows.last.amount, 54000);
  });

  test('converts every Photo receipt to the 17-column MISA layout', () {
    final source = parsePhotoSalesImportWorkbook(_sourceWorkbook());
    final output = Excel.decodeBytes(
      buildPhotoSalesMisaWorkbook(
        source: source,
        saleDate: DateTime(2026, 9, 2),
      ),
    );

    expect(output.tables.keys, ['Hóa đơn GTGT']);
    final rows = output.tables['Hóa đơn GTGT']!.rows;
    expect(rows, hasLength(10));
    expect(rows[7].map(_cellText).toList(), const [
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
    expect(_cellText(rows[8][1]), '02/09/2026');
    expect(_cellText(rows[8][9]), 'TM');
    expect(_cellText(rows[8][10]), 'Dịch vụ chụp ảnh');
    expect(_cellText(rows[8][11]), 'Lần');
    expect(_cellText(rows[8][12]), '1');
    expect(_cellText(rows[8][14]), '100000');
    expect(_cellText(rows[8][15]), '8');
    expect(_cellText(rows[8][16]), '8000');
    expect(_cellText(rows[9][14]), '50000');
    expect(_cellText(rows[9][16]), '4000');
  });

  test('accepts the HTML table used by Moers .xls downloads', () {
    final bytes = Uint8List.fromList(
      utf8.encode('''
        <html><body><table>
          <tr><td>Daily sales</td></tr>
          <tr><th>Store</th><th>Device Name</th><th>Device ID</th><th>Time</th><th>Amount</th><th>Type</th></tr>
          <tr><td>NOW ZONE</td><td>N-01</td><td>device-n</td><td>11:05:07</td><td>120,000</td><td>PHOTO</td></tr>
        </table></body></html>
      '''),
    );

    final source = parsePhotoSalesImportWorkbook(bytes);
    expect(source.receiptCount, 1);
    expect(source.rows.single.storeName, 'NOW ZONE');
    expect(source.rows.single.amount, 120000);
  });

  test('fails closed when a required source column is missing', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', 'Sales');
    excel['Sales'].appendRow([
      TextCellValue('Device Name'),
      TextCellValue('Amount'),
    ]);

    expect(
      () => parsePhotoSalesImportWorkbook(Uint8List.fromList(excel.encode()!)),
      throwsA(
        isA<PhotoSalesImportValidationException>().having(
          (error) => error.toString(),
          'message',
          contains('시간(Time)'),
        ),
      ),
    );
  });

  test(
    'blocks a dated source row that differs from the selected sales date',
    () {
      final excel = Excel.createExcel();
      excel.rename('Sheet1', 'Sales');
      final sheet = excel['Sales'];
      sheet.appendRow([
        TextCellValue('Device Name'),
        TextCellValue('Time'),
        TextCellValue('Amount'),
      ]);
      sheet.appendRow([
        TextCellValue('A-01'),
        TextCellValue('2026-09-01 10:00:00'),
        IntCellValue(108000),
      ]);
      final source = parsePhotoSalesImportWorkbook(
        Uint8List.fromList(excel.encode()!),
      );

      expect(
        () => buildPhotoSalesMisaWorkbook(
          source: source,
          saleDate: DateTime(2026, 9, 2),
        ),
        throwsA(
          isA<PhotoSalesImportValidationException>().having(
            (error) => error.toString(),
            'message',
            contains('선택한 매출일'),
          ),
        ),
      );
    },
  );

  testWidgets('uploads, previews, and downloads the converted workbook', (
    tester,
  ) async {
    String? savedName;
    Uint8List? savedBytes;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PhotoSalesImportScreen(
            todayOverride: DateTime(2026, 9, 2),
            pickFile: () async => XFile.fromData(
              _sourceWorkbook(),
              name: 'moers_sales.xlsx',
              mimeType:
                  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            ),
            saveFile: (fileName, bytes) async {
              savedName = fileName;
              savedBytes = bytes;
            },
          ),
        ),
      ),
    );

    final picker = find.byKey(const Key('photo_sales_import_file_picker'));
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('photo_sales_import_preview')), findsOneWidget);
    expect(find.textContaining('162'), findsOneWidget);
    final download = find.byKey(const Key('photo_sales_misa_download'));
    await tester.drag(
      find.byKey(const Key('photo_sales_import_screen')),
      const Offset(0, -500),
    );
    await tester.pump();
    await tester.tap(download);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(savedName, 'MISA_photo_sales_20260902.xlsx');
    expect(savedBytes, isNotNull);
    expect(
      Excel.decodeBytes(savedBytes!).tables.keys,
      contains('Hóa đơn GTGT'),
    );
  });
}

Uint8List _sourceWorkbook() {
  final excel = Excel.createExcel();
  excel.rename('Sheet1', 'Sales');
  final sheet = excel['Sales'];
  sheet.appendRow([TextCellValue('Photo Objet daily sales')]);
  sheet.appendRow([
    TextCellValue('매장'),
    TextCellValue('기기명'),
    TextCellValue('기기ID'),
    TextCellValue('시간'),
    TextCellValue('금액'),
    TextCellValue('구분'),
  ]);
  sheet.appendRow([
    TextCellValue('BIEN HOA'),
    TextCellValue('A-01'),
    TextCellValue('device-a'),
    TextCellValue('09:30:00'),
    IntCellValue(108000),
    TextCellValue('PHOTO'),
  ]);
  sheet.appendRow([
    TextCellValue('DI AN'),
    TextCellValue('B-01'),
    TextCellValue('device-b'),
    TextCellValue('10:15'),
    TextCellValue('54,000'),
    TextCellValue('PHOTO'),
  ]);
  sheet.appendRow([
    TextCellValue('DI AN'),
    TextCellValue('B-02'),
    TextCellValue('device-c'),
    TextCellValue('10:30'),
    IntCellValue(0),
    TextCellValue('PHOTO'),
  ]);
  return Uint8List.fromList(excel.encode()!);
}

String _cellText(Data? cell) => cell?.value.toString() ?? '';
