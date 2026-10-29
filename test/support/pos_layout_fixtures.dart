import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/providers/daily_closing_provider.dart';
import 'package:globos_pos_system/features/admin/tabs/reports_tab.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/report/menu_sales_analytics.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const layoutSampleStore = '00000000-0000-0000-0000-000000000001';
final layoutSampleClient = SupabaseClient(
  'http://127.0.0.1:54321',
  'sample-layout-only',
  httpClient: MockClient((request) async {
    throw StateError('Unexpected network request in isolated layout fixture');
  }),
);

class LayoutSampleAuth extends AuthNotifier {
  LayoutSampleAuth(String role) : super(client: layoutSampleClient) {
    layoutSampleClient.auth.stopAutoRefresh();
    state = PosAuthState(
      role: role,
      storeId: layoutSampleStore,
      primaryStoreId: layoutSampleStore,
      accessibleStores: const [
        AccessibleStore(
          id: layoutSampleStore,
          name: 'SAMPLE · Cửa hàng với tên dài · 긴 샘플 매장 이름',
          brandName: 'SAMPLE',
        ),
      ],
    );
  }
}

class LayoutSampleReport extends ReportNotifier {
  LayoutSampleReport({this.scene = 'populated'})
    : super(client: layoutSampleClient) {
    state = ReportState(
      startDate: DateTime(2026, 10, 28),
      endDate: DateTime(2026, 10, 28, 23, 59),
      isLoading: scene == 'loading',
      error: scene == 'error'
          ? 'SAMPLE · Không thể tải dữ liệu, vui lòng thử lại.'
          : null,
      summary: scene == 'empty' || scene == 'error' || scene == 'loading'
          ? null
          : ReportSummary(
              dineInRevenue: 123456789,
              deliveryRevenue: 987654,
              serviceTotal: 456789,
              totalRevenue: 124444443,
              totalOrders: 19,
              completedOrders: 19,
              paidOrders: 19,
              openOrders: 0,
              dailyBreakdown: [
                DailyRevenue(
                  date: DateTime(2026, 10, 28),
                  dineIn: 123456789,
                  delivery: 987654,
                  total: 124444443,
                  teamCount: 19,
                ),
              ],
              hourlyBreakdown: const [
                HourlyRevenue(hour: 10, amount: 100000),
                HourlyRevenue(hour: 12, amount: 200000),
              ],
              cashTotal: 100000000,
              bankTransferTotal: 24444443,
              missingProofPhotosCount: 1,
              failedEinvoiceJobsCount: 1,
              proofCompletePercent: 80,
              missingProofIssues: [
                MissingProofIssue(
                  paymentId: 'sample-payment',
                  orderId: 'sample-order',
                  amount: 100000,
                  method: 'BANK_TRANSFER',
                  createdAt: DateTime(2026, 10, 28, 12),
                ),
              ],
              einvoiceReviewIssues: [
                EinvoiceReviewIssue(
                  jobId: 'sample-job',
                  orderId: 'sample-order',
                  paymentId: 'sample-payment',
                  status: 'failed',
                  detail: 'SAMPLE · Kiểm tra thông tin của hóa đơn điện tử.',
                  createdAt: DateTime(2026, 10, 28, 12),
                ),
              ],
            ),
    );
  }
  final String scene;
  int loads = 0;
  @override
  Future<void> loadReport(String storeId) async {
    loads++;
  }
}

List<DailyClosingRecord> layoutSampleClosings() => [
  for (var i = 0; i < 12; i++)
    DailyClosingRecord.fromJson({
      'closing_id': 'sample-closing-$i',
      'closing_date': '2026-10-${(28 - i).toString().padLeft(2, '0')}',
      'closed_by_name': 'SAMPLE',
      'close_source': 'manual',
      'counted_cash_amount': 1234567,
      'opening_cash_amount': 0,
      'created_at': '2026-10-28T11:00:00Z',
      'bank': {
        'bin': '000000',
        'label': 'SAMPLE BANK',
        'account_number': '0000000000',
        'account_holder': 'SAMPLE COMPANY WITH A LONG REGISTERED DISPLAY NAME',
      },
    }),
];

Widget reportsLayoutFixture({
  String language = 'vi',
  double scale = 1,
  String role = 'store_admin',
  LayoutSampleReport? report,
}) => ProviderScope(
  overrides: [
    authProvider.overrideWith((ref) => LayoutSampleAuth(role)),
    reportProvider.overrideWith((ref) => report ?? LayoutSampleReport()),
    menuSalesAnalyticsProvider.overrideWith(
      (ref, params) async => MenuSalesAnalytics.fromJson(const {}),
    ),
    dailyClosingHistoryProvider.overrideWith(
      (ref, store) async => layoutSampleClosings(),
    ),
  ],
  child: MaterialApp(
    theme: AppTheme.build(),
    locale: Locale(language),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: const RepaintBoundary(
      key: Key('reports_layout_scene'),
      child: ReportsTab(),
    ),
  ),
);
