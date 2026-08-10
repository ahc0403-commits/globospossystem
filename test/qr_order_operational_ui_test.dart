import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/qr_order/qr_order_screen.dart';

class _FakeQrOrderService extends QrOrderService {
  _FakeQrOrderService({
    required this.fetch,
    required this.fetchActive,
    required this.place,
  });

  final Future<QrOrderMenu> Function(String token) fetch;
  final Future<QrActiveOrder> Function(String token) fetchActive;
  final Future<QrOrderResult> Function(
    String token,
    List<QrOrderLine> items,
    String clientOrderId,
  )
  place;

  @override
  Future<QrOrderMenu> fetchMenu(String token) => fetch(token);

  @override
  Future<QrActiveOrder> fetchActiveOrder(String token) => fetchActive(token);

  @override
  Future<QrOrderResult> placeOrder({
    required String token,
    required List<QrOrderLine> items,
    required String clientOrderId,
  }) => place(token, items, clientOrderId);
}

const _menu = QrOrderMenu(
  storeName: 'GLOBOS Nguyễn Huệ Central Restaurant',
  tableNumber: 'A-108',
  floorLabel: 'Tầng thượng / Rooftop',
  categories: [
    QrMenuCategory(id: 'main', name: 'Món chính · Main dishes'),
    QrMenuCategory(id: 'drink', name: 'Đồ uống · Drinks'),
  ],
  items: [
    QrMenuItem(
      id: 'food',
      categoryId: 'main',
      name:
          'Bún bò Huế đặc biệt với tên món rất dài để kiểm tra khả năng xuống dòng',
      description:
          'Nước dùng thơm, rau tươi và phần mô tả dài có đầy đủ dấu tiếng Việt.',
      price: 125000,
    ),
    QrMenuItem(
      id: 'drink',
      categoryId: 'drink',
      name: 'Cà phê sữa đá',
      price: 45000,
    ),
  ],
);

const _result = QrOrderResult(
  orderCode: 'QR-2026-001',
  batchNo: 2,
  tableNumber: 'A-108',
  floorLabel: 'Tầng thượng / Rooftop',
  items: [
    QrOrderResultItem(
      name:
          'Bún bò Huế đặc biệt với tên món rất dài để kiểm tra khả năng xuống dòng',
      quantity: 1,
    ),
  ],
);

const _noActiveOrder = QrActiveOrder(
  isActive: false,
  orderCode: '',
  status: '',
  items: [],
);

_FakeQrOrderService _service({
  Future<QrOrderMenu> Function(String token)? fetch,
  Future<QrActiveOrder> Function(String token)? fetchActive,
  Future<QrOrderResult> Function(
    String token,
    List<QrOrderLine> items,
    String clientOrderId,
  )?
  place,
}) {
  return _FakeQrOrderService(
    fetch: fetch ?? (_) async => _menu,
    fetchActive: fetchActive ?? (_) async => _noActiveOrder,
    place: place ?? (_, __, ___) async => _result,
  );
}

Future<void> _pumpQr(
  WidgetTester tester, {
  required _FakeQrOrderService service,
  Size size = const Size(390, 844),
  Locale locale = const Locale('en'),
  double textScale = 1,
  bool settle = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      locale: locale,
      supportedLocales: const [Locale('ko'), Locale('en'), Locale('vi')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: QrOrderScreen(key: UniqueKey(), token: 'token', service: service),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

void _expectNoLayoutFailure(WidgetTester tester) {
  expect(tester.takeException(), isNull);
  expect(find.textContaining('RIGHT OVERFLOWED'), findsNothing);
  expect(find.textContaining('BOTTOM OVERFLOWED'), findsNothing);
}

void main() {
  testWidgets(
    'promotion slot always shows VAT and uses welcome copy when idle',
    (tester) async {
      await _pumpQr(tester, service: _service());

      expect(find.byKey(const Key('qr_welcome_message')), findsOneWidget);
      expect(
        find.text('Món ăn được chuẩn bị tận tâm. Chúc quý khách ngon miệng.'),
        findsOneWidget,
      );
      expect(find.text('Chưa bao gồm 8% VAT.'), findsOneWidget);

      const promotedMenu = QrOrderMenu(
        storeName: 'BunsikClub',
        tableNumber: '8',
        floorLabel: '1F',
        promotionName: 'Grand opening',
        promotionDiscountPercent: 30,
        categories: [],
        items: [],
      );
      await _pumpQr(
        tester,
        service: _service(fetch: (_) async => promotedMenu),
      );

      expect(find.byKey(const Key('qr_active_promotion')), findsOneWidget);
      expect(find.textContaining('30%'), findsOneWidget);
      expect(find.text('Chưa bao gồm 8% VAT.'), findsOneWidget);
      expect(find.byKey(const Key('qr_welcome_message')), findsNothing);
      _expectNoLayoutFailure(tester);
    },
  );

  testWidgets(
    'active table order is visible and follows the selected language',
    (tester) async {
      const activeOrder = QrActiveOrder(
        isActive: true,
        orderCode: 'abcd1234',
        status: 'confirmed',
        items: [
          QrActiveOrderItem(
            name: '떡볶이',
            nameKo: '떡볶이',
            nameVi: 'Bánh gạo cay',
            nameEn: 'Spicy rice cakes',
            quantity: 2,
            status: 'preparing',
          ),
        ],
      );
      await _pumpQr(
        tester,
        service: _service(fetchActive: (_) async => activeOrder),
      );
      expect(find.byKey(const Key('qr_active_order_summary')), findsOneWidget);
      expect(find.text('Các món đã gọi'), findsOneWidget);
      expect(find.text('Bánh gạo cay'), findsOneWidget);
      expect(find.text('Đang chuẩn bị'), findsOneWidget);
      expect(find.text('Chọn món gọi thêm'), findsOneWidget);

      await tester.tap(find.byKey(const Key('qr_language_selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('한국어').last);
      await tester.pumpAndSettle();

      expect(find.text('현재 주문 내역'), findsOneWidget);
      expect(find.text('떡볶이'), findsOneWidget);
      expect(find.text('준비 중'), findsOneWidget);
      expect(find.text('추가 주문 메뉴'), findsOneWidget);
      _expectNoLayoutFailure(tester);
    },
  );

  testWidgets('combo addition requires the exact configured drink count', (
    tester,
  ) async {
    const comboMenu = QrOrderMenu(
      storeName: 'BunsikClub',
      tableNumber: '8',
      floorLabel: '1F',
      categories: [QrMenuCategory(id: 'combo-category', name: 'Combo')],
      items: [
        QrMenuItem(
          id: 'combo',
          categoryId: 'combo-category',
          name: 'Combo 3 + 2 drinks',
          price: 300000,
          isCombo: true,
          comboDrinkChoiceCount: 2,
          comboDrinkOptions: [
            QrComboDrinkOption(id: 'cola', name: 'Cola'),
            QrComboDrinkOption(id: 'water', name: 'Water'),
          ],
        ),
      ],
    );
    List<QrOrderLine>? submitted;
    await _pumpQr(
      tester,
      service: _service(
        fetch: (_) async => comboMenu,
        place: (_, items, __) async {
          submitted = items;
          return _result;
        },
      ),
    );

    expect(find.text('G · Bàn 8'), findsOneWidget);

    await tester.tap(find.byKey(const Key('qr_add_combo')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('qr_combo_drink_dialog_combo')),
      findsOneWidget,
    );
    final confirm = find.byKey(const Key('qr_combo_drink_confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(const Key('qr_combo_drink_plus_cola')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('qr_combo_drink_plus_water')));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('qr_open_review')));
    await tester.pumpAndSettle();
    expect(find.text('Cola, Water'), findsOneWidget);
    await tester.tap(find.byKey(const Key('qr_confirm_submit')));
    await tester.pumpAndSettle();

    expect(submitted, hasLength(1));
    expect(submitted!.single.comboDrinkChoices, ['cola', 'water']);
    _expectNoLayoutFailure(tester);
  });

  testWidgets('loading, empty, and customer-safe load failures are explicit', (
    tester,
  ) async {
    final pendingMenu = Completer<QrOrderMenu>();
    await _pumpQr(
      tester,
      service: _service(fetch: (_) => pendingMenu.future),
      settle: false,
    );
    expect(find.byKey(const Key('qr_state_loading')), findsOneWidget);

    pendingMenu.complete(
      const QrOrderMenu(
        storeName: 'GLOBOS',
        tableNumber: '1',
        floorLabel: 'Floor 1',
        categories: [],
        items: [],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('qr_state_empty')), findsOneWidget);

    const cases = <String, String>{
      'QR_TOKEN_INVALID': 'qr_state_invalid_expired_unavailable',
      'SocketException: offline': 'qr_state_offline_retry',
      'service unavailable': 'qr_state_unavailable',
    };
    for (final entry in cases.entries) {
      await _pumpQr(
        tester,
        service: _service(fetch: (_) => Future.error(entry.key)),
      );
      expect(find.byKey(Key(entry.value)), findsOneWidget);
      expect(find.byKey(const Key('qr_retry')), findsOneWidget);
      _expectNoLayoutFailure(tester);
    }
  });

  testWidgets(
    'menu, review, processing, and success preserve order hierarchy',
    (tester) async {
      final pendingOrder = Completer<QrOrderResult>();
      await _pumpQr(
        tester,
        service: _service(place: (_, __, ___) => pendingOrder.future),
      );

      final add = find.byKey(const Key('qr_add_food'));
      final openReview = find.byKey(const Key('qr_open_review'));
      expect(add, findsOneWidget);
      expect(tester.getSize(add).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(add).height, greaterThanOrEqualTo(48));

      final focusTraversal = tester.widget<FocusTraversalGroup>(
        find.byKey(const Key('qr_focus_traversal')),
      );
      expect(focusTraversal.policy, isA<ReadingOrderTraversalPolicy>());

      final selectedCategory = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(const Key('qr_category_main')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(selectedCategory.properties.selected, isTrue);

      final disabledReview = tester.widget<FilledButton>(openReview);
      expect(disabledReview.onPressed, isNull);
      await tester.tap(add);
      await tester.pump();
      expect(tester.widget<FilledButton>(openReview).onPressed, isNotNull);

      await tester.tap(openReview);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qr_confirm_dialog')), findsOneWidget);
      expect(find.byKey(const Key('qr_review_items')), findsOneWidget);
      expect(find.textContaining('Bún bò Huế'), findsWidgets);

      await tester.tap(find.byKey(const Key('qr_confirm_submit')));
      await tester.pump();
      expect(find.text('Đang gửi món'), findsOneWidget);
      expect(tester.widget<FilledButton>(openReview).onPressed, isNull);

      pendingOrder.complete(_result);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qr_state_success')), findsOneWidget);
      expect(find.textContaining('QR-2026-001'), findsOneWidget);
      expect(find.byKey(const Key('qr_add_more')), findsOneWidget);
      _expectNoLayoutFailure(tester);
    },
  );

  testWidgets('rate-limit and offline retry reuse the same client order id', (
    tester,
  ) async {
    final clientOrderIds = <String>[];
    var attempt = 0;
    await _pumpQr(
      tester,
      service: _service(
        place: (_, __, clientOrderId) async {
          clientOrderIds.add(clientOrderId);
          attempt += 1;
          if (attempt == 1) throw Exception('QR_TOO_FREQUENT');
          return _result;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('qr_add_food')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('qr_open_review')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qr_confirm_submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('qr_state_rate_limit')), findsOneWidget);

    final retry = find.byKey(const Key('qr_submit_retry'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qr_confirm_submit')));
    await tester.pumpAndSettle();

    expect(clientOrderIds, hasLength(2));
    expect(clientOrderIds[1], clientOrderIds[0]);
    expect(find.byKey(const Key('qr_state_success')), findsOneWidget);
  });

  testWidgets('submit errors expose every guarded customer state', (
    tester,
  ) async {
    const cases = <String, String>{
      'QR_ORDER_PAYMENT_IN_PROGRESS': 'qr_state_payment_processing',
      'QR_TOO_FREQUENT': 'qr_state_rate_limit',
      'QR_MENU_ITEM_UNAVAILABLE': 'qr_state_item_unavailable',
      'QR_ITEMS_INVALID': 'qr_state_invalid_items',
      'network timeout': 'qr_state_offline_retry',
      'unexpected server issue': 'qr_state_unavailable',
    };
    for (final entry in cases.entries) {
      await _pumpQr(
        tester,
        service: _service(place: (_, __, ___) => Future.error(entry.key)),
      );
      await tester.tap(find.byKey(const Key('qr_add_food')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('qr_open_review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('qr_confirm_submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key(entry.value)), findsOneWidget);
      _expectNoLayoutFailure(tester);
    }
  });

  testWidgets('target viewports and KO EN VI remain safe at 200 percent text', (
    tester,
  ) async {
    const fixtures = [
      (Size(390, 844), Locale('ko')),
      (Size(1024, 768), Locale('en')),
      (Size(1440, 900), Locale('vi')),
    ];
    for (final fixture in fixtures) {
      await _pumpQr(
        tester,
        service: _service(),
        size: fixture.$1,
        locale: fixture.$2,
        textScale: 2,
      );
      expect(find.byKey(const Key('qr_order_screen')), findsOneWidget);
      expect(find.byKey(const Key('qr_open_review')), findsOneWidget);
      _expectNoLayoutFailure(tester);
    }
  });
}
