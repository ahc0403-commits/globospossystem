import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/widgets/invoice_mapping_catalog_dialog.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/invoice_mapping_service.dart';
import 'package:globos_pos_system/features/admin/sales_export_validation.dart';

InvoiceMappingImport input() => InvoiceMappingImport.parse(
  jsonEncode({
    'format_version': 'pos-invoice-mapping-v1',
    'tax_entity_id': 'entity',
    'rows': [
      for (var i = 0; i < 205; i++)
        {
          'approval_type': 'menu_item',
          'menu_item_id': 'menu-$i',
          'invoice_name_vi': 'Món mới $i',
          'unit_name': 'Phần',
          'mapping_version': 'fixture-v1',
          'source_reference': 'Synthetic authenticated test',
          'effective_from': '2026-10-13T00:00:00+07:00',
        },
    ],
  }),
);

void main() {
  test(
    'policy resume skips completed approvals and bounds remaining writes',
    () async {
      final calls = <List<String>>[];
      final service = InvoiceMappingService((name, p) async {
        expect(name, 'apply_invoice_mapping_policy_batch');
        final ids = List<String>.from(p['p_menu_ids'] as List);
        calls.add(ids);
        expect(ids.length, lessThanOrEqualTo(100));
        expect(p['p_effective_from'], '2026-10-13T00:00:00+07:00');
        return {
          'profiles': ids.map((id) => {'menu_item_id': id}).toList(),
        };
      });
      final count = await service.applyPolicy([
        for (var i = 0; i < 205; i++)
          {
            'id': 'menu-$i',
            'store_id': 'store',
            'mapping_status': i < 100 ? 'mapped' : 'approval_required',
          },
      ], effectiveFrom: '2026-10-13T00:00:00+07:00');
      expect(count, 105);
      expect(calls.map((ids) => ids.length), [100, 5]);
      expect(calls.expand((ids) => ids), isNot(contains('menu-0')));
    },
  );
  testWidgets('policy approval records reviewed units and real evidence', (
    tester,
  ) async {
    Map<String, dynamic>? approval;
    final service = InvoiceMappingService((name, p) async {
      if (name == 'approve_invoice_mapping_policy') {
        approval = p;
        return {'id': 'server-policy'};
      }
      return {
        'total_count': 0,
        'mapped_count': 0,
        'missing_count': 0,
        'catalog_revision': 'fixture',
        'rows': [],
        'entities': [
          {'id': 'entity', 'name': 'Fixture entity'},
        ],
        'stores': [
          {
            'store_id': 'store',
            'store_name': 'Fixture',
            'categories': [
              {'id': 'food', 'name_vi': 'Món ăn'},
            ],
          },
        ],
      };
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InvoiceMappingCatalogDialog(
            taxEntityId: 'entity',
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fixture · Automatic mapping policy'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Món ăn · Unit'),
      'Phần',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Approval evidence'),
      'Synthetic owner-reviewed portion units',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Approve policy'));
    await tester.pumpAndSettle();
    expect(approval?['p_store_id'], 'store');
    expect(approval?['p_tax_entity_id'], 'entity');
    expect((approval?['p_rules'] as Map)['category_units'], {'food': 'Phần'});
    expect(approval?.containsKey('approved_by'), isFalse);
    expect(approval?.containsKey('approved_at'), isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'catalog item opens its actual profile editor and closes without approval',
    (tester) async {
      final calls = <String>[];
      final service = InvoiceMappingService((name, p) async {
        calls.add(name);
        return {
          'total_count': 1,
          'mapped_count': 0,
          'missing_count': 1,
          'catalog_revision': 'fixture',
          'entities': [],
          'stores': [],
          'rows': [
            {
              'id': 'never-sold',
              'name_vi': 'Món chưa bán',
              'store_name': 'Fixture',
              'suggested_unit': 'Phần',
              'mapping_status': 'approval_required',
            },
          ],
        };
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: InvoiceMappingCatalogDialog(service: service)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('invoice_catalog_never-sold')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invoice_profile_name')), findsOneWidget);
      expect(find.byKey(const Key('invoice_profile_unit')), findsOneWidget);
      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invoice_profile_name')), findsNothing);
      expect(calls, [
        'get_invoice_mapping_catalog',
        'get_invoice_mapping_catalog',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
  test('205 inputs validate every scope before three bounded writes', () async {
    final calls = <String>[];
    final service = InvoiceMappingService((name, p) async {
      calls.add(name);
      if (name == 'resolve_invoice_mapping_scope') {
        expect((p['p_menu_ids'] as List).length, lessThanOrEqualTo(100));
        return {
          'menus': [
            for (final id in p['p_menu_ids'] as List)
              {'menu_item_id': id, 'store_id': 'store'},
          ],
          'stores': [],
        };
      }
      expect((p['p_rows'] as List).length, lessThanOrEqualTo(100));
      return {
        'store_id': 'store',
        'tax_entity_id': 'entity',
        'profiles': [
          for (final row in p['p_rows'] as List)
            {...row, 'id': 'fixture-profile'},
        ],
      };
    });
    expect(await service.approve(input(), 'entity'), 205);
    expect(calls, [
      ...List.filled(3, 'resolve_invoice_mapping_scope'),
      ...List.filled(3, 'approve_invoice_mapping_batch'),
    ]);
  });
  test('scope failure on final batch prevents every approval write', () async {
    var calls = 0;
    final service = InvoiceMappingService((name, p) async {
      expect(name, 'resolve_invoice_mapping_scope');
      calls++;
      return {
        'menus': [
          if (calls < 3)
            for (final id in p['p_menu_ids'] as List)
              {'menu_item_id': id, 'store_id': 'store'},
        ],
        'stores': [],
      };
    });
    await expectLater(
      service.approve(input(), 'entity'),
      throwsFormatException,
    );
    expect(calls, 3);
  });
  test('catalog pages include never-sold and archived menus once', () async {
    var calls = 0;
    final service = InvoiceMappingService((name, p) async {
      calls++;
      expect(name, 'get_invoice_mapping_catalog');
      final offset = p['p_after_id'] == null
          ? 0
          : int.parse((p['p_after_id'] as String).substring(5)) + 1;
      return {
        'total_count': 205,
        'catalog_revision': 'revision',
        'rows': [
          for (var i = offset; i < offset + 100 && i < 205; i++)
            {
              'id': 'menu-${i.toString().padLeft(3, '0')}',
              'is_archived': i == 204,
            },
        ],
      };
    });
    final result = await service.catalog(taxEntityId: 'entity');
    expect((result['rows'] as List).length, 205);
    expect((result['rows'] as List).last['is_archived'], isTrue);
    expect(calls, 3);
  });
  test('all five rows report three missing menus and five receipts', () {
    final issues = validateSalesExportJobs([
      for (var i = 0; i < 5; i++)
        {
          'receipt_id': 'receipt-$i',
          'receipt_number': 'BC-fixture-$i',
          'source_system': 'restaurant_pos',
          'store_id': 'store',
          'created_at': '2026-10-13T12:00:00+07:00',
          'line_items_snapshot': [
            {
              'order_item_id': 'item-$i',
              'menu_item_id':
                  'menu-${i < 2
                      ? 0
                      : i < 4
                      ? 1
                      : 2}',
              'display_name': 'Món thiếu',
              'item_type': 'menu_item',
              'quantity': 1,
              'unit_price': 100,
              'misa_unit_price': 100,
              'misa_discount_amount': 0,
              'total_amount_ex_tax': 100,
              'vat_rate': 8,
              'vat_amount': 8,
            },
          ],
        },
    ]);
    final error = SalesExportValidationException(issues);
    expect(error.missingMenuCount, 3);
    expect(error.itemCount, 5);
    expect(error.receiptCount, 5);
    expect(issues.every((e) => e.lineNumber == 1), isTrue);
  });
  testWidgets('catalog opens for preselected entity and shows archived menus', (
    tester,
  ) async {
    final service = InvoiceMappingService(
      (name, p) async => {
        'total_count': 2,
        'mapped_count': 1,
        'missing_count': 1,
        'catalog_revision': 'fixture',
        'entities': [
          {'id': 'entity', 'name': 'Fixture entity'},
        ],
        'stores': [],
        'rows': [
          {
            'id': 'a',
            'name_vi': 'Món chưa bán',
            'store_name': 'Fixture',
            'mapping_status': 'approval_required',
          },
          {
            'id': 'b',
            'name_vi': 'Món lưu trữ',
            'store_name': 'Fixture',
            'is_archived': true,
            'mapping_status': 'mapped',
          },
        ],
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InvoiceMappingCatalogDialog(
            taxEntityId: 'entity',
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('invoice_catalog_counts')), findsOneWidget);
    expect(find.textContaining('Món chưa bán'), findsOneWidget);
    expect(find.textContaining('Món lưu trữ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
