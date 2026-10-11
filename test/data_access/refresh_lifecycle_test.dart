import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/coalesced_refresh.dart';
import 'package:globos_pos_system/features/table/table_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Tables extends WaiterTableNotifier {
  @override
  Future<void> subscribe(String storeId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'refresh error drains latest work once and disposed queue drops pending work',
    () async {
      final queue = CoalescedRefresh();
      final started = Completer<void>(), release = Completer<void>();
      var calls = 0, active = 0, peak = 0;
      Future<void> work() async {
        calls++;
        active++;
        if (active > peak) peak = active;
        try {
          if (calls == 1) {
            started.complete();
            await release.future;
            throw StateError('transient');
          }
        } finally {
          active--;
        }
      }

      final first = queue.run(work);
      final assertion = expectLater(first, throwsStateError);
      await started.future;
      for (var i = 0; i < 100; i++) {
        unawaited(queue.run(work).catchError((Object _) {}));
      }
      release.complete();
      await assertion;
      expect(calls, 2);
      expect(peak, 1);
      queue.dispose();
      await queue.run(work);
      expect(calls, 2);
    },
  );
  test(
    'store switch, delayed read, bounded delta burst and disposal retain correct scope',
    () async {
      SharedPreferences.setMockInitialValues({});
      final started = Completer<void>(), release = Completer<void>();
      final calls = <String>[];
      var delta = 0;
      await Supabase.initialize(
        url: 'http://127.0.0.1:54321',
        anonKey: 'synthetic',
        httpClient: MockClient((r) async {
          if (r.url.path.endsWith('/ensure_store_operational_day')) {
            return http.Response(
              jsonEncode({'enabled': false}),
              200,
              request: r,
              headers: {'content-type': 'application/json'},
            );
          }
          calls.add(r.url.path);
          Object data;
          if (r.url.path.endsWith('/tables')) {
            final store = r.url.queryParameters['restaurant_id']!.substring(3);
            if (store == 'store-a') {
              started.complete();
              await release.future;
            }
            data = [
              {
                'id': 'table-$store',
                'restaurant_id': store,
                'table_number': '1',
                'status': 'available',
              },
            ];
          } else if (r.url.path.endsWith('/orders')) {
            final store = r.url.queryParameters['restaurant_id']!.substring(3);
            data = [
              {
                'id': 'order-$store',
                'table_id': 'table-$store',
                'created_at': '2026-10-10T01:00:00Z',
                'status': 'confirmed',
                'order_items': [],
              },
            ];
          } else {
            expect(r.url.path, endsWith('/get_table_order_previews_delta'));
            final p = jsonDecode(r.body) as Map;
            expect((p['p_order_ids'] as List).length, lessThanOrEqualTo(50));
            expect((p['p_table_ids'] as List).length, lessThanOrEqualTo(50));
            delta++;
            data = {
              'version': 1,
              'rows': [
                {
                  'id': 'order-store-b',
                  'table_id': 'table-store-b',
                  'created_at': '2026-10-10T01:00:00Z',
                  'order_items': [
                    {
                      'id': 'item',
                      'quantity': 2,
                      'status': 'pending',
                      'label': 'Changed',
                      'created_at': '2026-10-10T01:00:00Z',
                    },
                  ],
                },
              ],
            };
          }
          return http.Response(
            jsonEncode(data),
            200,
            request: r,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final notifier = _Tables();
      final old = notifier.loadTables('store-a');
      await started.future;
      final latest = notifier.loadTables('store-b');
      release.complete();
      await Future.wait([old, latest]);
      expect(notifier.state.error, isNull);
      expect(notifier.state.tables.single.storeId, 'store-b');
      final floorReads = calls.where((p) => p.endsWith('/tables')).length;
      for (var i = 0; i < 100; i++) {
        notifier.queueChangedOrders('store-b', ['order-store-b']);
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(delta, 1);
      expect(
        notifier.state.orderPreviewByTableId['table-store-b']!.itemCount,
        2,
      );
      expect(calls.where((p) => p.endsWith('/tables')).length, floorReads);
      notifier.queueChangedOrders(
        'store-b',
        List.generate(100, (i) => 'dirty-$i'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(delta, 3);
      final before = calls.length;
      notifier.queueChangedOrders('store-b', ['order-store-b']);
      notifier.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(calls.length, before);
      await Supabase.instance.dispose();
    },
  );
}
