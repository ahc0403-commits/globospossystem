import 'dart:async';
import 'dart:convert';

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

class _PhotoService extends DirectOrderStaffService {
  bool photo = true;
  bool resubmissionPending = false;
  bool failDetail = false;
  String photoQuoteId = 'quote';
  String photoId = 'photo';
  String? approvalError;
  bool loseApprovalResponse = false;
  String state = 'awaiting_payment_review';
  int approvals = 0;
  num? confirmedAmount;
  String? confirmedQuote;
  String? confirmedPhoto;
  Completer<void>? approvalBarrier;

  @override
  Future<List<Map<String, dynamic>>> listRequests({
    required String storeId,
    List<String>? states,
    String? fulfillmentType,
    int limit = 100,
  }) async => [
    {'id': 'request', 'reference_code': 'D2A54A36B', 'state': state},
  ];

  @override
  Future<Map<String, dynamic>> requestDetail({
    required String storeId,
    required String requestId,
  }) async {
    if (failDetail) throw StateError('detail unavailable');
    return {
      'request': {
        'id': requestId,
        'reference_code': 'D2A54A36B',
        'state': state,
        'fulfillment_type': 'delivery',
      },
      'items': <Map<String, dynamic>>[],
      'quotes': [
        {
          'id': 'quote',
          'version': 1,
          'status': 'locked',
          'final_total': 255240,
          'menu_total': 255240,
          'delivery_payment_mode': 'customer_direct',
        },
      ],
      'messages': [
        if (photo)
          {
            'id': photoId,
            'request_id': requestId,
            'sender_type': 'customer',
            'message_type': 'payment_proof',
            'has_attachment': true,
            'metadata': {'quote_id': photoQuoteId, 'quote_version': 1},
          },
      ],
      'proof_reviews': [
        if (resubmissionPending)
          {'id': 'review', 'status': 'requested', 'reason_code': 'blurry'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>?> verifiedPaymentEvidence({
    required String storeId,
    required String requestId,
  }) => throw StateError('Photo review must not call SePay');

  @override
  Future<List<Map<String, dynamic>>> sepayCandidates({
    required String storeId,
    required String requestId,
  }) => throw StateError('Photo review must not call SePay');

  @override
  Future<Map<String, dynamic>> recordReceipt({
    required String storeId,
    required String requestId,
    required String quoteId,
    required String proofMessageId,
    required num amount,
    required String bankReference,
  }) => approve(
    storeId: storeId,
    requestId: requestId,
    confirmedAmount: amount,
    quoteId: quoteId,
    proofMessageId: proofMessageId,
  );

  @override
  Future<Map<String, dynamic>> approve({
    required String storeId,
    required String requestId,
    required num confirmedAmount,
    required String quoteId,
    required String proofMessageId,
  }) async {
    approvals++;
    this.confirmedAmount = confirmedAmount;
    confirmedQuote = quoteId;
    confirmedPhoto = proofMessageId;
    if (approvalError != null) {
      throw PostgrestException(message: approvalError!);
    }
    await approvalBarrier?.future;
    state = 'approved';
    if (loseApprovalResponse) throw TimeoutException('Approval response lost');
    return {
      'request_id': requestId,
      'payment_id': 'payment',
      'ticket_id': 'ticket',
    };
  }
}

Future<void> _pump(WidgetTester tester, _PhotoService service) async {
  tester.view.physicalSize = const Size(1450, 1700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/cashier/direct-orders',
    routes: [
      GoRoute(
        path: '/cashier/direct-orders',
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
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _fillReceipt(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('direct_actual_received_amount')),
    '255240',
  );
  await tester.enterText(
    find.byKey(const Key('direct_bank_receipt_reference')),
    'bank-fixture',
  );
  await tester.tap(find.byKey(const Key('direct_actual_receipt_verified')));
  await tester.pumpAndSettle();
}

void main() {
  final rpcRequests = <http.Request>[];
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'photo-test-anon',
      httpClient: MockClient((request) async {
        rpcRequests.add(request);
        return http.Response(
          '{"request_id":"request","ticket_id":"ticket"}',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());

  test(
    'staff service sends exact reviewed photo, quote and amount to RPC',
    () async {
      rpcRequests.clear();
      await const DirectOrderStaffService().approve(
        storeId: 'store',
        requestId: 'request',
        confirmedAmount: 255240,
        quoteId: 'quote',
        proofMessageId: 'photo',
      );
      final request = rpcRequests.single;
      expect(
        request.url.path,
        '/rest/v1/rpc/direct_order_approve_photo_payment',
      );
      expect(jsonDecode(request.body), {
        'p_store_id': 'store',
        'p_request_id': 'request',
        'p_confirmed_amount': 255240,
        'p_quote_id': 'quote',
        'p_proof_message_id': 'photo',
      });
    },
  );

  testWidgets('customer photo enables manual approval without SePay', (
    tester,
  ) async {
    final service = _PhotoService();
    await _pump(tester, service);
    final review = find.byKey(const Key('direct_order_photo_approval'));
    expect(tester.widget<FilledButton>(review).onPressed, isNotNull);
    expect(service.approvals, 0);
    await tester.tap(review);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('direct_actual_received_amount')),
      findsOneWidget,
    );
    expect(find.textContaining('255.240'), findsWidgets);
    expect(find.text('View image'), findsWidgets);
    expect(service.approvals, 0);
    await _fillReceipt(tester);
    await tester.tap(find.byKey(const Key('direct_order_approval_confirm')));
    await tester.pumpAndSettle();
    expect(service.approvals, 1);
    expect(service.confirmedAmount, 255240);
    expect(service.confirmedQuote, 'quote');
    expect(service.confirmedPhoto, 'photo');
    expect(review, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scenario in ['missing photo', 'different quote', 'resubmission']) {
    testWidgets('$scenario disables approval with visible reason', (
      tester,
    ) async {
      final service = _PhotoService();
      if (scenario == 'missing photo') service.photo = false;
      if (scenario == 'different quote') service.photoQuoteId = 'old-quote';
      if (scenario == 'resubmission') service.resubmissionPending = true;
      await _pump(tester, service);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('direct_order_photo_approval')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const Key('direct_order_photo_approval_blocked')),
        findsOneWidget,
      );
      expect(service.approvals, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('refresh failure hides stale approval and offers retry', (
    tester,
  ) async {
    final service = _PhotoService();
    await _pump(tester, service);
    service.failDetail = true;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('direct_order_photo_approval')), findsNothing);
    expect(find.text(DirectOrderCopy('en').loadFailed), findsOneWidget);
    service.failDetail = false;
    await tester.tap(find.text(DirectOrderCopy('en').retry));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('direct_order_photo_approval')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('in-flight staff approval cannot be clicked twice', (
    tester,
  ) async {
    final service = _PhotoService()..approvalBarrier = Completer<void>();
    await _pump(tester, service);
    await tester.tap(find.byKey(const Key('direct_order_photo_approval')));
    await tester.pumpAndSettle();
    await _fillReceipt(tester);
    await tester.tap(find.byKey(const Key('direct_order_approval_confirm')));
    await tester.pumpAndSettle();
    expect(service.approvals, 1);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('direct_order_photo_approval')),
          )
          .onPressed,
      isNull,
    );
    service.approvalBarrier!.complete();
    await tester.pumpAndSettle();
    expect(service.approvals, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a replaced photo invalidates an open confirmation', (
    tester,
  ) async {
    final service = _PhotoService();
    await _pump(tester, service);
    await tester.tap(find.byKey(const Key('direct_order_photo_approval')));
    await tester.pumpAndSettle();
    service.photoId = 'replacement';
    await tester.pump(const Duration(seconds: 35));
    await tester.pumpAndSettle();
    await _fillReceipt(tester);
    await tester.tap(find.byKey(const Key('direct_order_approval_confirm')));
    await tester.pumpAndSettle();
    expect(service.approvals, 0);
    expect(
      find.text(
        DirectOrderCopy(
          'en',
        ).errorMessage('DIRECT_ORDER_PAYMENT_REVIEW_CHANGED'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('server rejection stays pending and shows the actual reason', (
    tester,
  ) async {
    final service = _PhotoService()
      ..approvalError = 'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED';
    await _pump(tester, service);
    await tester.tap(find.byKey(const Key('direct_order_photo_approval')));
    await tester.pumpAndSettle();
    await _fillReceipt(tester);
    await tester.tap(find.byKey(const Key('direct_order_approval_confirm')));
    await tester.pumpAndSettle();
    expect(service.approvals, 1);
    expect(service.state, 'awaiting_payment_review');
    expect(find.text(DirectOrderCopy('en').approvalSuccess), findsNothing);
    expect(
      find.text(
        DirectOrderCopy(
          'en',
        ).errorMessage('DIRECT_ORDER_PAYMENT_REVIEW_CHANGED'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('direct_order_photo_approval')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('lost approval response refreshes the completed order', (
    tester,
  ) async {
    final service = _PhotoService()..loseApprovalResponse = true;
    await _pump(tester, service);
    await tester.tap(find.byKey(const Key('direct_order_photo_approval')));
    await tester.pumpAndSettle();
    await _fillReceipt(tester);
    await tester.tap(find.byKey(const Key('direct_order_approval_confirm')));
    await tester.pumpAndSettle();
    expect(service.approvals, 1);
    expect(service.state, 'approved');
    expect(find.byKey(const Key('direct_order_photo_approval')), findsNothing);
    expect(
      find.text(DirectOrderCopy('en').stateLabel('approved')),
      findsWidgets,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('manual review copy describes photo review in KO VI EN', () {
    for (final language in ['ko', 'vi', 'en']) {
      final copy = DirectOrderCopy(language);
      expect(copy.supportingEvidence, isNot(contains('SePay')));
      expect(copy.manualApprovalCheck, isNot(contains('verified bank')));
      expect(copy.reviewPaymentAmount, isNotEmpty);
      expect(copy.photoAwaitingSubmission, isNotEmpty);
    }
  });
}
