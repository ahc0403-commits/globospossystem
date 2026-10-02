import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/features/admin/providers/admin_scope_provider.dart';
import 'package:globos_pos_system/features/inventory/inventory_provider.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_purchase_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

const _store = 'store-a';
final _product = <String, dynamic>{
  'id': 'oil',
  'inventory_item_id': 'oil-item',
  'product_code': 'WR017',
  'name': 'Oil',
  'category': 'Sauce',
  'stock_unit': 'can',
  'base_unit': 'ml',
  'base_unit_factor': 25000,
  'shelf_life_days': 30,
  'is_active': true,
  'is_orderable': true,
  'inventory_item': {'current_stock': 24770, 'reorder_point': 5000},
};
const _supplier = <String, dynamic>{
  'id': 'supplier',
  'supplier_name': 'Supplier',
  'status': 'active',
};
Map<String, dynamic> get _link => {
  'id': 'link',
  'product_id': 'oil',
  'supplier_id': 'supplier',
  'is_active': true,
  'is_preferred': true,
  'supplier': _supplier,
  'product': _product,
};

class _Products extends InventoryPurchaseProductCatalogNotifier {
  _Products() {
    state = InventoryPurchaseProductCatalogState(products: [_product]);
  }
}

class _Suppliers extends InventoryPurchaseSupplierCatalogNotifier {
  _Suppliers() {
    state = InventoryPurchaseSupplierCatalogState(
      suppliers: [_supplier],
      supplierItems: [_link],
    );
  }
}

class _Stock extends InventoryPurchaseStockStatusNotifier {
  _Stock() {
    state = const InventoryPurchaseStockStatusState(
      rows: [
        {
          'product_id': 'oil',
          'product_name': 'Oil',
          'stock_unit': 'can',
          'base_unit': 'ml',
          'current_stock_base': 24770,
          'current_stock_display': 0.9908,
          'risk_status': 'stable',
        },
      ],
    );
  }
}

void main() {
  final writes = <Map<String, dynamic>>[];
  bool rejectSave = false;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://inventory.test',
      anonKey: 'test-key',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        dynamic result = <dynamic>[];
        if (path.endsWith('upsert_inventory_product_with_supplier_v2')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          writes.add(body);
          if (rejectSave) {
            return http.Response(
              jsonEncode({'code': 'P0001', 'message': 'TEST_REJECT'}),
              400,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          _product['inventory_item'] = {
            'current_stock': 24770,
            'reorder_point': body['p_safety_stock_base'],
          };
          result = {'product': _product, 'supplier_item': _link};
        } else if (path.endsWith('inventory_products')) {
          result = [_product];
        } else if (path.endsWith('inventory_suppliers')) {
          result = [_supplier];
        } else if (path.endsWith('inventory_supplier_items')) {
          result = [_link];
        } else if (path.endsWith('can_read_inventory_purchase_store')) {
          result = true;
        } else if (path.endsWith('get_inventory_purchase_dashboard')) {
          result = {};
        }
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
    );
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
  });
  setUp(() {
    writes.clear();
    rejectSave = false;
    _product['inventory_item'] = {
      'current_stock': 24770,
      'reorder_point': 5000,
    };
  });
  Future<void> mount(
    WidgetTester tester, {
    int section = 5,
    Size size = const Size(1440, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminScopedStoreIdProvider.overrideWithValue(_store),
          inventoryPurchaseProductCatalogProvider.overrideWith(
            (ref) => _Products(),
          ),
          inventoryPurchaseSupplierCatalogProvider.overrideWith(
            (ref) => _Suppliers(),
          ),
          inventoryPurchaseStockStatusProvider.overrideWith((ref) => _Stock()),
          posLiveEventsProvider(
            _store,
          ).overrideWith((ref) => const Stream.empty()),
        ],
        child: MaterialApp(
          locale: const Locale('ko'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: InventoryPurchaseScreen(
              autoLoad: false,
              initialSectionIndex: section,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    final edit = find.byIcon(Icons.edit_outlined).first;
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inventory_product_dialog')), findsOneWidget);
  }

  final field = find.byKey(const Key('inventory_product_safety_stock_field'));
  Future<void> save(WidgetTester tester, String value) async {
    await tester.ensureVisible(field);
    await tester.enterText(field, value);
    final button = find.byKey(const Key('inventory_product_save_action'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'existing 25L can threshold edits in L and persists base quantity',
    (tester) async {
      await mount(tester);
      await open(tester);
      expect(tester.widget<TextField>(field).controller!.text, '5');
      expect(tester.widget<TextField>(field).decoration!.suffixText, 'L');
      await save(tester, '1,25');
      expect(writes.single['p_store_id'], _store);
      expect(writes.single['p_product_id'], 'oil');
      expect(writes.single['p_safety_stock_base'], 1250);
      expect(writes.single['p_base_unit_factor'], 25000);
      expect(find.byKey(const Key('inventory_product_dialog')), findsNothing);
      await open(tester);
      expect(tester.widget<TextField>(field).controller!.text, '1.25');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('blank clears threshold, configured zero remains zero', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    await save(tester, '');
    expect(writes.single.containsKey('p_safety_stock_base'), isTrue);
    expect(writes.single['p_safety_stock_base'], isNull);
    await open(tester);
    expect(tester.widget<TextField>(field).controller!.text, '');
    await save(tester, '0');
    expect(writes.last['p_safety_stock_base'], 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('invalid and failed saves retain the dialog for correction', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    await save(tester, '-1');
    expect(writes, isEmpty);
    expect(find.text('0 이상의 유효한 수량을 입력하세요.'), findsOneWidget);
    rejectSave = true;
    await save(tester, '5');
    expect(writes, hasLength(1));
    expect(find.byKey(const Key('inventory_product_dialog')), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, '5');
    expect(find.text('원재료와 안전재고를 저장하지 못했습니다. 다시 시도하세요.'), findsOneWidget);
    rejectSave = false;
    await save(tester, '5');
    expect(find.byKey(const Key('inventory_product_dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'stock view shows physical threshold, status, and unset separately',
    (tester) async {
      _product['inventory_item'] = {
        'current_stock': 24770,
        'reorder_point': 25000,
      };
      await mount(tester, section: 1);
      expect(find.text('25 L'), findsOneWidget);
      expect(find.text('24.77 L'), findsOneWidget);
      expect(find.text('안전재고 이하'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unset stock threshold is visibly distinct from configured zero',
    (tester) async {
      _product['inventory_item'] = {
        'current_stock': 24770,
        'reorder_point': null,
      };
      await mount(tester, section: 1);
      expect(find.text('미설정'), findsNWidgets(2));
      expect(find.text('0 L'), findsNothing);
      expect(find.text('안전재고 이하'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('phone edit dialog keeps the safety stock input reachable', (
    tester,
  ) async {
    await mount(tester, size: const Size(390, 844));
    await open(tester);
    await tester.ensureVisible(field);
    expect(tester.widget<TextField>(field).decoration!.suffixText, 'L');
    expect(tester.takeException(), isNull);
  });
}
