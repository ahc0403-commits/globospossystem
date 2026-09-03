import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/photo_sales_import/photo_sales_import.dart';
import 'package:globos_pos_system/features/photo_sales_import/photo_sales_import_screen.dart';
import 'package:globos_pos_system/features/photo_sales_import/photo_sales_import_service.dart';

void main() {
  test('parses the Korean Moers layout and skips zero-amount rows', () {
    final source = parsePhotoSalesImportWorkbook(_sourceWorkbook());

    expect(source.sourceSheetName, 'Sales');
    expect(source.receiptCount, 2);
    expect(source.storeCount, 2);
    expect(source.totalAmount, 162000);
    expect(source.skippedZeroAmountCount, 1);
    expect(source.rows.first.branchCode, 'BH');
    expect(source.rows.last.branchCode, 'DA');
    expect(source.rows.first.deviceName, 'A-01');
    expect(source.rows.last.amount, 54000);
    expect(
      source.branchSummaries.map((branch) => branch.branchCode),
      containsAll(<String>['BH', 'DA']),
    );
  });

  test('normalizes Moers Branch names to stable POS store codes', () {
    expect(normalizePhotoSalesBranchCode('BH'), 'BH');
    expect(normalizePhotoSalesBranchCode('DI AN'), 'DA');
    expect(normalizePhotoSalesBranchCode('LONG THANH'), 'LT');
    expect(normalizePhotoSalesBranchCode('THẢO ĐIỀN'), 'TD');
    expect(normalizePhotoSalesBranchCode('QUANG TRUNG'), 'QT');
    expect(normalizePhotoSalesBranchCode('NOWZONE'), 'NZ');
    expect(normalizePhotoSalesBranchCode('UNKNOWN'), isNull);
  });

  test('builds stable occurrence numbers for identical source sales', () {
    final row = PhotoSalesImportRow(
      sourceRow: 3,
      branchCode: 'BH',
      storeName: 'BIEN HOA',
      deviceName: 'A-01',
      deviceId: 'device-a',
      saleTime: '09:30',
      amount: 108000,
      type: '현금',
    );
    final source = PhotoSalesImportWorkbook(
      rows: [row, row],
      sourceSheetName: 'Sales',
      skippedZeroAmountCount: 0,
    );

    final rows = buildPhotoSalesRegistrationRows(
      source: source,
      saleDate: DateTime(2026, 9, 2),
    );

    expect(rows.map((value) => value['branch_code']), everyElement('BH'));
    expect(rows.map((value) => value['sale_time']), everyElement('09:30:00'));
    expect(rows.map((value) => value['occurrence_no']), [1, 2]);
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
          <tr><th>Branch</th><th>Store</th><th>Device Name</th><th>Device ID</th><th>Time</th><th>Amount</th><th>Type</th></tr>
          <tr><td>NOWZONE</td><td>NOW ZONE</td><td>N-01</td><td>device-n</td><td>11:05:07</td><td>120,000</td><td>PHOTO</td></tr>
        </table></body></html>
      '''),
    );

    final source = parsePhotoSalesImportWorkbook(bytes);
    expect(source.receiptCount, 1);
    expect(source.rows.single.branchCode, 'NZ');
    expect(source.rows.single.storeName, 'NOW ZONE');
    expect(source.rows.single.amount, 120000);
  });

  test('fails closed when a required source column is missing', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', 'Sales');
    excel['Sales'].appendRow([
      TextCellValue('Branch'),
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
        TextCellValue('Branch'),
        TextCellValue('Device Name'),
        TextCellValue('Time'),
        TextCellValue('Amount'),
      ]);
      sheet.appendRow([
        TextCellValue('BH'),
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

  testWidgets('uploads, previews, and automatically saves the workbook', (
    tester,
  ) async {
    String? registeredFileName;
    DateTime? registeredDate;
    PhotoSalesImportWorkbook? registeredWorkbook;
    final registration = Completer<PhotoSalesRegistrationResult>();
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
            registerSales:
                ({
                  required workbook,
                  required saleDate,
                  required sourceFileName,
                }) async {
                  registeredWorkbook = workbook;
                  registeredDate = saleDate;
                  registeredFileName = sourceFileName;
                  return registration.future;
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
    expect(find.byKey(const Key('photo_sales_branch_BH')), findsOneWidget);
    expect(find.byKey(const Key('photo_sales_branch_DA')), findsOneWidget);
    expect(find.textContaining('162'), findsOneWidget);
    expect(find.byKey(const Key('photo_sales_auto_saving')), findsOneWidget);
    expect(registeredFileName, 'Moers Excel');
    expect(registeredDate, DateTime(2026, 9, 2));
    expect(registeredWorkbook?.receiptCount, 2);

    registration.complete(
      const PhotoSalesRegistrationResult(
        saleDate: '2026-09-02',
        sourceRows: 2,
        insertedRows: 2,
        duplicateRows: 0,
        totalAmount: 162000,
        branches: [
          PhotoSalesRegistrationBranch(
            branchCode: 'BH',
            storeId: 'store-bh',
            storeName: 'PHOTO OBJET BIEN HOA',
            receiptCount: 1,
            totalAmount: 108000,
          ),
          PhotoSalesRegistrationBranch(
            branchCode: 'DA',
            storeId: 'store-da',
            storeName: 'PHOTO OBJET DI AN',
            receiptCount: 1,
            totalAmount: 54000,
          ),
        ],
      ),
    );
    await tester.drag(
      find.byKey(const Key('photo_sales_import_screen')),
      const Offset(0, -650),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('photo_sales_registration_result')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('photo_sales_auto_saving')), findsNothing);
    expect(find.byKey(const Key('photo_sales_misa_download')), findsNothing);
  });
}

Uint8List _sourceWorkbook() {
  final excel = Excel.createExcel();
  excel.rename('Sheet1', 'Sales');
  final sheet = excel['Sales'];
  sheet.appendRow([TextCellValue('Photo Objet daily sales')]);
  sheet.appendRow([
    TextCellValue('Branch'),
    TextCellValue('매장'),
    TextCellValue('기기명'),
    TextCellValue('기기ID'),
    TextCellValue('시간'),
    TextCellValue('금액'),
    TextCellValue('구분'),
  ]);
  sheet.appendRow([
    TextCellValue('BH'),
    TextCellValue('BIEN HOA'),
    TextCellValue('A-01'),
    TextCellValue('device-a'),
    TextCellValue('09:30:00'),
    IntCellValue(108000),
    TextCellValue('PHOTO'),
  ]);
  sheet.appendRow([
    TextCellValue('DI AN'),
    TextCellValue('DI AN'),
    TextCellValue('B-01'),
    TextCellValue('device-b'),
    TextCellValue('10:15'),
    TextCellValue('54,000'),
    TextCellValue('PHOTO'),
  ]);
  sheet.appendRow([
    TextCellValue('DI AN'),
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
