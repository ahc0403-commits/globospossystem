import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../main.dart';
import '../photo_sales_import/photo_sales_registered_export.dart';
import 'combined_sales_export.dart';
import 'restaurant_sales_export.dart';

class SalesReportingBatchService {
  SalesReportingBatchService({SupabaseClient? client}) : _client = client;
  final SupabaseClient? _client;
  SupabaseClient get client => _client ?? supabase;

  Future<Map<String, dynamic>> prepare(CombinedSalesExport export) async {
    if (export.sourceRevision == null || export.mappingRevision == null) {
      throw const FormatException('SALES_BATCH_SOURCE_CHANGED');
    }
    return Map<String, dynamic>.from(
      await client.rpc(
            'admin_prepare_sales_batch_v1',
            params: {
              'p_id': const Uuid().v4(),
              'p_date': export.businessDate,
              'p_entity': export.taxEntityId,
              'p_source_revision': export.sourceRevision,
              'p_mapping_revision': export.mappingRevision,
            },
          )
          as Map,
    );
  }

  Future<Map<String, dynamic>> update(
    String id,
    String action,
    Map<String, dynamic> payload,
  ) async => Map<String, dynamic>.from(
    await client.rpc(
          'admin_update_sales_batch_v1',
          params: {'p_id': id, 'p_action': action, 'p_payload': payload},
        )
        as Map,
  );

  Future<List<Map<String, dynamic>>> list(
    String date,
    String entity, {
    String? before,
    String? beforeId,
  }) async =>
      (await client.rpc(
                'admin_list_sales_batches_v1',
                params: {
                  'p_date': date,
                  'p_entity': entity,
                  'p_before': before,
                  'p_before_id': beforeId,
                },
              )
              as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
}

CombinedSalesExport selectSalesBatch(
  CombinedSalesExport export,
  Map<String, dynamic> batch,
) {
  final members = (batch['members'] as List).cast<Map>();
  final pos = {
    for (final m in members.where((m) => m['source'] == 'restaurant_pos'))
      m['id']: m,
  };
  final photo = {
    for (final m in members.where((m) => m['source'] == 'photo_objet_moers'))
      m['id']: m,
  };
  final restaurantRows =
      export.restaurant?.receipts
          .where((r) => pos.containsKey(r.receiptId))
          .toList() ??
      <RestaurantSalesReceipt>[];
  final photoRows =
      export.photo?.receipts
          .where((r) => photo.containsKey(r.sourceHash))
          .toList() ??
      <PhotoSalesRegisteredReceipt>[];
  bool matches(Map m, String store, num gross, String name) =>
      m['store_id'] == store &&
      double.parse(m['gross'].toString()) == gross &&
      m['store_name'] == name;
  if (batch['business_date'] != export.businessDate ||
      batch['tax_entity_id'] != export.taxEntityId ||
      pos.length != restaurantRows.length ||
      photo.length != photoRows.length ||
      restaurantRows.any(
        (r) =>
            !matches(pos[r.receiptId]!, r.storeId, r.grossSales, r.storeName) ||
            pos[r.receiptId]!['source_hash'] != r.sourceHash,
      ) ||
      photoRows.any(
        (r) => !matches(photo[r.sourceHash]!, r.storeId, r.amount, r.storeName),
      )) {
    throw const FormatException('SALES_BATCH_SOURCE_CHANGED');
  }
  final restaurant = export.restaurant;
  final photographs = export.photo;
  final selected = CombinedSalesExport(
    taxEntityId: export.taxEntityId,
    sellerTaxCode: export.sellerTaxCode,
    sellerLegalName: export.sellerLegalName,
    sourceRevision: export.sourceRevision,
    mappingRevision: export.mappingRevision,
    restaurant: restaurant == null || restaurantRows.isEmpty
        ? null
        : RestaurantSalesExport(
            businessDate: restaurant.businessDate,
            taxEntityId: restaurant.taxEntityId,
            sellerTaxCode: restaurant.sellerTaxCode,
            sellerLegalName: restaurant.sellerLegalName,
            isSampleEntity: restaurant.isSampleEntity,
            storeCount: restaurantRows.map((r) => r.storeId).toSet().length,
            receiptCount: restaurantRows.length,
            grossSales: restaurantRows.fold<double>(
              0,
              (s, r) => s + r.grossSales,
            ),
            finalizedAt: restaurant.finalizedAt,
            receipts: restaurantRows,
          ),
    photo: photographs == null || photoRows.isEmpty
        ? null
        : PhotoSalesRegisteredExport(
            businessDate: photographs.businessDate,
            taxEntityId: photographs.taxEntityId,
            sellerTaxCode: photographs.sellerTaxCode,
            sellerLegalName: photographs.sellerLegalName,
            storeCount: photoRows.map((r) => r.storeId).toSet().length,
            receiptCount: photoRows.length,
            grossSales: photoRows.fold<int>(0, (s, r) => s + r.amount),
            receipts: photoRows,
          ),
  );
  if (selected.receiptCount != batch['receipt_count'] ||
      (selected.grossSales - double.parse(batch['gross'].toString())).abs() >
          .005) {
    throw const FormatException('SALES_BATCH_TOTAL_MISMATCH');
  }
  return selected;
}
