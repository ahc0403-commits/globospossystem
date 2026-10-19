import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/providers/daily_closing_provider.dart';
import 'package:globos_pos_system/core/services/collection_bank_service.dart';
import 'package:globos_pos_system/features/admin/tabs/reports_tab.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/report/menu_sales_analytics.dart';
import 'package:globos_pos_system/features/report/cash_deposit_qr_dialog.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '00000000-0000-0000-0000-000000000001';
const _otherId = '00000000-0000-0000-0000-000000000002';

class _Auth extends AuthNotifier {
  _Auth(String role, {bool hasBrand = true})
    : super(client: Supabase.instance.client) {
    state = PosAuthState(
      role: role,
      storeId: _storeId,
      accessibleStores: [
        AccessibleStore(
          id: _storeId,
          name: 'Binh Thanh',
          brandName: hasBrand ? 'Bunsikclub' : null,
        ),
        const AccessibleStore(
          id: _otherId,
          name: 'Other Store',
          brandName: 'Other Brand',
        ),
      ],
    );
  }
}

class _Report extends ReportNotifier {
  _Report({
    double cash = 1622160,
    bool hasSummary = true,
    bool loading = false,
    bool multiDay = false,
  }) {
    state = ReportState(
      startDate: DateTime(2026, 10, 16),
      endDate: DateTime(2026, 10, multiDay ? 17 : 16, 23, 59),
      isLoading: loading,
      summary: hasSummary
          ? ReportSummary(
              dineInRevenue: cash,
              deliveryRevenue: 0,
              serviceTotal: 0,
              totalRevenue: cash,
              totalOrders: 1,
              completedOrders: 1,
              paidOrders: 1,
              openOrders: 0,
              dailyBreakdown: const [],
              cashTotal: cash,
            )
          : null,
    );
  }
  bool get isLoading => state.isLoading;
  int loads = 0;
  @override
  Future<void> loadReport(String storeId) async {
    loads++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <http.Request>[];

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:54321',
      anonKey: 'fixture',
      authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        expect(request.url.path, '/rest/v1/rpc/get_store_collection_bank');
        return http.Response(
          jsonEncode({
            'bin': '970426',
            'account_number': '12345678901',
            'account_holder': 'FIXTURE COMPANY',
            'label': 'Fixture Bank',
          }),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());
  setUp(requests.clear);

  test('collection account adapter loads the scoped bank', () async {
    final bank = await collectionBankService.load(_storeId);
    expect(bank.accountNumber, '12345678901');
  });

  Future<_Report> mount(
    WidgetTester tester,
    String role, {
    String? override,
    bool hasBrand = true,
    _Report? reportFixture,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1024, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final report = reportFixture ?? _Report();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _Auth(role, hasBrand: hasBrand)),
          reportProvider.overrideWith((ref) => report),
          menuSalesAnalyticsProvider.overrideWith(
            (ref, params) async => MenuSalesAnalytics.fromJson(const {}),
          ),
          dailyClosingHistoryProvider.overrideWith(
            (ref, store) async => const [],
          ),
        ],
        child: MaterialApp(
          locale: const Locale('ko'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: ReportsTab(overrideStoreId: override)),
        ),
      ),
    );
    if (report.isLoading) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    } else {
      await tester.pumpAndSettle();
    }
    return report;
  }

  for (final role in ['store_admin', 'brand_admin']) {
    testWidgets('$role opens cash QR using only the selected store account', (
      tester,
    ) async {
      final selected = role == 'brand_admin' ? _otherId : _storeId;
      final report = await mount(tester, role, override: selected);
      expect(requests, isEmpty);
      final cashCard = find.byKey(const Key('reports_payment_cash'));
      await tester.ensureVisible(cashCard);
      // Tap the cash heading itself, in addition to the explicit QR button.
      await tester.tap(
        find.descendant(of: cashCard, matching: find.text('현금')),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cash_deposit_qr_dialog')), findsOneWidget);
      expect(requests, hasLength(1));
      expect(jsonDecode(requests.single.body), {'p_store_id': selected});
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('cash_deposit_short_purpose')),
            )
            .data,
        startsWith(
          role == 'brand_admin' ? 'OB OtherStore C ' : 'BC BT C Doanh thu ',
        ),
      );
      final dialog = tester.widget<CashDepositQrDialog>(
        find.byType(CashDepositQrDialog),
      );
      expect(dialog.reportDate, DateTime(2026, 10, 16));
      expect(dialog.amount, 1622160);
      expect(find.textContaining('조회일: 16/10/2026'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('cash_deposit_amount')),
            )
            .data,
        '1.622.160 VND',
      );
      expect(find.byType(TextFormField), findsNothing);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('cash_deposit_short_purpose')),
            )
            .data,
        endsWith('16/10'),
      );
      final generate = find.byKey(const Key('cash_deposit_generate_qr'));
      await tester.ensureVisible(generate);
      await tester.tap(generate);
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      expect(requests, hasLength(1));
      expect(report.loads, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'unapplied picker edits keep the displayed report date and amount',
    (tester) async {
      await mount(tester, 'store_admin');
      final startPicker = find.widgetWithIcon(
        OutlinedButton,
        Icons.event_outlined,
      );
      await tester.ensureVisible(startPicker);
      await tester.tap(startPicker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('15').last);
      await tester.tap(find.text('확인'));
      await tester.pumpAndSettle();
      final cashCard = find.byKey(const Key('reports_payment_cash'));
      await tester.ensureVisible(cashCard);
      await tester.tap(
        find.descendant(of: cashCard, matching: find.text('현금')),
      );
      await tester.pumpAndSettle();
      final dialog = tester.widget<CashDepositQrDialog>(
        find.byType(CashDepositQrDialog),
      );
      expect(dialog.reportDate, DateTime(2026, 10, 16));
      expect(dialog.amount, 1622160);
    },
  );

  for (final invalid in <String, _Report Function()>{
    'no query result': () => _Report(hasSummary: false),
    'loading result': () => _Report(loading: true),
    'multi-day range': () => _Report(multiDay: true),
    'zero amount': () => _Report(cash: 0),
    'fractional amount': () => _Report(cash: 1.5),
  }.entries) {
    testWidgets('${invalid.key} cannot generate a guessed transfer', (
      tester,
    ) async {
      await mount(tester, 'store_admin', reportFixture: invalid.value());
      final cashCard = find.byKey(const Key('reports_payment_cash'));
      await tester.ensureVisible(cashCard);
      await tester.tap(
        find.descendant(of: cashCard, matching: find.text('현금')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CashDepositQrDialog), findsNothing);
      expect(requests, isEmpty);
    });
  }

  testWidgets(
    'unavailable brand metadata blocks a guessed QR without requests',
    (tester) async {
      await mount(tester, 'store_admin', hasBrand: false);
      final cashCard = find.byKey(const Key('reports_payment_cash'));
      await tester.ensureVisible(cashCard);
      await tester.tap(
        find.descendant(of: cashCard, matching: find.text('현금')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byKey(const Key('cash_deposit_qr_dialog')), findsNothing);
      expect(requests, isEmpty);
    },
  );
}
