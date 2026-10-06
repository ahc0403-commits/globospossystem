import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/hardware/receipt_builder.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_storefront_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Service extends DirectOrderService {
  bool paused = false;
  bool unavailable = false;
  bool? accepted;
  bool? transferred;
  String state = 'approved';
  int resumes = 0;
  final session = DirectOrderSession(
    id: 'session',
    secret: 'secret',
    expiresAt: DateTime.now().add(const Duration(days: 1)),
  );
  DirectOrderStatus get status => DirectOrderStatus(
    requestId: 'same-order',
    referenceCode: 'D12345678',
    state: state,
    fulfillmentStatus: state == 'approved' ? 'ready' : null,
    messages: const [],
    delivery: DirectOrderDelivery(
      dinerCount: 3,
      method: accepted == true ? 'pickup' : 'delivery',
      version: accepted == true ? 2 : 1,
      storeName: 'Test Store',
      storeAddress: '123 Store Street',
      paidTotal: 129600,
      offer: DirectOrderPickupOffer(
        id: 'offer',
        status: accepted == null
            ? 'proposed'
            : accepted!
            ? 'accepted'
            : 'declined',
        reason: 'No drivers nearby',
        refundDue: 21600,
      ),
    ),
  );
  DirectOrderStorefront get storefront => DirectOrderStorefront(
    storeId: 'store',
    storeName: 'Test Store',
    slug: 'test-store',
    paused: paused,
    minimumOrderAmount: 0,
    defaultLatitude: 10.8,
    defaultLongitude: 106.7,
    googleMapsBrowserKey: null,
    bank: const DirectOrderBank(
      bin: '970457',
      accountNumber: '123456789',
      accountHolder: 'TEST',
      label: 'Test Bank',
    ),
    categories: const [],
    items: const [],
  );
  @override
  Future<DirectOrderStorefront> fetchStorefront(String slug) async {
    if (unavailable) {
      throw const DirectOrderException('DIRECT_ORDER_UNAVAILABLE');
    }
    return storefront;
  }

  @override
  Future<DirectOrderSession?> loadCachedSession(String slug) async =>
      unavailable ? session : null;
  @override
  Future<DirectOrderSession> ensureSession({
    required String slug,
    required String locale,
  }) async => session;
  @override
  Future<DirectOrderStorefront> resumeStorefront(
    DirectOrderSession session,
  ) async {
    resumes++;
    paused = true;
    return storefront;
  }

  @override
  Future<DirectOrderStatus> fetchStatus({
    required DirectOrderSession session,
    required String requestId,
  }) async => status;
  @override
  Future<List<DirectOrderSummary>> listOrders({
    required DirectOrderSession session,
  }) async => [
    DirectOrderSummary(
      requestId: 'same-order',
      referenceCode: 'D12345678',
      state: 'approved',
      fulfillmentStatus: 'ready',
      createdAt: DateTime.now(),
      itemCount: 1,
      hasOpenProofReview: false,
    ),
  ];
  @override
  Future<void> decidePickup({
    required DirectOrderSession session,
    required String requestId,
    required String offerId,
    required bool accept,
    bool alreadyPaid = false,
  }) async {
    expect(requestId, 'same-order');
    expect(offerId, 'offer');
    accepted = accept;
    transferred = alreadyPaid;
    if (accept && state == 'quoted' && !alreadyPaid) state = 'awaiting_quote';
  }
}

Widget _app(_Service service, String language) => ProviderScope(
  child: MaterialApp(
    locale: Locale(language),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: DirectOrderStorefrontScreen(slug: 'test-store', service: service),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'submit sends the versioned diner contract and invalid counts never invoke the server',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final service = DirectOrderService(
        invoker: (body) async {
          bodies.add(body);
          return {
            'request_id': 'order',
            'reference_code': 'D12345678',
            'state': 'awaiting_quote',
            'idempotent': false,
          };
        },
      );
      final session = DirectOrderSession(
        id: 'session',
        secret: 'secret',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
      Future<void> submit(int? count) async {
        await service.submit(
          slug: 'test-store',
          session: session,
          locale: 'en',
          cart: {'menu': 1},
          itemNotes: {},
          address: const DirectOrderAddress(
            customerName: 'Customer',
            customerPhone: '0901234567',
            formattedAddress: 'Test Address',
            detailAddress: 'Door 1',
          ),
          rememberAddress: false,
          dinerCount: count,
        );
      }

      for (final count in [null, 0, -1, 101]) {
        await expectLater(submit(count), throwsA(isA<DirectOrderException>()));
      }
      expect(bodies, isEmpty);
      await submit(3);
      expect(bodies.single['action'], 'submit_v3');
      expect((bodies.single['payload'] as Map)['diner_count'], 3);
    },
  );

  test(
    'versioned status parses pickup, refunds and linkless providers while keeping V2 valid',
    () {
      final base = <String, dynamic>{
        'request_id': 'same-order',
        'store_id': 'store',
        'reference_code': 'D12345678',
        'state': 'approved',
        'created_at': '2026-10-05T01:00:00Z',
        'items': <dynamic>[],
        'messages': <dynamic>[],
        'quote': null,
        'fulfillment': null,
        'dispatch': null,
        'proof_review': null,
      };
      expect(DirectOrderStatus.fromJson(base).delivery, isNull);
      final delivery = <String, dynamic>{
        'diner_count': 3,
        'method': 'pickup',
        'version': 2,
        'store_name': 'Test Store',
        'store_address': '123 Store Street',
        'provider': 'other',
        'provider_name': 'Local courier',
        'tracking_url': null,
        'driver_contact': '0901234567',
        'paid_total': 129600,
        'refunded_total': 21600,
        'pickup_offer': {
          'id': 'offer',
          'status': 'accepted',
          'reason': 'No driver',
          'refund_due': 21600,
          'refund_recorded': true,
          'refunded_at': '2026-10-05T02:00:00Z',
        },
      };
      final status = DirectOrderStatus.fromJson({
        ...base,
        'delivery': delivery,
      });
      expect(status.delivery!.isPickup, true);
      expect(status.delivery!.dinerCount, 3);
      expect(
        status.delivery!.paidTotal! - status.delivery!.refundedTotal,
        108000,
      );
      expect(status.delivery!.offer!.refundRecorded, true);
      expect(status.delivery!.driverContact, '0901234567');
      expect(
        () => DirectOrderStatus.fromJson({...base, 'delivery': 'malformed'}),
        throwsFormatException,
      );
      expect(
        () => DirectOrderDelivery.fromJson({...delivery, 'diner_count': 1.5}),
        throwsFormatException,
      );
      expect(
        () => DirectOrderDelivery.fromJson({
          ...delivery,
          'paid_total': double.nan,
        }),
        throwsFormatException,
      );
    },
  );

  for (final language in ['ko', 'vi', 'en']) {
    testWidgets(
      'pickup consent preserves the order and shows packing and refund in $language',
      (tester) async {
        final service = _Service();
        final copy = DirectOrderCopy(language);
        await tester.pumpWidget(_app(service, language));
        await tester.pumpAndSettle();
        expect(find.text(copy.packingCount(3)), findsOneWidget);
        final accept = find.byKey(const Key('direct_accept_pickup'));
        await tester.ensureVisible(accept);
        await tester.pumpAndSettle();
        await tester.tap(accept);
        await tester.pumpAndSettle();
        expect(service.accepted, true);
        await tester.drag(find.byType(ListView).first, const Offset(0, 1200));
        await tester.pumpAndSettle();
        expect(find.text('D12345678'), findsOneWidget);
        expect(find.byKey(const Key('direct_pickup_offer')), findsNothing);
        expect(find.text(copy.pickup), findsWidgets);
        expect(
          find.byKey(const Key('direct_order_progress_step_2')),
          findsOneWidget,
        );
        expect(find.text(copy.progressGrabHandoff), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final paid in [false, true]) {
    testWidgets(
      'quoted pickup asks whether the customer already transferred: $paid',
      (tester) async {
        final service = _Service()..state = 'quoted';
        final copy = DirectOrderCopy('en');
        await tester.pumpWidget(_app(service, 'en'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('direct_accept_pickup')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('direct_accept_pickup')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('direct_pickup_payment_status_dialog')),
          findsOneWidget,
        );
        await tester.tap(
          find.text(paid ? copy.alreadyTransferred : copy.notTransferred),
        );
        await tester.pumpAndSettle();
        expect(service.accepted, true);
        expect(service.transferred, paid);
        expect(service.state, paid ? 'quoted' : 'awaiting_quote');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets(
    'declining pickup keeps delivery and the three customer progress stages',
    (tester) async {
      final service = _Service();
      await tester.pumpWidget(_app(service, 'en'));
      await tester.pumpAndSettle();
      final decline = find.byKey(const Key('direct_decline_pickup'));
      await tester.ensureVisible(decline);
      await tester.pumpAndSettle();
      await tester.tap(decline);
      await tester.pumpAndSettle();
      expect(service.accepted, false);
      expect(
        find.byKey(const Key('direct_order_progress_step_2')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('a disabled storefront resumes a cached customer order', (
    tester,
  ) async {
    final service = _Service()..unavailable = true;
    await tester.pumpWidget(_app(service, 'en'));
    await tester.pumpAndSettle();
    expect(service.resumes, 1);
    expect(find.byKey(const Key('direct_order_status_title')), findsOneWidget);
    expect(find.byKey(const Key('direct_order_closed_state')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'CLOSED blocks an existing customer adding another order and lets them return',
    (tester) async {
      final service = _Service();
      final copy = DirectOrderCopy('en');
      await tester.pumpWidget(_app(service, 'en'));
      await tester.pumpAndSettle();
      service.paused = true;
      final add = find.text(copy.addOrder);
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('direct_order_closed_state')),
        findsOneWidget,
      );
      await tester.tap(find.text(copy.orderStatus));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('direct_order_status_title')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'pickup handoff receipt prints utensil count without the delivery address',
    () async {
      final bytes = await ReceiptBuilder.buildDeliveryDriverReceipt(
        restaurantName: 'Test',
        referenceCode: 'D12345678',
        customerName: 'Customer',
        customerPhone: '0901234567',
        formattedAddress: 'SECRET_DELIVERY_ADDRESS',
        detailAddress: 'PRIVATE_ROOM',
        items: const [
          ReceiptItem(name: 'Food', quantity: 1, unitPrice: 100000),
        ],
        menuTotal: 108000,
        serviceChargeTotal: 0,
        deliveryFeeTotal: 21600,
        finalTotal: 129600,
        printedAt: DateTime.utc(2026, 10, 5),
        dinerCount: 3,
        isPickup: true,
        refundedTotal: 21600,
      );
      final text = String.fromCharCodes(bytes);
      expect(text, contains('PHIEU NHAN MANG VE'));
      expect(text, contains('SO NGUOI: 3'));
      expect(text, contains('DUNG CU: 3 BO'));
      expect(text, isNot(contains('SECRET_DELIVERY_ADDRESS')));
      expect(text, isNot(contains('PRIVATE_ROOM')));
      expect(text, contains('Da hoan:'));
    },
  );
}
