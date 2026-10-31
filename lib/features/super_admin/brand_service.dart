import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/pos_backend.dart';

class BrandPage {
  const BrandPage(this.items, this.hasMore);
  final List<Map<String, dynamic>> items;
  final bool hasMore;
}

/// Each page is one bounded RPC, including links and store counts.
class BrandService {
  BrandService(this.client);
  final SupabaseClient client;

  Future<List<Map<String, dynamic>>> groups() async =>
      (await client.rpc('admin_brand_groups_v1') as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();

  Future<BrandPage> list({
    String search = '',
    Map<String, dynamic>? after,
  }) async {
    final result = Map<String, dynamic>.from(
      await client.rpc(
            'admin_list_brands_v1',
            params: {
              'p_search': search,
              'p_after_name': after?['name'],
              'p_after_id': after?['id'],
              'p_limit': 50,
            },
          )
          as Map,
    );
    return BrandPage(
      (result['items'] as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList(),
      result['has_more'] == true,
    );
  }

  Future<Map<String, dynamic>> create({
    required String id,
    required String name,
    required String code,
    required String groupId,
    required List<String> taxEntityIds,
  }) async => Map<String, dynamic>.from(
    await client.rpc(
          'admin_create_brand_v2',
          params: {
            'p_brand_id': id,
            'p_name': name,
            'p_code': code,
            'p_brand_master_id': groupId,
            'p_tax_entity_ids': taxEntityIds,
          },
        )
        as Map,
  );

  Future<Map<String, dynamic>> link({
    required String brandId,
    required List<String> taxEntityIds,
    String? code,
  }) async => Map<String, dynamic>.from(
    await client.rpc(
          'admin_update_brand_registration_v2',
          params: {
            'p_brand_id': brandId,
            'p_code': code,
            'p_tax_entity_ids': taxEntityIds,
          },
        )
        as Map,
  );
}

final brandServiceProvider = Provider<BrandService>(
  (ref) => BrandService(supabase),
);
