import '../../main.dart';
import '../photo_sales_import/photo_sales_registered_export.dart';
import 'combined_sales_export.dart';
import 'daily_sales_summary.dart';
import 'restaurant_sales_export.dart';

typedef SalesReportRpc = Future<dynamic> Function(String, Map<String, dynamic>);

class DailySalesReportService {
  DailySalesReportService({SalesReportRpc? rpc})
    : _rpc = rpc ?? ((name, params) => supabase.rpc(name, params: params));
  final SalesReportRpc _rpc;

  Future<List<DailySalesSummary>> summaries(String day) async {
    final response = Map<String, dynamic>.from(
      await _rpc('get_pos_daily_sales_summary', {'p_business_date': day})
          as Map,
    );
    if (response['business_date'] != day || response['entities'] is! List) {
      throw const FormatException('SALES_SUMMARY_SCOPE_INVALID');
    }
    final rows = (response['entities'] as List)
        .map(
          (row) => DailySalesSummary.fromJson(
            day,
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList();
    if (rows.map((r) => r.taxEntityId).toSet().length != rows.length) {
      throw const FormatException('SALES_SUMMARY_DUPLICATE_ENTITY');
    }
    return rows;
  }

  Future<List<Map<String, dynamic>>> _pages(
    String day,
    String entity,
    String source,
    int expectedCount,
  ) async {
    if (expectedCount == 0) return [];
    final rows = <Map<String, dynamic>>[];
    String? afterTime, afterId;
    while (true) {
      final result = Map<String, dynamic>.from(
        await _rpc('get_pos_daily_sales_export_page', {
              'p_business_date': day,
              'p_tax_entity_id': entity,
              'p_source_system': source,
              'p_after_time': afterTime,
              'p_after_id': afterId,
              'p_limit': 100,
            })
            as Map,
      );
      if (result['business_date'] != day ||
          result['tax_entity_id'] != entity ||
          result['source_system'] != source ||
          result['rows'] is! List) {
        throw const FormatException('SALES_EXPORT_PAGE_SCOPE_INVALID');
      }
      final batch = (result['rows'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      if (batch.length > 100) {
        throw const FormatException('SALES_EXPORT_PAGE_LIMIT');
      }
      rows.addAll(batch);
      if (rows.length > expectedCount) {
        throw const FormatException('SALES_REPORT_CHANGED_REFRESH_REQUIRED');
      }
      if (batch.length < 100 || rows.length == expectedCount) break;
      final last = batch.last;
      final nextId =
          last[source == 'restaurant_pos' ? 'receipt_id' : 'source_hash']
              ?.toString();
      final nextTime = last['sold_at']?.toString();
      if (nextId == null ||
          nextTime == null ||
          (nextId == afterId && nextTime == afterTime)) {
        throw const FormatException('SALES_EXPORT_CURSOR_INVALID');
      }
      afterId = nextId;
      afterTime = nextTime;
    }
    if (rows.length != expectedCount) {
      throw const FormatException('SALES_REPORT_CHANGED_REFRESH_REQUIRED');
    }
    return rows;
  }

  Future<int> refreshPendingSnapshots(DailySalesSummary summary) async {
    final rows = await _pages(
      summary.businessDate,
      summary.taxEntityId,
      'restaurant_pos',
      summary.restaurantReceiptCount,
    );
    var updated = 0;
    for (var start = 0; start < rows.length; start += 100) {
      final ids = rows
          .skip(start)
          .take(100)
          .map((r) => r['receipt_id'])
          .toList();
      updated +=
          (await _rpc('refresh_meinvoice_export_snapshots', {
                    'p_business_date': summary.businessDate,
                    'p_tax_entity_id': summary.taxEntityId,
                    'p_order_ids': ids,
                  })
                  as num)
              .toInt();
    }
    return updated;
  }

  Future<CombinedSalesExport> loadExport(DailySalesSummary summary) async {
    // At most two keyset streams; neither creates a request for each receipt.
    final loaded = await Future.wait([
      _pages(
        summary.businessDate,
        summary.taxEntityId,
        'restaurant_pos',
        summary.restaurantReceiptCount,
      ),
      _pages(
        summary.businessDate,
        summary.taxEntityId,
        'photo_objet_moers',
        summary.photoReceiptCount,
      ),
    ]);
    final restaurant = loaded[0];
    final photo = loaded[1];
    final restaurantExports = summary.restaurantReceiptCount == 0
        ? <RestaurantSalesExport>[]
        : [
            createRestaurantSalesExport({
              'business_date': summary.businessDate,
              'status': 'ready',
              'report_ready_at': '${summary.businessDate}T00:00:00+07:00',
              'tax_entity_id': summary.taxEntityId,
              'seller_tax_code': summary.sellerTaxCode,
              'seller_legal_name': summary.sellerLegalName,
              'is_sample_entity': false,
              'store_count': restaurant
                  .map((r) => r['store_id'])
                  .toSet()
                  .length,
              'receipt_count': summary.restaurantReceiptCount,
              'gross_sales': summary.restaurantGross,
              'receipts': restaurant,
            }),
          ];
    final photoExports = summary.photoReceiptCount == 0
        ? <PhotoSalesRegisteredExport>[]
        : createPhotoSalesRegisteredExports({
            'business_date': summary.businessDate,
            'entity_count': 1,
            'entities': [
              {
                'tax_entity_id': summary.taxEntityId,
                'seller_tax_code': summary.sellerTaxCode,
                'seller_legal_name': summary.sellerLegalName,
                'store_count': photo.map((r) => r['store_id']).toSet().length,
                'receipt_count': summary.photoReceiptCount,
                'gross_sales': summary.photoGross.round(),
                'receipts': photo,
              },
            ],
          });
    final combined = combineSalesExportsByTaxEntity(
      restaurantExports: restaurantExports,
      photoExports: photoExports,
    ).single;
    if ((combined.grossSales - summary.gross).abs() > 0.01) {
      throw const FormatException('SALES_REPORT_CHANGED_REFRESH_REQUIRED');
    }
    return combined;
  }
}

final dailySalesReportService = DailySalesReportService();
