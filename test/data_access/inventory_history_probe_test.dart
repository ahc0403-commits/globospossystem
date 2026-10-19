// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
// Actual InventoryService with an in-memory HTTP fixture; no network or DB.
// Run from repository root: flutter test --no-pub --concurrency=1
//   docs/audits/data_access_20261010/inventory_history_probe_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/inventory_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String fixtureId(int n) =>
    '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

void main() {
  final results = <Map<String, dynamic>>[];
  var fixtures = <String, String>{};
  var calls = 0, responseBytes = 0, returnedRows = 0, maxUrlBytes = 0;
  var historyCalls = 0;
  final historyBounds = <Map<String, String?>>[];
  final orderId = fixtureId(1), supplierItemId = fixtureId(2);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://audit.invalid',
      anonKey: 'synthetic-audit-key',
      httpClient: MockClient((request) async {
        calls++;
        final table = request.url.pathSegments.last;
        final historical = table == 'get_inventory_supplier_history_batch';
        final key = historical ? 'history' : table;
        if (!fixtures.containsKey(key)) {
          throw StateError('Unexpected fixture request: $table');
        }
        if (historical) {
          historyCalls++;
          historyBounds.add({
            'table': table,
            'limit': request.url.queryParameters['limit'],
            'range': request.headers['range'],
          });
        }
        final body = fixtures[key]!;
        responseBytes += utf8.encode(body).length;
        final decoded = jsonDecode(body);
        returnedRows += historical
            ? (decoded['rows'] as List).length
            : decoded is List
            ? decoded.length
            : 1;
        final urlBytes = utf8.encode(request.url.toString()).length;
        if (urlBytes > maxUrlBytes) maxUrlBytes = urlBytes;
        // Fixed synthetic transport delay; it is NOT a production RTT.
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return http.Response(
          body,
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
  });

  tearDownAll(() async {
    final out = Platform.environment['DATA_AUDIT_OUTPUT'];
    if (out != null) {
      File('$out/inventory_history_results.json').writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({'measurement': 'Actual InventoryService; mock HTTP; synthetic JSON; no DB/RLS/PostgREST server', 'latency': 'One warmup then five samples; each mock response waits 1 ms; includes JSON decode and client processing', 'rows': 'HTTP fixture rows returned, not physical DB rows read', 'memory': 'Process RSS snapshots include Flutter test VM and fixture; peak is cumulative process high-water, not isolated service heap', 'results': results})}\n',
      );
    }
    await Supabase.instance.dispose();
  });

  for (final n in [100, 1000, 10000, 100000]) {
    test(
      'inventory detail fetches $n history rows for three displayed rows',
      () async {
        fixtures = {
          'inventory_purchase_orders': jsonEncode({
            'id': orderId,
            'restaurant_id': fixtureId(3),
            'status': 'draft',
            'purchase_order_no': 'AUDIT',
          }),
          'restaurants': jsonEncode({
            'id': fixtureId(3),
            'name': 'Fixture store',
          }),
          'inventory_purchase_order_lines': jsonEncode([
            {
              'id': fixtureId(4),
              'supplier_item_id': supplierItemId,
              'ordered_quantity_base': 1,
              'product': {'name': 'Fixture product'},
            },
          ]),
          'inventory_receipts': '[]',
          'inventory_purchase_documents': '[]',
          'inventory_purchase_approval_events': '[]',
          'history': jsonEncode({
            'version': 1,
            'rows': List.generate(
              3,
              (i) => {
                'supplier_item_id': supplierItemId,
                'purchase_order_id': fixtureId(200000 + i),
                'purchase_order_no': 'HISTORY-$i',
                'order_status': 'received',
                'ordered_at': '2026-10-09T00:00:00Z',
                'product_name': 'Fixture product',
                'ordered_quantity_base': 1,
                'ordered_quantity_unit': 1,
                'order_unit': 'kg',
                'unit_price': 100,
                'received_quantity_base': 1,
                'accepted_quantity_base': 1,
                'rejected_quantity_base': 0,
                'last_receipt_status': 'confirmed',
                'last_receipt_at': '2026-10-09T00:00:00Z',
              },
            ),
          }),
        };
        final service = InventoryService();
        await service.fetchInventoryPurchaseOrderDetail(
          purchaseOrderId: orderId,
        );
        final samples = <double>[];
        final rssBefore = ProcessInfo.currentRss;
        var displayRows = 0;
        for (var repeat = 0; repeat < 20; repeat++) {
          calls = responseBytes = returnedRows = maxUrlBytes = historyCalls = 0;
          historyBounds.clear();
          final timer = Stopwatch()..start();
          final value = await service.fetchInventoryPurchaseOrderDetail(
            purchaseOrderId: orderId,
          );
          timer.stop();
          samples.add(timer.elapsedMicroseconds / 1000);
          displayRows =
              (((value!['lines'] as List).single as Map)['supplier_history']
                      as List)
                  .length;
          expect(displayRows, 3);
          expect(calls, 7);
          expect(returnedRows, 6);
          expect(historyCalls, 1);
          expect(
            historyBounds.every(
              (b) => b['limit'] == null && b['range'] == null,
            ),
            isTrue,
          );
        }
        samples.sort();
        final entry = <String, dynamic>{
          'history_orders': n,
          'http_calls': calls,
          'history_http_calls': historyCalls,
          'returned_http_rows': returnedRows,
          'history_rows': 3,
          'displayed_history_rows': displayRows,
          'response_bytes': responseBytes,
          'largest_request_url_bytes': maxUrlBytes,
          'sample_count': samples.length,
          'p50_client_ms': samples[9],
          'p95_client_ms': samples[18],
          'rss_before_bytes': rssBefore,
          'rss_after_bytes': ProcessInfo.currentRss,
          'process_peak_rss_bytes': ProcessInfo.maxRss,
          'history_query_bounds': historyBounds,
        };
        results.add(entry);
        print('DATA_AUDIT=${jsonEncode(entry)}');
      },
    );
  }
}
