import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/kitchen/kitchen_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Kitchen extends KitchenNotifier {
  _Kitchen(SupabaseClient client) : super(client: client);
  @override
  Future<void> subscribeRealtime(String storeId) async {}
}

void main() {
  late HttpServer server;
  late SupabaseClient client;
  late _Kitchen kitchen;
  final requests = <Uri>[];
  var activeCount = 251;
  var completedCount = 1000;
  var failPage = false;
  var repeatPage = false;
  var activeRequests = 0;
  final createdAt = DateTime.now().toUtc().toIso8601String();
  Map<String, dynamic> row(int i, String status) => {
    'id': '00000000-0000-0000-0000-${i.toString().padLeft(12, '0')}',
    'created_at': createdAt,
    'status': status,
    'order_purpose': 'customer',
    'order_source': 'qr',
    'tables': {'table_number': '$i'},
    'order_items': [
      {
        'id': 'item-$i',
        'created_at': createdAt,
        'label': 'Item',
        'quantity': 1,
        'status': status == 'completed' ? 'served' : 'pending',
        'menu_items': {'name': '메뉴', 'name_en': 'Item', 'name_vi': 'Món'},
      },
      {
        'id': 'cancelled-$i',
        'created_at': createdAt,
        'quantity': 1,
        'status': 'cancelled',
      },
    ],
  };

  setUp(() async {
    activeCount = 251;
    completedCount = 1000;
    failPage = false;
    repeatPage = false;
    activeRequests = 0;
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri);
      final params = request.uri.queryParameters;
      final completed = params['status'] == 'eq.completed';
      request.response.headers.contentType = ContentType.json;
      if (!completed) activeRequests++;
      if (failPage && !completed && activeRequests == 2) {
        request.response.statusCode = 503;
        request.response.write(jsonEncode({'message': 'fixture unavailable'}));
      } else {
        final all = completed
            ? List.generate(
                completedCount,
                (i) => row(10000 + completedCount - i, 'completed'),
              )
            : List.generate(activeCount, (i) => row(i + 1, 'pending'));
        final cursorMatch = RegExp(
          r'id.gt.([\w-]+)',
        ).firstMatch(params['or'] ?? '');
        final cursor = repeatPage ? null : cursorMatch?.group(1);
        final rows = all.where(
          (r) =>
              completed ||
              cursor == null ||
              (r['id'] as String).compareTo(cursor) > 0,
        );
        // Deliberately lower than the client's 100-row limit.
        final requestedLimit = int.parse(params['limit'] ?? '999999');
        request.response.write(
          jsonEncode(
            rows.take(requestedLimit < 50 ? requestedLimit : 50).toList(),
          ),
        );
      }
      await request.response.close();
    });
    client = SupabaseClient('http://127.0.0.1:${server.port}', 'fixture');
    kitchen = _Kitchen(client);
  });
  tearDown(() async {
    kitchen.dispose();
    await client.dispose();
    await server.close(force: true);
  });

  test(
    'active keyset pages are complete even below requested API cap; history is 12',
    () async {
      await kitchen.loadOrders('store-a');
      expect(kitchen.state.error, isNull);
      expect(kitchen.state.orders, hasLength(251));
      expect(
        kitchen.state.orders.map((r) => r.orderId).toSet(),
        hasLength(251),
      );
      expect(kitchen.state.completedOrders, hasLength(12));
      expect(kitchen.state.completedOrders.first.tableNumber, '11000');
      expect(kitchen.state.completedOrders.last.tableNumber, '10989');
      expect(kitchen.state.orders.every((r) => r.items.length == 1), isTrue);
      expect(
        kitchen.state.completedOrders.every((r) => r.items.length == 1),
        isTrue,
      );
      expect(activeRequests, 7);
      for (final request in requests) {
        final q = request.queryParameters;
        expect(q['restaurant_id'], 'eq.store-a');
        expect(request.queryParametersAll['created_at']!.length, 2);
        expect(q['limit'], q['status'] == 'eq.completed' ? '12' : '100');
        expect(q['status'], isNot(contains('serving,completed')));
      }
    },
  );

  test('empty queue terminates without unnecessary paging', () async {
    activeCount = 0;
    completedCount = 0;
    await kitchen.loadOrders('store-a');
    expect(kitchen.state.orders, isEmpty);
    expect(kitchen.state.completedOrders, isEmpty);
    expect(requests, hasLength(2));
  });

  test('failed active page does not publish a partial queue', () async {
    failPage = true;
    await kitchen.loadOrders('store-a');
    expect(kitchen.state.error, isNotNull);
    expect(kitchen.state.orders, isEmpty);
    expect(kitchen.state.completedOrders, isEmpty);
  });

  test('repeating cursor fails instead of looping indefinitely', () async {
    repeatPage = true;
    await kitchen.loadOrders('store-a');
    expect(kitchen.state.error, contains('KITCHEN_ORDER_PAGE_INVALID'));
    expect(activeRequests, 2);
  });
}
