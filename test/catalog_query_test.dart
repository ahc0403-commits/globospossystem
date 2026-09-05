import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/catalog_query_service.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late HttpServer server;
  late SupabaseClient client;
  var requests = 0;
  var fail = false;
  Completer<void>? block;
  String id(int i) =>
      '10000000-0000-0000-0000-${i.toString().padLeft(12, '0')}';
  setUp(() async {
    requests = 0;
    fail = false;
    block = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      await block?.future;
      final cursor = RegExp(
        r'id.gt.([\w-]+)',
      ).firstMatch(request.uri.queryParameters['or'] ?? '')?.group(1);
      final rows = List.generate(
        7,
        (i) => {
          'id': id(i + 1),
          'name': 'Name ${7 - i}',
          'created_at': '2026-01-01',
          'brands': null,
          'tax_entity': null,
        },
      );
      request.response.headers.contentType = ContentType.json;
      if (fail && cursor != null) {
        request.response.statusCode = 503;
        request.response.write(jsonEncode({'message': 'fixture failure'}));
      } else {
        request.response.write(
          jsonEncode(
            rows
                .where((r) => cursor == null || r['id']!.compareTo(cursor) > 0)
                .take(2)
                .toList(),
          ),
        );
      }
      await request.response.close();
    });
    client = SupabaseClient('http://127.0.0.1:${server.port}', 'fixture');
  });
  tearDown(() async {
    await client.dispose();
    await server.close(force: true);
  });
  test('catalog reads beyond a lower API cap without duplicates', () async {
    final rows = await fetchCompleteCatalog(
      () => client.from('brands').select('id,name'),
    );
    expect(rows, hasLength(7));
    expect(requests, 5);
  });
  test(
    'concurrent catalog loads share a request and publish complete data',
    () async {
      block = Completer<void>();
      final admin = SuperAdminNotifier(client: client);
      addTearDown(admin.dispose);
      final first = admin.loadBrands();
      final second = admin.loadBrands();
      block!.complete();
      await Future.wait([first, second]);
      expect(requests, 5);
      expect(admin.state.brands, hasLength(7));
      expect(admin.state.brands.first['name'], 'Name 1');
    },
  );
  test('failed store page cannot be mistaken for a complete catalog', () async {
    final admin = SuperAdminNotifier(client: client);
    addTearDown(admin.dispose);
    await admin.loadAllRestaurants();
    expect(admin.state.restaurants, hasLength(7));
    fail = true;
    await admin.loadAllRestaurants();
    expect(admin.state.restaurants, isEmpty);
    expect(admin.state.error, isNotNull);
  });
  test(
    'force refresh waits for in-flight read and then fetches again',
    () async {
      final admin = SuperAdminNotifier(client: client);
      addTearDown(admin.dispose);
      block = Completer<void>();
      final first = admin.loadBrands();
      final second = admin.loadBrands(force: true);
      block!.complete();
      await Future.wait([first, second]);
      expect(requests, 10);
    },
  );
  test('disposed catalog provider ignores a late result', () async {
    final admin = SuperAdminNotifier(client: client);
    block = Completer<void>();
    final pending = admin.loadBrands();
    admin.dispose();
    block!.complete();
    await pending;
  });
}
