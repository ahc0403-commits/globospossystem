import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_storefront_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';

import 'fixtures/direct_order_notice_capture.dart';

const _request = '90000000-0000-4000-8000-000000000001';
const _key = 'fixture-random-order-key-with-at-least-40-characters';
const _location = '/order/fixture/r/$_request#access=$_key';

class _LinkService extends DirectOrderService {
  _LinkService()
    : super(
        invoker: (body) async {
          if (body['action'] == 'resume_order') {
            expect(body['session_id'], _request);
            expect(body['secret'], _key);
            return {
              'session_id': _request,
              'secret': _key,
              'expires_at': '2099-01-01T00:00:00Z',
              'order_scoped': true,
            };
          }
          expect(body['action'], 'message');
          expect(body['order_scoped'], true);
          expect(body['request_id'], _request);
          expect(body['secret'], _key);
          return {
            'message_id': 'sent-message',
            'created_at': '2026-10-09T02:00:00Z',
          };
        },
      );

  bool closed = false;
  bool completedPickup = false;
  bool completedDelivery = false;
  double overpaymentDue = 0;
  bool refundEvidenceAvailable = false;
  bool chatOpen = true;
  bool pickupRefunded = false;
  int restored = 0;
  final List<DirectOrderMessage> messages = [];

  @override
  Future<DirectOrderMessage> sendMessage({
    required DirectOrderSession session,
    required String requestId,
    required String message,
  }) async {
    final sent = await super.sendMessage(
      session: session,
      requestId: requestId,
      message: message,
    );
    messages.add(sent);
    return sent;
  }

  @override
  Future<DirectOrderSession> resumeOrder({
    required String slug,
    required String requestId,
    required String accessKey,
  }) {
    restored++;
    if (closed) throw const DirectOrderException('DIRECT_ORDER_ORDER_CLOSED');
    return super.resumeOrder(
      slug: slug,
      requestId: requestId,
      accessKey: accessKey,
    );
  }

  @override
  Future<DirectOrderStorefront> fetchStorefront(String slug) async =>
      DirectOrderStorefront(
        storeId: 'store',
        storeName: 'Fixture Store',
        slug: slug,
        paused: false,
        minimumOrderAmount: 0,
        defaultLatitude: 10.8,
        defaultLongitude: 106.7,
        googleMapsBrowserKey: null,
        bank: const DirectOrderBank(
          bin: '970457',
          accountNumber: '123456789',
          accountHolder: 'FIXTURE',
          label: 'Bank',
        ),
        categories: const [],
        items: const [],
      );

  @override
  Future<List<DirectOrderSummary>> listOrders({
    required DirectOrderSession session,
  }) async {
    expect(session.orderScoped, true);
    return [
      DirectOrderSummary(
        requestId: _request,
        referenceCode: 'DLINK0001',
        state: 'approved',
        createdAt: DateTime.utc(2026, 10, 9),
        itemCount: 1,
        hasOpenProofReview: false,
        fulfillmentStatus: 'ready',
      ),
    ];
  }

  @override
  Future<DirectOrderStatus> fetchStatus({
    required DirectOrderSession session,
    required String requestId,
  }) async {
    expect(session.orderScoped, true);
    expect(requestId, _request);
    return DirectOrderStatus(
      requestId: _request,
      referenceCode: 'DLINK0001',
      state: 'approved',
      fulfillmentStatus: completedPickup || completedDelivery
          ? 'completed'
          : 'ready',
      messages: List.of(messages),
      support: {
        'chat_open': chatOpen,
        'overpayment_due': overpaymentDue,
        'refund_evidence_available': refundEvidenceAvailable,
      },
      delivery: completedPickup
          ? DirectOrderDelivery(
              dinerCount: 1,
              method: 'pickup',
              version: 2,
              storeName: 'Fixture Store',
              storeAddress: 'Store address',
              paidTotal: 129600,
              offer: DirectOrderPickupOffer(
                id: 'offer',
                status: 'accepted',
                reason: 'Driver unavailable',
                refundDue: 18000,
                refundRecorded: pickupRefunded,
              ),
            )
          : null,
    );
  }
}

Future<GoRouter> _pump(
  WidgetTester tester,
  _LinkService service, {
  String language = 'en',
}) async {
  final router = GoRouter(
    initialLocation: _location,
    routes: [
      GoRoute(
        path: '/order/:slug/r/:requestId',
        builder: (_, state) => DirectOrderStorefrontScreen(
          slug: state.pathParameters['slug']!,
          requestId: state.pathParameters['requestId'],
          accessKey: Uri.splitQueryString(state.uri.fragment)['access'],
          service: service,
          statusSafetyRefreshInterval: const Duration(seconds: 1),
          statusSafetyRefreshJitter: Duration.zero,
        ),
      ),
      GoRoute(
        path: '/order/:slug',
        builder: (_, __) => const Scaffold(body: Text('Fixture menu')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      child: RepaintBoundary(
        key: noticeCaptureKey,
        child: MaterialApp.router(
          theme: AppTheme.build(),
          locale: Locale(language),
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadNoticeFont);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final entry in <String, String>{
    'ko': '서로 다른 언어로 대화해도 메시지가 자동 번역됩니다. 편하게 채팅하세요!',
    'vi':
        'Tin nhắn được tự động dịch khi trò chuyện bằng các ngôn ngữ khác nhau. Hãy thoải mái trò chuyện!',
    'en':
        'Messages are automatically translated across languages. Feel free to chat!',
  }.entries) {
    for (final width in [390.0, 1440.0]) {
      testWidgets(
        'customer chat first entry shows separate ${entry.key} help at $width without sending a message',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final service = _LinkService();
          final router = await _pump(tester, service, language: entry.key);
          final notice = find.byKey(
            const Key('direct_auto_translation_notice'),
          );
          await tester.ensureVisible(notice);
          await tester.pumpAndSettle();
          expect(find.text(entry.value), findsOneWidget);
          expect(service.messages, isEmpty);
          expect(service.restored, 1);
          // Let the existing transient progress snackbar expire before capture.
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
          await captureNotice(
            tester,
            'customer_chat_${entry.key}_${width.toInt()}',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
        },
      );
    }
  }

  testWidgets('completed delivery keeps excess refund access and polling', (
    tester,
  ) async {
    final service = _LinkService()
      ..completedDelivery = true
      ..overpaymentDue = 12000;
    final router = await _pump(tester, service);
    expect(find.text('DLINK0001'), findsOneWidget);
    expect(find.byKey(const Key('direct_order_copy_link')), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('direct_order_access_v1_fixture_$_request'),
      _key,
    );
    service.overpaymentDue = 0;
    service.chatOpen = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(DirectOrderCopy('en').orderClosed),
      findsOneWidget,
    );
    expect(
      preferences.getString('direct_order_access_v1_fixture_$_request'),
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
  });

  testWidgets(
    'completed delivery retains recent refund evidence until closed',
    (tester) async {
      final service = _LinkService()
        ..completedDelivery = true
        ..refundEvidenceAvailable = true;
      final router = await _pump(tester, service);
      expect(find.text('DLINK0001'), findsOneWidget);
      expect(find.byKey(const Key('direct_order_copy_link')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('DLINK0001'), findsOneWidget);
      service.chatOpen = false;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(DirectOrderCopy('en').orderClosed),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    },
  );

  testWidgets(
    'a completed pickup keeps its order and chat until the delivery refund is recorded',
    (tester) async {
      final service = _LinkService()..completedPickup = true;
      final router = await _pump(tester, service);
      expect(find.text('DLINK0001'), findsOneWidget);
      expect(find.byKey(const Key('direct_order_copy_link')), findsOneWidget);
      expect(
        find.textContaining(DirectOrderCopy('en').refundPending),
        findsOneWidget,
      );
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('direct_order_access_v1_fixture_$_request'),
        _key,
      );
      service.pickupRefunded = true;
      service.chatOpen = false;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(DirectOrderCopy('en').orderClosed),
        findsOneWidget,
      );
      expect(
        preferences.getString('direct_order_access_v1_fixture_$_request'),
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    },
  );

  testWidgets(
    'the same order URL restores the order and chat after closing and clearing browser storage',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _LinkService();
      var router = await _pump(tester, service);
      expect(find.text('DLINK0001'), findsOneWidget);
      expect(find.byKey(const Key('direct_order_copy_link')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      SharedPreferences.setMockInitialValues({});
      router = await _pump(tester, service);
      expect(service.restored, 2);
      expect(find.text('DLINK0001'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('direct_customer_chat_input')),
        'Please check my delivery',
      );
      await tester.ensureVisible(find.byIcon(Icons.send_rounded));
      // The existing progress snackbar temporarily covers the bottom composer.
      // Preserve it and send after its normal display duration.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.send_rounded).hitTestable(), findsOneWidget);
      await captureNotice(tester, 'customer_send_before');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Please check my delivery'), findsWidgets);
      expect(service.messages, hasLength(1));
      expect(service.messages.single.body, 'Please check my delivery');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    },
  );

  testWidgets(
    'a closed order URL clears only that order key and offers the menu',
    (tester) async {
      final service = _LinkService()..closed = true;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        'direct_order_access_v1_fixture_$_request',
        _key,
      );
      await preferences.setString(
        'direct_order_access_v1_fixture_other',
        'other-key',
      );
      const address = DirectOrderAddress(
        customerName: 'Fixture',
        customerPhone: '0901234567',
        formattedAddress: 'Saved address',
        detailAddress: '',
      );
      await service.saveAddress('fixture', address);
      final router = await _pump(tester, service);
      expect(
        find.textContaining(DirectOrderCopy('en').orderClosed),
        findsOneWidget,
      );
      expect(
        preferences.getString('direct_order_access_v1_fixture_$_request'),
        isNull,
      );
      expect(
        preferences.getString('direct_order_access_v1_fixture_other'),
        'other-key',
      );
      expect(
        (await service.loadAddress('fixture'))!.formattedAddress,
        'Saved address',
      );
      await tester.tap(find.text(DirectOrderCopy('en').menu));
      await tester.pumpAndSettle();
      expect(find.text('Fixture menu'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    },
  );
}
