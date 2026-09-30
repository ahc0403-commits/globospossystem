import 'dart:convert';
import 'package:globos_pos_system/core/services/inventory_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/features/inventory_purchase/stock_audit_dated_dialogs.dart';

void main() {
  final requests = <String>[];
  final row = <String, dynamic>{
    'product_id': 'product',
    'product_code': 'WR001',
    'product_name': 'Test ingredient',
    'base_unit': 'ea',
    'inventory_item_id': 'item',
    'supplier_name': 'Woori',
    'baseline_quantity_base': 100,
    'actual_quantity_base': 80,
    'observed_quantity_base': 80,
    'variance_quantity_base': -20,
    'unit_cost': 5,
    'variance_amount': -100,
    'counted_at': '2026-09-30T16:00:00Z',
    'after_increase_base': 30,
    'after_decrease_base': -25,
    'current_after_base': 85,
  };
  final session = <String, dynamic>{
    'id': 'session',
    'store_id': 'binh',
    'store_name': 'Bunsik Binh Thanh',
    'business_date': '2026-09-30',
    'effective_at': '2026-09-30T16:00:00Z',
    'completed_at': '2026-10-01T03:00:00Z',
    'as_of': '2026-10-01T04:00:00Z',
    'status': 'completed',
    'audit_no': 'INV-test',
    'snapshot': [row],
  };
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://stocktake.test',
      anonKey: 'test-key',
      httpClient: MockClient((request) async {
        requests.add(request.url.path);
        dynamic result;
        if (request.url.path.endsWith('list_inventory_stock_audits')) {
          result = [session];
        } else if (request.url.path.endsWith(
          'get_inventory_stock_audit_report',
        )) {
          result = {
            ...session,
            'rows': [row],
            'movements': [
              {
                'ingredient_id': 'item',
                'product_code': 'WR001',
                'product_name': 'Test ingredient',
                'base_unit': 'ea',
                'business_date': '2026-10-01',
                'quantity_base': 30,
              },
              {
                'ingredient_id': 'item',
                'product_code': 'WR001',
                'product_name': 'Test ingredient',
                'base_unit': 'ea',
                'business_date': '2026-10-01',
                'quantity_base': -20,
              },
              {
                'ingredient_id': 'item',
                'product_code': 'WR001',
                'product_name': 'Test ingredient',
                'base_unit': 'ea',
                'business_date': '2026-10-01',
                'quantity_base': -5,
              },
            ],
          };
        } else if (request.url.path.endsWith(
          'preview_inventory_stock_audit_v3',
        )) {
          result = {
            'rows': [row],
            'token': 'token',
            'can_complete': true,
          };
        } else {
          result = {};
        }
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
    );
    expect((await inventoryService.listInventoryStockAudits('binh')).length, 1);
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
  });
  Widget app(Widget body) => MaterialApp(
    locale: const Locale('ko'),
    supportedLocales: const [Locale('ko'), Locale('en'), Locale('vi')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: Scaffold(body: body),
  );
  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'stocktake_reference_date_dialog preserves previous business date after midnight',
    (tester) async {
      size(tester);
      StockAuditDateSelection? result;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await selectStockAuditDate(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('stocktake_reference_date_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('stocktake_business_date')),
        '2026-09-30',
      );
      await tester.enterText(
        find.byKey(const Key('stocktake_effective_at')),
        '2026-10-01T00:10:00+09:00',
      );
      await tester.tap(find.text('양식 준비'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.enterText(
        find.byKey(const Key('stocktake_effective_at')),
        '2026-10-01T00:10:00+07:00',
      );
      await tester.tap(find.text('양식 준비'));
      await tester.pumpAndSettle();
      expect(result!.businessDate, '2026-09-30');
      expect(result!.effectiveAt, DateTime.parse('2026-09-30T17:10:00Z'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'inventory_stock_audit_excel_preview_dialog shows next-day +/- and returns token',
    (tester) async {
      size(tester);
      StockAuditDatedDecision? result;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await reviewDatedStockAudit(
                  context,
                  storeId: 'binh',
                  session: session,
                  lines: [
                    {'product_id': 'product', 'actual_quantity_base': 80},
                  ],
                  blankCount: 0,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('inventory_stock_audit_excel_preview_dialog')),
        findsOneWidget,
      );
      expect(
        find.text('+30'),
        findsOneWidget,
        reason:
            '${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()} / $requests',
      );
      expect(find.text('-25'), findsOneWidget);
      expect(find.text('85'), findsOneWidget);
      await tester.tap(find.text('확정'));
      await tester.pumpAndSettle();
      expect(result!.complete, true);
      expect(result!.token, 'token');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'stocktake_report_dialog renders frozen variance and current calculation without table errors',
    (tester) async {
      size(tester);
      await tester.pumpWidget(
        app(const StockAuditReportPanel(storeId: 'binh')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('stocktake_report_session')),
        findsOneWidget,
        reason:
            '${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()} / $requests',
      );
      await tester.tap(find.byKey(const Key('stocktake_report_session')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stocktake_report_dialog')), findsOneWidget);
      expect(find.text('-20'), findsOneWidget);
      expect(find.text('85'), findsOneWidget);
      expect(find.text('Excel 다운로드'), findsOneWidget);
      expect(find.text('인쇄'), findsOneWidget);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
