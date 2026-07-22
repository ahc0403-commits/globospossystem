import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/qr_order/qr_order_screen.dart';

class _FakeQrOrderService extends QrOrderService {
  _FakeQrOrderService({required this.fetch, required this.place});

  final Future<QrOrderMenu> Function(String token) fetch;
  final Future<QrOrderResult> Function(
    String token,
    List<QrOrderLine> items,
    String clientOrderId,
  )
  place;

  @override
  Future<QrOrderMenu> fetchMenu(String token) => fetch(token);

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

_FakeQrOrderService _service({
  Future<QrOrderMenu> Function(String token)? fetch,
  Future<QrOrderResult> Function(
    String token,
    List<QrOrderLine> items,
    String clientOrderId,
  )?
  place,
}) {
  return _FakeQrOrderService(
    fetch: fetch ?? (_) async => _menu,
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
