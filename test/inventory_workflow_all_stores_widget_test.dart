import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:globos_pos_system/core/services/inventory_service.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/core/utils/permission_utils.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_order_workflow_screen.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_workflow_state.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Auth extends AuthNotifier {
  _Auth(String role) : super() {
    state = PosAuthState(
      role: role,
      storeId: 'operating-store',
      user: User(
        id: 'actor',
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: '',
      ),
    );
  }
}

class _Inventory extends InventoryService {
  int detailLoads = 0;
  int listLoads = 0;
  bool failNext = false;
  final submissions = <Map<String, dynamic>>[];
  final orderSubmissions = <Map<String, dynamic>>[];
  Map<String, dynamic> quantityWarnings = {
    'warning_token': null,
    'warnings': <Map<String, dynamic>>[],
  };
  final order = <String, dynamic>{
    'id': 'order-1',
    'purchase_order_no': 'PO-OPERATING',
    'restaurant_id': 'operating-store',
    'supplier_id': 'supplier',
    'supplier': {'supplier_name': 'Supplier'},
    'store': {'name': 'Operating store'},
    'status': 'ordered',
    'row_version': 3,
    'total_amount': 2000,
    'document_status': 'none',
  };
  late final lines = List.generate(
    20,
    (i) => <String, dynamic>{
      'id': 'line-$i',
      'product': {'name': 'Ingredient $i'},
      'ordered_quantity_unit': 2,
      'ordered_quantity_base': 20,
      'order_unit': 'box',
      'unit_price': 100,
      'supplier_item': {'order_unit_quantity_base': 10},
    },
  );
  late final receipt = <String, dynamic>{
    'id': 'receipt',
    'restaurant_id': 'operating-store',
    'status': 'draft',
    'row_version': 1,
    'received_by': 'maker',
    'statement_storage_path': 'operating-store/receipt/file.pdf',
    'line_details': [
      for (final line in lines)
        {
          'purchase_order_line_id': line['id'],
          'received_quantity_base': 0,
          'accepted_quantity_base': 0,
          'actual_unit_price': 100,
        },
    ],
  };
  @override
  Future<Map<String, dynamic>> fetchInventoryWorkflowPage({
    String? storeId,
    List<String>? statuses,
    bool mineOnly = false,
    int offset = 0,
    int limit = 80,
  }) async {
    listLoads++;
    return {
      'orders': statuses?.contains(order['status']) == true ? [order] : [],
      'total': statuses?.contains(order['status']) == true ? 1 : 0,
      'counts': {'ordered': 301, 'submitted': 7},
      'stores': [
        {'id': 'operating-store', 'name': 'Operating store'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> fetchInventoryOrderCatalog(
    String storeId,
  ) async => {'items': [], 'suppliers': []};
  @override
  Future<Map<String, dynamic>> fetchInventoryWorkflowDetail(
    String orderId,
  ) async {
    detailLoads++;
    return {
      'order': Map<String, dynamic>.from(order),
      'lines': lines,
      'receipts': [Map<String, dynamic>.from(receipt)],
      'documents': [],
      'approval_events': [],
    };
  }

  @override
  Future<Map<String, dynamic>> submitInventoryReceiptBatch(
    Map<String, dynamic> params,
  ) async {
    submissions.add(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(params)) as Map),
    );
    if (failNext) {
      failNext = false;
      throw StateError('simulated network failure');
    }
    receipt['inspector_name'] = params['p_inspector_name'];
    receipt['row_version'] = 2;
    receipt['line_details'] = params['p_lines'];
    return {'receipt_id': 'receipt', 'row_version': 2};
  }

  @override
  Future<Map<String, dynamic>> fetchInventoryPurchaseQuantityWarnings({
    required String purchaseOrderId,
    required int expectedVersion,
  }) async => Map<String, dynamic>.from(quantityWarnings);

  @override
  Future<Map<String, dynamic>> submitInventoryPurchaseOrder({
    required String purchaseOrderId,
    required int expectedVersion,
    String? warningToken,
  }) async {
    orderSubmissions.add({
      'purchase_order_id': purchaseOrderId,
      'expected_version': expectedVersion,
      'warning_token': warningToken,
    });
    order['status'] = 'submitted';
    order['row_version'] = expectedVersion + 1;
    return Map<String, dynamic>.from(order);
  }
}

Future<GoRouter> _mount(
  WidgetTester tester,
  _Inventory service,
  StreamController<PosLiveEvent> events, {
  String role = 'inventory_orderer',
}) async {
  tester.view.physicalSize = const Size(1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/inventory-orders',
    routes: [
      GoRoute(
        path: '/inventory-orders',
        builder: (_, _) => InventoryOrderWorkflowScreen(service: service),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _Auth(role)),
        posLiveEventsProvider(
          'operating-store',
        ).overrideWith((ref) => events.stream),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://inventory-fixture.supabase.co',
      anonKey: 'fixture',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());

  test(
    'all known states are discoverable and master permissions follow roles',
    () {
      final statuses = InventoryOrderGroup.values
          .expand((g) => g.statuses)
          .toList();
      expect(statuses.toSet(), {
        'draft',
        'submitted',
        'store_approved',
        'office_returned',
        'ordered',
        'partially_received',
        'received',
        'office_approved',
        'cancelled',
        'office_rejected',
        'brand_approved',
      });
      expect(statuses.length, statuses.toSet().length);
      expect(
        InventoryOrderGroup.placed.count({'ordered': 301, 'received': 50}),
        351,
      );
      expect(
        PermissionUtils.canManageInventorySupplierPrices('inventory_orderer'),
        isFalse,
      );
      expect(
        PermissionUtils.canManageInventorySupplierPrices('brand_admin'),
        isTrue,
      );
      expect(
        PermissionUtils.canCreateInventoryPurchaseOrder('inventory_orderer'),
        isTrue,
      );
      expect(
        PermissionUtils.canCreateInventoryPurchaseOrder('photo_objet_master'),
        isFalse,
      );
      for (final invalid in ['', ' ', 'abc', '-1', 'NaN', 'Infinity']) {
        expect(parseInventoryQuantity(invalid), isNull, reason: invalid);
      }
      expect(parseInventoryQuantity('0'), 0);
      expect(parseInventoryQuantity('1,234.5'), 1234.5);
    },
  );

  testWidgets(
    '20 inputs and live changes preserve the form; confirmation batches once and retries the same request',
    (tester) async {
      final service = _Inventory();
      final events = StreamController<PosLiveEvent>.broadcast();
      final router = await _mount(tester, service, events);
      expect(find.text('Supplier prices'), findsNothing);
      expect(find.text('Placed (301)'), findsOneWidget);
      await tester.tap(find.text('Receiving'));
      await tester.pumpAndSettle();
      final baseline = service.detailLoads;
      for (var i = 0; i < 20; i++) {
        final field = find.byKey(
          ValueKey('inventory_receipt_quantity_line-$i'),
        );
        await tester.ensureVisible(field);
        await tester.enterText(field, '${i + 1}');
        await tester.pump(const Duration(milliseconds: 800));
      }
      expect(service.submissions, isEmpty);
      expect(service.detailLoads, baseline);
      final loads = service.listLoads;
      events.add(
        const PosLiveEvent(
          domain: 'inventory',
          sourceTable: 'inventory_purchase_orders',
          eventType: 'INSERT',
        ),
      );
      await tester.pumpAndSettle();
      expect(service.listLoads, greaterThan(loads));
      expect(service.detailLoads, baseline);
      for (var i = 0; i < 20; i++) {
        expect(
          tester
              .widget<TextField>(
                find.byKey(ValueKey('inventory_receipt_quantity_line-$i')),
              )
              .controller!
              .text,
          '${i + 1}',
        );
      }
      service.failNext = true;
      final submit = find.byKey(const Key('inventory_receipt_submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('inventory_statement_confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('inventory_receipt_inspector')),
        'Inspector A',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('inventory_receipt_inspection_note')),
        'Actual delivery differs from order',
      );
      await tester.pump();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(service.submissions, hasLength(1));
      expect(service.submissions.single['p_lines'], hasLength(20));
      expect(
        (service.submissions.single['p_lines'] as List)
            .first['discrepancy_reason'],
        'Actual delivery differs from order',
      );
      expect(
        (service.submissions.single['p_lines']
            as List)[1]['discrepancy_reason'],
        isNull,
      );
      expect(service.submissions.single['p_statement_number'], isNull);
      expect(service.submissions.single['p_statement_date'], isNull);
      expect(service.detailLoads, baseline);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('inventory_receipt_quantity_line-19')),
            )
            .controller!
            .text,
        '20',
      );
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(service.submissions, hasLength(2));
      expect(service.submissions.first, service.submissions.last);
      expect(service.submissions.first['p_expected_order_version'], 3);
      expect(
        (service.submissions.first['p_lines'] as List)
            .last['received_quantity_base'],
        200,
      );
      expect(service.detailLoads, baseline + 1);
      expect(find.text('You have unsaved changes.'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      await events.close();
    },
  );

  testWidgets(
    'six-times quantity requires explicit confirmation before submit',
    (tester) async {
      final service = _Inventory();
      service.order['status'] = 'draft';
      service.quantityWarnings = {
        'warning_token': 'warning-token-v1',
        'warnings': [
          {
            'product_name': 'Lettuce',
            'usual_quantity_unit': 2,
            'ordered_quantity_unit': 12,
            'order_unit': 'KG',
            'ratio': 6,
          },
        ],
      };
      final events = StreamController<PosLiveEvent>.broadcast();
      final router = await _mount(tester, service, events);

      await tester.tap(find.byKey(const Key('inventory_order_submit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('inventory_quantity_warning_dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('Lettuce'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('inventory_quantity_warning_edit')),
      );
      await tester.pumpAndSettle();
      expect(service.orderSubmissions, isEmpty);

      await tester.tap(find.byKey(const Key('inventory_order_submit')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('inventory_quantity_warning_continue')),
      );
      await tester.pumpAndSettle();
      expect(service.orderSubmissions, hasLength(1));
      expect(
        service.orderSubmissions.single['warning_token'],
        'warning-token-v1',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      await events.close();
    },
  );

  testWidgets('switching sections asks before discarding receiving edits', (
    tester,
  ) async {
    final service = _Inventory();
    final events = StreamController<PosLiveEvent>.broadcast();
    final router = await _mount(tester, service, events);
    await tester.tap(find.text('Receiving'));
    await tester.pumpAndSettle();
    final field = find.byKey(
      const ValueKey('inventory_receipt_quantity_line-0'),
    );
    await tester.ensureVisible(field);
    await tester.enterText(field, '7');
    await tester.tap(find.text('Orders & approvals'));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved receipt'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '7');
    expect(service.submissions, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await events.close();
  });
}
