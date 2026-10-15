import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/super_admin/brand_service.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late HttpServer server;
  late SupabaseClient client;
  late BrandService service;
  final requests = <({String path, Map<String, dynamic> body})>[];
  Completer<void>? block;
  var fail = false;
  List<Map<String, dynamic>> catalogRows = [];
  List<Map<String, dynamic>> linkRows = [];
  setUp(() async {
    requests.clear();
    block = null;
    fail = false;
    catalogRows = [];
    linkRows = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add((
        path: request.uri.path,
        body: body.isEmpty ? {} : jsonDecode(body) as Map<String, dynamic>,
      ));
      await block?.future;
      request.response.headers.contentType = ContentType.json;
      if (fail) {
        request.response.statusCode = 503;
        request.response.write(jsonEncode({'message': 'unavailable'}));
      } else if (request.uri.path.endsWith('admin_list_brands_v1')) {
        request.response.write(
          jsonEncode({
            'items': List.generate(
              50,
              (i) => {
                'id':
                    '50000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
                'name': 'Brand $i',
                'code': 'brand_$i',
                'store_count': 100,
                'tax_entity_ids': ['entity-1', 'entity-2'],
                'tax_entity_names': ['A', 'B'],
              },
            ),
            'has_more': true,
          }),
        );
      } else if (request.uri.path.contains('/rpc/')) {
        request.response.write(
          jsonEncode({
            'id': 'brand',
            'name': 'New brand',
            'code': 'new_brand',
            'short_code': 'NB',
            'tax_entity_ids': ['entity-1'],
          }),
        );
      } else {
        request.response.write(
          jsonEncode(
            request.uri.queryParameters.containsKey('or')
                ? []
                : request.uri.path.endsWith('/brands')
                ? catalogRows
                : linkRows,
          ),
        );
      }
      await request.response.close();
    });
    client = SupabaseClient('http://127.0.0.1:${server.port}', 'fixture');
    service = BrandService(client);
  });
  tearDown(() async {
    await client.dispose();
    await server.close(force: true);
  });

  test('50 brands, their links and counts use one request per page', () async {
    final page = await service.list(search: 'Brand');
    expect(page.items, hasLength(50));
    expect(page.hasMore, isTrue);
    expect(requests, hasLength(1));
    expect(requests.single.body['p_limit'], 50);
    expect(requests.single.body['p_search'], 'Brand');
    await service.list(search: 'Brand', after: page.items.last);
    expect(requests, hasLength(2));
    expect(requests.last.body['p_after_id'], page.items.last['id']);
    expect(requests.last.body['p_after_name'], page.items.last['name']);
  });

  test(
    'create and link commit results update store choices without catalog reload',
    () async {
      final admin = SuperAdminNotifier(client: client);
      addTearDown(admin.dispose);
      final created = await service.create(
        id: 'brand',
        name: 'New brand',
        code: 'NB',
        groupId: 'group',
        taxEntityIds: [],
      );
      admin.applyBrandMutation(created);
      expect(admin.state.restaurants, isEmpty);
      expect(admin.state.brandsForTaxEntity('entity-1').single['id'], 'brand');
      final linked = await service.link(
        brandId: 'brand',
        code: 'NB',
        taxEntityIds: ['entity-1'],
      );
      admin.applyBrandMutation(linked);
      expect(requests.last.body['p_code'], 'NB');
      expect(requests.first.path, endsWith('admin_create_brand_v2'));
      expect(requests, hasLength(2));
      expect(admin.state.brands, hasLength(1));
      expect(admin.state.taxEntityBrands, hasLength(1));
      expect(requests.first.body['p_tax_entity_ids'], isEmpty);
      expect(
        requests.last.path,
        endsWith('admin_update_brand_registration_v2'),
      );
    },
  );

  test(
    'late catalog snapshot cannot erase a committed brand or its links',
    () async {
      final admin = SuperAdminNotifier(client: client);
      addTearDown(admin.dispose);
      const oldBrandId = '50000000-0000-4000-8000-000000000099';
      const oldEntityId = '40000000-0000-4000-8000-000000000099';
      catalogRows = [
        {'id': oldBrandId, 'name': 'Existing', 'code': 'existing'},
      ];
      linkRows = [
        {'tax_entity_id': oldEntityId, 'brand_id': oldBrandId},
      ];
      block = Completer<void>();
      final pending = admin.loadBrands();
      final links = admin.loadBrandLinks();
      admin.applyBrandMutation({
        'id': 'brand',
        'name': 'New brand',
        'code': 'new_brand',
        'short_code': 'NB',
        'tax_entity_ids': ['entity-1'],
      });
      block!.complete();
      await Future.wait([pending, links]);
      expect(
        admin.state.brands.map((b) => b['id']),
        containsAll([oldBrandId, 'brand']),
      );
      expect(admin.state.brandsForTaxEntity('entity-1'), hasLength(1));
      expect(
        admin.state.brandsForTaxEntity(oldEntityId).single['id'],
        oldBrandId,
      );
    },
  );

  test(
    'failed catalog load preserves last complete data and exposes error',
    () async {
      final admin = SuperAdminNotifier(client: client);
      addTearDown(admin.dispose);
      admin.applyBrandMutation({
        'id': 'brand',
        'name': 'New brand',
        'code': 'new_brand',
        'short_code': 'NB',
        'tax_entity_ids': [],
      });
      fail = true;
      await admin.loadBrands();
      expect(admin.state.brands, hasLength(1));
      expect(admin.state.error, isNotNull);
    },
  );
}
