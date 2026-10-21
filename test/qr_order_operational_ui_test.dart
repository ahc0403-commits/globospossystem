import 'fixtures/menu_choice_data.dart';
import 'package:globos_pos_system/core/menu/menu_choices.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/utils/time_utils.dart';
import 'package:globos_pos_system/features/qr_order/qr_order_screen.dart';

class _FakeQrOrderService extends QrOrderService {
  _FakeQrOrderService({
    required this.fetch,
    required this.fetchActive,
    required this.place,
    this.requestLeftover,
  });

  final Future<QrOrderMenu> Function(String token) fetch;
  final Future<QrActiveOrder> Function(String token) fetchActive;
  final Future<QrOrderResult> Function(
    String token,
    List<QrOrderLine> items,
    String clientOrderId,
    String? expectedOrderId,
  )
  place;
  final Future<Map<String, dynamic>> Function(String token, String requestId)?
  requestLeftover;

  @override
  Future<QrOrderMenu> fetchMenu(String token) => fetch(token);

  @override
  Future<QrActiveOrder> fetchActiveOrder(String token) => fetchActive(token);

  @override
  Future<QrOrderResult> placeOrder({
    required String token,
    required List<QrOrderLine> items,
    required String clientOrderId,
    String? expectedOrderId,
  }) => place(token, items, clientOrderId, expectedOrderId);

  @override
  Future<Map<String, dynamic>> requestLeftoverPackaging({
    required String token,
    required String requestId,
  }) =>
      requestLeftover?.call(token, requestId) ??
      Future.value(<String, dynamic>{'status': 'awaiting_floor_pickup'});
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
  orderId: 'order-a',
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
    String? expectedOrderId,
  )?
  place,
  Future<Map<String, dynamic>> Function(String token, String requestId)?
  requestLeftover,
}) {
  return _FakeQrOrderService(
    fetch: fetch ?? (_) async => _menu,
    fetchActive: fetchActive ?? (_) async => _noActiveOrder,
    place: place ?? (_, __, ___, ____) async => _result,
    requestLeftover: requestLeftover,
  );
}

Future<void> _pumpQr(
  WidgetTester tester, {
  required _FakeQrOrderService service,
  Size size = const Size(390, 844),
  Locale locale = const Locale('en'),
  double textScale = 1,
  bool settle = true,
  Duration menuSafetyRefreshInterval = const Duration(minutes: 5),
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
      home: QrOrderScreen(
        key: UniqueKey(),
        token: 'token',
        service: service,
        menuSafetyRefreshInterval: menuSafetyRefreshInterval,
        menuSafetyRefreshJitter: Duration.zero,
      ),
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
  testWidgets('QR sends real menu ID with distinct registered selections', (
    tester,
  ) async {
    List<QrOrderLine>? submitted;
    final key = catalogKey();
    final catalog = MenuChoiceCatalog.fromKey(key)!;
    final menu = QrOrderMenu(
      storeId: 'store',
      storeName: 'Choice store',
      tableNumber: '1',
      floorLabel: '1F',
      categories: const [QrMenuCategory(id: 'main', name: 'Main')],
      items: [
        QrMenuItem(
          id: 'choice',
          categoryId: 'main',
          name: 'Choice dish',
          price: 10000,
          menuOptionKey: key,
        ),
      ],
    );
    await _pumpQr(
      tester,
      service: _service(
        fetch: (_) async => menu,
        place: (_, items, _, _) async {
          submitted = items;
          return _result;
        },
      ),
    );
    for (final spice in ['Mild', 'Hot']) {
      final add = find.byKey(const Key('qr_add_choice'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      for (final label in [if (spice == 'Hot') 'Cay', 'Vừa']) {
        final row = find.widgetWithText(ListTile, label);
        await tester.ensureVisible(row);
        await tester.tap(
          find.descendant(of: row, matching: find.byType(Checkbox)),
        );
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('menu_choice_confirm')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('qr_open_review')));
    await tester.pumpAndSettle();
    final mild = catalog
        .select({'mild': 1, 'normal': 1}, 'qr')
        .lineId('choice');
    final hot = catalog.select({'hot': 1, 'normal': 1}, 'qr').lineId('choice');
    expect(find.byKey(Key('qr_cart_$mild|dine_in_quantity')), findsOneWidget);
    expect(find.byKey(Key('qr_cart_$hot|dine_in_quantity')), findsOneWidget);
    await tester.tap(find.byKey(const Key('qr_confirm_submit')));
    await tester.pumpAndSettle();
    expect(submitted!.length, 2);
    expect(submitted!.map((line) => line.menuItemId).toSet(), {'choice'});
    expect(submitted!.map((line) => line.menuOptionKey).toSet().length, 2);
    _expectNoLayoutFailure(tester);
  });

  QrOrderMenu sizesMenu({double largePrice = 370000, bool withMedia = false}) =>
      QrOrderMenu(
        storeName: 'JeonGabok',
        tableNumber: '1205',
        floorLabel: '1F',
        categories: const [QrMenuCategory(id: 'main', name: '요리')],
        items: [
          for (final size in ['S', 'L'])
            QrMenuItem(
              id: size == 'S' ? 'small' : 'large',
              categoryId: 'main',
              name: '$size · 탕수육',
              nameKo: '$size · 탕수육',
              nameVi: '$size · Thịt chua ngọt',
              nameEn: '$size · Sweet and sour pork',
              imageUrl: withMedia && size == 'S'
                  ? 'https://example.invalid/tangsuyuk.jpg'
                  : null,
              description: withMedia ? 'Registered dish description' : null,
              price: size == 'S' ? 190000 : largePrice,
              menuOptionKey: jsonEncode([
                size,
                'unknown',
                '',
                size == 'S' ? 190000 : largePrice,
                {
                  'menu_id': 'small',
                  'names': {
                    'name': '탕수육',
                    'name_ko': '탕수육',
                    'name_vi': 'Thịt chua ngọt',
                    'name_en': 'Sweet and sour pork',
                  },
                },
              ]),
            ),
        ],
      );

  for (final order in [
    const ['S', 'L'],
    const ['L', 'S'],
  ]) {
    testWidgets(
      'cart keeps both sizes in order $order and allows edits before sending',
      (tester) async {
        var reads = 0, submissions = 0;
        await _pumpQr(
          tester,
          service: _service(
            fetch: (_) async {
              reads++;
              return sizesMenu();
            },
            place: (_, _, _, _) async {
              submissions++;
              return _result;
            },
          ),
        );
        for (final size in order) {
          final add = find.byKey(const Key('qr_add_option_small'));
          await tester.ensureVisible(add);
          await tester.tap(add);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(Key('menu_size_$size')));
          await tester.pumpAndSettle();
        }
        final readCount = reads;
        await tester.tap(find.byKey(const Key('qr_open_review')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('qr_cart_small|dine_in_quantity')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('qr_cart_large|dine_in_quantity')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('qr_cart_small|dine_in_plus')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(
                find.byKey(const Key('qr_cart_small|dine_in_quantity')),
              )
              .data,
          '2',
        );
        await tester.tap(find.byKey(const Key('qr_cart_small|dine_in_minus')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('qr_cart_small|dine_in_details')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(
          find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(TextButton),
              )
              .last,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('qr_cart_small|dine_in_options')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('menu_size_L')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('qr_cart_small|dine_in_quantity')),
          findsNothing,
        );
        expect(
          tester
              .widget<Text>(
                find.byKey(const Key('qr_cart_large|dine_in_quantity')),
              )
              .data,
          '2',
        );
        await tester.ensureVisible(
          find.byKey(const Key('qr_cart_large|dine_in_remove')),
        );
        await tester.tap(find.byKey(const Key('qr_cart_large|dine_in_remove')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('qr_confirm_submit')))
              .onPressed,
          isNull,
        );
        expect(submissions, 0);
        expect(reads, readCount);
        _expectNoLayoutFailure(tester);
      },
    );
  }

  testWidgets(
    'noodles and rice require a choice and remain editable separate cart rows',
    (tester) async {
      final sent = <QrOrderLine>[];
      final menu = QrOrderMenu(
        storeName: 'JeonGabok',
        tableNumber: '1',
        floorLabel: '1F',
        categories: const [QrMenuCategory(id: 'main', name: 'Main')],
        items: [
          for (final meal in ['noodles', 'rice'])
            QrMenuItem(
              id: meal,
              categoryId: 'main',
              name: '$meal Jjamppong',
              nameEn: '$meal Jjamppong',
              price: 165000,
              menuOptionKey: jsonEncode([
                '',
                'unknown',
                '',
                165000,
                {
                  'menu_id': 'noodles',
                  'meal_choice': meal,
                  'names': {'name_en': 'Jjamppong'},
                },
              ]),
            ),
        ],
      );
      await _pumpQr(
        tester,
        service: _service(
          fetch: (_) async => menu,
          place: (_, items, _, _) async {
            sent.addAll(items);
            return _result;
          },
        ),
      );
      expect(find.text('Chọn tùy chọn'), findsOneWidget);
      expect(find.text('Chọn cỡ'), findsNothing);
      for (final meal in ['noodles', 'rice']) {
        await tester.tap(find.byKey(const Key('qr_add_option_noodles')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('menu_size__$meal')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('qr_open_review')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('qr_cart_noodles|dine_in_quantity')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('qr_cart_rice|dine_in_quantity')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('qr_cart_noodles|dine_in_options')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_size__rice')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('qr_cart_rice|dine_in_quantity')),
            )
            .data,
        '2',
      );
      await tester.tap(find.byKey(const Key('qr_cart_rice|dine_in_minus')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('qr_confirm_submit')));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(sent.single.menuItemId, 'rice');
      expect(sent.single.quantity, 1);
      expect(
        (jsonDecode(sent.single.menuOptionKey!) as List)[4]['meal_choice'],
        'rice',
      );
      _expectNoLayoutFailure(tester);
    },
  );

  testWidgets('one sized menu retains its registered photo and description', (
    tester,
  ) async {
    await _pumpQr(
      tester,
      service: _service(fetch: (_) async => sizesMenu(withMedia: true)),
    );
    final photo = tester.widget<Image>(
      find.byKey(const Key('qr_size_image_small')),
    );
    expect(
      (photo.image as NetworkImage).url,
      'https://example.invalid/tangsuyuk.jpg',
    );
    expect(find.text('Registered dish description'), findsOneWidget);
    await tester.tap(find.byKey(const Key('qr_choose_size_small')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu_size_picker')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cart option edits retain the existing takeout selection', (
    tester,
  ) async {
    final sent = <QrOrderLine>[];
    await _pumpQr(
      tester,
      service: _service(
        fetch: (_) async => sizesMenu(),
        place: (_, items, __, ___) async {
          sent.addAll(items);
          return _result;
        },
      ),
    );
    await tester.tap(find.byKey(const Key('qr_choose_size_small')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu_size_S')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qr_open_review')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qr_cart_small|takeout_options')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('menu_size_L')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('qr_cart_large|takeout_quantity')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('qr_confirm_submit')));
    await tester.pumpAndSettle();
    expect(sent.single.menuItemId, 'large');
    expect(sent.single.isTakeout, isTrue);
  });

  for (final language in ['ko', 'vi', 'en']) {
    testWidgets(
      'one dish opens S/L selection and submits distinct chosen prices $language',
      (tester) async {
        final sent = <QrOrderLine>[];
        await _pumpQr(
          tester,
          locale: Locale(language),
          textScale: 2,
          service: _service(
            fetch: (_) async => sizesMenu(),
            place: (_, items, __, ___) async {
              sent.addAll(items);
              return _result;
            },
          ),
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('qr_choose_size_small')),
          120,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('qr_menu_scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('qr_menu_item_small')), findsOneWidget);
        expect(find.byKey(const Key('qr_menu_item_large')), findsNothing);
        for (final size in ['L', 'S']) {
          await tester.ensureVisible(
            find.byKey(const Key('qr_choose_size_small')),
          );
          await tester.tap(find.byKey(const Key('qr_choose_size_small')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('menu_size_picker')), findsOneWidget);
          await tester.ensureVisible(find.byKey(Key('menu_size_$size')));
          await tester.tap(find.byKey(Key('menu_size_$size')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const Key('qr_open_review')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('qr_confirm_submit')));
        await tester.tap(find.byKey(const Key('qr_confirm_submit')));
        await tester.pumpAndSettle();
        expect(sent.map((line) => line.menuItemId).toSet(), {'small', 'large'});
        expect(sent.every((line) => line.quantity == 1), isTrue);
        expect(
          sent
              .map((line) => (jsonDecode(line.menuOptionKey!) as List)[3])
              .toSet(),
          {190000, 370000},
        );
        _expectNoLayoutFailure(tester);
      },
    );
  }

  testWidgets(
    'size price refresh requires reselection rather than repricing a cart',
    (tester) async {
      var menu = sizesMenu();
      await _pumpQr(
        tester,
        menuSafetyRefreshInterval: const Duration(seconds: 15),
        service: _service(fetch: (_) async => menu),
      );
      await tester.tap(find.byKey(const Key('qr_choose_size_small')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_size_L')));
      await tester.pumpAndSettle();
      menu = sizesMenu(largePrice: 390000);
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('qr_open_review')))
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const Key('qr_state_item_unavailable')),
        findsOneWidget,
      );
      _expectNoLayoutFailure(tester);
    },
  );

  testWidgets(
    'Vietnam midnight clears an unsent QR cart and reloads the table',
    (tester) async {
      var reads = 0;
      final delay = TimeUtils.currentVietnamBusinessDay().refreshDelay(
        DateTime.now().toUtc(),
      );
      await _pumpQr(
        tester,
        menuSafetyRefreshInterval: const Duration(days: 2),
        service: _service(
          fetchActive: (_) async {
            reads++;
            return _noActiveOrder;
          },
        ),
      );
      await tester.tap(find.byKey(const Key('qr_add_food')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('qr_open_review')))
            .onPressed,
        isNotNull,
      );
      await tester.pump(delay + const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(reads, greaterThan(1));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('qr_open_review')))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      _expectNoLayoutFailure(tester);
    },
  );

  testWidgets('disabled takeout exposes dine-in controls only', (tester) async {
    List<QrOrderLine>? submitted;
    const dineInOnlyMenu = QrOrderMenu(
      storeName: 'BunsikClub',
      tableNumber: '8',
      floorLabel: '1F',
      isTakeoutEnabled: false,
      categories: [QrMenuCategory(id: 'main', name: 'Main')],
      items: [
        QrMenuItem(
          id: 'food',
          categoryId: 'main',
          name: 'Tteokbokki',
          price: 125000,
        ),
      ],
    );
    await _pumpQr(
      tester,
      service: _service(
        fetch: (_) async => dineInOnlyMenu,
        place: (_, items, __, ___) async {
          submitted = items;
          return _result;
        },
      ),
    );

    expect(find.byKey(const Key('qr_add_food')), findsOneWidget);
    expect(find.byKey(const Key('qr_add_food_takeout')), findsNothing);
    await tester.tap(find.byKey(const Key('qr_add_food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qr_open_review')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qr_confirm_submit')));
    await tester.pumpAndSettle();

    expect(submitted, hasLength(1));
    expect(submitted!.single.isTakeout, isFalse);
  });

  testWidgets('same menu keeps separate dine-in and takeout lines', (
    tester,
  ) async {
    List<QrOrderLine>? submitted;
    await _pumpQr(
      tester,
      service: _service(
        place: (_, items, __, ___) async {
          submitted = items;
          return _result;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('qr_add_food')));
    await tester.pumpAndSettle();
    final addTakeout = find.byKey(const Key('qr_add_food_takeout'));
    await tester.ensureVisible(addTakeout);
    await tester.pumpAndSettle();
    await tester.tap(addTakeout);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qr_open_review')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('qr_review_mode_food|dine_in')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('qr_review_mode_food|takeout')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('qr_confirm_submit')));
    await tester.pumpAndSettle();

    expect(submitted, hasLength(2));
    expect(submitted!.where((line) => line.isTakeout), hasLength(1));
    expect(submitted!.where((line) => !line.isTakeout), hasLength(1));
  });

  testWidgets('leftover packaging request becomes one active-order status', (
    tester,
  ) async {
    var activeReads = 0;
    var requestCount = 0;
    QrActiveOrder activeOrder({String? packagingStatus}) => QrActiveOrder(
      isActive: true,
      orderCode: 'abcd1234',
      status: 'serving',
      fulfillmentMode: 'paperless',
      leftoverPackagingStatus: packagingStatus,
      items: const [
        QrActiveOrderItem(
          name: 'Food',
          quantity: 1,
          status: 'served',
          servedQuantity: 1,
        ),
      ],
    );
    await _pumpQr(
      tester,
      service: _service(
        fetchActive: (_) async => activeOrder(
          packagingStatus: activeReads++ == 0 ? null : 'awaiting_floor_pickup',
        ),
        requestLeftover: (_, __) async {
          requestCount += 1;
          return {'status': 'awaiting_floor_pickup'};
        },
      ),
    );

    final requestButton = find.byKey(
      const Key('qr_leftover_packaging_request'),
    );
    await tester.ensureVisible(requestButton);
    await tester.pumpAndSettle();
    await tester.tap(requestButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('toast_confirm_dialog_confirm')));
    await tester.pumpAndSettle();

    expect(requestCount, 1);
    expect(
      find.byKey(const Key('qr_leftover_packaging_status')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('qr_leftover_packaging_request')),
      findsNothing,
    );
  });

  testWidgets('promotion slot always shows VAT and uses welcome copy when idle', (
    tester,
  ) async {
    await _pumpQr(tester, service: _service());

    expect(find.byKey(const Key('qr_welcome_message')), findsOneWidget);
    expect(
      find.text('Món ăn được chuẩn bị tận tâm. Chúc quý khách ngon miệng.'),
      findsOneWidget,
    );
    expect(find.text('Chưa bao gồm VAT.'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('qr_menu_scroll')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('qr_environmental_notice')), findsOneWidget);
    expect(
      find.text(
        'Chúng tôi chung tay bảo vệ môi trường. Hãy hạn chế sử dụng hóa đơn giấy để cùng góp phần bảo vệ môi trường.',
      ),
      findsOneWidget,
    );

    const promotedMenu = QrOrderMenu(
      storeName: 'BunsikClub',
      tableNumber: '8',
      floorLabel: '1F',
      promotionName: 'Grand opening',
      promotionDiscountPercent: 30,
      categories: [],
      items: [],
    );
    await _pumpQr(tester, service: _service(fetch: (_) async => promotedMenu));

    expect(find.byKey(const Key('qr_active_promotion')), findsOneWidget);
    expect(find.textContaining('30%'), findsOneWidget);
    expect(find.text('Chưa bao gồm VAT.'), findsOneWidget);
    expect(find.byKey(const Key('qr_welcome_message')), findsNothing);
    _expectNoLayoutFailure(tester);
  });

  testWidgets(
    'paperless active order shows delivered and remaining quantities',
    (tester) async {
      const activeOrder = QrActiveOrder(
        isActive: true,
        orderCode: 'abcd1234',
        status: 'confirmed',
        fulfillmentMode: 'paperless',
        items: [
          QrActiveOrderItem(
            name: '떡볶이',
            nameKo: '떡볶이',
            nameVi: 'Bánh gạo cay',
            nameEn: 'Spicy rice cakes',
            quantity: 2,
            status: 'preparing',
            servedQuantity: 1,
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
      expect(find.text('Đã giao 1 · Còn 1'), findsOneWidget);
      expect(find.text('Chọn món gọi thêm'), findsOneWidget);

      await tester.tap(find.byKey(const Key('qr_language_selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('한국어').last);
      await tester.pumpAndSettle();

      expect(find.text('현재 주문 내역'), findsOneWidget);
      expect(find.text('떡볶이'), findsOneWidget);
      expect(find.text('전달 1 · 남음 1'), findsOneWidget);
      expect(find.text('추가 주문 메뉴'), findsOneWidget);
      _expectNoLayoutFailure(tester);
    },
  );

  testWidgets('printed active order shows the full list without progress', (
    tester,
  ) async {
    const activeOrder = QrActiveOrder(
      isActive: true,
      orderCode: 'printed123',
      status: 'confirmed',
      items: [
        QrActiveOrderItem(
          name: 'Tteokbokki',
          nameVi: 'Bánh gạo cay',
          quantity: 5,
          status: 'served',
          servedQuantity: 4,
        ),
      ],
    );

    await _pumpQr(
      tester,
      service: _service(fetchActive: (_) async => activeOrder),
    );

    expect(find.text('Bánh gạo cay'), findsOneWidget);
    expect(find.text('× 5'), findsOneWidget);
    expect(find.byKey(const Key('qr_delivery_progress_0')), findsNothing);
    expect(find.textContaining('Đã giao'), findsNothing);
    expect(find.textContaining('Còn'), findsNothing);
    _expectNoLayoutFailure(tester);
  });

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
        place: (_, items, __, ___) async {
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
        service: _service(place: (_, __, ___, ____) => pendingOrder.future),
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

  testWidgets('submitted order stays visible until cashier payment', (
    tester,
  ) async {
    var activeOrderReads = 0;
    const activeOrder = QrActiveOrder(
      isActive: true,
      orderId: 'order-a',
      orderCode: 'paid-later',
      status: 'confirmed',
      fulfillmentMode: 'paperless',
      items: [
        QrActiveOrderItem(
          name: 'Tteokbokki',
          nameVi: 'Bánh gạo cay',
          quantity: 5,
          status: 'ready',
          servedQuantity: 4,
        ),
      ],
    );
    await _pumpQr(
      tester,
      menuSafetyRefreshInterval: const Duration(seconds: 15),
      service: _service(
        fetchActive: (_) async {
          activeOrderReads += 1;
          if (activeOrderReads == 1) return _noActiveOrder;
          if (activeOrderReads == 2) return activeOrder;
          return _noActiveOrder;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('qr_add_food')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('qr_open_review')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qr_confirm_submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('qr_state_success')), findsOneWidget);
    expect(find.text('Đã giao 4 · Còn 1'), findsOneWidget);

    await tester.pump(const Duration(seconds: 15));
    await tester.pump();

    expect(find.byKey(const Key('qr_state_success')), findsNothing);
    expect(find.byKey(const Key('qr_order_screen')), findsOneWidget);
    _expectNoLayoutFailure(tester);
  });

  testWidgets('ten-minute display version reset keeps an in-progress cart', (
    tester,
  ) async {
    var activeOrderReads = 0;
    final resetDueAt = DateTime.now().add(const Duration(seconds: 2));
    final beforeReset = QrActiveOrder(
      isActive: true,
      orderId: 'order-a',
      orderCode: 'order-a',
      status: 'serving',
      displayVersion: 0,
      resetDueAt: resetDueAt,
      items: const [
        QrActiveOrderItem(name: 'Pho', quantity: 1, status: 'served'),
      ],
    );
    final afterReset = QrActiveOrder(
      isActive: true,
      orderId: 'order-a',
      orderCode: 'order-a',
      status: 'serving',
      displayVersion: 1,
      displayResetAt: resetDueAt,
      resetDueAt: resetDueAt,
      items: const [],
    );
    await _pumpQr(
      tester,
      service: _service(
        fetchActive: (_) async =>
            activeOrderReads++ == 0 ? beforeReset : afterReset,
      ),
    );

    expect(find.byKey(const Key('qr_active_order_summary')), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('qr_menu_scroll')),
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qr_add_food')));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('qr_open_review')))
          .onPressed,
      isNotNull,
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('qr_active_order_summary')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('qr_open_review')))
          .onPressed,
      isNotNull,
    );
    _expectNoLayoutFailure(tester);
  });

  testWidgets('a new table order clears the previous order cart context', (
    tester,
  ) async {
    var activeOrderReads = 0;
    const firstOrder = QrActiveOrder(
      isActive: true,
      orderId: 'order-a',
      orderCode: 'order-a',
      status: 'serving',
      items: [],
    );
    const nextOrder = QrActiveOrder(
      isActive: true,
      orderId: 'order-b',
      orderCode: 'order-b',
      status: 'pending',
      items: [],
    );
    await _pumpQr(
      tester,
      menuSafetyRefreshInterval: const Duration(seconds: 15),
      service: _service(
        fetchActive: (_) async =>
            activeOrderReads++ == 0 ? firstOrder : nextOrder,
      ),
    );

    await tester.tap(find.byKey(const Key('qr_add_food')));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('qr_open_review')))
          .onPressed,
      isNotNull,
    );

    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('qr_open_review')))
          .onPressed,
      isNull,
    );
    _expectNoLayoutFailure(tester);
  });

  testWidgets('submission sends the active order context to the server', (
    tester,
  ) async {
    String? submittedExpectedOrderId;
    const activeOrder = QrActiveOrder(
      isActive: true,
      orderId: 'order-a',
      orderCode: 'order-a',
      status: 'serving',
      items: [],
    );
    await _pumpQr(
      tester,
      service: _service(
        fetchActive: (_) async => activeOrder,
        place: (_, __, ___, expectedOrderId) async {
          submittedExpectedOrderId = expectedOrderId;
          return _result;
        },
      ),
    );

    await tester.drag(
      find.byKey(const Key('qr_menu_scroll')),
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qr_add_food')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('qr_open_review')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qr_confirm_submit')));
    await tester.pumpAndSettle();

    expect(submittedExpectedOrderId, 'order-a');
    expect(find.byKey(const Key('qr_state_success')), findsOneWidget);
    _expectNoLayoutFailure(tester);
  });

  testWidgets('rate-limit and offline retry reuse the same client order id', (
    tester,
  ) async {
    final clientOrderIds = <String>[];
    var attempt = 0;
    await _pumpQr(
      tester,
      service: _service(
        place: (_, __, clientOrderId, ___) async {
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
      'QR_ORDER_CONTEXT_CHANGED': 'qr_state_order_context_changed',
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
        service: _service(place: (_, __, ___, ____) => Future.error(entry.key)),
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
