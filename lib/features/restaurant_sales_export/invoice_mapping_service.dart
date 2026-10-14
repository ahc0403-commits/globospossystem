import 'dart:convert';
import 'daily_sales_report_service.dart';

class InvoiceMappingImport {
  InvoiceMappingImport.parse(String json) {
    final payload = jsonDecode(json);
    if (payload is! Map ||
        payload['format_version'] != 'pos-invoice-mapping-v1' ||
        payload['rows'] is! List) {
      throw const FormatException('INVOICE_MAPPING_FILE_INVALID');
    }
    taxEntityId = payload['tax_entity_id'] as String;
    rows = (payload['rows'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    if (rows.isEmpty || rows.length > 10000) {
      throw const FormatException('INVOICE_MAPPING_BATCH_LIMIT');
    }
    final keys = <String>{};
    for (final row in rows) {
      for (final field in [
        'invoice_name_vi',
        'unit_name',
        'mapping_version',
        'source_reference',
        'effective_from',
      ]) {
        if ('${row[field] ?? ''}'.trim().isEmpty) {
          throw FormatException('INVOICE_MAPPING_REQUIRED:$field');
        }
      }
      final from = DateTime.tryParse(row['effective_from'].toString());
      final to = row['effective_to'] == null
          ? null
          : DateTime.tryParse(row['effective_to'].toString());
      if (from == null ||
          (row['effective_to'] != null && (to == null || !to.isAfter(from)))) {
        throw const FormatException('INVOICE_MAPPING_PERIOD_INVALID');
      }
      if (row['approval_type'] != 'menu_item' &&
          row['approval_type'] != 'item_type') {
        throw const FormatException('INVOICE_MAPPING_TYPE_INVALID');
      }
      final key =
          '${row['approval_type']}:${row['menu_item_id'] ?? row['item_type']}';
      if (!keys.add(key)) {
        throw const FormatException('INVOICE_MAPPING_DUPLICATE');
      }
    }
  }
  late final String taxEntityId;
  late final List<Map<String, dynamic>> rows;
}

/// Read scope once, then sequential atomic batches of at most 100 approvals.
class InvoiceMappingService {
  InvoiceMappingService(this.rpc);
  final SalesReportRpc rpc;

  Future<Map<String, dynamic>> catalog({String? taxEntityId}) async {
    final rows = <Map<String, dynamic>>[];
    Map<String, dynamic>? first;
    String? after;
    while (true) {
      final page = Map<String, dynamic>.from(
        await rpc('get_invoice_mapping_catalog', {
              'p_tax_entity_id': taxEntityId,
              'p_after_id': after,
              'p_limit': 100,
            })
            as Map,
      );
      first ??= page;
      if (page['total_count'] != first['total_count'] ||
          page['catalog_revision'] != first['catalog_revision']) {
        throw const FormatException('INVOICE_CATALOG_CHANGED_REFRESH_REQUIRED');
      }
      final batch = (page['rows'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      for (final row in batch) {
        final id = row['id'] as String;
        if (after != null && id.compareTo(after) <= 0) {
          throw const FormatException('INVOICE_CATALOG_CURSOR_INVALID');
        }
        after = id;
      }
      rows.addAll(batch);
      if (rows.length == first['total_count']) break;
      if (batch.length != 100 || rows.length > (first['total_count'] as int)) {
        throw const FormatException('INVOICE_CATALOG_CHANGED_REFRESH_REQUIRED');
      }
    }
    return {...first, 'rows': rows};
  }

  Future<int> applyPolicy(
    List<Map<String, dynamic>> rows, {
    required String effectiveFrom,
  }) async {
    final stores = <String, List<String>>{};
    for (final row in rows) {
      if (row['mapping_status'] == 'mapped') continue;
      stores
          .putIfAbsent(row['store_id'] as String, () => [])
          .add(row['id'] as String);
    }
    var changed = 0;
    for (final entry in stores.entries) {
      for (var start = 0; start < entry.value.length; start += 100) {
        final result = Map<String, dynamic>.from(
          await rpc('apply_invoice_mapping_policy_batch', {
                'p_store_id': entry.key,
                'p_menu_ids': entry.value.skip(start).take(100).toList(),
                'p_effective_from': effectiveFrom,
              })
              as Map,
        );
        changed += (result['profiles'] as List).length;
      }
    }
    return changed;
  }

  Future<int> approve(InvoiceMappingImport input, String selectedEntity) async {
    if (input.taxEntityId != selectedEntity) {
      throw const FormatException('INVOICE_MAPPING_ENTITY_MISMATCH');
    }
    final menuIds = input.rows
        .where((r) => r['approval_type'] == 'menu_item')
        .map((r) => r['menu_item_id'])
        .toList();
    final storeNames = input.rows
        .expand((r) => (r['store_names'] as List? ?? []))
        .toSet()
        .toList();
    // Validate every scope before any write. Each endpoint accepts at most 100
    // identifiers, while an import can span many endpoint-sized batches.
    final scope = <String, List<dynamic>>{'menus': [], 'stores': []};
    final length = menuIds.length > storeNames.length
        ? menuIds.length
        : storeNames.length;
    for (var start = 0; start < length; start += 100) {
      final batch = Map<String, dynamic>.from(
        await rpc('resolve_invoice_mapping_scope', {
              'p_tax_entity_id': selectedEntity,
              'p_menu_ids': menuIds.skip(start).take(100).toList(),
              'p_store_names': storeNames.skip(start).take(100).toList(),
            })
            as Map,
      );
      scope['menus']!.addAll(batch['menus'] as List);
      scope['stores']!.addAll(batch['stores'] as List);
    }
    final menus = {
      for (final m in scope['menus'] as List) m['menu_item_id']: m['store_id'],
    };
    if (menus.length != menuIds.length) {
      throw const FormatException('INVOICE_MAPPING_MENU_SCOPE_INVALID');
    }
    final stores = <String, String>{};
    for (final s in scope['stores'] as List) {
      if (stores.containsKey(s['store_name'])) {
        throw const FormatException('INVOICE_MAPPING_STORE_AMBIGUOUS');
      }
      stores[s['store_name'] as String] = s['store_id'] as String;
    }
    if (stores.length != storeNames.length) {
      throw const FormatException('INVOICE_MAPPING_STORE_SCOPE_INVALID');
    }
    final batches = <String, List<Map<String, dynamic>>>{};
    for (final r in input.rows) {
      final ids = r['approval_type'] == 'menu_item'
          ? [menus[r['menu_item_id']] as String]
          : (r['store_names'] as List).map((n) => stores[n]!).toList();
      for (final id in ids) {
        batches.putIfAbsent(id, () => []).add({...r}..remove('store_names'));
      }
    }
    var count = 0;
    for (final entry in batches.entries) {
      for (var i = 0; i < entry.value.length; i += 100) {
        final chunk = entry.value.skip(i).take(100).toList();
        final result = Map<String, dynamic>.from(
          await rpc('approve_invoice_mapping_batch', {
                'p_store_id': entry.key,
                'p_tax_entity_id': selectedEntity,
                'p_rows': chunk,
              })
              as Map,
        );
        if (result['store_id'] != entry.key ||
            result['tax_entity_id'] != selectedEntity ||
            (result['profiles'] as List).length != chunk.length) {
          throw const FormatException(
            'INVOICE_MAPPING_APPROVAL_RESULT_INVALID',
          );
        }
        count += chunk.length;
      }
    }
    return count;
  }
}
