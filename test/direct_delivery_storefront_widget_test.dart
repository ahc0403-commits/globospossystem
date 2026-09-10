import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_storefront_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StorefrontFixtureService extends DirectOrderService {
  _StorefrontFixtureService({
    this.savedAddress,
    this.activeStatus,
    this.orderSummaries,
    this.paused = false,
    this.pauseOnSubmit = false,
  });

  final DirectOrderAddress? savedAddress;
  final DirectOrderStatus? activeStatus;
  final List<DirectOrderSummary>? orderSummaries;
  final bool paused;
  final bool pauseOnSubmit;
  DirectOrderAddress? submittedAddress;
  bool? submittedRememberAddress;
  int submitCalls = 0;
  int clearAddressCalls = 0;
  int clearActiveRequestCalls = 0;
  var fetchStatusCalls = 0;
  var sendMessageCalls = 0;
  var ensureSessionCalls = 0;

  @override
  Future<DirectOrderStorefront> fetchStorefront(String slug) async =>
      DirectOrderStorefront(
        storeId: 'fixture-store',
        storeName: 'GLOBOS BUNSIK',
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
        categories: const [
          DirectOrderCategory(
            id: 'popular',
            nameKo: '인기 메뉴',
            nameVi: 'Món phổ biến',
            nameEn: 'Popular',
            sortOrder: 1,
          ),
        ],
        items: const [
          DirectOrderMenuItem(
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
        ],
      );

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
  Future<DirectOrderSubmission> submit({
    required String slug,
    required DirectOrderSession session,
    String? draftId,
    required String locale,
    required Map<String, int> cart,
    required Map<String, String> itemNotes,
    required DirectOrderAddress address,
    required bool rememberAddress,
    String? customerNote,
  }) async {
    submitCalls++;
    submittedAddress = address;
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
}) => ProviderScope(
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
    ),
  ),
);

Future<void> _openAddress(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('direct_add_tteokbokki')));
  await tester.pump();
  await tester.tap(find.text('Địa chỉ').last);
  await tester.pumpAndSettle();
}

void main() {
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
    expect(find.text('배달 중 · 메뉴 2개'), findsOneWidget);
    expect(find.text('견적 완료 · 메뉴 1개'), findsOneWidget);
    expect(find.text('주문이 완료되었습니다 · 메뉴 3개'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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

    expect(find.text('계좌이체 안내'), findsOneWidget);
    expect(find.text('포함된 VAT'), findsWidgets);
    expect(find.textContaining('Vietcombank'), findsOneWidget);
    expect(find.textContaining('123456789'), findsOneWidget);
    expect(find.text('GLOBOS VN'), findsOneWidget);
    expect(find.text('#D1234VAT1'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(
      find.byKey(const Key('direct_upload_payment_proof')),
      findsOneWidget,
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
            expiresAt: DateTime.utc(2099),
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
        find.byKey(const Key('direct_open_payment_details')),
      );

      expect(find.textContaining('이미지가 흐림'), findsOneWidget);
      expect(find.textContaining('다시 송금하지 마세요'), findsOneWidget);
      await tester.tap(find.byKey(const Key('direct_open_payment_details')));
      await tester.pumpAndSettle();

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
    expect(find.text('현재 배달 주문을 잠시 쉬고 있습니다'), findsOneWidget);
    expect(
      find.text(
        '현재 주문량이 많아 새 배달 주문을 받기 어렵습니다. 불편을 드려 정말 죄송합니다. 잠시 후 다시 주문해 주세요.',
      ),
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
      '조리 중',
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
      scrollable: find.byType(Scrollable).last,
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
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(service.submitCalls, 0);
    // Let the first validation snackbar leave the small viewport before the
    // next real tap, just as a customer would after reading its message.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    for (final entry in {
      'direct_address_input': '1 Song Hanh, Ho Chi Minh',
      'direct_address_detail': '1001',
      'direct_recipient_name': 'Test',
      'direct_recipient_phone': 'abc',
    }.entries) {
      await tester.enterText(find.byKey(Key(entry.key)), entry.value);
    }
    await tester.ensureVisible(submit);
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
    'customer sees the five-stage delivery progress in their locale',
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
      expect(find.text('주문 확인'), findsOneWidget);
      expect(find.text('입금 확인'), findsOneWidget);
      expect(find.text('메뉴 조리 중'), findsOneWidget);
      expect(find.text('배달 중'), findsOneWidget);
      expect(find.text('주문 완료'), findsOneWidget);
      final statusTitle = tester.widget<Text>(
        find.byKey(const Key('direct_order_status_title')),
      );
      expect(statusTitle.data, '조리 중');
      for (var index = 0; index < 5; index++) {
        expect(
          find.byKey(Key('direct_order_progress_step_$index')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
