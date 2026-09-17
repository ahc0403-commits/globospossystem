import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/providers/daily_closing_provider.dart';
import 'package:globos_pos_system/features/admin/tabs/reports_tab.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/report/menu_sales_analytics.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '00000000-0000-0000-0000-000000000001';

final _testClient = SupabaseClient('http://localhost:54321', 'test-anon-key');

class _ReportsAuthNotifier extends AuthNotifier {
  _ReportsAuthNotifier() : super(client: _testClient) {
    _testClient.auth.stopAutoRefresh();
    state = const PosAuthState(
      role: 'store_admin',
      storeId: _storeId,
      primaryStoreId: _storeId,
      accessibleStores: [AccessibleStore(id: _storeId, name: 'Bunsik')],
    );
  }
}

class _CountingReportNotifier extends ReportNotifier {
  _CountingReportNotifier() {
    state = ReportState(
      startDate: DateTime(2026, 9, 17),
      endDate: DateTime(2026, 9, 17),
    );
  }

  int loadCount = 0;

  @override
  Future<void> loadReport(String storeId) async {
    loadCount++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('date lookup refreshes sales and daily closing together', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final reportNotifier = _CountingReportNotifier();
    var dailyClosingLoadCount = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _ReportsAuthNotifier()),
          reportProvider.overrideWith((ref) => reportNotifier),
          menuSalesAnalyticsProvider.overrideWith(
            (ref, params) async => MenuSalesAnalytics.fromJson(const {}),
          ),
          dailyClosingHistoryProvider.overrideWith((ref, storeId) async {
            dailyClosingLoadCount++;
            return const [];
          }),
        ],
        child: const MaterialApp(
          locale: Locale('ko'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: ReportsTab(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(reportNotifier.loadCount, 1);
    expect(dailyClosingLoadCount, 1);

    await tester.tap(find.byKey(const Key('reports_date_lookup')));
    await tester.pumpAndSettle();

    expect(reportNotifier.loadCount, 2);
    expect(dailyClosingLoadCount, 2);
    expect(tester.takeException(), isNull);
  });
}
