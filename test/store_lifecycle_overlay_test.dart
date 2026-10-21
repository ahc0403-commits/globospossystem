import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/procurement/inventory_lot_workspace.dart';
import 'package:globos_pos_system/features/store_procurement/quality_profile_editor.dart';
import 'package:globos_pos_system/features/store_procurement/store_procurement_setup_card.dart';
import 'package:globos_pos_system/features/store_setup/widgets/store_operational_acceptance_dialog.dart';
import 'package:globos_pos_system/features/store_setup/widgets/store_lifecycle_card.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/sales_reporting_batches_dialog.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/sales_reporting_batch_service.dart';

class _Setup extends StoreProcurementSetupService {
  final writes = <String>[];
  @override
  Future<dynamic> call(String name, Map<String, dynamic> p) async {
    if (name == 'admin_procurement_reference_page_v1') return {'rows': []};
    if (name == 'admin_get_procurement_setup_v1') {
      return {
        'readiness': {'checks': {}, 'enforced': true},
        'templates': [],
        'specs': [
          {
            'id': 'spec',
            'code': 'RAW',
            'revision': 1,
            'name': 'Material',
            'base_unit': 'g',
          },
        ],
        'products': [
          {
            'id': 'product',
            'name': 'Material',
            'product_code': 'RAW',
            'base_unit': 'g',
            'stock_unit': 'g',
            'base_unit_factor': 1,
            'specification': 'Reviewed material',
            'suppliers': [
              {
                'id': 'supplier-item',
                'supplier_name': 'Supplier',
                'order_unit': 'box',
                'order_unit_quantity_base': 1000,
                'unit_price': 100,
              },
            ],
          },
        ],
      };
    }
    writes.add(name);
    return {};
  }
}

class _Lifecycle extends StoreLifecycleService {
  final writes = <String>[];
  @override
  Future<Map<String, dynamic>> load(String store) async => {
    'lifecycle': {'state': 'closed', 'revision': 2},
    'checks': {},
    'employees': [],
    'closure': {},
  };
  @override
  Future<Map<String, dynamic>> transferOptions(String store) async => {
    'targets': [
      {
        'brand_id': 'brand',
        'brand_name': 'Brand',
        'entity_id': 'entity',
        'entity_name': 'Entity',
      },
    ],
  };
  @override
  Future<void> write(String name, Map<String, dynamic> p) async {
    writes.add(name);
  }
}

class _Sales extends SalesReportingBatchService {
  final writes = <String>[];
  @override
  Future<List<Map<String, dynamic>>> list(
    String date,
    String entity, {
    String? before,
    String? beforeId,
  }) async => [
    {
      'id': 'batch',
      'created_at': '2026-10-22T00:00:00Z',
      'status': 'generated',
      'receipt_count': 1,
      'gross': 100,
      'file_sha256': 'fixed-hash',
    },
  ];
  @override
  Future<Map<String, dynamic>> update(
    String id,
    String action,
    Map<String, dynamic> p,
  ) async {
    writes.add(action);
    return {};
  }
}

Future<void> _cancel(WidgetTester tester) async {
  await tester.tap(
    find.textContaining(RegExp(r'^cancel$', caseSensitive: false)).last,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'approved quality editor closes without publishing invented criteria',
    (tester) async {
      var saved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => editQualityProfile(
                  context,
                  storeId: 'store',
                  product: {'id': 'product', 'name': 'Material'},
                  save: (n, p) async {
                    saved = true;
                  },
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await _cancel(tester);
      expect(saved, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('operational acceptance cancels without inventing opening cash', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showStoreOperationalAcceptance(
                  context,
                  inputs: {
                    'menus_without_recipe': [],
                    'office_required': false,
                  },
                  employees: [
                    {'id': 'e', 'name': 'Employee'},
                  ],
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await _cancel(tester);
    expect(saved, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'purchase terms review and reference search both cancel without approval',
    (tester) async {
      final service = _Setup();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StoreProcurementSetupCard(
                storeId: 'store',
                service: service,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Check procurement readiness'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Approve purchase terms'));
      await tester.tap(find.byTooltip('Approve purchase terms'));
      await tester.pumpAndSettle();
      expect(find.text('Approve item and purchase terms'), findsOneWidget);
      await _cancel(tester);
      await tester.ensureVisible(find.text('Choose approved policy'));
      await tester.tap(find.text('Choose approved policy'));
      await tester.pumpAndSettle();
      expect(find.text('Find approved policy'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(service.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('closed store transfer requires explicit reviewed destination', (
    tester,
  ) async {
    final service = _Lifecycle();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StoreLifecycleCard(storeId: 'store', service: service),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Transfer entity / brand'));
    await tester.tap(find.text('Transfer entity / brand'));
    await tester.pumpAndSettle();
    expect(find.text('Transfer legal entity / brand'), findsOneWidget);
    await _cancel(tester);
    expect(service.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('reporting batch owner confirmation closes without reporting', (
    tester,
  ) async {
    final service = _Sales();
    await tester.pumpWidget(
      MaterialApp(
        home: SalesReportingBatchesDialog(
          date: '2026-10-22',
          entity: 'entity',
          service: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Owner confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Owner sales confirmation'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Owner sales confirmation'), findsNothing);
    expect(service.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'lot location count disposition and reinspection dialogs preserve cancelled work',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final writes = <String>[];
      Future<dynamic> call(String name, Map<String, dynamic> p) async {
        if (name == 'admin_get_inventory_count_inputs_v1') {
          return {
            'items': [
              {
                'id': 'item',
                'name': 'Material',
                'product_id': 'product',
                'unit': 'g',
                'base_unit': 'g',
                'current_stock': 0,
                'tracked': false,
              },
            ],
          };
        }
        if (name == 'inventory_lot_workspace_v1') {
          return {
            'lots': p['p_ingredient'] != null
                ? []
                : [
                    {
                      'id': 'lot',
                      'ingredient_name': 'Held material',
                      'unit': 'g',
                      'state': 'held',
                      'quantity_base': 2,
                      'purchase_order_line_id': 'po-line',
                      'quality': {
                        'profile_id': 'quality',
                        'revision': 1,
                        'criteria': {
                          'temperature_required': false,
                          'expiry_required': false,
                          'photo_required': false,
                          'lot_required': true,
                          'min_sample_count': 1,
                        },
                      },
                    },
                  ],
            'employees': [
              {'id': 'e', 'name': 'Employee'},
            ],
            'locations': [
              {'id': 'loc', 'name': 'Shelf', 'kind': 'storage'},
            ],
            'can_dispose': true,
          };
        }
        writes.add(name);
        return {};
      }

      await tester.pumpWidget(
        MaterialApp(
          home: InventoryLotWorkspace(
            storeId: 'store',
            admin: true,
            call: call,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Add storage location'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(AlertDialog), findsOneWidget);
      await _cancel(tester);
      await tester.tap(find.text('Count'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Material · Opening / stock count'), findsOneWidget);
      await _cancel(tester);
      await tester.tap(find.text('Reinspect and release'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Review details'), findsOneWidget);
      await _cancel(tester);
      await tester.tap(find.text('Reinspect and release'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Employee').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Shelf').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      for (var i = 0; i < 3; i++) {
        await tester.enterText(
          find.byType(TextFormField).at(i),
          i == 0 ? '1' : 'Reviewed source evidence',
        );
      }
      await tester.tap(find.text('Review details'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Delivery inspection'), findsOneWidget);
      expect(find.text('Rejected quantity (base units)'), findsNothing);
      await _cancel(tester);
      expect(writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
