import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_cashier_screen.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_payment_document.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_staff_service.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _data({int lines = 6, bool payment = true}) => {
  'request_id': 'request',
  'reference_code': 'DFIXTURE1',
  'quote_id': 'quote',
  'quote_version': 1,
  'store_name': 'GLOBOS Fixture',
  'items': [
    for (var n = 1; n <= lines; n++)
      {
        'display_name': 'Item $n',
        'name_ko': '주문 메뉴 $n',
        'name_en': 'Item $n',
        'name_vi': 'Món ăn $n',
        'quantity': 1,
        'unit_price': 72000,
        'listed_total': 72000,
      },
  ],
  'menu_pretax': 72000 * lines,
  'menu_vat': 5760 * lines,
  'menu_total': 77760 * lines,
  'service_charge_total': 0,
  'service_charge_vat': 0,
  'final_total': 77760 * lines,
  'amount_due': 77760 * lines,
  'include_payment': payment,
  'delivery_payment_mode': 'customer_direct',
  'delivery_fee_total': 0,
  'bank': payment
      ? {
          'bin': '970457',
          'account_number': '1234567890',
          'account_holder': 'FIXTURE ONLY',
          'label': 'Fixture Bank',
        }
      : null,
};

class _Auth extends AuthNotifier {
  _Auth() : super() {
    state = const PosAuthState(role: 'cashier', storeId: 'store');
  }
}

class _Staff extends DirectOrderStaffService {
  String state = 'awaiting_quote';
  int reads = 0, quoteCalls = 0, linkCalls = 0, uploads = 0;
  bool failRefresh = false,
      loseLink = false,
      loseUpload = false,
      staleDocument = false;
  String? op, key, path;
  final committed = <String>{};
  final quoteRow = {
    'id': 'quote',
    'version': 1,
    'status': 'active',
    ..._data(),
  };
  @override
  Future<List<Map<String, dynamic>>> listRequests({
    required String storeId,
    List<String>? states,
    int limit = 100,
  }) async => [
    {'id': 'request', 'reference_code': 'DFIXTURE1', 'state': state},
  ];
  @override
  Future<Map<String, dynamic>> requestDetail({
    required String storeId,
    required String requestId,
  }) async {
    reads++;
    if (failRefresh) throw StateError('Refresh failed');
    return {
      'request': {
        'id': 'request',
        'state': state,
        'reference_code': 'DFIXTURE1',
        'delivery_policy_version': 2,
      },
      'items': _data()['items'],
      'delivery': {'method': 'delivery', 'diner_count': 1},
      'quotes': state == 'quoted' ? [quoteRow] : [],
      'amount_summary': {'finalized': state == 'quoted', 'amounts': _data()},
      'can_issue_order_link': true,
      'messages': [],
    };
  }

  @override
  Future<Map<String, dynamic>> quote({
    required String storeId,
    required String requestId,
    required double deliveryFee,
    required DirectOrderDeliveryPaymentMode deliveryPaymentMode,
    String? note,
  }) async {
    quoteCalls++;
    expect(deliveryFee, 0);
    expect(deliveryPaymentMode, DirectOrderDeliveryPaymentMode.customerDirect);
    state = 'quoted';
    return quoteRow;
  }

  @override
  Future<Map<String, dynamic>> issueOrderLink({
    required String storeId,
    required String requestId,
    required String operationId,
    required String accessKey,
    required bool sendToCustomer,
  }) async {
    linkCalls++;
    if (op != null) {
      expect(operationId, op);
      expect(accessKey, key);
    }
    op = operationId;
    key = accessKey;
    expect(accessKey.length, 43);
    if (loseLink) {
      loseLink = false;
      throw TimeoutException('Lost link response');
    }
    return {
      'url':
          'https://globospossystem.vercel.app/order/fixture/r/request#access=$accessKey',
      'message_id': 'link',
      'request_id': requestId,
    };
  }

  @override
  Future<Map<String, dynamic>> paymentDocument({
    required String storeId,
    required String requestId,
    required String quoteId,
    required int quoteVersion,
    required bool includePayment,
  }) async {
    if (staleDocument) {
      throw const DirectOrderException('DIRECT_ORDER_QUOTE_CHANGED');
    }
    return {
      'data': _data(payment: includePayment),
      'source_hash': 'stable-source',
    };
  }

  @override
  Future<void> uploadPaymentDocument({
    required String storeId,
    required String requestId,
    required String quoteId,
    required int quoteVersion,
    required bool includePayment,
    required String sourceHash,
    required String path,
    required String filename,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    uploads++;
    if (this.path != null) expect(path, this.path);
    this.path = path;
    committed.add(path);
    expect(quoteVersion, 1);
    expect(includePayment, true);
    expect(mimeType, 'application/pdf');
    expect(sourceHash, 'stable-source');
    if (loseUpload) {
      loseUpload = false;
      throw TimeoutException('Lost attachment response');
    }
  }
}

class _Documents extends DirectOrderPaymentDocumentService {
  int builds = 0, saves = 0;
  @override
  Future<Uint8List> buildPdf(
    Map<String, dynamic> data, {
    required String language,
  }) async {
    builds++;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<void> save(
    Uint8List bytes, {
    required String filename,
    required bool png,
  }) async {
    saves++;
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Staff service,
  _Documents documents, {
  String locale = 'en',
  double width = 1440,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/cashier/direct-orders',
    routes: [
      GoRoute(
        path: '/cashier/direct-orders',
        builder: (_, __) => DirectOrderCashierScreen(
          service: service,
          documentService: documents,
        ),
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
      child: RepaintBoundary(
        key: const Key('guide_visual'),
        child: MaterialApp.router(
          theme: AppTheme.build(),
          locale: Locale(locale),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (width < 860) {
    await tester.tap(find.text('#DFIXTURE1'));
    await tester.pumpAndSettle();
  }
}

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'fixture',
      httpClient: MockClient(
        (request) async => http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        ),
      ),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());
  for (final locale in ['ko', 'vi', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets(
        'server preview stays visible while items scroll $locale $width',
        (tester) async {
          final service = _Staff(), documents = _Documents();
          await _pump(tester, service, documents, locale: locale, width: width);
          expect(
            find.byKey(const Key('direct_staff_fixed_amount')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byKey(const Key('direct_staff_fixed_amount')),
              matching: find.textContaining('466.560'),
            ),
            findsOneWidget,
          );
          await tester.drag(
            find.byKey(const Key('direct_staff_detail_list')),
            const Offset(0, -400),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('direct_staff_fixed_amount')),
            findsOneWidget,
          );
          expect(service.reads, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
  testWidgets(
    'first quote preserves committed final total when background refresh fails',
    (tester) async {
      final service = _Staff(), documents = _Documents();
      await _pump(tester, service, documents);
      service.failRefresh = true;
      await tester.scrollUntilVisible(
        find.text(DirectOrderCopy('en').sendQuote),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('direct_staff_detail_list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(find.text(DirectOrderCopy('en').sendQuote));
      await tester.pumpAndSettle();
      await tester.tap(find.text(DirectOrderCopy('en').sendQuote));
      await tester.pumpAndSettle();
      expect(service.quoteCalls, 1);
      expect(
        find.byKey(const Key('direct_staff_fixed_amount')),
        findsOneWidget,
      );
      expect(
        find.text(DirectOrderPaymentGuideCopy('en').finalAmount),
        findsWidgets,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('lost link response retries identical key and operation', (
    tester,
  ) async {
    final service = _Staff()..loseLink = true;
    await _pump(tester, service, _Documents());
    await _tap(tester, const Key('direct_staff_send_order_link'));
    await _tap(tester, const Key('direct_staff_send_order_link'));
    expect(service.linkCalls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('lost document response retries same bytes and attachment path', (
    tester,
  ) async {
    final service = _Staff()
      ..state = 'quoted'
      ..loseUpload = true;
    final docs = _Documents();
    await _pump(tester, service, docs);
    await _tap(tester, const Key('direct_staff_send_payment_pdf'));
    await _tap(tester, const Key('direct_staff_send_payment_pdf'));
    expect(service.uploads, 2);
    expect(service.committed.length, 1);
    expect(docs.builds, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('stale quote blocks generating or sending a payment document', (
    tester,
  ) async {
    final service = _Staff()
      ..state = 'quoted'
      ..staleDocument = true;
    final docs = _Documents();
    await _pump(tester, service, docs);
    await _tap(tester, const Key('direct_staff_send_payment_pdf'));
    expect(service.uploads, 0);
    expect(docs.builds, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test(
    'QR uses server outstanding amount and reference instead of listed sum',
    () {
      const docs = DirectOrderPaymentDocumentService();
      final data = _data()..['amount_due'] = 100000;
      final qr = docs.paymentQr(data);
      expect(qr, contains('5406100000'));
      expect(qr, contains('DFIXTURE1'));
      expect(qr, contains('1234567890'));
      expect(
        () => docs.paymentQr(_data(payment: false)),
        throwsA(isA<DirectOrderException>()),
      );
    },
  );
  testWidgets(
    'real PDFs and payment images support all locales and long quotes',
    (tester) async {
      await tester.runAsync(() async {
        final loader = FontLoader('Pretendard')
          ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'));
        await loader.load();
        const service = DirectOrderPaymentDocumentService();
        final out = Directory('outputs/direct-order-payment-guide-20261013');
        await out.create(recursive: true);
        for (final locale in ['ko', 'vi', 'en']) {
          for (final count in [1, 20, 100]) {
            final data = _data(lines: count);
            final bytes = await service.buildPdf(data, language: locale);
            expect(bytes.length, greaterThan(1000));
            await File(
              '${out.path}/payment-$count-$locale.pdf',
            ).writeAsBytes(bytes);
          }
          final png = await service.buildPng(_data(), language: locale);
          expect(png.length, greaterThan(1000));
          await File('${out.path}/payment-$locale.png').writeAsBytes(png);
        }
      });
    },
  );
  testWidgets('capture Vietnamese cashier payment controls', (tester) async {
    final service = _Staff()..state = 'quoted';
    await _pump(tester, service, _Documents(), locale: 'vi');
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('guide_visual')),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        'outputs/direct-order-payment-guide-20261013/cashier-vi.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
