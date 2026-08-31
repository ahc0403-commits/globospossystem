import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/report_analysis_screens.dart';
import 'package:globos_pos_system/features/admin/widgets/paperless_operations_dashboard.dart';
import 'package:globos_pos_system/features/report/menu_sales_analytics.dart';
import 'package:globos_pos_system/features/report/menu_sales_analytics_panel.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:intl/intl.dart';

const _storeId = '00000000-0000-0000-0000-000000000001';
final _startDate = DateTime(2026, 8, 1);
final _endDate = DateTime(2026, 8, 2);

MenuSalesAnalytics _menuAnalytics() => MenuSalesAnalytics(
  summary: const MenuSalesSummary(
    orderCount: 4,
    soldQuantity: 7,
    soldMenuCount: 1,
    comboSoldQuantity: 0,
    comboSoldMenuCount: 0,
    comboMenuSalesAmount: 0,
    menuSalesAmount: 350000,
    unallocatedAdjustmentCount: 0,
    unallocatedAdjustmentAmount: 0,
  ),
  menuRows: const [
    MenuSalesRow(
      rank: 1,
      menuKey: 'menu-1',
      displayName: '쌀국수',
      identityQuality: 'stable_id',
      nameChangedInPeriod: false,
      soldQuantity: 7,
      orderCount: 4,
      menuSalesAmount: 350000,
      quantityShare: 100,
      revenueShare: 100,
      peakHour: 12,
      dineInQuantity: 4,
      takeawayQuantity: 2,
      deliveryQuantity: 1,
      isCombo: false,
    ),
  ],
  hourRows: const [
    MenuSalesHour(
      hour: 12,
      soldQuantity: 7,
      menuSalesAmount: 350000,
      orderCount: 4,
    ),
  ],
  topMenuHourRows: const [
    TopMenuSalesHour(
      rank: 1,
      menuKey: 'menu-1',
      displayName: '쌀국수',
      hour: 12,
      soldQuantity: 7,
      menuSalesAmount: 350000,
    ),
  ],
  scope: const {'timezone': 'Asia/Ho_Chi_Minh'},
);

Map<String, dynamic> _operationsReport() => {
  'order_count': 8,
  'completed_order_count': 7,
  'dining_order_count': 6,
  'average_operation_seconds': 540,
  'average_dining_seconds': 1200,
  'bottleneck_station': 'kitchen',
  'stations': [
    {
      'station': 'kitchen',
      'sample_count': 7,
      'average_seconds': 420,
      'backlog_quantity': 1,
    },
  ],
  'category_operation_times': [
    {
      'category_key': 'noodles',
      'name_ko': '면류',
      'name_vi': 'Mì',
      'name_en': 'Noodles',
      'sample_count': 7,
      'operation_average_seconds': 540,
    },
  ],
  'menu_operation_times': [
    {
      'menu_key': 'menu-1',
      'name_ko': '쌀국수',
      'name_vi': 'Phở',
      'name_en': 'Pho',
      'category_name_ko': '면류',
      'category_name_vi': 'Mì',
      'category_name_en': 'Noodles',
      'sample_count': 7,
      'kitchen_average_seconds': 420,
      'tray_average_seconds': 30,
      'floor_average_seconds': 90,
      'operation_average_seconds': 540,
    },
  ],
};

ReportSummary _salesSummary() => ReportSummary(
  dineInRevenue: 500000,
  deliveryRevenue: 100000,
  serviceTotal: 20000,
  totalRevenue: 600000,
  totalOrders: 6,
  completedOrders: 6,
  paidOrders: 6,
  openOrders: 0,
  dailyBreakdown: [
    DailyRevenue(
      date: _startDate,
      dineIn: 500000,
      delivery: 100000,
      total: 600000,
    ),
  ],
);

class _LoadedReportNotifier extends ReportNotifier {
  _LoadedReportNotifier() {
    state = ReportState(
      startDate: _startDate,
      endDate: _endDate,
      summary: _salesSummary(),
    );
  }
}

MaterialApp _materialApp(Widget home) => MaterialApp(
  locale: const Locale('ko'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('menu sales downloads the current range and scope as Excel', (
    tester,
  ) async {
    String? savedName;
    Uint8List? savedBytes;
    final params = MenuSalesAnalyticsParams(
      storeId: _storeId,
      startDate: _startDate,
      endDate: _endDate,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          menuSalesAnalyticsProvider.overrideWith(
            (ref, params) async => _menuAnalytics(),
          ),
        ],
        child: _materialApp(
          Scaffold(
            body: SingleChildScrollView(
              child: MenuSalesAnalyticsPanel(
                params: params,
                currency: NumberFormat('#,###', 'vi_VN'),
                saveExcelFile:
                    ({required String name, required Uint8List bytes}) async {
                      savedName = name;
                      savedBytes = bytes;
                    },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('menu_sales_excel_download')));
    await tester.pump();

    expect(savedName, 'menu_sales_20260801_20260802_all');
    final workbook = Excel.decodeBytes(savedBytes!);
    expect(workbook.tables.keys, containsAll(['Menu Sales', 'Menu by Hour']));
    expect(workbook.tables.keys, isNot(contains('Sheet1')));
    expect(workbook.tables['Menu Sales']!.rows[2][1]!.value.toString(), 'all');
    expect(workbook.tables['Menu Sales']!.rows[10][1]!.value.toString(), '쌀국수');
  });

  testWidgets('operations performance downloads all analysis slices', (
    tester,
  ) async {
    String? savedName;
    Uint8List? savedBytes;
    await tester.pumpWidget(
      _materialApp(
        Scaffold(
          body: SingleChildScrollView(
            child: PaperlessOperationsDashboard(
              storeId: _storeId,
              startDate: _startDate,
              endDate: _endDate,
              loader: () async => _operationsReport(),
              saveExcelFile:
                  ({required String name, required Uint8List bytes}) async {
                    savedName = name;
                    savedBytes = bytes;
                  },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('paperless_operations_excel_download')),
    );
    await tester.pump();

    expect(savedName, 'operations_performance_20260801_20260802');
    final workbook = Excel.decodeBytes(savedBytes!);
    expect(
      workbook.tables.keys,
      containsAll(['Summary', 'Stations', 'Categories', 'Menu Times']),
    );
    expect(workbook.tables.keys, isNot(contains('Sheet1')));
    expect(workbook.tables['Stations']!.rows[1][0]!.value.toString(), '주방');
    expect(workbook.tables['Menu Times']!.rows[1][2]!.value.toString(), '쌀국수');
    expect(workbook.tables['Menu Times']!.rows[1][8]!.value.toString(), '540');
  });

  testWidgets('sales trend downloads the loaded report workbook', (
    tester,
  ) async {
    String? savedName;
    Uint8List? savedBytes;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reportProvider.overrideWith((ref) => _LoadedReportNotifier()),
        ],
        child: _materialApp(
          SalesRevenueAnalyticsScreen(
            storeId: _storeId,
            startDate: _startDate,
            endDate: _endDate,
            saveExcelFile:
                ({required String name, required Uint8List bytes}) async {
                  savedName = name;
                  savedBytes = bytes;
                },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sales_revenue_excel_download')));
    await tester.pump();

    expect(savedName, 'sales_revenue_20260801_20260802');
    final workbook = Excel.decodeBytes(savedBytes!);
    expect(workbook.tables.keys, contains('Sales Report'));
    expect(
      workbook.tables['Sales Report']!.rows[7][1]!.value.toString(),
      '600000',
    );
  });
}
