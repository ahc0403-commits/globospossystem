import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_order_workflow_screen.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_workflow_state.dart';

const _supplier = <String, dynamic>{
  'id': 'supplier-1',
  'supplier_name': '우리푸드',
  'status': 'active',
};

const _supplierItem = <String, dynamic>{
  'id': 'supplier-item-1',
  'supplier_id': 'supplier-1',
  'order_unit': 'box',
  'min_order_quantity': 2,
  'unit_price': 250000,
  'is_active': true,
  'supplier': _supplier,
  'product': <String, dynamic>{
    'id': 'product-1',
    'name': 'Thịt bò',
    'is_active': true,
    'is_orderable': true,
  },
};

const _fractionalSupplierItem = <String, dynamic>{
  'id': 'supplier-item-kg',
  'supplier_id': 'supplier-1',
  'order_unit': 'KG',
  'min_order_quantity': 1,
  'allows_fractional_quantity': true,
  'usual_order_quantity_unit': 2,
  'usual_order_sample_count': 5,
  'unit_price': 30000,
  'is_active': true,
  'supplier': _supplier,
  'product': <String, dynamic>{
    'id': 'product-kg',
    'name': 'Lettuce',
    'is_active': true,
    'is_orderable': true,
  },
};

void main() {
  test('order quantity parser preserves supported decimal precision', () {
    for (final value in ['0.001', '0.2', '0.5', '0.75', '1.25']) {
      expect(parseInventoryOrderQuantity(value), double.parse(value));
    }
    for (final value in ['', '0', '-1', '0,5', '0.0001', 'NaN']) {
      expect(parseInventoryOrderQuantity(value), isNull, reason: value);
    }
  });

  testWidgets(
    'loads supplier items, adds a line, and validates the minimum quantity',
    (tester) async {
      var requestedSupplierId = '';
      await _openDialog(
        tester,
        locale: const Locale('vi'),
        loader: (supplierId) async {
          requestedSupplierId = supplierId;
          return [_supplierItem];
        },
      );

      await _selectSupplier(tester);
      expect(requestedSupplierId, 'supplier-1');
      expect(find.text('Chọn nguyên liệu rồi nhấn Thêm.'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('inventory_draft_supplier_item_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Thịt bò').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('inventory_draft_add_ingredient')));
      await tester.pumpAndSettle();

      expect(
        find.text('Đã thêm tất cả nguyên liệu có thể chọn.'),
        findsOneWidget,
      );
      var saveButton = tester.widget<FilledButton>(
        find.byKey(const Key('inventory_draft_save')),
      );
      expect(saveButton.onPressed, isNotNull);

      await tester.enterText(
        find.byKey(const ValueKey('draft_qty_supplier-item-1')),
        '1',
      );
      await tester.pump();
      expect(find.text('Số lượng tối thiểu là 2.'), findsOneWidget);
      saveButton = tester.widget<FilledButton>(
        find.byKey(const Key('inventory_draft_save')),
      );
      expect(saveButton.onPressed, isNull);
    },
  );

  testWidgets(
    'orderer can select sanitized items without seeing or editing a master price',
    (tester) async {
      final sanitized = Map<String, dynamic>.from(_supplierItem)
        ..remove('unit_price');
      await _openDialog(
        tester,
        locale: const Locale('en'),
        canEditPrice: false,
        loader: (_) async => [sanitized],
      );
      await _selectSupplier(tester);
      await tester.tap(
        find.byKey(const Key('inventory_draft_supplier_item_dropdown')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('VND'), findsNothing);
      await tester.tap(find.textContaining('Thịt bò').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('inventory_draft_add_ingredient')));
      await tester.pumpAndSettle();
      final price = tester.widget<TextFormField>(
        find.byKey(const ValueKey('draft_price_supplier-item-1')),
      );
      expect(price.initialValue, isEmpty);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('draft_price_supplier-item-1')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.readOnly, isTrue);
      expect(find.text('Set on save'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('inventory_draft_save')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('KG quantity accepts 0.5 and shows the six-times warning', (
    tester,
  ) async {
    await _openDialog(tester, loader: (_) async => [_fractionalSupplierItem]);
    await _selectSupplier(tester);
    await tester.tap(
      find.byKey(const Key('inventory_draft_supplier_item_dropdown')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Lettuce').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inventory_draft_add_ingredient')));
    await tester.pumpAndSettle();

    final quantity = find.byKey(const ValueKey('draft_qty_supplier-item-kg'));
    await tester.enterText(quantity, '0.5');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('inventory_draft_save')))
          .onPressed,
      isNotNull,
    );

    await tester.enterText(quantity, '12');
    await tester.pump();
    expect(find.textContaining('6배'), findsOneWidget);

    await tester.enterText(quantity, '0,5');
    await tester.pump();
    expect(find.textContaining('소수점 세 자리'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('inventory_draft_save')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('distinguishes access failure and retries without closing', (
    tester,
  ) async {
    var attempts = 0;
    await _openDialog(
      tester,
      loader: (_) async {
        attempts += 1;
        if (attempts == 1) {
          throw StateError('INVENTORY_PURCHASE_CATALOG_FORBIDDEN');
        }
        return const [];
      },
    );

    await _selectSupplier(tester);
    expect(find.text('이 계정의 발주 품목 조회 권한을 확인해 주세요.'), findsOneWidget);
    expect(
      find.byKey(const Key('inventory_draft_catalog_retry')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('inventory_draft_catalog_retry')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('이 매장·거래처에 등록된 발주 가능 원재료가 없습니다.'), findsOneWidget);
  });
}

Future<void> _openDialog(
  WidgetTester tester, {
  required InventoryPurchaseSupplierItemLoader loader,
  Locale locale = const Locale('ko'),
  bool canEditPrice = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1100, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('ko'), Locale('en'), Locale('vi')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => InventoryPurchaseDraftOrderDialog(
                  suppliers: const [_supplier],
                  supplierItems: const [],
                  loadSupplierItems: loader,
                  canEditPrice: canEditPrice,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _selectSupplier(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('inventory_draft_supplier_dropdown')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('우리푸드').last);
  await tester.pumpAndSettle();
}
