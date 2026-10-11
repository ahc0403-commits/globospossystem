import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/combined_sales_export.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:globos_pos_system/features/admin/einvoice_misa_workbook.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/invoice_mapping_service.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_report_service.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_summary.dart';
import 'daily_sales_report_service_test.dart' as fixtures;

Map<String, dynamic> line(String id, {bool wet = false}) => {
  'order_item_id': id,
  'source_order_item_id': id.split(':').first,
  'menu_item_id': wet ? null : 'menu-$id',
  'item_type': wet ? 'wet_tissue_charge' : 'menu_item',
  'invoice_name_vi': wet ? 'Khăn ướt' : 'Food $id',
  'misa_unit_name': wet ? 'Cái' : 'Phần',
  'invoice_profile_id': 'approved-$id',
  'invoice_approval_type': wet ? 'item_type' : 'menu_item',
  'invoice_mapping_version': 'fixture-v1',
  'invoice_source_reference': 'synthetic approval',
  'invoice_store_id': 'store',
  'invoice_effective_from': '2026-10-08T00:00:00+07:00',
  'invoice_effective_to': '2026-10-09T00:00:00+07:00',
  'quantity': 2,
  'unit_price': 100,
  'misa_unit_price': 100,
  'misa_discount_amount': 0,
  'total_amount_ex_tax': 200,
  'vat_rate': 8,
  'vat_amount': 16,
};
Map<String, dynamic> job(String id, List<Map<String, dynamic>> lines) => {
  'receipt_id': id,
  'receipt_number': 'R-$id',
  'source_system': 'restaurant_pos',
  'tax_entity_id': 'entity',
  'store_id': 'store',
  'created_at': '2026-10-08T12:00:00+07:00',
  'payment_method_snapshot': 'CK',
  'buyer_snapshot': {'email': 'fixture@example.com', 'phone': '0123456789'},
  'line_items_snapshot': lines,
};
String text(Data? c) => c?.value?.toString() ?? '';

void main() {
  test(
    'OOXML has text A, empty B:J continuation, unchanged numeric K:Q and source ledger',
    () {
      final a = line('a')
        ..addAll({'misa_unit_price': 120, 'misa_discount_amount': 40});
      final bytes = buildMisaPendingInvoiceWorkbook([
        job('r1', [a, line('b'), line('wet', wet: true)]),
        job('r2', [line('c')]),
      ]);
      final book = Excel.decodeBytes(bytes);
      final rows = book.tables['Hóa đơn GTGT']!.rows;
      expect(rows[7].length, 17);
      expect(rows.length, 12);
      for (final row in rows.skip(8)) {
        expect(row[0]!.value, isA<TextCellValue>());
      }
      expect(rows[8][6]!.value.toString(), 'fixture@example.com');
      for (final row in rows.skip(9).take(2)) {
        expect(row.sublist(1, 10).every((c) => c?.value == null), isTrue);
      }
      expect(text(rows[11][9]), 'CK');
      expect(text(rows[8][13]), '100');
      expect(text(rows[8][14]), '200');
      final mapping = book.tables['Invoice Mapping']!.rows;
      expect(text(mapping[1][11]), '120');
      expect(text(mapping[1][12]), '40');
      expect(text(mapping[3][4]), 'item_type');
      expect(text(book.tables['POS Ledger']!.rows[1][9]), '9');
      final archive = ZipDecoder().decodeBytes(bytes);
      final xml = XmlDocument.parse(
        utf8.decode(
          archive.findFile('xl/worksheets/sheet1.xml')!.content as List<int>,
        ),
      );
      expect(xml.findAllElements('mergeCell'), isEmpty);
      expect(
        xml.findAllElements('dimension').single.getAttribute('ref'),
        'A1:Q12',
      );
      final cells = {
        for (final c in xml.findAllElements('c')) c.getAttribute('r'): c,
      };
      for (final row in [10, 11]) {
        for (final col in ['B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J']) {
          final c = cells['$col$row'];
          expect(c?.findElements('v') ?? [], isEmpty);
          expect(c?.findElements('is') ?? [], isEmpty);
          expect(c?.findElements('f') ?? [], isEmpty);
          expect(c?.getAttribute('t'), isNull);
        }
      }
    },
  );
  test(
    'collects all receipt/item/field errors and rejects missing numerics, wrong approval, scope and interval',
    () {
      final bad = line('a')
        ..remove('quantity')
        ..remove('vat_rate')
        ..remove('invoice_profile_id');
      final other = line('b')
        ..addAll({
          'misa_unit_price': double.nan,
          'invoice_store_id': 'other',
          'invoice_effective_to': '2026-10-08T01:00:00+07:00',
        });
      try {
        buildMisaPendingInvoiceWorkbook([
          job('r1', [bad]),
          job('r2', [other]),
        ]);
        fail('invalid source saved');
      } on SalesExportValidationException catch (e) {
        expect(e.receiptCount, 2);
        expect(e.itemCount, 2);
        expect(
          e.issues.map((i) => i.field),
          containsAll([
            'quantity',
            'vat_rate',
            'invoice_profile_id',
            'misa_unit_price',
            'invoice_store_id',
            'invoice_effective_from',
          ]),
        );
        expect(
          e.issues.every((i) => !i.toString().contains('fixture@example.com')),
          isTrue,
        );
      }
      for (final mutation in [
        {'quantity': 0},
        {'quantity': 'NaN'},
        {'vat_amount': -1},
        {'misa_discount_amount': -1},
        {'misa_unit_price': 123},
        {'invoice_approval_type': 'item_type'},
        {'menu_item_id': null},
      ]) {
        expect(
          () => buildMisaPendingInvoiceWorkbook([
            job('r', [line('a')..addAll(mutation)]),
          ]),
          throwsFormatException,
        );
      }
      expect(
        () => buildMisaPendingInvoiceWorkbook([
          job('r', [line('a')]),
          job('r', [line('b')]),
        ]),
        throwsFormatException,
      );
      expect(
        () => buildMisaPendingInvoiceWorkbook([
          job('r', [line('a'), line('a')]),
        ]),
        throwsFormatException,
      );
      expect(
        () => buildMisaPendingInvoiceWorkbook([
          job('r', [line('a')])..['externally_reported'] = true,
        ]),
        throwsFormatException,
      );
    },
  );
  test(
    'file sidecar SHA matches final XLSX and embedded generation identity',
    () {
      final l = line('a')..['display_name'] = 'Food';
      final r = createRestaurantSalesExport({
        'business_date': '2026-10-08',
        'status': 'ready',
        'report_ready_at': '2026-10-08T00:00:00+07:00',
        'tax_entity_id': 'entity',
        'seller_tax_code': 'FIXTURE',
        'seller_legal_name': 'Fixture',
        'store_count': 1,
        'receipt_count': 1,
        'gross_sales': 216,
        'receipts': [
          {
            'receipt_id': 'r',
            'receipt_source': 'pos_payment',
            'source_system': 'restaurant_pos',
            'store_id': 'store',
            'store_name': 'Fixture',
            'sold_at': '2026-10-08T12:00:00+07:00',
            'gross_sales': 216,
            'payment_method': 'CK',
            'line_items': [l],
          },
        ],
      });
      final artifact = buildCombinedSalesArtifact(
        combineSalesExportsByTaxEntity(
          restaurantExports: [r],
          photoExports: [],
        ).single,
      );
      final contract = {
        for (final row in Excel.decodeBytes(
          artifact.bytes,
        ).tables['Export Contract']!.rows)
          text(row[0]): text(row[1]),
      };
      expect(
        artifact.manifest['file_sha256'],
        sha256.convert(artifact.bytes).toString(),
      );
      expect(artifact.manifest['generation_id'], contract['generation_id']);
      expect(artifact.manifest['receipt_count'], 1);
      expect(artifact.manifest['export_line_count'], 1);
    },
  );
  test('positive HALF_UP rounds each supply and VAT separately', () {
    final l = line('a')
      ..addAll({
        'quantity': 3,
        'unit_price': 100.5 / 3,
        'misa_unit_price': 100.5 / 3,
        'total_amount_ex_tax': 100.5,
        'vat_rate': 0,
        'vat_amount': 0,
      });
    final b = Excel.decodeBytes(
      buildMisaPendingInvoiceWorkbook([
        job('r', [l]),
      ]),
    );
    final contract = {
      for (final r in b.tables['Export Contract']!.rows) text(r[0]): text(r[1]),
    };
    expect(contract['source_gross'], '100.50');
    expect(contract['rounded_line_gross'], '101');
    expect(contract['rounding_difference'], '-0.50');
  });
  test(
    'bounded mapping scope resolution and approval retries keep exact finite interval',
    () async {
      final input = InvoiceMappingImport.parse(
        jsonEncode({
          'format_version': 'pos-invoice-mapping-v1',
          'tax_entity_id': 'entity',
          'rows': [
            for (var i = 0; i < 73; i++)
              {
                'approval_type': 'menu_item',
                'menu_item_id': 'menu-$i',
                'invoice_name_vi': 'Food $i',
                'unit_name': 'Phần',
                'mapping_version': 'v1',
                'source_reference': 'synthetic',
                'effective_from': '2026-10-08T00:00:00+07:00',
                'effective_to': '2026-10-09T00:00:00+07:00',
              },
            {
              'approval_type': 'item_type',
              'item_type': 'wet_tissue_charge',
              'store_names': ['Restaurant'],
              'invoice_name_vi': 'Khăn ướt',
              'unit_name': 'Cái',
              'mapping_version': 'v1',
              'source_reference': 'synthetic',
              'effective_from': '2026-10-08T00:00:00+07:00',
              'effective_to': '2026-10-09T00:00:00+07:00',
            },
          ],
        }),
      );
      var calls = 0;
      final service = InvoiceMappingService((name, p) async {
        calls++;
        if (name == 'resolve_invoice_mapping_scope') {
          return {
            'menus': [
              for (var i = 0; i < 73; i++)
                {'menu_item_id': 'menu-$i', 'store_id': 'store'},
            ],
            'stores': [
              {'store_id': 'store', 'store_name': 'Restaurant'},
            ],
          };
        }
        expect((p['p_rows'] as List).length, 74);
        expect(
          (p['p_rows'] as List).every(
            (r) => r['effective_to'] == '2026-10-09T00:00:00+07:00',
          ),
          isTrue,
        );
        return {
          'store_id': 'store',
          'tax_entity_id': 'entity',
          'profiles': [
            for (final r in p['p_rows']) {...r, 'id': 'real-fixture-id'},
          ],
        };
      });
      expect(await service.approve(input, 'entity'), 74);
      expect(calls, 2);
      await expectLater(service.approve(input, 'other'), throwsFormatException);
      expect(calls, 2);
    },
  );
  test(
    'page order, revision changes and reported scopes fail before exporting',
    () async {
      for (final change in ['order', 'revision', 'source', 'protected']) {
        final summary = DailySalesSummary.fromJson(
          '2026-10-08',
          fixtures.row()..addAll({
            'restaurant_receipt_count': 2,
            'restaurant_gross': 21600,
            'photo_receipt_count': 0,
            'photo_gross': 0,
            'mapping_revision': 1,
            'source_revision': 'fixture-source',
          }),
        );
        final service = DailySalesReportService(
          rpc: (_, p) async => {
            'business_date': '2026-10-08',
            'tax_entity_id': 'entity',
            'source_system': 'restaurant_pos',
            'mapping_revision': change == 'revision' ? 2 : 1,
            'source_revision': change == 'source'
                ? 'changed-source'
                : 'fixture-source',
            'externally_reported': change == 'protected',
            'rows': [
              fixtures.receipt(1),
              fixtures.receipt(change == 'order' ? 0 : 2),
            ],
          },
        );
        await expectLater(service.loadExport(summary), throwsFormatException);
      }
    },
  );
  test(
    'in-flight source loads share pages without caching completed results',
    () async {
      final summary = DailySalesSummary.fromJson(
        '2026-10-08',
        fixtures.row()..addAll({
          'restaurant_receipt_count': 1,
          'restaurant_gross': 10800,
          'photo_receipt_count': 0,
          'photo_gross': 0,
        }),
      );
      var calls = 0;
      final service = DailySalesReportService(
        rpc: (_, p) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return {
            'business_date': '2026-10-08',
            'tax_entity_id': 'entity',
            'source_system': 'restaurant_pos',
            'rows': [fixtures.receipt(1)],
          };
        },
      );
      await Future.wait([
        service.loadExport(summary),
        service.loadExport(summary),
      ]);
      expect(calls, 1);
      await service.loadExport(summary);
      expect(calls, 2);
    },
  );
  test(
    '569 receipts/1034 rows and 10x preserve all source lines with bounded file growth',
    () {
      for (final scale in [1, 10]) {
        final jobs = <Map<String, dynamic>>[];
        for (var copy = 0; copy < scale; copy++) {
          for (var i = 0; i < 105; i++) {
            jobs.add(
              job('restaurant-$copy-$i', [
                for (var l = 0; l < (i < 45 ? 6 : 5); l++)
                  line('item-$copy-$i-$l'),
              ]),
            );
          }
          for (var i = 0; i < 464; i++) {
            jobs.add({
              'receipt_id': 'photo-$copy-$i',
              'source_system': 'photo_objet_moers',
              'created_at': '2026-10-08T12:00:00+07:00',
              'payment_method_snapshot': 'CASH',
              'line_items_snapshot': [
                {
                  'order_item_id': 'photo-$copy-$i',
                  'quantity': 1,
                  'paying_amount_inc_tax': 10800,
                },
              ],
            });
          }
        }
        final timer = Stopwatch()..start();
        final bytes = buildMisaPendingInvoiceWorkbook(jobs);
        timer.stop();
        final encodeMaxRss = ProcessInfo.maxRss;
        final book = Excel.decodeBytes(bytes);
        final rows = book.tables['Hóa đơn GTGT']!.rows.skip(8).toList();
        expect(rows.length, 1034 * scale);
        expect(rows.where((r) => r[1]?.value == null).length, 465 * scale);
        expect(rows.map((r) => text(r[0])).toSet().length, 569 * scale);
        expect(book.tables['POS Ledger']!.rows.length, 1034 * scale + 1);
        // Local metric output has no customer or receipt identities.
        // ignore: avoid_print
        print(
          'SALES_XLSX_METRICS receipts=${jobs.length} lines=${rows.length} elapsed_ms=${timer.elapsedMilliseconds} bytes=${bytes.length} encode_max_rss=$encodeMaxRss decode_max_rss=${ProcessInfo.maxRss}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
