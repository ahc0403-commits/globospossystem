import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/payments/vietqr_payload.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_customer_push_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_storefront_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StorefrontFixtureService extends DirectOrderService {
  _StorefrontFixtureService({
    this.savedAddress,
    this.activeStatus,
    this.orderSummaries,
    this.paused = false,
    this.pauseOnSubmit = false,
    this.extraItems = const [],
    this.extraCategories = const [],
    this.defaultMenu = true,
    this.proofHandler,
  });

  final DirectOrderAddress? savedAddress;
  DirectOrderStatus? activeStatus;
  final List<DirectOrderSummary>? orderSummaries;
  bool paused;
  final bool pauseOnSubmit;
  final List<DirectOrderMenuItem> extraItems;
  List<DirectOrderCategory> extraCategories;
  bool defaultMenu;
  final Future<void> Function(DirectOrderProofAttempt)? proofHandler;
  bool failStatus = false;
  int storefrontCalls = 0;
  DirectOrderAddress? submittedAddress;
  Map<String, String>? submittedItemNotes;
  bool? submittedRememberAddress;
  DirectOrderFulfillmentType? submittedFulfillmentType;
  int submitCalls = 0;
  int clearAddressCalls = 0;
  int clearActiveRequestCalls = 0;
  var fetchStatusCalls = 0;
  var sendMessageCalls = 0;
  var ensureSessionCalls = 0;
  var fetchStorefrontCalls = 0;

  @override
  Future<DirectOrderStorefront> fetchStorefront(String slug) async {
    fetchStorefrontCalls += 1;
    storefrontCalls++;
    return DirectOrderStorefront(
      storeId: 'fixture-store',
      storeName: 'GLOBOS BUNSIK',
      storeAddress: '69 Nguyen Gia Tri, Binh Thanh',
      slug: 'fixture-store',
      paused: paused,
      minimumOrderAmount: 100000,
      defaultLatitude: 10.8,
      defaultLongitude: 106.7,
      googleMapsBrowserKey: null,
      bank: const DirectOrderBank(
        bin: '970436',
        accountNumber: '123456789',
        accountHolder: 'GLOBOS VN',
        label: 'Vietcombank',
      ),
      categories: [
        const DirectOrderCategory(
          id: 'popular',
          nameKo: '인기 메뉴',
          nameVi: 'Món phổ biến',
          nameEn: 'Popular',
          sortOrder: 1,
        ),
        ...extraCategories,
      ],
      items: [
        if (defaultMenu)
          const DirectOrderMenuItem(
            id: 'tteokbokki',
            categoryId: 'popular',
            nameKo: '즉석 떡볶이',
            nameVi: 'Tokbokki cay',
            nameEn: 'Spicy tteokbokki',
            description: 'Bánh gạo, chả cá và sốt cay',
            price: 125000,
            imageUrl: null,
            vatCategory: 'food',
            sortOrder: 1,
          ),
        ...extraItems,
      ],
    );
  }

  @override
  Future<DirectOrderSession> ensureSession({
    required String slug,
    required String locale,
  }) async {
    ensureSessionCalls += 1;
    return DirectOrderSession(
      id: 'fixture-session',
      secret: 'fixture-secret',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<DirectOrderAddress?> loadAddress(String slug) async => savedAddress;

  @override
  Future<String?> loadActiveRequestId(String slug) async =>
      activeStatus?.requestId;

  @override
  Future<List<DirectOrderSummary>> listOrders({
    required DirectOrderSession session,
  }) async {
    if (orderSummaries != null) return orderSummaries!;
    final status = activeStatus;
    if (status == null) return const [];
    return [
      DirectOrderSummary(
        requestId: status.requestId,
        referenceCode: status.referenceCode,
        state: status.state,
        createdAt: DateTime.utc(2026, 8, 24, 2),
        itemCount: 1,
        finalTotal: status.quote?.finalTotal,
        fulfillmentStatus: status.fulfillmentStatus,
        completedAt: status.completedAt,
        hasOpenProofReview: status.proofReview != null,
      ),
    ];
  }

  @override
  Future<void> clearActiveRequest(String slug) async {
    clearActiveRequestCalls += 1;
  }

  @override
  Future<DirectOrderStatus> fetchStatus({
    required DirectOrderSession session,
    required String requestId,
  }) async {
    fetchStatusCalls += 1;
    if (failStatus) {
      throw const DirectOrderException('DIRECT_ORDER_TEMPORARILY_UNAVAILABLE');
    }
    return activeStatus ??
        const DirectOrderStatus(
          requestId: 'fixture-request',
          referenceCode: 'D12345678',
          state: 'awaiting_quote',
          messages: [],
        );
  }

  @override
  Future<DirectOrderMessage> sendMessage({
    required DirectOrderSession session,
    required String requestId,
    required String message,
  }) async {
    sendMessageCalls += 1;
    return DirectOrderMessage(
      id: 'fixture-sent-message',
      senderType: 'customer',
      messageType: 'text',
      body: message,
      hasAttachment: false,
      createdAt: DateTime.utc(2026, 8, 24, 3),
    );
  }

  @override
  Future<void> clearAddress(String slug) async {
    clearAddressCalls++;
  }

  @override
  Future<void> resumePaymentProof({
    required DirectOrderSession session,
    required DirectOrderProofAttempt attempt,
    void Function()? onChanged,
    bool allowUpload = true,
  }) async {
    await proofHandler!(attempt);
    onChanged?.call();
  }

  @override
  Future<DirectOrderSubmission> submit({
    required String slug,
    required DirectOrderSession session,
    String? draftId,
    required String locale,
    required Map<String, int> cart,
    required Map<String, String> itemNotes,
    required DirectOrderAddress address,
    required bool rememberAddress,
    DirectOrderFulfillmentType fulfillmentType =
        DirectOrderFulfillmentType.delivery,
    String? customerNote,
    int? dinerCount,
  }) async {
    submitCalls++;
    submittedAddress = address;
    submittedFulfillmentType = fulfillmentType;
    submittedItemNotes = Map.of(itemNotes);
    submittedRememberAddress = rememberAddress;
    if (pauseOnSubmit) {
      throw const DirectOrderException('DIRECT_ORDER_STOREFRONT_PAUSED');
    }
    return const DirectOrderSubmission(
      requestId: 'fixture-request',
      referenceCode: 'D12345678',
    );
  }
}

Widget _fixtureApp({
  _StorefrontFixtureService? service,
  Locale locale = const Locale('vi'),
  DateTime Function() now = DateTime.now,
  Future<XFile?> Function()? pickProofImage,
  DirectOrderCustomerPushService? pushService,
}) => ProviderScope(
  child: RepaintBoundary(
    key: const Key('direct_customer_visual_boundary'),
    child: MaterialApp(
      theme: AppTheme.build(),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: DirectOrderStorefrontScreen(
        slug: 'fixture-store',
        service: service ?? _StorefrontFixtureService(),
        now: now,
        pickProofImage: pickProofImage,
        pushService: pushService,
      ),
    ),
  ),
);

Future<void> _revealSubmit(WidgetTester tester) async {
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const Key('direct_submit_quote_request')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> _captureCustomerUi(WidgetTester tester, String name) async {
  final directory = Platform.environment['DIRECT_ORDER_CUSTOMER_SCREENSHOTS'];
  if (directory == null) return;
  final originalSize = tester.view.physicalSize;
  final originalRatio = tester.view.devicePixelRatio;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('direct_customer_visual_boundary')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
  tester.view.physicalSize = originalSize;
  tester.view.devicePixelRatio = originalRatio;
  await tester.pumpAndSettle();
}

class _CustomerPushFixture extends DirectOrderCustomerPushService {
  int explicitEnables = 0;
  int restores = 0;
  int disables = 0;
  Completer<DirectOrderPushReadiness>? pendingEnable;
  DirectOrderPushReadiness disableResult = DirectOrderPushReadiness.off;
  @override
  Future<DirectOrderPushReadiness> enable({
    required String slug,
    required DirectOrderSession session,
    required DirectOrderService service,
    required String locale,
    bool restore = false,
    void Function(String requestId, String kind)? onForeground,
  }) async {
    if (restore) {
      restores++;
      return DirectOrderPushReadiness.off;
    }
    explicitEnables++;
    return pendingEnable?.future ?? DirectOrderPushReadiness.ready;
  }

  @override
  Future<DirectOrderPushReadiness> disable({
    required String slug,
    required DirectOrderSession session,
    required DirectOrderService service,
    required String locale,
  }) async {
    disables++;
    return disableResult;
  }
}

Future<void> _openAddress(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('direct_add_tteokbokki')));
  await tester.pump();
  await tester.tap(find.text('Địa chỉ').last);
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('direct_diner_count_input')),
    '3',
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (Platform.environment['DIRECT_ORDER_CUSTOMER_SCREENSHOTS'] == null) {
      return;
    }
    final text = FontLoader('Pretendard')
      ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([text.load(), icons.load()]);
  });
  const drinks = DirectOrderCategory(
    id: 'drinks',
    nameKo: '음료',
    nameVi: 'Nước uống',
    nameEn: 'Drinks',
    sortOrder: 2,
  );
  const tea = DirectOrderMenuItem(
    id: 'tea',
    categoryId: 'drinks',
    nameKo: '차',
    nameVi: 'Trà',
    nameEn: 'Tea',
    description: '',
    price: 25000,
    imageUrl: null,
    vatCategory: 'beverage',
    sortOrder: 2,
  );
  DirectOrderStatus quoted() => DirectOrderStatus(
    requestId: 'proof-request',
    referenceCode: 'DPROOF01',
    state: 'quoted',
    quote: DirectOrderQuote(
      id: 'quote-1',
      version: 1,
      menuTotal: 125000,
      serviceChargeTotal: 0,
      deliveryFeeTotal: 0,
      finalTotal: 125000,
      status: 'active',
      expiresAt: DateTime.utc(2099),
    ),
    messages: const [],
  );
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  Future<XFile?> photo() async =>
      XFile.fromData(png, name: 'transfer.png', mimeType: 'image/png');
  Future<void> openProof(WidgetTester tester) async {
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('direct_upload_payment_proof')),
    );
    await tester.tap(find.byKey(const Key('direct_upload_payment_proof')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'category selection is pinned, local and preserves cart across locale and address',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final service = _StorefrontFixtureService(
        extraCategories: [drinks],
        extraItems: [tea],
      );
      await tester.pumpWidget(_fixtureApp(service: service));
      await tester.pumpAndSettle();
      final calls = service.storefrontCalls;
      await tester.tap(find.byKey(const Key('direct_add_tteokbokki')));
      await tester.tap(find.byKey(const Key('direct_category_drinks')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('direct_add_tteokbokki')), findsNothing);
      expect(find.byKey(const Key('direct_add_tea')), findsOneWidget);
      expect(service.storefrontCalls, calls);
      await tester.tap(find.byKey(const Key('direct_add_tea')));
      await tester.pumpWidget(
        _fixtureApp(service: service, locale: const Locale('ko')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('direct_category_drinks')))
            .selected,
        isTrue,
      );
      await tester.tap(find.text('배송지').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('direct_diner_count_input')),
        '3',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.tap(find.text('메뉴').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('direct_category_drinks')))
            .selected,
        isTrue,
      );
      expect(find.textContaining('장바구니 보기 · 2'), findsOneWidget);
      service.extraCategories = [];
      await tester.tap(find.text('배송지').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('direct_diner_count_input')),
            )
            .controller!
            .text,
        '3',
      );
      await tester.tap(find.text('메뉴').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('direct_category_all')))
            .selected,
        isTrue,
      );
      expect(find.byKey(const Key('direct_add_tea')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [360.0, 390.0, 768.0, 1024.0, 1440.0]) {
    testWidgets('many long categories can reach the last category at $width', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const {});
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final categories = List.generate(
        12,
        (i) => DirectOrderCategory(
          id: 'c$i',
          nameKo: '아주 긴 카테고리 이름 $i',
          nameVi: 'Danh mục với tên dài $i',
          nameEn: 'A very long category name $i',
          sortOrder: i,
        ),
      );
      final service = _StorefrontFixtureService(
        extraCategories: categories,
        extraItems: [
          for (var i = 0; i < 12; i++)
            DirectOrderMenuItem(
              id: 'i$i',
              categoryId: 'c$i',
              nameKo: '메뉴$i',
              nameVi: 'Món$i',
              nameEn: 'Item$i',
              description: '',
              price: 10000,
              imageUrl: null,
              vatCategory: 'food',
              sortOrder: i,
            ),
        ],
      );
      await tester.pumpWidget(_fixtureApp(service: service));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('direct_category_c11')),
        280,
        scrollable: find.descendant(
          of: find.byKey(const Key('direct_category_bar')),
          matching: find.byType(Scrollable),
        ),
        maxScrolls: 30,
      );
      await tester.drag(
        find.byKey(const Key('direct_category_bar')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('direct_category_c11')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('direct_category_c11')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('direct_add_i11')), findsOneWidget);
      expect(find.byKey(const Key('direct_add_tteokbokki')), findsNothing);
      final top = tester
          .getTopLeft(find.byKey(const Key('direct_category_bar')))
          .dy;
      await tester.drag(
        find.byKey(const PageStorageKey('direct_menu_list')),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const Key('direct_category_bar'))).dy,
        top,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty menu hides unused categories and provides refresh', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    await tester.pumpWidget(
      _fixtureApp(service: _StorefrontFixtureService(defaultMenu: false)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Chưa có món để đặt.'), findsOneWidget);
    expect(find.byKey(const Key('direct_category_popular')), findsNothing);
  });

  testWidgets('direct screenshot picker cancellation sends nothing', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    var calls = 0;
    final service = _StorefrontFixtureService(
      activeStatus: quoted(),
      proofHandler: (_) async {
        calls++;
      },
    );
    await tester.pumpWidget(
      _fixtureApp(service: service, pickProofImage: () async => null),
    );
    await tester.pumpAndSettle();
    await openProof(tester);
    expect(calls, 0);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.byKey(const Key('direct_upload_payment_proof')),
      findsOneWidget,
    );
  });

  testWidgets(
    'failed screenshot retries the retained photo without payment dialog',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final attempts = <DirectOrderProofAttempt>[];
      var picks = 0;
      final service = _StorefrontFixtureService(
        activeStatus: quoted(),
        proofHandler: (attempt) async {
          attempts.add(attempt);
          if (attempts.length == 1) {
            throw const DirectOrderException(
              'PROOF_UPLOAD_TEMPORARILY_UNAVAILABLE',
            );
          }
          attempt.complete = true;
        },
      );
      await tester.pumpWidget(
        _fixtureApp(
          service: service,
          pickProofImage: () {
            picks++;
            return photo();
          },
        ),
      );
      await tester.pumpAndSettle();
      await openProof(tester);
      expect(find.byType(QrImageView), findsNothing);
      expect(find.textContaining('DPROOF01'), findsWidgets);
      await tester.tap(find.byKey(const Key('direct_confirm_payment_proof')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('direct_proof_error')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('direct_change_payment_proof')),
      );
      await tester.tap(find.byKey(const Key('direct_change_payment_proof')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('direct_cancel_payment_proof')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('direct_proof_error')), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('direct_retry_payment_proof')),
      );
      await tester.tap(find.byKey(const Key('direct_retry_payment_proof')));
      await tester.pumpAndSettle();
      expect(attempts, hasLength(2));
      expect(identical(attempts[0], attempts[1]), isTrue);
      expect(picks, 2);
      expect(service.submitCalls, 0);
      expect(find.byKey(const Key('direct_proof_sent')), findsOneWidget);
    },
  );

  testWidgets('commit success remains sent when status refresh fails', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    late _StorefrontFixtureService service;
    service = _StorefrontFixtureService(
      activeStatus: quoted(),
      proofHandler: (attempt) async {
        attempt.complete = true;
        service.failStatus = true;
      },
    );
    await tester.pumpWidget(
      _fixtureApp(service: service, pickProofImage: photo),
    );
    await tester.pumpAndSettle();
    await openProof(tester);
    await tester.tap(find.byKey(const Key('direct_confirm_payment_proof')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('direct_proof_sent')), findsOneWidget);
    expect(find.byKey(const Key('direct_retry_payment_proof')), findsNothing);
    expect(
      find.byKey(const Key('direct_refresh_proof_status')),
      findsOneWidget,
    );
    service.failStatus = false;
    service.activeStatus = const DirectOrderStatus(
      requestId: 'proof-request',
      referenceCode: 'DPROOF01',
      state: 'approved',
      messages: [],
    );
    await tester.ensureVisible(
      find.byKey(const Key('direct_refresh_proof_status')),
    );
    await tester.tap(find.byKey(const Key('direct_refresh_proof_status')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('direct_proof_sent')), findsNothing);
    expect(find.byKey(const Key('direct_upload_payment_proof')), findsNothing);
  });

  testWidgets(
    'picker is guarded from the first click and preview cancel sends nothing',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final picker = Completer<XFile?>();
      var picks = 0;
      var sends = 0;
      final service = _StorefrontFixtureService(
        activeStatus: quoted(),
        proofHandler: (_) async {
          sends++;
        },
      );
      await tester.pumpWidget(
        _fixtureApp(
          service: service,
          pickProofImage: () {
            picks++;
            return picker.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).last, const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('direct_upload_payment_proof')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('direct_upload_payment_proof')),
            )
            .onPressed,
        isNull,
      );
      picker.complete(await photo());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('direct_cancel_payment_proof')));
      await tester.pumpAndSettle();
      expect(picks, 1);
      expect(sends, 0);
    },
  );
  testWidgets('cart preview lists selected items without submitting an order', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final money = NumberFormat.currency(
      locale: 'vi_VN',
      symbol: '₫',
      decimalDigits: 0,
    );
    final service = _StorefrontFixtureService(
      extraItems: const [
        DirectOrderMenuItem(
          id: 'ramen',
          categoryId: 'popular',
          nameKo: '떡만두라면',
          nameVi: 'Ramen bánh gạo và mandu',
          nameEn: 'Rice cake and dumpling ramen',
          description: null,
          price: 69000,
          imageUrl: null,
          vatCategory: 'food',
          sortOrder: 2,
        ),
      ],
    );
    await tester.pumpWidget(
      _fixtureApp(service: service, locale: const Locale('ko')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('direct_view_cart')), findsNothing);
    await tester.tap(find.byKey(const Key('direct_add_tteokbokki')));
    await tester.pump();
    final tteokbokkiCard = find.ancestor(
      of: find.text('즉석 떡볶이'),
      matching: find.byType(Card),
    );
    await tester.tap(
      find.descendant(
        of: tteokbokkiCard,
        matching: find.byIcon(Icons.add_rounded),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('direct_add_ramen')));
    await tester.pump();
    await tester.tap(find.text(money.format(319000)));
    await tester.pumpAndSettle();

    final sheet = find.byKey(const Key('direct_cart_sheet'));
    expect(sheet, findsOneWidget);
    for (final entry in {
      'tteokbokki': [
        '즉석 떡볶이',
        '${money.format(125000)} × 2',
        money.format(250000),
      ],
      'ramen': ['떡만두라면', '${money.format(69000)} × 1', money.format(69000)],
    }.entries) {
      final line = find.byKey(Key('direct_cart_item_${entry.key}'));
      expect(line, findsOneWidget);
      for (final text in entry.value) {
        expect(
          find.descendant(of: line, matching: find.text(text)),
          findsOneWidget,
        );
      }
    }
    expect(
      tester.widget<Text>(find.byKey(const Key('direct_cart_subtotal'))).data,
      money.format(319000),
    );
    expect(service.submitCalls, 0);
    await tester.tap(find.byKey(const Key('direct_cart_close')));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('direct_view_cart')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('direct_cart_address')));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(find.byKey(const Key('direct_address_input')), findsOneWidget);
    expect(service.submitCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cart preview is localized and responsive in all three locales', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final entry in {
      'ko': '즉석 떡볶이',
      'vi': 'Tokbokki cay',
      'en': 'Spicy tteokbokki',
    }.entries) {
      final copy = DirectOrderCopy(entry.key);
      for (final size in const [
        Size(320, 568),
        Size(390, 844),
        Size(1440, 900),
      ]) {
        for (final isPickup in [false, true]) {
          tester.view.physicalSize = size;
          final service = _StorefrontFixtureService();
          await tester.pumpWidget(
            _fixtureApp(service: service, locale: Locale(entry.key)),
          );
          await tester.pumpAndSettle();
          if (isPickup) {
            await tester.tap(
              find.descendant(
                of: find.byKey(const Key('direct_fulfillment_type')),
                matching: find.text(copy.pickup),
              ),
            );
            await tester.pump();
          }
          await tester.ensureVisible(
            find.byKey(const Key('direct_add_tteokbokki')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('direct_add_tteokbokki')));
          await tester.pump();
          expect(
            find.text(
              '${isPickup ? copy.pickup : copy.delivery} · ${copy.viewCart} · 1',
            ),
            findsOneWidget,
          );
          final cartButton = find.byKey(const Key('direct_view_cart'));
          expect(cartButton.hitTestable(), findsOneWidget);
          expect(tester.getSize(cartButton).height, lessThanOrEqualTo(132));
          final continueButton = find.byKey(const Key('direct_cart_continue'));
          expect(continueButton.hitTestable(), findsOneWidget);
          expect(tester.getSize(continueButton).height, lessThanOrEqualTo(132));
          await tester.drag(
            find.byKey(const PageStorageKey('direct_menu_list')),
            const Offset(0, 800),
          );
          await tester.pumpAndSettle();
          expect(
            tester.getTopLeft(cartButton).dy,
            greaterThan(
              tester
                  .getBottomLeft(
                    find.byKey(const Key('direct_fulfillment_type')),
                  )
                  .dy,
            ),
          );
          await tester.tap(find.byKey(const Key('direct_view_cart')));
          await tester.pumpAndSettle();
          final sheet = find.byKey(const Key('direct_cart_sheet'));
          expect(
            find.descendant(of: sheet, matching: find.text(entry.value)),
            findsOneWidget,
          );
          expect(
            find.text(isPickup ? copy.vatNotice : copy.cartQuoteNotice),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull, reason: '${entry.key}:$size');
          await tester.tap(find.byKey(const Key('direct_cart_close')));
          await tester.pumpAndSettle();
          // The original footer action must still open the address form directly.
          await tester.tap(find.byKey(const Key('direct_cart_continue')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('direct_recipient_name')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('direct_address_input')),
            isPickup ? findsNothing : findsOneWidget,
          );
          expect(service.submitCalls, 0);
          expect(tester.takeException(), isNull, reason: '${entry.key}:$size');
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
  });

  testWidgets('cart preview scrolls through long names and many selected items', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 568);
    addTearDown(tester.view.reset);
    final service = _StorefrontFixtureService(
      extraItems: List.generate(
        8,
        (index) => DirectOrderMenuItem(
          id: 'extra_$index',
          categoryId: 'popular',
          nameKo: '메뉴 $index',
          nameVi: 'Món $index',
          nameEn:
              'Menu $index with rice cakes, dumplings, vegetables and spicy broth',
          description: null,
          price: 10000,
          imageUrl: null,
          vatCategory: 'food',
          sortOrder: index + 2,
        ),
      ),
    );
    await tester.pumpWidget(
      _fixtureApp(service: service, locale: const Locale('en')),
    );
    await tester.pumpAndSettle();
    for (var index = 0; index < 8; index++) {
      final add = find.byKey(Key('direct_add_extra_$index'));
      await tester.scrollUntilVisible(
        add,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('direct_menu_list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await Scrollable.ensureVisible(tester.element(add), alignment: 0.2);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('direct_view_cart')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('direct_cart_item_tteokbokki')), findsNothing);
    final last = find.byKey(const Key('direct_cart_item_extra_7'));
    await tester.scrollUntilVisible(
      last,
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('direct_cart_sheet')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find
          .descendant(
            of: last,
            matching: find.text(service.extraItems.last.nameEn),
          )
          .hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('direct_cart_address')).hitTestable(),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('direct_cart_subtotal'))).data,
      NumberFormat.currency(
        locale: 'vi_VN',
        symbol: '₫',
        decimalDigits: 0,
      ).format(80000),
    );
    expect(service.submitCalls, 0);
    expect(tester.takeException(), isNull);
  });

  for (final hour in [11, 22]) {
    testWidgets('open storefront refreshes automatically at Vietnam $hour:00', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const {});
      var now = DateTime.utc(
        2026,
        10,
        3,
        hour - 7,
      ).subtract(const Duration(seconds: 2));
      final service = _StorefrontFixtureService(paused: hour == 11);
      await tester.pumpWidget(_fixtureApp(service: service, now: () => now));
      await tester.pumpAndSettle();
      expect(service.fetchStorefrontCalls, 1);
      expect(
        find.byKey(const Key('direct_order_closed_state')),
        hour == 11 ? findsOneWidget : findsNothing,
      );
      service.paused = hour == 22;
      now = now.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(service.fetchStorefrontCalls, 2);
      expect(
        find.byKey(const Key('direct_order_closed_state')),
        hour == 22 ? findsOneWidget : findsNothing,
      );
      expect(service.ensureSessionCalls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('pickup needs contact only and shows store collection address', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final service = _StorefrontFixtureService();
    await tester.pumpWidget(
      _fixtureApp(service: service, locale: const Locale('ko')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('포장 · 픽업').first);
    await tester.tap(find.byKey(const Key('direct_add_tteokbokki')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('수령 정보').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('direct_address_input')), findsNothing);
    expect(find.byKey(const Key('direct_address_detail')), findsNothing);
    expect(find.textContaining('69 Nguyen Gia Tri, Binh Thanh'), findsWidgets);
    await tester.enterText(
      find.byKey(const Key('direct_recipient_name')),
      'Pickup Customer',
    );
    await tester.enterText(
      find.byKey(const Key('direct_recipient_phone')),
      '0901234567',
    );
    await tester.enterText(
      find.byKey(const Key('direct_diner_count_input')),
      '3',
    );
    final submit = find.byKey(const Key('direct_submit_quote_request'));
    await _revealSubmit(tester);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(service.submitCalls, 1);
    expect(service.submittedFulfillmentType, DirectOrderFulfillmentType.pickup);
    expect(service.submittedAddress?.customerName, 'Pickup Customer');
    expect(service.submittedRememberAddress, false);
    expect(service.clearAddressCalls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'pickup ready shows collection code instead of dispatch progress',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final service = _StorefrontFixtureService(
        activeStatus: const DirectOrderStatus(
          requestId: 'pickup-ready',
          referenceCode: 'DPICKUP01',
          state: 'approved',
          fulfillmentType: DirectOrderFulfillmentType.pickup,
          fulfillmentStatus: 'ready',
          pickupCode: '4821',
          messages: [],
        ),
      );
      await tester.pumpWidget(
        _fixtureApp(service: service, locale: const Locale('ko')),
      );
      await tester.pumpAndSettle();
      expect(find.text('수령 준비 완료'), findsWidgets);
      expect(find.textContaining('4821'), findsWidgets);
      expect(find.text('포장 · 픽업'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('completed order remains visible with an explicit final status', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    const saved = DirectOrderAddress(
      customerName: 'Nguyen Van A',
      customerPhone: '+84901234567',
      formattedAddress: 'Landmark 81, Bình Thạnh, Hồ Chí Minh',
      detailAddress: 'Tầng 12, căn 1201',
    );
    const completed = DirectOrderStatus(
      requestId: 'completed-request',
      referenceCode: 'D87654321',
      state: 'approved',
      fulfillmentStatus: 'completed',
      messages: [],
    );
    final service = _StorefrontFixtureService(
      savedAddress: saved,
      activeStatus: completed,
    );

    await tester.pumpWidget(_fixtureApp(service: service));
    await tester.pumpAndSettle();

    expect(service.clearActiveRequestCalls, 0);
    expect(find.text('D87654321'), findsOneWidget);
    expect(find.text('Đơn hàng đã hoàn tất'), findsWidgets);
    expect(find.byKey(const Key('direct_order_status_title')), findsOneWidget);
    expect(find.byKey(const Key('direct_customer_my_orders')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('order history shows each order with its own status', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    const selected = DirectOrderStatus(
      requestId: 'order-a',
      referenceCode: 'DAAAAAAAA',
      state: 'approved',
      fulfillmentStatus: 'dispatched',
      messages: [],
    );
    final service = _StorefrontFixtureService(
      activeStatus: selected,
      orderSummaries: [
        DirectOrderSummary(
          requestId: 'order-a',
          referenceCode: 'DAAAAAAAA',
          state: 'approved',
          createdAt: DateTime.utc(2026, 9, 10, 10),
          itemCount: 2,
          hasOpenProofReview: false,
          finalTotal: 200000,
          fulfillmentStatus: 'dispatched',
        ),
        DirectOrderSummary(
          requestId: 'order-b',
          referenceCode: 'DBBBBBBBB',
          state: 'quoted',
          createdAt: DateTime.utc(2026, 9, 10, 9),
          itemCount: 1,
          hasOpenProofReview: false,
          finalTotal: 125000,
        ),
        DirectOrderSummary(
          requestId: 'order-c',
          referenceCode: 'DCCCCCCCC',
          state: 'approved',
          createdAt: DateTime.utc(2026, 9, 10, 8),
          itemCount: 3,
          hasOpenProofReview: false,
          finalTotal: 340000,
          fulfillmentStatus: 'completed',
          completedAt: DateTime.utc(2026, 9, 10, 9),
        ),
      ],
    );

    await tester.pumpWidget(
      _fixtureApp(service: service, locale: const Locale('ko')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('direct_customer_my_orders')));
    await tester.pumpAndSettle();

    expect(find.text('#DAAAAAAAA'), findsOneWidget);
    expect(find.text('#DBBBBBBBB'), findsOneWidget);
    expect(find.text('#DCCCCCCCC'), findsOneWidget);
    expect(find.text('배달 · 결제 완료 · 메뉴 2개'), findsOneWidget);
    expect(find.text('배달 · 확인 대기 · 메뉴 1개'), findsOneWidget);
    expect(find.text('배달 · 완료 · 메뉴 3개'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cashier Grab policy changes customer instructions and transfer QR amount',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      for (final prepaid in [false, true]) {
        final total = prepaid ? 135000.0 : 110000.0;
        final service = _StorefrontFixtureService(
          activeStatus: DirectOrderStatus(
            requestId: 'delivery-quote',
            referenceCode: 'DFEEMODE',
            state: 'quoted',
            messages: const [],
            quote: DirectOrderQuote(
              id: 'quote',
              version: 1,
              menuTotal: 100000,
              serviceChargeTotal: 10000,
              deliveryFeeTotal: prepaid ? 25000 : 0,
              finalTotal: total,
              status: 'active',
              expiresAt: DateTime.utc(2099),
              deliveryPaymentMode: prepaid
                  ? 'store_prepaid'
                  : 'customer_direct',
            ),
          ),
        );
        await tester.pumpWidget(
          _fixtureApp(service: service, locale: const Locale('ko')),
        );
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ListView).last, const Offset(0, -700));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('direct_open_payment_details')),
        );
        await tester.tap(find.byKey(const Key('direct_open_payment_details')));
        await tester.pumpAndSettle();
        final paint = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(QrImageView),
            matching: find.byType(CustomPaint),
          ),
        );
        final actual = await tester.runAsync(
          () => (paint.painter! as QrPainter).toImageData(210),
        );
        final expected = await tester.runAsync(
          () => QrPainter(
            data: VietQrPayload.bankTransfer(
              bankBin: '970436',
              accountNumber: '123456789',
              amount: total.toInt(),
              purpose: 'DFEEMODE',
            ),
            version: QrVersions.auto,
            gapless: true,
          ).toImageData(210),
        );
        expect(actual!.buffer.asUint8List(), expected!.buffer.asUint8List());
        expect(
          find.textContaining(
            prepaid ? '기사에게 추가로 지급하지 마세요' : '매장 결제 금액과 Bill에 포함되지 않습니다',
          ),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets('quoted order shows VAT and complete bank transfer details', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final service = _StorefrontFixtureService(
      activeStatus: DirectOrderStatus(
        requestId: 'quoted-request',
        referenceCode: 'D1234VAT1',
        state: 'quoted',
        quote: DirectOrderQuote(
          id: 'quote-vat',
          version: 2,
          menuTotal: 200000,
          serviceChargeTotal: 10000,
          deliveryFeeTotal: 30000,
          finalTotal: 240000,
          status: 'active',
          expiresAt: DateTime.utc(2099),
          menuPretax: 181818,
          menuVat: 18182,
          serviceChargePretax: 9091,
          serviceChargeVat: 909,
          deliveryFeePretax: 30000,
          deliveryFeeVat: 0,
          vatTotal: 19091,
        ),
        messages: const [],
      ),
    );

    await tester.pumpWidget(
      _fixtureApp(service: service, locale: const Locale('ko')),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('direct_open_payment_details')),
    );
    await tester.tap(find.byKey(const Key('direct_open_payment_details')));
    await tester.pumpAndSettle();

    expect(find.text('계좌이체 안내'), findsWidgets);
    expect(find.text('포함된 VAT'), findsWidgets);
    expect(find.textContaining('Vietcombank'), findsOneWidget);
    expect(find.textContaining('123456789'), findsOneWidget);
    expect(find.text('GLOBOS VN'), findsOneWidget);
    expect(find.text('#D1234VAT1'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byKey(const Key('direct_upload_payment_proof')),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'proof review asks for an image without asking for payment again',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final service = _StorefrontFixtureService(
        activeStatus: DirectOrderStatus(
          requestId: 'proof-review-request',
          referenceCode: 'DPROOF01',
          state: 'awaiting_payment_review',
          quote: DirectOrderQuote(
            id: 'proof-review-quote',
            version: 1,
            menuTotal: 125000,
            serviceChargeTotal: 0,
            deliveryFeeTotal: 0,
            finalTotal: 125000,
            status: 'locked',
            expiresAt: DateTime.utc(2020),
            vatTotal: 9259,
          ),
          messages: const [],
          proofReview: DirectOrderProofReview(
            id: 'proof-review-1',
            reasonCode: 'blurry',
            reasonNote: '거래번호가 보이게 촬영해 주세요.',
            requestedAt: DateTime.utc(2026, 9, 10, 10),
            canResubmit: true,
          ),
        ),
      );

      await tester.pumpWidget(
        _fixtureApp(service: service, locale: const Locale('ko')),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).last, const Offset(0, -700));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('direct_upload_payment_proof')),
      );

      expect(find.textContaining('이미지가 흐림'), findsOneWidget);
      expect(find.textContaining('다시 송금하지 마세요'), findsOneWidget);
      expect(
        find.byKey(const Key('direct_open_payment_details')),
        findsNothing,
      );

      expect(find.text('이미지 다시 보내기'), findsWidgets);
      expect(find.byType(QrImageView), findsNothing);
      expect(find.textContaining('다시 송금하지 마세요'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('paused storefront shows an apology and loads order history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final service = _StorefrontFixtureService(paused: true);

    await tester.pumpWidget(
      _fixtureApp(service: service, locale: const Locale('ko')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('direct_order_closed_state')), findsOneWidget);
    expect(find.text('🙏'), findsOneWidget);
    expect(find.text(const DirectOrderCopy('ko').pausedTitle), findsOneWidget);
    expect(
      find.text(const DirectOrderCopy('ko').pausedMessage),
      findsOneWidget,
    );
    expect(find.text('즉석 떡볶이'), findsNothing);
    expect(service.ensureSessionCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paused storefront keeps an active order status visible', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    const status = DirectOrderStatus(
      requestId: 'fixture-request',
      referenceCode: 'D12345678',
      state: 'approved',
      fulfillmentStatus: 'preparing',
      messages: [],
    );
    final service = _StorefrontFixtureService(
      paused: true,
      activeStatus: status,
    );

    await tester.pumpWidget(
      _fixtureApp(service: service, locale: const Locale('ko')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('direct_order_closed_state')), findsNothing);
    expect(find.byKey(const Key('direct_order_status_title')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('direct_order_status_title')))
          .data,
      '결제 완료',
    );
    expect(service.ensureSessionCalls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('closed apology is responsive in every supported locale', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final locale in const [Locale('ko'), Locale('vi'), Locale('en')]) {
      final copy = DirectOrderCopy(locale.languageCode);
      for (final size in const [
        Size(390, 844),
        Size(768, 1024),
        Size(1024, 768),
        Size(1440, 900),
      ]) {
        tester.view.physicalSize = size;
        final service = _StorefrontFixtureService(paused: true);
        await tester.pumpWidget(_fixtureApp(service: service, locale: locale));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('direct_order_closed_state')),
          findsOneWidget,
          reason: '${locale.languageCode}:$size',
        );
        expect(find.text(copy.pausedTitle), findsOneWidget);
        expect(find.text(copy.pausedMessage), findsOneWidget);
        expect(find.text(copy.checkAgain), findsOneWidget);
        expect(find.text('🙏'), findsOneWidget);
        expect(service.ensureSessionCalls, 1);
        expect(tester.takeException(), isNull, reason: '$locale:$size');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('submit race transitions to the closed apology state', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    const saved = DirectOrderAddress(
      customerName: 'Nguyen Van A',
      customerPhone: '+84901234567',
      formattedAddress: 'Landmark 81, Bình Thạnh, Hồ Chí Minh',
      detailAddress: 'Tầng 12, căn 1201',
      latitude: 10.795,
      longitude: 106.722,
      addressSource: 'search',
      locationVerified: true,
    );
    final service = _StorefrontFixtureService(
      savedAddress: saved,
      pauseOnSubmit: true,
    );

    await tester.pumpWidget(_fixtureApp(service: service));
    await tester.pumpAndSettle();
    await _openAddress(tester);
    final submit = find.byKey(const Key('direct_submit_quote_request'));
    await tester.scrollUntilVisible(
      submit,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(service.submitCalls, 1);
    expect(find.byKey(const Key('direct_order_closed_state')), findsOneWidget);
    expect(find.text('🙏'), findsOneWidget);
    expect(find.text('Tokbokki cay'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('storefront stays usable at all required responsive widths', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final size in const [
      Size(390, 844),
      Size(768, 1024),
      Size(1024, 768),
      Size(1440, 900),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(_fixtureApp());
      await tester.pumpAndSettle();
      expect(find.text('Tokbokki cay'), findsOneWidget, reason: '$size');
      expect(tester.takeException(), isNull, reason: '$size');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('manual address submits without coordinates at $size', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const {});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final service = _StorefrontFixtureService();
      await tester.pumpWidget(_fixtureApp(service: service));
      await tester.pumpAndSettle();
      await _openAddress(tester);
      expect(find.text('Chọn trực tiếp trên bản đồ'), findsNothing);
      expect(
        find.byKey(const Key('direct_use_current_location')),
        findsNothing,
      );
      for (final entry in {
        'direct_address_input': 'Cantavil Premier, 1 Song Hanh, Ho Chi Minh',
        'direct_address_detail': 'Floor 10, 1001',
        'direct_recipient_name': 'Test Recipient',
        'direct_recipient_phone': '+84901234567',
      }.entries) {
        await tester.enterText(find.byKey(Key(entry.key)), entry.value);
      }
      await tester.ensureVisible(
        find.byKey(const Key('direct_submit_quote_request')),
      );
      await _revealSubmit(tester);
      await tester.tap(find.byKey(const Key('direct_submit_quote_request')));
      await tester.pumpAndSettle();
      expect(service.submitCalls, 1);
      expect(service.submittedAddress!.latitude, isNull);
      expect(service.submittedAddress!.longitude, isNull);
      expect(service.submittedAddress!.googlePlaceId, isNull);
      expect(service.submittedAddress!.locationVerified, isFalse);
      expect(service.submittedAddress!.addressSource, 'manual');
      expect(service.submittedAddress!.formattedAddress, contains('Cantavil'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('required fields and invalid phone prevent manual submission', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final service = _StorefrontFixtureService();
    await tester.pumpWidget(_fixtureApp(service: service));
    await tester.pumpAndSettle();
    await _openAddress(tester);
    final submit = find.byKey(const Key('direct_submit_quote_request'));
    await _revealSubmit(tester);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(service.submitCalls, 0);
    // Let the first validation snackbar leave the small viewport before the
    // next real tap, just as a customer would after reading its message.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    for (final entry in {
      'direct_diner_count_input': '3',
      'direct_address_input': '1 Song Hanh, Ho Chi Minh',
      'direct_address_detail': '1001',
      'direct_recipient_name': 'Test',
      'direct_recipient_phone': 'abc',
    }.entries) {
      await tester.enterText(find.byKey(Key(entry.key)), entry.value);
    }
    await _revealSubmit(tester);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(service.submitCalls, 0);
    expect(
      find.text('Vui lòng kiểm tra định dạng số điện thoại.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'legacy saved address stays editable and is resubmitted as manual',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      const saved = DirectOrderAddress(
        customerName: 'Saved Recipient',
        customerPhone: '+84901234567',
        formattedAddress: 'Old address, Ho Chi Minh',
        detailAddress: 'Old room',
        latitude: 10.8,
        longitude: 106.7,
        googlePlaceId: 'old-place',
        addressSource: 'search',
        locationVerified: true,
      );
      final service = _StorefrontFixtureService(savedAddress: saved);
      await tester.pumpWidget(_fixtureApp(service: service));
      await tester.pumpAndSettle();
      await _openAddress(tester);
      final input = find.byKey(const Key('direct_address_input'));
      expect(
        tester.widget<TextField>(input).controller!.text,
        saved.formattedAddress,
      );
      await tester.enterText(input, 'New address, Ho Chi Minh');
      await tester.scrollUntilVisible(
        find.byKey(const Key('direct_submit_quote_request')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await _revealSubmit(tester);
      await tester.tap(find.byKey(const Key('direct_submit_quote_request')));
      await tester.pumpAndSettle();
      expect(
        service.submittedAddress!.formattedAddress,
        'New address, Ho Chi Minh',
      );
      expect(service.submittedAddress!.latitude, isNull);
      expect(service.submittedAddress!.locationVerified, isFalse);
      expect(service.submittedRememberAddress, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('sent chat message renders without a second status round trip', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    const status = DirectOrderStatus(
      requestId: 'fixture-request',
      referenceCode: 'D12345678',
      state: 'awaiting_quote',
      messages: [],
    );
    final service = _StorefrontFixtureService(
      activeStatus: status,
      orderSummaries: [
        DirectOrderSummary(
          requestId: status.requestId,
          referenceCode: status.referenceCode,
          state: 'cancelled',
          createdAt: DateTime.utc(2026, 9, 10),
          itemCount: 1,
          hasOpenProofReview: false,
        ),
      ],
    );

    await tester.pumpWidget(_fixtureApp(service: service));
    await tester.pumpAndSettle();
    expect(service.fetchStatusCalls, 1);

    await tester.drag(find.byType(ListView).last, const Offset(0, -800));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Nhập tin nhắn'),
      'Xin chào',
    );
    await tester.ensureVisible(find.byTooltip('Gửi'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Gửi'));
    await tester.pumpAndSettle();
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    expect(service.sendMessageCalls, 1);
    await tester.drag(find.byType(ListView).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.text('Xin chào', skipOffstage: false), findsOneWidget);
    expect(
      service.fetchStatusCalls,
      1,
      reason: 'successful send is appended locally instead of refetching',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'customer sees three payment and fulfillment stages in their locale',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      const status = DirectOrderStatus(
        requestId: 'fixture-request',
        referenceCode: 'D12345678',
        state: 'approved',
        fulfillmentStatus: 'preparing',
        messages: [],
      );

      await tester.pumpWidget(
        _fixtureApp(
          service: _StorefrontFixtureService(activeStatus: status),
          locale: const Locale('ko'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('direct_order_customer_progress')),
        findsOneWidget,
      );
      expect(find.text('확인 대기'), findsOneWidget);
      expect(find.text('결제 완료'), findsWidgets);
      expect(find.text('완료'), findsOneWidget);
      expect(find.text('조리 중'), findsOneWidget);
      final statusTitle = tester.widget<Text>(
        find.byKey(const Key('direct_order_status_title')),
      );
      expect(statusTitle.data, '결제 완료');
      for (var index = 0; index < 3; index++) {
        expect(
          find.byKey(Key('direct_order_progress_step_$index')),
          findsOneWidget,
        );
      }
      await _captureCustomerUi(tester, 'customer-paid-ko');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'item requests survive locale changes, cart review and submission',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final service = _StorefrontFixtureService();
      await tester.pumpWidget(_fixtureApp(service: service));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('direct_add_tteokbokki')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('direct_menu_request_tteokbokki')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('direct_item_request_input_tteokbokki')),
        '파 제외',
      );
      await tester.tap(find.byKey(const Key('direct_item_request_save')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _fixtureApp(service: service, locale: const Locale('ko')),
      );
      await tester.pumpAndSettle();
      expect(find.text('메뉴 요청사항: 파 제외'), findsOneWidget);
      await _captureCustomerUi(tester, 'menu-item-request-ko');
      await tester.tap(find.text('배달 · 장바구니 보기 · 1'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('direct_cart_sheet')),
          matching: find.text('메뉴 요청사항: 파 제외'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('direct_cart_close')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_fixtureApp(service: service));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Địa chỉ').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('direct_diner_count_input')),
        '3',
      );
      for (final entry in {
        'direct_address_input': 'Fixture Street, Ho Chi Minh',
        'direct_address_detail': 'Door 1',
        'direct_recipient_name': 'Fixture Recipient',
        'direct_recipient_phone': '+84901234567',
      }.entries) {
        await tester.enterText(find.byKey(Key(entry.key)), entry.value);
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('direct_submit_quote_request')),
        300,
        scrollable: find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(
        find.byKey(const Key('direct_submit_quote_request')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('direct_submit_quote_request')));
      await tester.pumpAndSettle();
      expect(service.submittedItemNotes, {'tteokbokki': '파 제외'});
      expect(service.submitCalls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'driver-paid delivery fee is unconfirmed rather than shown as zero',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final service = _StorefrontFixtureService(
        activeStatus: DirectOrderStatus(
          requestId: 'fixture-request',
          referenceCode: 'DFIXTURE1',
          state: 'quoted',
          messages: const [],
          quote: DirectOrderQuote(
            id: 'quote',
            menuTotal: 108000,
            serviceChargeTotal: 0,
            deliveryFeeTotal: 0,
            finalTotal: 108000,
            status: 'active',
            expiresAt: DateTime.utc(2099),
            vatTotal: 8000,
            deliveryPaymentMode: 'customer_direct',
          ),
        ),
      );
      await tester.pumpWidget(
        _fixtureApp(service: service, locale: const Locale('ko')),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).last, const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(find.text('배송비 미정 · 기사에게 직접 결제'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'completed order details use stored items and show tax and separate delivery payment',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final status = DirectOrderStatus(
        requestId: 'fixture-request',
        referenceCode: 'DFIXTURE1',
        state: 'approved',
        createdAt: DateTime.utc(2026, 10, 6, 2, 15),
        fulfillmentStatus: 'completed',
        messages: const [],
        customer: const DirectOrderCustomerDetails(
          customerName: '저장된 고객',
          customerPhone: 'Fixture phone',
          formattedAddress: '저장된 배송지',
          detailAddress: '7층, 경비실 옆',
          district: 'Fixture district',
          ward: 'Fixture ward',
          customerNote: '도착 전에 연락 주세요\n문 앞에서 기다려 주세요',
        ),
        delivery: const DirectOrderDelivery(dinerCount: 4, paidTotal: 108000),
        items: const [
          DirectOrderItemSnapshot(
            menuItemId: 'old-menu',
            nameKo: '주문 당시 메뉴',
            nameVi: 'Món đã đặt',
            nameEn: 'Ordered item',
            unitPrice: 100000,
            quantity: 1,
            note: '파 제외',
          ),
        ],
        quote: DirectOrderQuote(
          id: 'old-quote',
          menuTotal: 108000,
          serviceChargeTotal: 0,
          deliveryFeeTotal: 0,
          finalTotal: 108000,
          status: 'locked',
          expiresAt: DateTime.utc(2026),
          vatTotal: 8000,
          deliveryPaymentMode: 'customer_direct',
        ),
      );
      final service = _StorefrontFixtureService(activeStatus: status);
      await tester.pumpWidget(
        _fixtureApp(service: service, locale: const Locale('ko')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('direct_open_order_details')),
      );
      await tester.tap(find.byKey(const Key('direct_open_order_details')));
      await tester.pumpAndSettle();
      expect(find.text(DirectOrderCopy('ko').packingCount(4)), findsWidgets);
      expect(find.text('받는 분: 저장된 고객'), findsOneWidget);
      expect(find.text('전화번호: Fixture phone'), findsOneWidget);
      expect(
        find.text('${DirectOrderCopy('ko').detailAddress}: 7층, 경비실 옆'),
        findsOneWidget,
      );
      expect(find.text('주문 요청사항: 도착 전에 연락 주세요\n문 앞에서 기다려 주세요'), findsOneWidget);
      await _captureCustomerUi(tester, 'order-customer-information-ko');
      await tester.scrollUntilVisible(
        find.text('메뉴 요청사항: 파 제외'),
        250,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('direct_order_details_list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('주문 당시 메뉴'), findsOneWidget);
      expect(find.text('메뉴 요청사항: 파 제외'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('총 결제금액'),
        250,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('direct_order_details_list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('총 결제금액'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('direct_order_details_list')),
          matching: find.text('기사에게 별도 지급 · 매장 결제에 미포함'),
        ),
        findsOneWidget,
      );
      expect(
        service.fetchStatusCalls,
        1,
        reason: 'Opening existing details needs no per-item API calls',
      );
      await _captureCustomerUi(tester, 'completed-order-details-ko');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'push permission is explicit and an unfinished enable survives closing settings',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final push = _CustomerPushFixture()
        ..pendingEnable = Completer<DirectOrderPushReadiness>();
      await tester.pumpWidget(
        _fixtureApp(pushService: push, locale: const Locale('ko')),
      );
      await tester.pumpAndSettle();
      expect(push.restores, 1);
      expect(push.explicitEnables, 0);
      await tester.tap(find.byKey(const Key('direct_customer_notifications')));
      await tester.pumpAndSettle();
      await _captureCustomerUi(tester, 'customer-notification-settings-ko');
      await tester.tap(find.byKey(const Key('direct_customer_push_toggle')));
      await tester.pump();
      expect(push.explicitEnables, 1);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('direct_customer_push_toggle')),
            )
            .onPressed,
        isNull,
      );
      Navigator.of(
        tester.element(find.byKey(const Key('direct_customer_push_toggle'))),
      ).pop();
      await tester.pumpAndSettle();
      push.pendingEnable!.complete(DirectOrderPushReadiness.ready);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('direct_customer_notifications')));
      await tester.pumpAndSettle();
      expect(
        find.text(DirectOrderCopy('ko').disableCustomerNotifications),
        findsOneWidget,
      );
      push.disableResult = DirectOrderPushReadiness.error;
      await tester.tap(find.byKey(const Key('direct_customer_push_toggle')));
      await tester.pumpAndSettle();
      expect(
        find.text(DirectOrderCopy('ko').disableCustomerNotifications),
        findsOneWidget,
      );
      expect(push.disables, 1);
      push.disableResult = DirectOrderPushReadiness.off;
      await tester.tap(find.byKey(const Key('direct_customer_push_toggle')));
      await tester.pumpAndSettle();
      expect(
        find.text(DirectOrderCopy('ko').enableCustomerNotifications),
        findsOneWidget,
      );
      expect(push.disables, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
