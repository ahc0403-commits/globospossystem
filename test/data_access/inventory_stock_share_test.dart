import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/core/services/inventory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'dashboard and stock panel share one read and compose exact low stock',
    () async {
      SharedPreferences.setMockInitialValues({});
      final stockStarted = Completer<void>(), releaseStock = Completer<void>();
      var stockCalls = 0, dashboardCalls = 0;
      await Supabase.initialize(
        url: 'http://127.0.0.1:54321',
        anonKey: 'fixture',
        httpClient: MockClient((request) async {
          final dashboard = request.url.path.endsWith(
            '/get_inventory_purchase_dashboard_v2',
          );
          if (dashboard) {
            dashboardCalls++;
            return http.Response(
              jsonEncode({
                'store_count': 1,
                'total_inventory_amount': 3006,
                'submitted_purchase_amount': 7,
                'approved_purchase_amount': 13,
              }),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          expect(
            request.url.path.endsWith('/get_inventory_stock_status'),
            isTrue,
          );
          stockCalls++;
          stockStarted.complete();
          await releaseStock.future;
          return http.Response(
            jsonEncode([
              {'risk_status': 'danger'},
              {'risk_status': 'warning'},
              {'risk_status': 'safe'},
            ]),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final service = InventoryService();
      final dashboard = service.fetchInventoryPurchaseDashboard(
        storeId: 'target-store',
      );
      await stockStarted.future;
      final panel = service.fetchInventoryStockStatus(storeId: 'target-store');
      releaseStock.complete();
      expect((await dashboard)['low_stock_count'], 2);
      expect(await panel, hasLength(3));
      expect(stockCalls, 1);
      expect(dashboardCalls, 1);
      stdout.writeln(
        'AUDIT_MEASUREMENT ${jsonEncode({'case': 'dashboard_shared_stock', 'http_calls': stockCalls + dashboardCalls, 'stock_rpc_calls': stockCalls, 'stock_rows': 3, 'low_stock_count': 2, 'network': 'mock_only'})}',
      );
      await Supabase.instance.dispose();
    },
  );
}
