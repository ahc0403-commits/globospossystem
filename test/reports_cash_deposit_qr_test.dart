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
  _Report() {
    // Deliberately a historical range: the deposit still uses today's date.
    state = ReportState(
      startDate: DateTime(2025),
      endDate: DateTime(2025, 1, 2),
    );
  }
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
  }) async {
    await tester.binding.setSurfaceSize(const Size(1024, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final report = _Report();
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
    await tester.pumpAndSettle();
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
          role == 'brand_admin' ? 'OB OtherStore C ' : 'BC BT Cash Doanh thu ',
        ),
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('cash_deposit_purpose')),
            )
            .data,
        startsWith(
          role == 'brand_admin'
              ? 'Other Brand Other Store Cash Doanh thu'
              : 'BC BT Cash Doanh thu',
        ),
      );
      await tester.enterText(
        find.byKey(const Key('cash_deposit_amount')),
        '1622160',
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
