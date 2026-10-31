import '../../core/services/pos_backend.dart';
import '../admin/einvoice_misa_workbook.dart';
import '../photo_sales_import/photo_sales_registered_export.dart';
import 'combined_sales_export.dart';
import 'daily_sales_summary.dart';
import 'restaurant_sales_export.dart';

typedef SalesReportRpc = Future<dynamic> Function(String, Map<String, dynamic>);

class DailySalesReportService {
  DailySalesReportService({
    SalesReportRpc? rpc,
    String Function()? sessionKey,
    DateTime Function()? now,
  }) : _rpc = rpc ?? ((name, params) => supabase.rpc(name, params: params)),
       _now = now ?? DateTime.now,
       _sessionKey =
           sessionKey ??
           (rpc == null
               ? (() =>
                     '${supabase.auth.currentUser?.id}:${supabase.auth.currentSession?.accessToken.hashCode}')
               : (() => '${identityHashCode(rpc)}'));
  final String Function() _sessionKey;
  final DateTime Function() _now;
  final SalesReportRpc _rpc;
  final _inflight = <String, Future<CombinedSalesExport>>{};
  final _summaryInflight = <String, Future<List<DailySalesSummary>>>{};
  final _summaryCache =
      <String, ({DateTime expires, List<DailySalesSummary> rows})>{};
  int _summaryGeneration = 0;
  void invalidateSummary([String? day]) {
    _summaryGeneration++;
    _summaryCache.removeWhere((key, _) => day == null || key.endsWith(':$day'));
    _summaryInflight.removeWhere(
      (key, _) => day == null || key.endsWith(':$day'),
    );
  }

  Future<dynamic> mappingRpc(String name, Map<String, dynamic> params) =>
      _rpc(name, params);

  Future<Map<String, dynamic>> bankTransfers({
    required String fromDate,
    required String toDate,
    String? taxEntityId,
    String? storeId,
    String? afterTime,
    String? afterId,
  }) async {
    final session = _sessionKey();
    final result = Map<String, dynamic>.from(
      await _rpc('get_bank_transfer_sales_page', {
            'p_from_date': fromDate,
            'p_to_date': toDate,
            'p_tax_entity_id': taxEntityId,
            'p_store_id': storeId,
            'p_after_time': afterTime,
            'p_after_id': afterId,
            'p_limit': 100,
          })
          as Map,
    );
    if (_sessionKey() != session) {
      throw const FormatException('BANK_TRANSFER_SESSION_CHANGED');
    }
    if (result['from_date'] != fromDate ||
        result['to_date'] != toDate ||
        result['tax_entity_id'] != taxEntityId ||
        result['store_id'] != storeId ||
        result['has_more'] is! bool ||
        result['rows'] is! List ||
        (result['rows'] as List).length > 100) {
      throw const FormatException('BANK_TRANSFER_PAGE_INVALID');
    }
    DateTime? previous = afterTime == null ? null : DateTime.parse(afterTime);
    String? previousId = afterId;
    for (final value in result['rows'] as List) {
      final row = Map<String, dynamic>.from(value as Map);
      final time = DateTime.tryParse(row['created_at']?.toString() ?? '');
      final id = row['payment_id'];
      final amount = row['amount'];
      if (time == null ||
          id is! String ||
          id.isEmpty ||
          amount is! num ||
          !amount.isFinite ||
          amount < 0 ||
          row['store_name'] is! String ||
          (storeId != null && row['store_id'] != storeId) ||
          restaurantHcmBusinessDate(time).compareTo(fromDate) < 0 ||
          restaurantHcmBusinessDate(time).compareTo(toDate) > 0 ||
          (previous != null &&
              (time.isBefore(previous) ||
                  (time.isAtSameMomentAs(previous) &&
                      id.compareTo(previousId!) <= 0)))) {
        throw const FormatException('BANK_TRANSFER_PAGE_INVALID');
      }
      previous = time;
      previousId = id;
    }
    if (result['has_more'] == true && (result['rows'] as List).isEmpty) {
      throw const FormatException('BANK_TRANSFER_PAGE_INVALID');
    }
    return result;
  }

  Future<List<DailySalesSummary>> summaries(String day) {
    final key = '${_sessionKey()}:$day';
    final cached = _summaryCache[key];
    if (cached != null && _now().isBefore(cached.expires)) {
      return Future.value(cached.rows);
    }
    final generation = _summaryGeneration;
    final session = _sessionKey();
    return _summaryInflight.putIfAbsent(key, () {
      late final Future<List<DailySalesSummary>> request;
      request = _summaries(day)
          .then((rows) {
            if (_sessionKey() != session) {
              throw const FormatException('SALES_SUMMARY_SCOPE_INVALID');
            }
            if (generation == _summaryGeneration) {
              _summaryCache.removeWhere(
                (_, entry) => !_now().isBefore(entry.expires),
              );
              if (_summaryCache.length >= 32) {
                _summaryCache.remove(_summaryCache.keys.first);
              }
              _summaryCache[key] = (
                expires: _now().add(const Duration(seconds: 30)),
                rows: rows,
              );
            }
            return rows;
          })
          .whenComplete(() {
            if (identical(_summaryInflight[key], request)) {
              _summaryInflight.remove(key);
            }
          });
      return request;
    });
  }

  Future<List<DailySalesSummary>> _summaries(
    String day, {
    bool includeExportMetadata = false,
  }) async {
    final response = Map<String, dynamic>.from(
      await _rpc('get_pos_daily_sales_summary', {
            'p_business_date': day,
            'p_include_export_metadata': includeExportMetadata,
          })
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
            asOf: DateTime.tryParse(response['as_of']?.toString() ?? ''),
          ),
        )
        .toList();
    if (rows.map((r) => r.taxEntityId).toSet().length != rows.length) {
      throw const FormatException('SALES_SUMMARY_DUPLICATE_ENTITY');
    }
    return List.unmodifiable(rows);
  }

  Future<List<Map<String, dynamic>>> _pages(
    String day,
    String entity,
    String source,
    int expectedCount, {
    int? mappingRevision,
    String? sourceRevision,
  }) async {
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
      if (result['externally_reported'] == true) {
        throw SalesExportValidationException([
          SalesExportIssue(
            receiptId: '$day:$entity',
            receiptNumber: day,
            source: source,
            itemId: '',
            itemName: '',
            field: 'scope',
            code: 'SALES_EXPORT_EXTERNALLY_REPORTED',
            soldAt: day,
          ),
        ]);
      }
      if (sourceRevision != null &&
          result['source_revision'] != sourceRevision) {
        throw const FormatException('SALES_REPORT_CHANGED_REFRESH_REQUIRED');
      }
      if (mappingRevision != null &&
          result['mapping_revision'] != mappingRevision) {
        throw const FormatException('SALES_REPORT_CHANGED_REFRESH_REQUIRED');
      }
      final batch = (result['rows'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      if (batch.length > 100) {
        throw const FormatException('SALES_EXPORT_PAGE_LIMIT');
      }
      for (final row in batch) {
        final id =
            row[source == 'restaurant_pos' ? 'receipt_id' : 'source_hash']
                ?.toString();
        final time = DateTime.tryParse(row['sold_at']?.toString() ?? '');
        final prevTime = afterTime == null
            ? null
            : DateTime.tryParse(afterTime);
        if (id == null ||
            id.isEmpty ||
            time == null ||
            restaurantHcmBusinessDate(time) != day ||
            (row['tax_entity_id'] != null && row['tax_entity_id'] != entity) ||
            (prevTime != null &&
                (time.isBefore(prevTime) ||
                    (time.isAtSameMomentAs(prevTime) &&
                        id.compareTo(afterId!) <= 0)))) {
          throw const FormatException('SALES_EXPORT_CURSOR_INVALID');
        }
        afterTime = row['sold_at'].toString();
        afterId = id;
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
      if (nextId == null || nextTime == null || nextId.isEmpty) {
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

  Future<Map<String, dynamic>> revalidatePendingSnapshots(
    DailySalesSummary summary, {
    List<String>? receiptIds,
  }) async {
    final rows = receiptIds == null
        ? await _pages(
            summary.businessDate,
            summary.taxEntityId,
            'restaurant_pos',
            summary.restaurantReceiptCount,
          )
        : [
            for (final id in receiptIds) {'receipt_id': id},
          ];
    final result = <String, dynamic>{
      'target_count': 0,
      'updated_count': 0,
      'unchanged_count': 0,
      'protected_count': 0,
      'error_count': 0,
      'receipts': <dynamic>[],
    };
    for (var start = 0; start < rows.length; start += 100) {
      final ids = rows
          .skip(start)
          .take(100)
          .map((r) => r['receipt_id'])
          .toList();
      final batch = Map<String, dynamic>.from(
        await _rpc('revalidate_meinvoice_export_snapshots', {
              'p_business_date': summary.businessDate,
              'p_tax_entity_id': summary.taxEntityId,
              'p_order_ids': ids,
            })
            as Map,
      );
      if (batch['target_count'] != ids.length) {
        throw const FormatException('INVOICE_EXPORT_SCOPE_CHANGED');
      }
      for (final key in [
        'target_count',
        'updated_count',
        'unchanged_count',
        'protected_count',
        'error_count',
      ]) {
        result[key] = (result[key] as int) + (batch[key] as num).toInt();
      }
      (result['receipts'] as List).addAll(batch['receipts'] as List);
    }
    return result;
  }

  Future<int> refreshPendingSnapshots(DailySalesSummary summary) async =>
      (await revalidatePendingSnapshots(summary))['updated_count'] as int;

  Future<CombinedSalesExport> loadExport(DailySalesSummary summary) {
    final key =
        '${_sessionKey()}:${summary.businessDate}:${summary.taxEntityId}:${summary.mappingRevision}:${summary.sourceRevision}:${summary.gross}:${summary.receiptCount}';
    return _inflight.putIfAbsent(
      key,
      () => _loadExport(summary).whenComplete(() {
        _inflight.remove(key);
      }),
    );
  }

  Future<CombinedSalesExport> _loadExport(DailySalesSummary summary) async {
    final session = _sessionKey();
    if (summary.exportMetadataDeferred) {
      final current = (await _summaries(
        summary.businessDate,
        includeExportMetadata: true,
      )).where((s) => s.taxEntityId == summary.taxEntityId).single;
      if (session != _sessionKey() ||
          current.exportMetadataDeferred ||
          current.sourceRevision == null ||
          current.gross != summary.gross ||
          current.receiptCount != summary.receiptCount ||
          current.mappingRevision != summary.mappingRevision ||
          current.externallyReported) {
        throw const FormatException('SALES_REPORT_CHANGED_REFRESH_REQUIRED');
      }
      summary = current;
    }
    // At most two keyset streams; neither creates a request for each receipt.
    final loaded = await Future.wait([
      _pages(
        summary.businessDate,
        summary.taxEntityId,
        'restaurant_pos',
        summary.restaurantReceiptCount,
        mappingRevision: summary.mappingRevision,
        sourceRevision: summary.sourceRevision,
      ),
      _pages(
        summary.businessDate,
        summary.taxEntityId,
        'photo_objet_moers',
        summary.photoReceiptCount,
        mappingRevision: summary.mappingRevision,
        sourceRevision: summary.sourceRevision,
      ),
    ]);
    final restaurant = loaded[0];
    final photo = loaded[1];
    final issues = validateSalesExportJobs([
      for (final r in restaurant)
        {
          ...r,
          'created_at': r['sold_at'],
          'line_items_snapshot': r['line_items'],
          'tax_entity_id': summary.taxEntityId,
        },
    ]);
    if (issues.isNotEmpty) throw SalesExportValidationException(issues);
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
    if (summary.exportLineCount != null &&
        (combined.lineCount != summary.exportLineCount ||
            combined.sourceItemCount != summary.sourceItemCount)) {
      throw const FormatException('SALES_REPORT_CHANGED_REFRESH_REQUIRED');
    }
    if ((combined.grossSales - summary.gross).abs() > 0.01) {
      throw const FormatException('SALES_REPORT_CHANGED_REFRESH_REQUIRED');
    }
    if (session != _sessionKey()) {
      throw const FormatException('SALES_EXPORT_SESSION_CHANGED');
    }
    return CombinedSalesExport(
      taxEntityId: combined.taxEntityId,
      sellerTaxCode: combined.sellerTaxCode,
      sellerLegalName: combined.sellerLegalName,
      restaurant: combined.restaurant,
      photo: combined.photo,
      sourceRevision: summary.sourceRevision,
      mappingRevision: summary.mappingRevision,
    );
  }
}

final dailySalesReportService = DailySalesReportService();
