import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/models/pos_table.dart';
import 'package:globos_pos_system/features/cashier/cashier_item_edit_dialogs.dart';
import 'package:globos_pos_system/features/order/order_model.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['CASHIER_ITEM_EDIT_SCREENSHOTS'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('cashier-item-edit-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (Platform.environment['CASHIER_ITEM_EDIT_SCREENSHOTS'] == null) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    final font = FontLoader('Pretendard')
      ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([font.load(), icons.load()]);
  });
  const item = OrderItem(
    id: 'menu',
    menuItemId: 'menu-id',
    label: 'Sprite',
    unitPrice: 18000,
    quantity: 3,
    status: 'served',
    itemType: 'menu_item',
  );
  Widget app(Widget body) => RepaintBoundary(
    key: const Key('cashier-item-edit-capture'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      locale: const Locale('ko'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: body),
    ),
  );
  testWidgets(
    'a served menu can cancel one of three without canceling the entire line',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      int? result;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showCashierCancelQuantity(context, item);
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('3 → 2'), findsOneWidget);
      await _capture(tester, 'cashier-partial-cancel');
      await tester.tap(
        find.byKey(const Key('cashier_cancel_quantity_confirm')),
      );
      await tester.pumpAndSettle();
      expect(result, 1);
    },
  );
  testWidgets(
    'item movement offers occupied destinations and preserves selected quantities',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      CashierMoveSelection? result;
      const tables = [
        PosTable(
          id: 'source',
          storeId: 'store',
          tableNumber: '1103',
          seatCount: 4,
          status: 'occupied',
        ),
        PosTable(
          id: 'destination',
          storeId: 'store',
          tableNumber: '1104',
          seatCount: 4,
          status: 'occupied',
          floorLabel: '2F',
        ),
      ];
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showCashierMoveItems(
                  context,
                  items: [item],
                  tables: tables,
                  currentTableId: 'source',
                  initialItem: item,
                );
              },
              child: const Text('Move'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Move'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cashier_move_target_table')));
      await tester.pumpAndSettle();
      expect(find.textContaining('1103'), findsNothing);
      await tester.tap(find.text('2F · 1104').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pumpAndSettle();
      await _capture(tester, 'cashier-move-occupied-table');
      await tester.tap(find.byKey(const Key('cashier_move_confirm')));
      await tester.pumpAndSettle();
      expect(result!.tableId, 'destination');
      expect(result!.items.single, {
        'item_id': 'menu',
        'quantity': 2,
        'expected_quantity': 3,
      });
    },
  );
}
