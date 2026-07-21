import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/red_invoice_intake/red_invoice_intake_models.dart';
import 'package:globos_pos_system/features/red_invoice_intake/red_invoice_intake_screen.dart';
import 'package:globos_pos_system/features/red_invoice_intake/red_invoice_intake_service.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeRedInvoiceIntakeService extends RedInvoiceIntakeService {
  @override
  Future<List<RedInvoiceIntake>> load(String businessDate) async => [
    RedInvoiceIntake(
      id: 'intake-1',
      orderId: 'order-1',
      storeId: 'store-1',
      storeName: 'BunsikClub Binh Thanh',
      meInvoiceJobId: 'job-1',
      invoiceSeries: '1C26TAA',
      receiptIds: const ['receipt-1'],
      saleAt: DateTime.parse('2026-07-21T12:35:42+07:00'),
      grossAmount: 200000,
      paymentMethod: 'Cash',
      source: 'business_card',
      status: 'awaiting_information',
      buyerTaxCode: '',
      buyerUnitCode: '',
      buyerLegalName: '',
      buyerFullName: '',
      buyerAddress: '',
      buyerEmail: '',
      buyerEmailCc: '',
      buyerPhone: '',
      buyerId: '',
      sourceNote: 'Business card received at cashier',
      attachmentUrls: const [],
      requestedAt: DateTime.parse('2026-07-21T12:36:00+07:00'),
      exportBatchId: null,
      lineItems: const [],
      meInvoiceStatus: 'dispatch_paused',
    ),
  ];
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'test-anon-key',
    );
  });

  testWidgets('red_invoice_intake_edit_dialog opens from a live request', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _FakeRedInvoiceIntakeService();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => RedInvoiceIntakeScreen(service: service),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(),
          locale: const Locale('ko'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('red_invoice_edit_intake-1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('red_invoice_intake_edit_dialog')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('red_invoice_intake_edit_cancel')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('red_invoice_intake_edit_dialog')),
      findsNothing,
    );
  });
}
