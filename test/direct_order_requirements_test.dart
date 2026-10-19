import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/hardware/print_job_agent_service.dart';
import 'package:globos_pos_system/core/hardware/receipt_builder.dart';
import 'package:globos_pos_system/features/digital_receipt/digital_receipt_model.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_requirements.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _q = DirectOrderRequirement(
  id: 'request-note',
  version: 2,
  requestText: '덜 맵게 해주세요',
  status: 'awaiting_customer',
  sourceLocale: 'ko',
  replyText: '소스를 줄여 준비하겠습니다. 기본 소스에도 매운맛이 조금 있습니다. 이렇게 준비해도 괜찮으실까요?',
  replyMessageId: 'reply-2',
  printRequestVi: 'Ít cay',
  printReplyVi: 'Giảm sốt, sốt gốc vẫn hơi cay',
  printScope: 'preparation',
);

Widget _app(Widget child, {String locale = 'ko'}) => MaterialApp(
  theme: ThemeData(fontFamily: 'Pretendard'),
  debugShowCheckedModeBanner: false,
  locale: Locale(locale),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: RepaintBoundary(
    key: const Key('request_visual'),
    child: Scaffold(
      appBar: AppBar(title: const Text('GLOBOS · D12345678')),
      body: SingleChildScrollView(child: child),
    ),
  ),
);

Future<void> _capture(WidgetTester tester, String name) async {
  final directory =
      Platform.environment['DIRECT_ORDER_REQUIREMENT_SCREENSHOTS'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('request_visual')),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['DIRECT_ORDER_REQUIREMENT_SCREENSHOTS'] == null) {
      return;
    }
    await (FontLoader(
      'Pretendard',
    )..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test(
    'public decisions carry scope and reply identity in one request',
    () async {
      final calls = <Map<String, dynamic>>[];
      final service = DirectOrderService(
        invoker: (body) async {
          calls.add(body);
          return {
            'request_id': 'order',
            'store_id': 'store',
            'reference_code': 'D12345678',
            'state': 'quoted',
            'created_at': '2026-10-10T00:00:00Z',
            'items': [],
            'messages': [],
            'requirements': [
              {
                'id': 'request-note',
                'version': 2,
                'request_text': '덜 맵게 해주세요',
                'status': 'confirmed',
                'reply_message_id': 'reply-2',
              },
            ],
          };
        },
      );
      final session = DirectOrderSession(
        id: 'order',
        secret: 'fixture',
        expiresAt: DateTime.utc(2099),
        orderScoped: true,
      );
      final result = await service.decideRequirement(
        session: session,
        requestId: 'order',
        requirement: _q,
        accept: true,
      );
      expect(calls, hasLength(1));
      expect(calls.single, containsPair('action', 'decide_requirement'));
      expect(calls.single, containsPair('order_scoped', true));
      expect(calls.single, containsPair('expected_version', 2));
      expect(calls.single, containsPair('reply_message_id', 'reply-2'));
      expect(result.requirements.single.isConfirmed, isTrue);
    },
  );

  test(
    'paper alphabet accepts Vietnamese and rejects silently dropped scripts',
    () {
      expect(
        directOrderPrintableVi('Ít cay, để sốt riêng; gọi trước khi đến.'),
        isTrue,
      );
      expect(directOrderPrintableVi('맵지 않게'), isFalse);
      expect(directOrderPrintableVi('Готово'), isFalse);
      expect(directOrderPrintableVi('Sốt\u001b@test'), isFalse);
    },
  );

  for (final locale in ['ko', 'vi', 'en']) {
    testWidgets('request confirmation fits a 320px $locale phone', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 760);
      addTearDown(tester.view.reset);
      var confirmations = 0;
      var clarifications = 0;
      await tester.pumpWidget(
        _app(
          DirectOrderRequirementCard(
            requirement: _q,
            cashier: false,
            onConfirm: () => confirmations++,
            onClarify: () => clarifications++,
          ),
          locale: locale,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_q.requestText), findsOneWidget);
      expect(find.text(_q.replyText!), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('requirement_confirm_request-note')),
      );
      await tester.tap(
        find.byKey(const Key('requirement_clarify_request-note')),
      );
      expect(confirmations, 1);
      expect(clarifications, 1);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'customer-requirement-$locale');
    });
  }

  testWidgets('cashier composes a real reply and reviewed paper text', (
    tester,
  ) async {
    DirectOrderRequirementReply? reply;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              reply = await showDialog<DirectOrderRequirementReply>(
                context: context,
                builder: (_) =>
                    const DirectOrderRequirementReplyDialog(requirement: _q),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('가능합니다'), findsNothing);
    expect(find.text('어렵습니다'), findsNothing);
    await tester.enterText(
      find.byKey(const Key('requirement_reply_body')),
      '소스는 별도 포장하고 양파도 빼겠습니다.',
    );
    await tester.enterText(
      find.byKey(const Key('requirement_print_reply')),
      'Để sốt riêng và không hành',
    );
    await tester.ensureVisible(
      find.byKey(const Key('requirement_reply_submit')),
    );
    await tester.tap(find.byKey(const Key('requirement_reply_submit')));
    await tester.pumpAndSettle();
    expect(reply!.body, '소스는 별도 포장하고 양파도 빼겠습니다.');
    expect(reply!.printReplyVi, 'Để sốt riêng và không hành');
    expect(reply!.needsConfirmation, isTrue);
  });

  testWidgets(
    'unanswered request retains its reply action without approval buttons',
    (tester) async {
      const pending = DirectOrderRequirement(
        id: 'pending',
        version: 1,
        requestText: '도착 전에 전화해주세요',
        status: 'awaiting_reply',
        sourceLocale: 'ko',
      );
      await tester.pumpWidget(
        _app(
          const DirectOrderRequirementCard(requirement: pending, cashier: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('답변 필요'), findsOneWidget);
      expect(find.text('요청에 답변하기'), findsOneWidget);
      expect(find.text('이 내용으로 확정'), findsNothing);
      await _capture(tester, 'cashier-request-due-ko');
    },
  );

  testWidgets(
    'customer writes a custom clarification and dialog disposes cleanly',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showRequirementClarification(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('requirement_customer_followup')),
        '그러면 소스를 별도로 주세요',
      );
      await tester.tap(find.widgetWithText(FilledButton, '답변 전송'));
      await tester.pumpAndSettle();
      expect(result, '그러면 소스를 별도로 주세요');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'customer sees pending translation on a Vietnamese cashier reply',
    (tester) async {
      const q = DirectOrderRequirement(
        id: 'translated',
        version: 2,
        requestText: '소스를 별도로 주세요',
        sourceLocale: 'ko',
        status: 'awaiting_customer',
        replyText: 'Sẽ để sốt riêng',
        replyLocale: 'vi',
        replyTranslationStatus: 'pending',
      );
      await tester.pumpWidget(
        _app(const DirectOrderRequirementCard(requirement: q, cashier: false)),
      );
      await tester.pumpAndSettle();
      expect(find.text('자동 번역 중'), findsOneWidget);
      expect(find.text('Sẽ để sốt riêng'), findsOneWidget);
    },
  );

  test(
    'additional slip has reference and agreement, without a payment total',
    () async {
      final ticket = PrintTicket.fromPayload({
        'ticket': 'request_update',
        'direct_order_reference': 'D12345678',
        'at': '2026-10-10T12:00:00Z',
        'order_notes': 'Yêu cầu: Ít cay\nĐã thống nhất: Để sốt riêng',
        'items': [],
      });
      final text = String.fromCharCodes(
        await ReceiptBuilder.buildRequestUpdate(ticket),
      );
      expect(text, contains('YEU CAU BO SUNG DA THONG NHAT'));
      expect(text, contains('D12345678'));
      expect(text, contains('Xac nhan: 2026-10-10 19:00'));
      expect(text, contains('De sot rieng'));
      expect(text, isNot(contains('TONG CONG')));
      expect(text, isNot(contains('DA THANH TOAN')));
    },
  );

  test('driver copy receives the agreed delivery instructions', () async {
    final ticket = PrintTicket.fromPayload({
      'ticket': 'delivery_driver_receipt',
      'order_notes': 'Sẽ gọi trước khi đến',
      'items': [],
    });
    final text = String.fromCharCodes(
      await ReceiptBuilder.buildKitchenTicket(ticket),
    );
    expect(text, contains('Se goi truoc khi den'));
  });

  test(
    'digital receipt keeps base notes and separately displays later agreements',
    () {
      final receipt = DigitalReceipt.fromJson({
        'order_notes': 'Yêu cầu đã thống nhất',
        'request_addenda': [
          {'order_notes': 'Để sốt riêng'},
        ],
      });
      expect(receipt.orderNotes, 'Yêu cầu đã thống nhất');
      expect(receipt.requestAddenda, ['Để sốt riêng']);
    },
  );

  for (final size in [1, 10, 50]) {
    test(
      'printer destinations and endpoints use two reads for $size destinations',
      () async {
        final calls = <String>[];
        final client = SupabaseClient(
          'https://fixture.supabase.co',
          'fixture',
          httpClient: MockClient((request) async {
            calls.add(request.url.path);
            final rows = List.generate(
              size,
              (i) => request.url.path.endsWith('printer_destinations')
                  ? {
                      'id': 'dest-$i',
                      'name': 'Printer $i',
                      'ip': '127.0.0.1',
                      'port': 9100,
                      'purpose': 'receipt',
                      'physical_printer_id': 'physical-$i',
                    }
                  : {
                      'id': 'endpoint-$i',
                      'physical_printer_id': 'physical-$i',
                      'endpoint_type': 'wifi',
                      'ip': '127.0.0.1',
                      'port': 9100,
                      'priority': 1,
                      'is_active': true,
                    },
            );
            return http.Response(
              jsonEncode(rows),
              200,
              request: request,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(client.dispose);
        final destinations = await SupabasePrintJobBackend(
          client,
        ).loadDestinations(List.generate(size, (i) => 'dest-$i'));
        expect(destinations, hasLength(size));
        expect(calls, hasLength(2));
        expect(destinations['dest-0']!.endpoints, hasLength(1));
      },
    );
  }
}
