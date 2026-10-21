import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_report_service.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_summary.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'daily_sales_report_service_test.dart' as fixtures;

Map<String, dynamic> storeRow() => {
  'store_id': 'new-brand-store',
  'store_name': 'JeonGabok Binh Thanh',
  'receipt_count': 5,
  'gross': 2218320,
  'cash': 470880,
  'bank_transfer': 1747440,
  'other_payments': 0,
  'supply': 2054000,
  'vat': 164320,
  'missing_mapping_count': 1,
  'closing_status': 'pending',
  'policy_ready': true,
};

void main() {
  test(
    'new restaurant details retain split payments and mapping readiness',
    () {
      final s = DailySalesSummary.fromJson(
        '2026-10-21',
        fixtures.row()..['restaurant_stores'] = [storeRow()],
      );
      final store = s.restaurantStores.single;
      expect(store.name, 'JeonGabok Binh Thanh');
      expect(
        store.cash + store.bankTransfer + store.otherPayments,
        store.gross,
      );
      expect(store.supply + store.vat, store.gross);
      expect(store.missingMappingCount, 1);
      expect(store.closingStatus, 'pending');
      expect(
        () => DailySalesSummary.fromJson(
          '2026-10-21',
          fixtures.row()
            ..['restaurant_stores'] = [
              storeRow()..['closing_status'] = 'invalid',
            ],
        ),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'JeonGabok appears in legal entity report and cash title is generic',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      final service = DailySalesReportService(
        rpc: (name, params) async {
          calls++;
          expect(name, 'get_pos_daily_sales_summary');
          return {
            'business_date': '2026-10-21',
            'entities': [
              fixtures.row()..['restaurant_stores'] = [storeRow()],
            ],
          };
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ko'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: RestaurantSalesExportScreen(
              embedded: true,
              reportService: service,
              initialBusinessDate: '2026-10-21',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('JeonGabok Binh Thanh'), findsOneWidget);
      expect(find.textContaining('계산서 매핑 필요: 1'), findsOneWidget);
      expect(find.text('식당 현금 · 익일 법인통장 입금 예정액'), findsOneWidget);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
