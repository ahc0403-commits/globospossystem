import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_cashier_screen.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_staff_service.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Auth extends AuthNotifier {
  _Auth() : super() {
    state = const PosAuthState(role: 'cashier', storeId: 'store');
  }
}

class _Staff extends DirectOrderStaffService {
  bool pickup = false;
  bool proposed = false;
  bool refunded = false;
  int diners = 3;
  int version = 1;
  String ticketStatus = 'ready';
  String state = 'approved';
  String? sentProvider;
  String? sentUrl;
  String? bankReference;
  int? sentTicketVersion;

  @override
  Future<List<Map<String, dynamic>>> listRequests({
    required String storeId,
    List<String>? states,
    int limit = 100,
  }) async => [
    {
      'id': 'request',
      'state': state,
      'reference_code': 'D12345678',
      'fulfillment_status': ticketStatus,
    },
  ];

  @override
  Future<Map<String, dynamic>> requestDetail({
    required String storeId,
    required String requestId,
  }) async => {
    'request': {'id': requestId, 'state': state, 'reference_code': 'D12345678'},
    'items': <Map<String, dynamic>>[],
    'quotes': <Map<String, dynamic>>[
      if (state == 'quoted')
        {
          'id': 'original-quote',
          'status': 'active',
          'delivery_fee_total': 21600,
          'final_total': 129600,
          'delivery_payment_mode': 'store_prepaid',
        },
    ],
    'messages': <Map<String, dynamic>>[],
    'address': {
      'customer_name': 'Customer',
      'customer_phone': '0901234567',
      'formatted_address': 'Customer address',
      'detail_address': 'Door 1',
    },
    'financial': {
      'final_total': 129600,
      'delivery_fee_total': 21600,
      'delivery_payment_mode': pickup ? 'store_prepaid' : 'customer_direct',
    },
    'fulfillment': {'id': 'ticket', 'status': ticketStatus, 'version': 3},
    'delivery': {
      'diner_count': diners,
      'version': version,
      'method': pickup ? 'pickup' : 'delivery',
      'paid_total': 129600,
      'refunded_total': refunded ? 21600 : 0,
      'pickup_offer': pickup || proposed
          ? {
              'id': 'offer',
              'status': pickup ? 'accepted' : 'proposed',
              'reason': 'No driver',
              'refund_due': 21600,
              'refund_recorded': refunded,
            }
          : null,
    },
  };

  @override
  Future<DirectOrderDriverReceiptStatus> driverReceiptStatus({
    required String storeId,
    required String requestId,
  }) async => const DirectOrderDriverReceiptStatus.empty();
  @override
  Future<DirectOrderDriverReceiptStatus> customerReceiptStatus({
    required String storeId,
    required String requestId,
  }) async => const DirectOrderDriverReceiptStatus.empty();
  @override
  Future<void> setDinerCount({
    required String storeId,
    required String requestId,
    required int expectedVersion,
    required int dinerCount,
  }) async {
    expect(requestId, 'request');
    expect(expectedVersion, version);
    diners = dinerCount;
    version++;
  }

  @override
  Future<void> offerPickup({
    required String storeId,
    required String requestId,
    required int expectedVersion,
    required String reason,
  }) async {
    expect(requestId, 'request');
    expect(expectedVersion, version);
    expect(reason, 'No driver in any app');
    proposed = true;
  }

  @override
  Future<void> recordPickupRefund({
    required String storeId,
    required String requestId,
    required String offerId,
    required String reference,
  }) async {
    expect(requestId, 'request');
    expect(offerId, 'offer');
    bankReference = reference;
    refunded = true;
  }

  @override
  Future<Map<String, dynamic>> completePickup({
    required String storeId,
    required String requestId,
    required int expectedVersion,
  }) async {
    expect(requestId, 'request');
    expect(expectedVersion, 3);
    ticketStatus = 'completed';
    return {'status': 'completed'};
  }

  @override
  Future<void> setDispatch({
    required String storeId,
    required String requestId,
    required String grabUrl,
    double? actualGrabFee,
    int? expectedVersion,
    String provider = 'grab',
    String? providerName,
    String? driverContact,
  }) async {
    expect(requestId, 'request');
    expect(actualGrabFee, isNull);
    sentProvider = provider;
    sentUrl = grabUrl;
    sentTicketVersion = expectedVersion;
    ticketStatus = 'dispatched';
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Staff service, {
  String language = 'en',
  Size size = const Size(1440, 960),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => DirectOrderCashierScreen(service: service),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _Auth()),
        posLiveEventsProvider(
          'store',
        ).overrideWith((ref) => const Stream<PosLiveEvent>.empty()),
      ],
      child: MaterialApp.router(
        theme: AppTheme.build(),
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('direct_staff_detail_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _enterDialog(
  WidgetTester tester,
  String value,
  DirectOrderCopy copy,
) async {
  await tester.enterText(
    find.byKey(const Key('direct_fulfillment_dialog_input')),
    value,
  );
  await _tap(tester, find.widgetWithText(FilledButton, copy.confirm));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'staff-fallback-test',
      httpClient: MockClient((request) async => http.Response('{}', 200)),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());
  testWidgets(
    'staff corrects packing count and proposes pickup without changing method',
    (tester) async {
      final service = _Staff();
      final copy = DirectOrderCopy('en');
      await _pump(tester, service);
      await _tap(tester, find.byKey(const Key('direct_edit_diner_count')));
      await _enterDialog(tester, '5', copy);
      expect(service.diners, 5);
      expect(find.text(copy.packingCount(5)), findsWidgets);
      await _tap(tester, find.byKey(const Key('direct_offer_pickup')));
      await _enterDialog(tester, 'No driver in any app', copy);
      expect(service.proposed, true);
      expect(service.pickup, false);
      expect(find.byKey(const Key('direct_delivery_provider')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'BE link is sent with the ready ticket version and no cash payout',
    (tester) async {
      final service = _Staff();
      final copy = DirectOrderCopy('en');
      await _pump(tester, service);
      final provider = find.byKey(const Key('direct_delivery_provider'));
      await tester.scrollUntilVisible(
        provider,
        400,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('direct_staff_detail_list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await _tap(tester, provider);
      await _tap(tester, find.text('BE').last);
      final urlField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == 'https://...',
      );
      await tester.enterText(urlField, 'https://be.example/track/abc');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await _tap(tester, find.widgetWithText(FilledButton, copy.handoffDriver));
      expect(service.sentProvider, 'be');
      expect(service.sentUrl, 'https://be.example/track/abc');
      expect(service.sentTicketVersion, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'a transferred pickup retains the original quote and waits for proof',
    (tester) async {
      final service = _Staff()
        ..pickup = true
        ..state = 'quoted';
      final copy = DirectOrderCopy('en');
      await _pump(tester, service);
      expect(find.text(copy.pickupOriginalPaymentHelp), findsOneWidget);
      expect(
        find.byKey(const Key('direct_order_delivery_fee_input')),
        findsNothing,
      );
      expect(service.refunded, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final language in ['ko', 'vi', 'en']) {
    testWidgets(
      'pickup completion and bank refund stay separate in $language on mobile',
      (tester) async {
        final service = _Staff()..pickup = true;
        final copy = DirectOrderCopy(language);
        await _pump(
          tester,
          service,
          language: language,
          size: const Size(390, 844),
        );
        expect(find.byKey(const Key('direct_delivery_provider')), findsNothing);
        await _tap(
          tester,
          find.byKey(const Key('direct_order_complete_pickup')),
        );
        await _tap(
          tester,
          find
              .widgetWithText(
                FilledButton,
                DirectOrderCopy(language).pickupComplete,
              )
              .last,
        );
        expect(service.ticketStatus, 'completed');
        expect(service.refunded, false);
        // Completion preserves the user's scroll offset; return to packing/refund controls.
        tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byKey(const Key('direct_staff_detail_list')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        await _tap(
          tester,
          find.byKey(const Key('direct_record_pickup_refund')),
        );
        await _enterDialog(tester, 'bank-transfer-ref-123', copy);
        expect(service.bankReference, 'bank-transfer-ref-123');
        expect(service.refunded, true);
        expect(
          find.byKey(const Key('direct_record_pickup_refund')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
