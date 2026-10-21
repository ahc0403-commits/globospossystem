import 'package:globos_pos_system/features/emergency_fulfillment/kds_realtime_sync.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:globos_pos_system/features/procurement/inventory_lot_workspace.dart';
import 'package:globos_pos_system/features/procurement/procurement_order_review_dialog.dart';
import 'package:globos_pos_system/features/store_procurement/procurement_reference_picker.dart';

void main() {
  test(
    'shared receiver subscriptions retain every area and preserve legacy fallback',
    () {
      final shared = KdsSyncConfig.fromJson({
        'mode': 'active',
        'assigned': true,
        'restaurant_id': 'store-a',
        'station_type': 'floor',
        'floor_label': 'HALL',
        'service_area_codes': ['HALL', 'ROOM'],
      });
      final legacy = KdsSyncConfig.fromJson({
        'mode': 'active',
        'assigned': true,
        'restaurant_id': 'store-a',
        'station_type': 'floor',
        'floor_label': 'HALL',
      });
      expect(shared.servedAreas, ['HALL', 'ROOM']);
      expect(legacy.servedAreas, ['HALL']);
      expect(shared.hasSameSubscriptionAs(legacy), isFalse);
    },
  );

  testWidgets(
    'an unresolved lot request survives reopening and retries the exact command',
    (tester) async {
      final original = {
        'p_id': 'request-one',
        'p_store': 'store-a',
        'p_lot': 'lot-a',
        'p_action': 'waste',
        'p_quantity': 1,
        'p_payload': {'reason': 'Actual broken stock'},
      };
      SharedPreferences.setMockInitialValues({
        'lot-scope': jsonEncode({
          'method': 'inventory_dispose_lot_v1',
          'params': original,
        }),
      });
      final writes = <Map<String, dynamic>>[];
      Future<dynamic> call(String name, Map<String, dynamic> params) async {
        if (name == 'inventory_lot_workspace_v1') {
          return {
            'lots': [],
            'employees': [],
            'locations': [],
            'can_dispose': true,
          };
        }
        expect(name, 'inventory_dispose_lot_v1');
        writes.add(params);
        return {'ok': true};
      }

      await tester.pumpWidget(
        MaterialApp(
          home: InventoryLotWorkspace(
            storeId: 'store-a',
            persistenceKey: 'lot-scope',
            call: call,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await tester.tap(find.text('Retry the same request'));
      await tester.pumpAndSettle();
      expect(writes, [original]);
      expect(
        (await SharedPreferences.getInstance()).getString('lot-scope'),
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'accounting requires actual external amounts and carries the reviewed source hash',
    (tester) async {
      final writes = <Map<String, dynamic>>[];
      Future<dynamic> call(String name, Map<String, dynamic> params) async {
        if (name == 'get_procurement_reconciliation_source_v1') {
          return [
            {
              'identity': {
                'store_name': 'Single hall',
                'store_code': 'ST0001',
                'tax_entity_id': 'entity-a',
              },
              'source_hash': 'frozen-version',
              'expected_gross': 1200,
              'expected_credit': 200,
            },
          ];
        }
        expect(name, 'admin_record_procurement_reconciliation_v1');
        writes.add(params);
        return {'matched': true, 'settled': true};
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<dynamic>(
                  context: context,
                  builder: (_) => ProcurementOrderReviewDialog(
                    storeId: 'store-a',
                    orderId: 'po-a',
                    accounting: true,
                    call: call,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save evidence'));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      for (final entry in {
        'invoice_ids': 'invoice-1',
        'invoice_amount': '1200',
        'credit_amount': '200',
        'paid_amount': '1000',
        'office_reference': 'Office reviewed document 1',
      }.entries) {
        await tester.enterText(find.byKey(ValueKey(entry.key)), entry.value);
      }
      await tester.tap(find.text('Save evidence'));
      await tester.pumpAndSettle();
      expect(writes.single['p_source_hash'], 'frozen-version');
      expect((writes.single['p_payload'] as Map)['paid_amount'], 1000);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('reference picker uses a bounded cursor and explicit search', (
    tester,
  ) async {
    final calls = <(String?, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ProcurementReferencePicker(
          title: 'Specifications',
          load: (after, search) async {
            calls.add((after, search));
            return {
              'rows': [
                {
                  'id': after ?? 'first',
                  'code': after == null ? 'RAW-A' : 'RAW-B',
                  'name': 'Material',
                  'revision': 1,
                },
              ],
              'next_cursor': after == null ? 'next-id' : null,
            };
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, [(null, '')]);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(calls.last, ('next-id', ''));
    expect(find.text('RAW-B v1'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'rice');
    await tester.pumpAndSettle();
    expect(calls.length, 2);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    expect(calls.last, (null, 'rice'));
    expect(tester.takeException(), isNull);
  });
}
