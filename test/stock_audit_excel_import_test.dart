import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/inventory_purchase/stock_audit_excel_import.dart';

void main() {
  final session = <String, dynamic>{
    'id': 'session',
    'store_id': 'binh',
    'version': 1,
    'status': 'planned',
    'exported_at': '2026-09-30T10:00:00Z',
    'lines': <Map<String, dynamic>>[],
    'snapshot': List.generate(
      123,
      (i) => {
        'product_id': 'product-$i',
        'product_code': 'WR${i.toString().padLeft(3, '0')}',
        'product_name': '품목 $i',
        'base_unit': i == 1
            ? 'ml'
            : i == 2
            ? 'ea'
            : 'g',
      },
    ),
  };
  final now = DateTime.parse('2026-09-30T12:00:00Z');
  Uint8List file(void Function(Excel) edit) {
    final excel = Excel.decodeBytes(buildStockAuditTemplate(session));
    excel[stockAuditSettingsSheet].cell(CellIndex.indexByString('B6')).value =
        TextCellValue('2026-09-30T18:00:00+07:00');
    edit(excel);
    return Uint8List.fromList(excel.encode()!);
  }

  StockAuditImport parse(Uint8List bytes) => parseStockAuditWorkbook(
    bytes,
    storeId: 'binh',
    session: session,
    now: now,
  );
  test(
    'all 123 targets exported; blanks stay uncounted, zero counts as zero',
    () {
      final bytes = file(
        (excel) =>
            excel[stockAuditSheet].cell(CellIndex.indexByString('D2')).value =
                IntCellValue(0),
      );
      final result = parse(bytes);
      expect(result.targetCount, 123);
      expect(result.countedCount, 1);
      expect(result.blankCount, 122);
      expect(result.lines.single['actual_quantity_base'], 0);
      expect(result.canComplete, false);
    },
  );
  test('kg and L convert to base units, fractional ea is retained', () {
    final result = parse(
      file((excel) {
        final sheet = excel[stockAuditSheet];
        for (final r in [2, 3, 4]) {
          sheet.cell(CellIndex.indexByString('D$r')).value = DoubleCellValue(
            1.5,
          );
        }
        sheet.cell(CellIndex.indexByString('E2')).value = TextCellValue('kg');
        sheet.cell(CellIndex.indexByString('E3')).value = TextCellValue('L');
      }),
    );
    expect(result.lines.map((l) => l['actual_quantity_base']), [
      1500,
      1500,
      1.5,
    ]);
  });
  test('full counts including explicit exclusions can complete', () {
    final result = parse(
      file((excel) {
        for (var r = 2; r <= 124; r++) {
          excel[stockAuditSheet].cell(CellIndex.indexByString('D$r')).value =
              IntCellValue(0);
        }
        excel[stockAuditSheet].cell(CellIndex.indexByString('D124')).value =
            null;
        excel[stockAuditSheet].cell(CellIndex.indexByString('H124')).value =
            TextCellValue('sealed offsite stock');
      }),
    );
    expect(result.countedCount, 122);
    expect(result.excludedCount, 1);
    expect(result.canComplete, true);
  });
  test('roundtrip draft quantities and timestamps', () {
    final draft = {
      ...session,
      'version': 2,
      'lines': [
        {
          'product_id': 'product-0',
          'actual_quantity_base': 12.5,
          'counted_at': '2026-09-30T11:00:00Z',
          'memo': 'partial',
        },
      ],
    };
    final result = parseStockAuditWorkbook(
      Uint8List.fromList(buildStockAuditTemplate(draft)),
      storeId: 'binh',
      session: draft,
      now: now,
    );
    expect(result.lines.single['actual_quantity_base'], 12.5);
    expect(result.lines.single['memo'], 'partial');
  });
  for (final field in ['store_id', 'session_id', 'version', 'exported_at']) {
    test('reject changed metadata $field', () {
      final bytes = file((excel) {
        final row = {
          'store_id': 2,
          'session_id': 3,
          'version': 4,
          'exported_at': 5,
        }[field]!;
        excel[stockAuditSettingsSheet]
            .cell(CellIndex.indexByString('B$row'))
            .value = TextCellValue(
          'wrong',
        );
      });
      expect(() => parse(bytes), throwsA(isA<StockAuditImportException>()));
    });
  }
  final badEdits = <String, void Function(Excel)>{
    'duplicate ID': (e) {
      for (final col in ['A', 'B', 'C']) {
        e[stockAuditSheet].cell(CellIndex.indexByString('${col}3')).value =
            e[stockAuditSheet].cell(CellIndex.indexByString('${col}2')).value;
      }
    },
    'changed code': (e) =>
        e[stockAuditSheet].cell(CellIndex.indexByString('B2')).value =
            TextCellValue('TD001'),
    'formula': (e) =>
        e[stockAuditSheet].cell(CellIndex.indexByString('D2')).value =
            FormulaCellValue('1+1'),
    'negative': (e) =>
        e[stockAuditSheet].cell(CellIndex.indexByString('D2')).value =
            IntCellValue(-1),
    'too many decimals': (e) =>
        e[stockAuditSheet].cell(CellIndex.indexByString('D2')).value =
            DoubleCellValue(0.0001),
    'wrong unit': (e) {
      e[stockAuditSheet].cell(CellIndex.indexByString('D2')).value =
          IntCellValue(1);
      e[stockAuditSheet].cell(CellIndex.indexByString('E2')).value =
          TextCellValue('box');
    },
    'missing count time': (e) {
      e[stockAuditSheet].cell(CellIndex.indexByString('D2')).value =
          IntCellValue(1);
      e[stockAuditSettingsSheet].cell(CellIndex.indexByString('B6')).value =
          null;
    },
    'count before snapshot': (e) {
      e[stockAuditSheet].cell(CellIndex.indexByString('D2')).value =
          IntCellValue(1);
      e[stockAuditSheet].cell(CellIndex.indexByString('F2')).value =
          TextCellValue('2026-09-30T15:00:00+07:00');
    },
  };
  for (final entry in badEdits.entries) {
    test(
      'reject ${entry.key}',
      () => expect(
        () => parse(file(entry.value)),
        throwsA(isA<StockAuditImportException>()),
      ),
    );
  }
}
