import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/inventory_purchase/stock_audit_excel_import.dart';

void main() {
  final session = <String, dynamic>{
    'id': '11111111-1111-4111-8111-111111111111',
    'store_id': 'binh',
    'store_name': 'BunsikClub Binh Thanh',
    'version': 1,
    'status': 'planned',
    'template_version': 2,
    'business_date': '2026-09-30',
    'effective_at': '2026-09-30T16:00:00Z',
    'exported_at': '2026-10-01T00:00:00Z',
    'lines': <dynamic>[],
    'snapshot': List.generate(
      123,
      (i) => {
        'product_id': 'product-$i',
        'product_code': 'WR${i.toString().padLeft(3, '0')}',
        'product_name': '품목 $i',
        'base_unit': 'ea',
        'supplier_name': 'Woori',
        'current_stock_base': 100,
      },
    ),
  };
  final now = DateTime.parse('2026-10-01T05:00:00Z');
  Uint8List edit(void Function(Excel) change) {
    final e = Excel.decodeBytes(buildStockAuditTemplate(session));
    change(e);
    return Uint8List.fromList(e.encode()!);
  }

  StockAuditImport parse(Uint8List bytes, {Map<String, dynamic>? saved}) =>
      parseStockAuditWorkbook(
        bytes,
        storeId: 'binh',
        session: saved ?? session,
        now: now,
      );
  test(
    'dated template has all 123 targets, visible date, supplier and instructions',
    () {
      final e = Excel.decodeBytes(buildStockAuditTemplate(session));
      expect(
        e.tables.keys,
        containsAll([
          stockAuditSheet,
          stockAuditInfoSheet,
          stockAuditGuideSheet,
        ]),
      );
      expect(e[stockAuditSheet].maxRows, 129);
      expect(
        e[stockAuditSheet].cell(CellIndex.indexByString('B2')).value,
        TextCellValue('2026-09-30'),
      );
      expect(
        e[stockAuditSheet].cell(CellIndex.indexByString('B3')).value,
        TextCellValue('2026-09-30 23:00:00 +07:00'),
      );
      expect(stockAuditFileName(session), contains('20260930_2300'));
    },
  );
  test('next-day upload retains the reference and explicit zero', () {
    final result = parse(
      edit(
        (e) => e[stockAuditSheet].cell(CellIndex.indexByString('D7')).value =
            IntCellValue(0),
      ),
    );
    expect(result.targetCount, 123);
    expect(result.countedCount, 1);
    expect(result.blankCount, 122);
    expect(result.lines.single['counted_at'], '2026-09-30T16:00:00.000Z');
    expect(result.lines.single['actual_quantity_base'], 0);
  });
  for (final field in [
    'business_date',
    'effective_at',
    'timezone',
    'version',
  ]) {
    test('reject changed fixed metadata $field', () {
      final bytes = edit((e) {
        final sheet = e[stockAuditInfoSheet];
        final i = sheet.rows.indexWhere(
          (r) => r.first?.value == TextCellValue(field),
        );
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: i))
            .value = TextCellValue(
          'wrong',
        );
      });
      expect(() => parse(bytes), throwsA(isA<StockAuditImportException>()));
    });
  }
  test(
    'missing rows, formulas, blank-row unit edits and duplicate IDs fail',
    () {
      final edits = <void Function(Excel)>[
        (e) {
          for (var c = 0; c < 10; c++) {
            e[stockAuditSheet]
                    .cell(
                      CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 128),
                    )
                    .value =
                null;
          }
        },
        (e) => e[stockAuditSheet].cell(CellIndex.indexByString('D7')).value =
            FormulaCellValue('1+1'),
        (e) => e[stockAuditSheet].cell(CellIndex.indexByString('E7')).value =
            TextCellValue('kg'),
        (e) => e[stockAuditSheet].cell(CellIndex.indexByString('A8')).value =
            TextCellValue('product-0'),
      ];
      for (final change in edits) {
        expect(
          () => parse(edit(change)),
          throwsA(isA<StockAuditImportException>()),
        );
      }
    },
  );
  test('completed original file can be retried, edited identity cannot', () {
    final completed = {...session, 'status': 'completed', 'version': 2};
    final bytes = edit(
      (e) => e[stockAuditSheet].cell(CellIndex.indexByString('D7')).value =
          IntCellValue(80),
    );
    expect(
      parse(bytes, saved: completed).lines.single['actual_quantity_base'],
      80,
    );
  });
  test(
    'report freezes reference POS/actual difference and exports separate +/-',
    () {
      final report = {
        ...session,
        'status': 'completed',
        'completed_at': '2026-10-01T05:00:00Z',
        'as_of': '2026-10-01T05:00:00Z',
        'rows': [
          {
            'product_code': 'WR001',
            'product_name': '품목',
            'supplier_name': 'Woori',
            'base_unit': 'ea',
            'inventory_item_id': 'item',
            'baseline_quantity_base': 100,
            'actual_quantity_base': 80,
            'variance_quantity_base': -20,
            'unit_cost': null,
            'variance_amount': null,
            'counted_at': '2026-09-30T16:00:00Z',
          },
        ],
        'movements': [
          {
            'ingredient_id': 'item',
            'product_code': 'WR001',
            'product_name': '품목',
            'base_unit': 'ea',
            'business_date': '2026-10-01',
            'effective_at': '2026-10-01T01:00:00Z',
            'quantity_base': 30,
          },
          {
            'ingredient_id': 'item',
            'product_code': 'WR001',
            'product_name': '품목',
            'base_unit': 'ea',
            'business_date': '2026-10-01',
            'effective_at': '2026-10-01T02:00:00Z',
            'quantity_base': -20,
          },
          {
            'ingredient_id': 'item',
            'product_code': 'WR001',
            'product_name': '품목',
            'base_unit': 'ea',
            'business_date': '2026-10-01',
            'effective_at': '2026-10-01T03:00:00Z',
            'quantity_base': -5,
          },
        ],
      };
      final e = Excel.decodeBytes(buildStockAuditReport(report));
      final s = e['실사결과'];
      expect(s.cell(CellIndex.indexByString('E7')).value, IntCellValue(100));
      expect(s.cell(CellIndex.indexByString('F7')).value, IntCellValue(80));
      expect(s.cell(CellIndex.indexByString('G7')).value, IntCellValue(-20));
      expect(s.cell(CellIndex.indexByString('M7')).value, IntCellValue(85));
      expect(
        s.cell(CellIndex.indexByString('I7')).value,
        TextCellValue('비교 불가 / 미등록'),
      );
      expect(e['기준이후증감'].maxRows, 4);
    },
  );
}
