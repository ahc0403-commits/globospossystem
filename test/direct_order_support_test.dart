import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_staff_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_support.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const chargeId = '11111111-1111-4111-8111-111111111111';
final session = DirectOrderSession(
  id: 'session',
  secret: 'fixture',
  expiresAt: DateTime.utc(2099),
);
const bank = DirectOrderBank(
  bin: '970436',
  accountNumber: 'fixture',
  accountHolder: 'Fixture',
  label: 'Fixture bank',
);

class _Staff extends DirectOrderStaffService {
  final actions = <String>[];
  final payloads = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> saveBuyerInformation({
    required String storeId,
    required String requestId,
    required int expectedVersion,
    required Map<String, dynamic> patch,
  }) async {
    actions.add('pos_buyer');
    payloads.add(patch);
    return {'version': expectedVersion + 1};
  }

  @override
  Future<Map<String, dynamic>> supportAction({
    required String storeId,
    required String requestId,
    required int expectedVersion,
    required String action,
    Map<String, dynamic> payload = const {},
  }) async {
    actions.add(action);
    payloads.add(payload);
    return {};
  }
}

Future<void> pumpSupport(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Pretendard'),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

DirectOrderStatus status(String chargeState) => DirectOrderStatus(
  requestId: 'request',
  referenceCode: 'DTEST1234',
  state: 'approved',
  messages: const [],
  support: {
    'chat_open': true,
    'delivery_fee_finalized': true,
    'charges': [
      {
        'id': chargeId,
        'kind': 'delivery',
        'amount': 15000,
        'received': 0,
        'reason': 'Additional actual delivery cost',
        'status': chargeState,
      },
    ],
  },
);
void main() {
  final requests = <http.Request>[];
  var commits = 0;
  var saved = false;
  var lostUpload = false;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final font = FontLoader('Pretendard')
      ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'));
    await font.load();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'fixture',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.contains('/functions/')) {
          final body = jsonDecode(request.body) as Map;
          if (body['action'] == 'staff_chat_attachment_commit') {
            commits++;
            return http.Response(
              saved
                  ? jsonEncode({
                      'data': {
                        'message_id': 'fixture-message',
                        'created_at': '2026-10-08T00:00:00Z',
                      },
                    })
                  : jsonEncode({'error': 'PROOF_UPLOAD_INCOMPLETE'}),
              saved ? 200 : 409,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'data': {'token': 'fixture-token'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        saved = true;
        if (lostUpload) {
          lostUpload = false;
          throw http.ClientException('lost upload response');
        }
        return http.Response(
          jsonEncode({'Key': 'fixture'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());
  setUp(() {
    requests.clear();
    commits = 0;
    saved = false;
    lostUpload = false;
  });
  testWidgets(
    'receipt review requires actual amount, bank reference and explicit comparison',
    (tester) async {
      DirectOrderReceiptReview? result;
      await pumpSupport(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDirectOrderReceiptReview(context, 108000);
            },
            child: const Text('Review'),
          ),
        ),
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('direct_order_approval_confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('direct_actual_received_amount')),
            )
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('direct_actual_received_amount')),
        '100000',
      );
      await tester.enterText(
        find.byKey(const Key('direct_bank_receipt_reference')),
        'transaction-fixture',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.tap(find.byKey(const Key('direct_actual_receipt_verified')));
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.enterText(
        find.byKey(const Key('direct_actual_received_amount')),
        '109000',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      expect(find.textContaining('Overpayment to refund'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('direct_actual_received_amount')),
        '100000',
      );
      await tester.pump();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(result!.amount, 100000);
      expect(result!.reference, 'transaction-fixture');
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
  testWidgets(
    'verified shipping asks for payment directly and legacy demands await store review',
    (tester) async {
      final calls = <Map<String, dynamic>>[];
      final service = DirectOrderService(
        invoker: (body) async {
          calls.add(body);
          return {};
        },
      );
      Widget panel(String state) => DirectOrderCustomerSupportPanel(
        status: status(state),
        session: session,
        bank: bank,
        storeId: 'store',
        service: service,
        onChanged: () async {},
      );
      await pumpSupport(tester, panel('awaiting_consent'));
      expect(find.byType(QrImageView), findsNothing);
      expect(find.byType(DirectOrderAttachmentButton), findsNothing);
      expect(find.text('Agree to delivery fee'), findsNothing);
      expect(calls, isEmpty);
      expect(
        find.text('The store is verifying actual delivery cost.'),
        findsOneWidget,
      );
      await pumpSupport(tester, panel('pending'));
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.byType(DirectOrderAttachmentButton), findsOneWidget);
      expect(find.textContaining('15.000'), findsWidgets);
    },
  );
  testWidgets(
    'cashier reconciliation requires a provider reference and cost attachment',
    (tester) async {
      final service = _Staff();
      await pumpSupport(
        tester,
        DirectOrderStaffSupportPanel(
          storeId: 'store',
          requestId: 'request',
          service: service,
          onChanged: () async {},
          detail: {
            'messages': [
              {
                'id': 'cost-evidence',
                'sender_type': 'cashier',
                'message_type': 'attachment',
                'body': 'Grab booking evidence',
                'metadata': {'filename': 'grab-cost.png'},
              },
            ],
            'request': {'state': 'approved'},
            'financial': {'delivery_payment_mode': 'store_prepaid'},
            'delivery': {'method': 'delivery'},
            'support': {
              'version': 5,
              'delivery_fee_deferred': false,
              'delivery_fee_finalized': true,
              'food_due': 0,
              'food_received': 138000,
              'invoice': {},
              'charges': [],
            },
          },
        ),
      );
      await tester.tap(find.text('Reconcile actual delivery fee'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '15000');
      await tester.enterText(fields.at(1), 'GRAB-BOOKING-001');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.widgetWithText(
          DropdownButtonFormField<String>,
          'Delivery cost evidence',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('grab-cost.png').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(service.actions, ['reconcile_delivery_fee']);
      final payload = service.payloads.single;
      expect(payload['amount'], 15000);
      expect(payload['provider'], 'grab');
      expect(payload['reference'], 'GRAB-BOOKING-001');
      expect(payload['evidence_message_id'], 'cost-evidence');
      expect(payload['operation_id'], isNotEmpty);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
  testWidgets('VAT invoice draft is saved on the customer request', (
    tester,
  ) async {
    final service = _Staff();
    await pumpSupport(
      tester,
      DirectOrderStaffSupportPanel(
        storeId: 'store',
        requestId: 'request',
        service: service,
        onChanged: () async {},
        detail: {
          'request': {'state': 'awaiting_quote'},
          'support': {
            'version': 1,
            'invoice': {'requested': false},
            'charges': [],
          },
        },
      ),
    );
    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Request VAT invoice'),
    );
    await tester.pumpAndSettle();
    for (final field in {
      'buyer_number_value': '0012345678',
      'buyer_legal_name': 'Company fixture',
      'buyer_address': 'Billing address',
      'buyer_email': 'fixture@example.test',
      'buyer_phone': '0900000000',
    }.entries) {
      await tester.ensureVisible(find.byKey(Key('pos_${field.key}')));
      await tester.enterText(find.byKey(Key('pos_${field.key}')), field.value);
    }
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(service.actions, ['pos_buyer']);
    expect(service.payloads.single['buyer_number_type'], 'vn_tax');
    expect(service.payloads.single['buyer_number_value'], '0012345678');
    await tester.pump(const Duration(milliseconds: 500));
  });
  testWidgets('unrefunded cancellation keeps close-conversation disabled', (
    tester,
  ) async {
    await pumpSupport(
      tester,
      DirectOrderStaffSupportPanel(
        storeId: 'store',
        requestId: 'request',
        service: _Staff(),
        onChanged: () async {},
        detail: {
          'request': {'state': 'cancelled'},
          'support': {
            'version': 1,
            'invoice': {},
            'charges': [],
            'refund_due': 100000,
            'chat_open': true,
          },
        },
      ),
    );
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Close refund conversation'),
          )
          .onPressed,
      isNull,
    );
  });
  test(
    'staff attachment unwraps Edge response and recovers a lost Storage response',
    () async {
      lostUpload = true;
      const service = DirectOrderStaffService();
      Future<void> send() => service.uploadChatAttachment(
        storeId: 'store',
        requestId: 'request',
        path: 'store/request/fixture.png',
        filename: 'fixture.png',
        mimeType: 'image/png',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      await expectLater(send(), throwsA(isA<http.ClientException>()));
      await send();
      expect(requests.where((r) => r.url.path.contains('/storage/')).length, 1);
      expect(commits, 2);
    },
  );
  test(
    'customer supplementary proof recovers a lost commit without reupload',
    () async {
      var stored = false;
      var fail = true;
      var uploads = 0;
      final service = DirectOrderService(
        invoker: (body) async {
          if (body['action'] == 'customer_attachment_upload') {
            return {'token': 'fixture'};
          }
          if (!stored) {
            throw const DirectOrderException('PROOF_UPLOAD_INCOMPLETE');
          }
          if (fail) {
            fail = false;
            throw TimeoutException('lost commit');
          }
          return {'message_id': 'fixture'};
        },
        proofUploader: (path, token, bytes, mime) async {
          uploads++;
          stored = true;
        },
      );
      Future<void> send() => service.uploadSupportAttachment(
        session: session,
        requestId: 'request',
        chargeId: chargeId,
        path: 'store/request/fixture.png',
        filename: 'fixture.png',
        mimeType: 'image/png',
        bytes: Uint8List.fromList([1]),
      );
      await expectLater(send(), throwsA(isA<TimeoutException>()));
      await send();
      expect(uploads, 1);
    },
  );
  test(
    'kitchen notes keep identical menus with different requests in separate groups',
    () {
      EmergencyFulfillmentItem item(String id, String? note) =>
          EmergencyFulfillmentItem(
            id: id,
            orderItemId: id,
            nameKo: '계란말이',
            nameVi: 'Trứng cuộn',
            nameEn: 'Egg roll',
            orderedQuantity: 1,
            kitchenDoneQuantity: 0,
            trayReceivedQuantity: 0,
            trayDispatchedQuantity: 0,
            floorServedQuantity: 0,
            needsReview: false,
            notes: note,
          );
      final groups = buildKitchenChecketMenuGroups([
        EmergencyFulfillmentOrder(
          queueId: 'q',
          orderId: 'o',
          queueNo: 1,
          tableNumber: '1',
          floorLabel: '1',
          createdAt: DateTime(2026),
          items: [
            item('1', 'không hành lá'),
            item('2', null),
            item('3', 'không hành lá'),
          ],
        ),
      ]);
      expect(groups.length, 2);
      expect(groups.first.notes, 'không hành lá');
      expect(groups.first.pendingQuantity, 2);
      expect(groups.last.pendingQuantity, 1);
    },
  );
  testWidgets(
    'cashier records supplemental pickup refund without food refund',
    (tester) async {
      final staff = _Staff();
      await pumpSupport(
        tester,
        DirectOrderStaffSupportPanel(
          storeId: 'store',
          requestId: 'request',
          service: staff,
          onChanged: () async {},
          detail: const {
            'request': {'state': 'approved'},
            'messages': [
              {
                'id': 'evidence',
                'sender_type': 'cashier',
                'message_type': 'attachment',
                'body': 'refund.jpg',
                'metadata': {'filename': 'refund.jpg'},
              },
            ],
            'delivery': {'method': 'pickup'},
            'support': {'version': 2, 'pickup_delivery_refund_due': 20000},
          },
        ),
      );
      await tester.tap(
        find.textContaining('Record additional delivery refund for pickup'),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('direct_money_reference')),
        'pickup-refund-fixture',
      );
      await tester.tap(find.byKey(const Key('direct_money_evidence')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('refund.jpg').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('direct_money_confirm')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('direct_money_paid_confirmed')));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(staff.actions, ['refund_delivery_complete']);
      expect(staff.payloads.single['amount'], 20000);
      expect(staff.payloads.single['evidence_message_id'], 'evidence');
      expect(staff.payloads.single['method'], 'BANKTRANSFER');
      expect(staff.payloads.single['reference'], 'pickup-refund-fixture');
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
  testWidgets('render localized staff support acceptance screen', (
    tester,
  ) async {
    const capture = bool.fromEnvironment('DIRECT_ORDER_SUPPORT_CAPTURE');
    final key = GlobalKey();
    await pumpSupport(
      tester,
      RepaintBoundary(
        key: key,
        child: DirectOrderStaffSupportPanel(
          storeId: 'store',
          requestId: 'request',
          service: _Staff(),
          onChanged: () async {},
          detail: {
            'request': {'state': 'approved'},
            'financial': {'delivery_payment_mode': 'store_prepaid'},
            'delivery': {'method': 'delivery'},
            'support': {
              'version': 1,
              'food_received': 138000,
              'food_due': 0,
              'actual_received': 155000,
              'overpayment_due': 17000,
              'refund_account': {
                'bank': 'Fixture Bank',
                'account': 'fixture-account',
                'holder': 'Fixture Customer',
              },
              'driver_cash': {
                'paid': 15000,
                'recovered_cash': 0,
                'recovered_bank': 0,
                'movements': <Map<String, dynamic>>[],
              },
              'delivery_received': 0,
              'delivery_fee_finalized': true,
              'invoice': {'requested': true, 'legal_name': '샘플 회사'},
              'charges': [
                {
                  'id': chargeId,
                  'kind': 'delivery',
                  'amount': 15000,
                  'received': 0,
                  'reason': '실제 배송비가 안내 금액보다 증가하여 차액 추가 청구',
                  'status': 'awaiting_consent',
                },
              ],
            },
          },
        ),
      ),
      locale: const Locale('ko'),
    );
    expect(find.text('미수금: 15.000 VND'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '실제 배송비 정산'),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
    if (capture) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final pixels = await boundary.toImage(pixelRatio: 1);
        final bytes = await pixels.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '.dart_tool/direct_order_support_staff.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
    }
    tester.view.physicalSize = const Size(320, 900);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
