// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/features/table/table_provider.dart';

// Isolate actual read implementation while preventing a real websocket/network.
class ReadOnlyProbeNotifier extends WaiterTableNotifier {
  @override
  Future<void> subscribe(String storeId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var dayCalls = 0;
  var calls = 0, active = 0, peak = 0, bytes = 0, topRows = 0, childRows = 0;
  final tables = List.generate(
    20,
    (i) => {
      'id': 'table-$i',
      'restaurant_id': 'audit-store',
      'table_number': '$i',
      'status': 'available',
      'seat_count': 4,
    },
  );
  final orders = List.generate(
    10,
    (i) => {
      'id': 'order-$i',
      'table_id': 'table-$i',
      'status': 'confirmed',
      'created_at': '2026-10-10T01:00:00Z',
      'order_items': List.generate(
        10,
        (j) => {
          'id': 'item-$i-$j',
          'created_at': '2026-10-10T01:00:00Z',
          'label': 'Example item $j',
          'quantity': 1,
          'status': 'pending',
          'menu_items': {
            'name': 'Example item $j',
            'name_en': 'Example item $j',
            'name_ko': '예시 메뉴 $j',
            'name_vi': 'Món mẫu $j',
          },
        },
      ),
    },
  );
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:54321',
      anonKey: 'audit-fixture',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/ensure_store_operational_day')) {
          dayCalls++;
          return http.Response(
            jsonEncode({'enabled': false}),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        calls++;
        active++;
        if (active > peak) peak = active;
        final isTables = request.url.path.endsWith('/tables');
        expect(isTables || request.url.path.endsWith('/orders'), isTrue);
        final rows = isTables ? tables : orders;
        final body = jsonEncode(rows);
        bytes += utf8.encode(body).length;
        topRows += rows.length;
        if (!isTables) childRows += 100;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        active--;
        return http.Response(
          body,
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
  });
  for (final burst in [1, 100]) {
    test('actual table read burst $burst', () async {
      calls = 0;
      dayCalls = 0;
      active = 0;
      peak = 0;
      bytes = 0;
      topRows = 0;
      childRows = 0;
      final notifier = ReadOnlyProbeNotifier();
      final watch = Stopwatch()..start();
      await Future.wait(
        List.generate(
          burst,
          (_) => notifier.loadTables('audit-store', showLoading: false),
        ),
      );
      watch.stop();
      expect(notifier.state.error, isNull);
      expect(notifier.state.tables.length, 20);
      expect(notifier.state.orderPreviewByTableId.length, 10);
      expect(calls, burst == 1 ? 2 : 4);
      expect(peak, 1);
      expect(dayCalls, lessThanOrEqualTo(1));
      print(
        'AUDIT_MEASUREMENT ' +
            jsonEncode({
              'burst': burst,
              'http_calls': calls + dayCalls,
              'table_http_calls': calls,
              'operational_day_http_calls': dayCalls,
              'peak_http_in_flight': peak,
              'response_body_bytes': bytes,
              'root_rows_transferred': topRows,
              'nested_item_rows_transferred': childRows,
              'elapsed_ms': watch.elapsedMilliseconds,
              'fixture_http_delay_ms': 20,
              'network': 'mock_only',
            }),
      );
      notifier.dispose();
    });
  }
}
