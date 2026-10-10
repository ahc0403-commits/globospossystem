import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_cashier_screen.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_requirements.dart';
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
  bool prepaid = false;
  double? verifiedFee;
  bool proposed = false;
  bool refunded = false;
  int diners = 3;
  int version = 1;
  String ticketStatus = 'ready';
  String state = 'approved';
  String? sentProvider;
  final sentMessages = <String>[];
  String? sentUrl;
  List<Map<String, dynamic>> requirements = [];
  DirectOrderRequirementReply? requirementReply;
  String? bankReference;
  int? sentTicketVersion;
  String? customerNote;
  String? itemNote;
  bool failRequirementReply = false;
  final requirementMutations = <String>[];

  @override
  Future<Map<String, dynamic>> replyRequirement({
    required String storeId,
    required String requestId,
    required DirectOrderRequirement requirement,
    required DirectOrderRequirementReply reply,
    required String locale,
    required String mutationId,
  }) async {
    requirementReply = reply;
    requirementMutations.add(mutationId);
    expect(requirement.id, 'note');
    expect(requirement.version, 1);
    expect(mutationId, isNotEmpty);
    if (failRequirementReply) throw StateError('simulated response failure');
    requirements = [
      {
        ...requirements.single,
        'status': 'awaiting_customer',
        'version': 2,
        'reply_text': reply.body,
        'reply_message_id': 'reply-id',
      },
    ];
    return requestDetail(storeId: storeId, requestId: requestId);
  }

  @override
  Future<List<Map<String, dynamic>>> listRequests({
    required String storeId,
    List<String>? states,
    String? fulfillmentType,
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
    'requirements': requirements,
    'request': {
      'id': requestId,
      'state': state,
      'reference_code': 'D12345678',
      'customer_note': customerNote,
    },
    'items': <Map<String, dynamic>>[
      if (itemNote != null)
        {
          'name_ko': '김밥',
          'name_vi': 'Kimbap',
          'name_en': 'Kimbap',
          'quantity': 2,
          'unit_price': 49000,
          'item_note': itemNote,
        },
    ],
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
    'messages': <Map<String, dynamic>>[
      {
        'id': 'evidence',
        'sender_type': 'cashier',
        'message_type': 'attachment',
        'body': 'evidence.jpg',
        'metadata': {'filename': 'evidence.jpg'},
      },
    ],
    'address': {
      'customer_name': 'Customer',
      'customer_phone': '0901234567',
      'formatted_address': 'Customer address',
      'detail_address': 'Door 1',
    },
    'financial': {
      'final_total': 129600,
      'delivery_fee_total': 21600,
      'delivery_payment_mode': pickup || prepaid
          ? 'store_prepaid'
          : 'customer_direct',
    },
    'support': {
      if (verifiedFee != null) 'delivery_cost': {'actual_fee': verifiedFee},
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
  Future<Map<String, dynamic>> sendMessage({
    required String storeId,
    required String requestId,
    required String message,
  }) async {
    sentMessages.add(message);
    return {
      'message_id': 'fixture-message',
      'created_at': DateTime.utc(2026, 10, 6).toIso8601String(),
    };
  }

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
  Future<Map<String, dynamic>> supportAction({
    required String storeId,
    required String requestId,
    required int expectedVersion,
    required String action,
    Map<String, dynamic> payload = const {},
  }) async {
    expect(action, 'refund_original_pickup');
    expect(payload['amount'], 21600);
    expect(payload['method'], 'BANKTRANSFER');
    expect(payload['evidence_message_id'], 'evidence');
    refunded = true;
    bankReference = payload['reference'] as String;
    return {};
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
    bool cashConfirmed = false,
    String? evidenceMessageId,
    String? operationId,
    String? cashReference,
  }) async {
    expect(requestId, 'request');
    expect(actualGrabFee, prepaid ? verifiedFee : null);
    sentProvider = provider;
    sentUrl = grabUrl;
    sentTicketVersion = expectedVersion;
    ticketStatus = 'dispatched';
  }
}

Future<void> _confirmEvidence(WidgetTester tester, String reference) async {
  await tester.enterText(
    find.byKey(const Key('direct_money_reference')),
    reference,
  );
  await tester.tap(find.byKey(const Key('direct_money_evidence')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('evidence.jpg').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('direct_money_paid_confirmed')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('direct_money_confirm')));
  await tester.pumpAndSettle();
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
    'cashier must answer each request before a quote, using custom text',
    (tester) async {
      final service = _Staff()
        ..state = 'awaiting_quote'
        ..requirements = [
          {
            'id': 'note',
            'version': 1,
            'request_text': 'Xin sốt riêng',
            'source_locale': 'vi',
            'status': 'awaiting_reply',
          },
        ];
      await _pump(tester, service, language: 'vi');
      expect(find.byKey(const Key('requirement_quote_gate')), findsOneWidget);
      final button = find.widgetWithText(
        FilledButton,
        DirectOrderCopy('vi').sendQuote,
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await _tap(tester, find.byKey(const Key('requirement_reply_note')));
      await tester.enterText(
        find.byKey(const Key('requirement_reply_body')),
        'Sẽ để sốt riêng trong hai hộp nhỏ. Bạn đồng ý không?',
      );
      await _tap(tester, find.byKey(const Key('requirement_reply_submit')));
      expect(
        service.requirementReply!.body,
        'Sẽ để sốt riêng trong hai hộp nhỏ. Bạn đồng ý không?',
      );
      expect(
        service.requirementReply!.printReplyVi,
        service.requirementReply!.body,
      );
      expect(service.requirementReply!.needsConfirmation, isTrue);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.text('Chờ khách xác nhận'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cashier clarification retry retains freeform draft and mutation identity',
    (tester) async {
      final service = _Staff()
        ..state = 'awaiting_quote'
        ..failRequirementReply = true
        ..requirements = [
          {
            'id': 'note',
            'version': 1,
            'request_text': 'Xin sốt riêng',
            'followup_text': 'Chia hai hộp được không?',
            'source_locale': 'vi',
            'status': 'awaiting_reply',
          },
        ];
      await _pump(tester, service, language: 'vi');
      await _tap(tester, find.byKey(const Key('requirement_reply_note')));
      const answer = 'Sẽ chia sốt thành hai hộp nhỏ.';
      await tester.enterText(
        find.byKey(const Key('requirement_reply_body')),
        answer,
      );
      await _tap(tester, find.byKey(const Key('requirement_reply_submit')));
      expect(service.requirementMutations, hasLength(1));
      await _tap(tester, find.byKey(const Key('requirement_reply_note')));
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('requirement_reply_body')),
            )
            .controller!
            .text,
        answer,
      );
      service.failRequirementReply = false;
      await _tap(tester, find.byKey(const Key('requirement_reply_submit')));
      expect(service.requirementMutations, hasLength(2));
      expect(service.requirementMutations[1], service.requirementMutations[0]);
      expect(service.requirementReply!.body, answer);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'staff shows persisted item_note, whole-order note, contact and diner count',
    (tester) async {
      final service = _Staff()
        ..customerNote = '수령 전에 연락\n문 앞에서 기다려 주세요'
        ..itemNote = '파 제외\n소스 별도';
      await _pump(tester, service, language: 'ko');
      expect(find.text(DirectOrderCopy('ko').packingCount(3)), findsWidgets);
      final details = find.byKey(const Key('direct_staff_detail_list'));
      final scrollable = find
          .descendant(of: details, matching: find.byType(Scrollable))
          .first;
      for (final text in [
        '받는 분: Customer',
        '전화번호: 0901234567',
        '${DirectOrderCopy('ko').detailAddress}: Door 1',
        '주문 요청사항: 수령 전에 연락\n문 앞에서 기다려 주세요',
        '메뉴 요청사항: 파 제외\n소스 별도',
      ]) {
        await tester.scrollUntilVisible(
          find.text(text),
          150,
          scrollable: scrollable,
        );
        expect(find.text(text), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
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
        await _confirmEvidence(tester, 'bank-transfer-ref-123');
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
  for (final prepaid in [false, true]) {
    testWidgets(
      'verified driver cost follows the payment mode: prepaid=$prepaid',
      (tester) async {
        final service = _Staff()
          ..prepaid = prepaid
          ..verifiedFee = 15000;
        final copy = DirectOrderCopy('en');
        await _pump(tester, service);
        await tester.scrollUntilVisible(
          find.byKey(const Key('direct_driver_contact')),
          300,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('direct_staff_detail_list')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        if (prepaid) {
          final input = tester.widget<TextField>(
            find.byKey(const Key('direct_order_actual_grab_fee_input')),
          );
          expect(input.readOnly, isTrue);
          expect(input.controller!.text, '15.000');
        }
        await tester.enterText(
          find.byKey(const Key('direct_driver_contact')),
          '0901234567',
        );
        await _tap(
          tester,
          find.widgetWithText(FilledButton, copy.handoffDriver),
        );
        if (prepaid) await _confirmEvidence(tester, 'cash handoff');
        expect(service.ticketStatus, 'dispatched');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('staff selects and edits a template before sending once', (
    tester,
  ) async {
    final service = _Staff();
    await _pump(tester, service);
    await _tap(tester, find.byKey(const Key('direct_chat_templates')));
    await _tap(tester, find.byKey(const Key('direct_chat_template_address')));
    final field = tester.widget<TextField>(
      find.byKey(const Key('direct_staff_chat_input')),
    );
    expect(field.controller!.text, contains('D12345678'));
    expect(field.controller!.text, contains('Customer address Door 1'));
    expect(service.sentMessages, isEmpty);
    await tester.enterText(
      find.byKey(const Key('direct_staff_chat_input')),
      'Edited fixture message',
    );
    await _tap(tester, find.byKey(const Key('direct_staff_chat_send')));
    expect(service.sentMessages, ['Edited fixture message']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
