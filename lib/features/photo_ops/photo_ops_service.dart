import '../../core/services/attendance_service.dart';
import '../../core/services/inventory_service.dart';
import '../../core/services/payroll_service.dart';
import '../../main.dart';
import 'photo_ops_sales_export.dart';

const _photoObjetBrandId = '77000000-0000-0000-0000-000000000001';
const _photoSalesExportPageSize = 1000;

class PhotoOpsKpi {
  const PhotoOpsKpi({
    required this.allAttendanceEvents,
    required this.activeAttendanceEvents,
    required this.allInventoryAlerts,
    required this.activeInventoryAlerts,
    required this.activePayrollEstimate,
    this.activeStoreSales = 0,
    this.networkSales = 0,
    this.activeStoreTransactions = 0,
    this.lastSalesPulledAt,
  });

  final int allAttendanceEvents;
  final int activeAttendanceEvents;
  final int allInventoryAlerts;
  final int activeInventoryAlerts;
  final double activePayrollEstimate;

  /// Gross sales for the active store on the latest completed sales date.
  final double activeStoreSales;

  /// Gross sales across every accessible store on the latest completed date.
  final double networkSales;

  /// Transaction count for the active store on the latest completed date.
  final int activeStoreTransactions;

  /// Timestamp of the most recent sales pull in the accessible scope.
  final DateTime? lastSalesPulledAt;
}

class PhotoOpsAttendanceRow {
  const PhotoOpsAttendanceRow({
    required this.employeeName,
    required this.type,
    required this.loggedAt,
  });

  final String employeeName;
  final String type;
  final DateTime loggedAt;
}

class PhotoOpsInventoryRow {
  const PhotoOpsInventoryRow({
    required this.ingredientId,
    required this.itemName,
    required this.currentStock,
    required this.unit,
    this.reorderPoint,
    required this.needsReorder,
    this.supplierName,
  });

  final String ingredientId;
  final String itemName;
  final double currentStock;
  final String unit;
  final double? reorderPoint;
  final bool needsReorder;
  final String? supplierName;
}

class PhotoOpsPayrollRow {
  const PhotoOpsPayrollRow({
    required this.employeeName,
    required this.totalHours,
    required this.totalAmount,
    required this.shiftCount,
  });

  final String employeeName;
  final double totalHours;
  final double totalAmount;
  final int shiftCount;
}

class PhotoOpsSalesRow {
  const PhotoOpsSalesRow({
    required this.storeId,
    required this.storeName,
    required this.saleDate,
    required this.grossSales,
    required this.totalTransactions,
    required this.serviceAmount,
    required this.activeMachines,
    this.lastPulledAt,
  });

  final String storeId;
  final String storeName;
  final DateTime saleDate;
  final double grossSales;
  final int totalTransactions;
  final double serviceAmount;
  final int activeMachines;
  final DateTime? lastPulledAt;
}

class PhotoOpsDashboardData {
  const PhotoOpsDashboardData({
    required this.kpi,
    required this.recentAttendance,
    required this.inventoryAlerts,
    required this.payrollPreview,
    this.inventoryItems = const [],
    this.salesSummary = const [],
    this.salesWarningCode,
    this.salesWarningDetail,
    this.attendanceWarningDetail,
    this.inventoryWarningDetail,
    this.payrollWarningDetail,
  });

  final PhotoOpsKpi kpi;
  final List<PhotoOpsAttendanceRow> recentAttendance;
  final List<PhotoOpsInventoryRow> inventoryAlerts;
  final List<PhotoOpsPayrollRow> payrollPreview;

  /// Full catalog for the active store. Alerts remain available separately
  /// for KPI and priority-queue presentation.
  final List<PhotoOpsInventoryRow> inventoryItems;

  /// Latest completed HCM sales-date rows for accessible stores.
  final List<PhotoOpsSalesRow> salesSummary;

  /// Wave 1.6 sales-overlay: warning code emitted by the sales loader
  /// when the dashboard window is degraded (e.g. partial pull).
  final String? salesWarningCode;

  /// Wave 1.6 sales-overlay: human-readable diagnostic for the warning
  /// code above. Null when no warning is active.
  final String? salesWarningDetail;
  final String? attendanceWarningDetail;
  final String? inventoryWarningDetail;
  final String? payrollWarningDetail;
}

class PhotoOpsSalesSnapshot {
  const PhotoOpsSalesSnapshot({
    required this.rows,
    required this.activeStoreSales,
    required this.networkSales,
    required this.activeStoreTransactions,
    required this.lastSalesPulledAt,
  });

  final List<PhotoOpsSalesRow> rows;
  final double activeStoreSales;
  final double networkSales;
  final int activeStoreTransactions;
  final DateTime? lastSalesPulledAt;
}

String photoOpsHcmDate(DateTime value) {
  final hcm = value.toUtc().add(const Duration(hours: 7));
  return '${hcm.year.toString().padLeft(4, '0')}-'
      '${hcm.month.toString().padLeft(2, '0')}-'
      '${hcm.day.toString().padLeft(2, '0')}';
}

PhotoOpsSalesSnapshot summarizePhotoOpsSales({
  required String activeStoreId,
  required List<Map<String, dynamic>> rows,
}) {
  final salesRows = <PhotoOpsSalesRow>[];
  var activeStoreSales = 0.0;
  var networkSales = 0.0;
  var activeStoreTransactions = 0;
  DateTime? lastSalesPulledAt;

  for (final row in rows) {
    final storeId = row['store_id']?.toString().trim() ?? '';
    final saleDate = DateTime.tryParse(row['sale_date']?.toString() ?? '');
    if (storeId.isEmpty || saleDate == null) continue;

    final grossSales = _photoOpsDouble(row['total_gross_sales']);
    final totalTransactions = _photoOpsInt(row['total_transactions']);
    final pulledAt = DateTime.tryParse(row['last_pulled_at']?.toString() ?? '');
    final salesRow = PhotoOpsSalesRow(
      storeId: storeId,
      storeName: row['store_name']?.toString().trim().isNotEmpty == true
          ? row['store_name'].toString().trim()
          : storeId,
      saleDate: saleDate,
      grossSales: grossSales,
      totalTransactions: totalTransactions,
      serviceAmount: _photoOpsDouble(row['total_service_amount']),
      activeMachines: _photoOpsInt(row['active_machines']),
      lastPulledAt: pulledAt,
    );
    salesRows.add(salesRow);
    networkSales += grossSales;

    if (storeId == activeStoreId) {
      activeStoreSales += grossSales;
      activeStoreTransactions += totalTransactions;
    }
    if (pulledAt != null &&
        (lastSalesPulledAt == null || pulledAt.isAfter(lastSalesPulledAt))) {
      lastSalesPulledAt = pulledAt;
    }
  }

  salesRows.sort((a, b) {
    final dateOrder = b.saleDate.compareTo(a.saleDate);
    return dateOrder != 0 ? dateOrder : a.storeName.compareTo(b.storeName);
  });

  return PhotoOpsSalesSnapshot(
    rows: salesRows,
    activeStoreSales: activeStoreSales,
    networkSales: networkSales,
    activeStoreTransactions: activeStoreTransactions,
    lastSalesPulledAt: lastSalesPulledAt,
  );
}

double _photoOpsDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

int _photoOpsInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

class PhotoOpsService {
  Future<PhotoOpsDashboardData> loadOperatorDashboard({
    required String activeStoreId,
  }) async {
    final now = DateTime.now();
    var attendanceRaw = <Map<String, dynamic>>[];
    var inventoryRaw = <Map<String, dynamic>>[];
    String? attendanceWarningDetail;
    String? inventoryWarningDetail;

    await Future.wait<void>([
      () async {
        try {
          attendanceRaw = await attendanceService.fetchLogs(
            storeId: activeStoreId,
            from: now.subtract(const Duration(days: 6)),
            to: now.add(const Duration(days: 1)),
          );
        } catch (error) {
          attendanceWarningDetail = error.toString();
        }
      }(),
      () async {
        try {
          inventoryRaw = await inventoryService.fetchIngredients(activeStoreId);
        } catch (error) {
          inventoryWarningDetail = error.toString();
        }
      }(),
    ]);

    final attendance = _attendanceRows(attendanceRaw);
    final inventoryItems = _inventoryRows(inventoryRaw);
    final inventoryAlerts = inventoryItems
        .where((row) => row.needsReorder)
        .take(10)
        .toList();
    return PhotoOpsDashboardData(
      kpi: PhotoOpsKpi(
        allAttendanceEvents: attendance.length,
        activeAttendanceEvents: attendance.length,
        allInventoryAlerts: inventoryAlerts.length,
        activeInventoryAlerts: inventoryAlerts.length,
        activePayrollEstimate: 0,
      ),
      recentAttendance: attendance,
      inventoryAlerts: inventoryAlerts,
      inventoryItems: inventoryItems,
      payrollPreview: const [],
      attendanceWarningDetail: attendanceWarningDetail,
      inventoryWarningDetail: inventoryWarningDetail,
    );
  }

  Future<PhotoOpsSalesExport> loadSalesExport({
    required List<String> accessibleStoreIds,
    required String saleDate,
  }) async {
    if (accessibleStoreIds.isEmpty) {
      throw const FormatException('PHOTO_EXPORT_NO_ACCESSIBLE_STORES');
    }

    final policyResponse = await supabase
        .from('photo_objet_monitoring_policies')
        .select('store_id')
        .inFilter('store_id', accessibleStoreIds)
        .eq('schedule_version', 'hcm-eod-2220-v3')
        .eq('is_enabled', true)
        .isFilter('effective_to', null);
    final configuredStoreIds = List<Map<String, dynamic>>.from(
      policyResponse,
    ).map((row) => row['store_id'].toString()).toList();
    if (configuredStoreIds.isEmpty) {
      throw const FormatException('PHOTO_EXPORT_NO_CONFIGURED_STORES');
    }

    final storeResponse = await supabase
        .from('restaurants')
        .select('id, name, tax_entity_id')
        .inFilter('id', configuredStoreIds)
        .eq('brand_id', _photoObjetBrandId);
    final stores = List<Map<String, dynamic>>.from(storeResponse);
    if (stores.isEmpty) {
      throw const FormatException('PHOTO_EXPORT_NO_ACCESSIBLE_STORES');
    }
    final exportStoreIds = stores.map((row) => row['id'].toString()).toList();

    final completedRunResponse = await supabase
        .from('photo_objet_sales_pull_runs')
        .select('store_id')
        .inFilter('store_id', exportStoreIds)
        .eq('slot_date_hcm', saleDate)
        .eq('slot_time_hcm', '22:20:00')
        .eq('run_source', 'scheduled')
        .eq('status', 'success');
    validatePhotoOpsSalesExportReady(
      stores: stores,
      completedRuns: List<Map<String, dynamic>>.from(completedRunResponse),
    );

    final rawSales = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += _photoSalesExportPageSize) {
      final response = await supabase
          .from('photo_objet_sales_raw')
          .select(
            'id, store_id, sold_at, sale_time_text, device_name, device_id, '
            'amount, raw_type, payment_method, source_hash',
          )
          .inFilter('store_id', exportStoreIds)
          .eq('sale_date', saleDate)
          .gte('sold_at', '${saleDate}T00:00:00+07:00')
          .lt('sold_at', '${saleDate}T22:20:00+07:00')
          .order('sold_at')
          .order('id')
          .range(offset, offset + _photoSalesExportPageSize - 1);
      final page = List<Map<String, dynamic>>.from(response);
      rawSales.addAll(page);
      if (page.length < _photoSalesExportPageSize) break;
    }

    return createPhotoOpsSalesExport(
      saleDate: saleDate,
      stores: stores,
      rawSales: rawSales,
    );
  }

  Future<PhotoOpsDashboardData> loadDashboard({
    required String activeStoreId,
    required List<String> accessibleStoreIds,
  }) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final monthStart = DateTime(now.year, now.month, 1);
    final attendanceWindowStart = today.subtract(const Duration(days: 6));
    var salesRowsRaw = <Map<String, dynamic>>[];
    String? salesWarningCode;
    String? salesWarningDetail;
    try {
      final response = await supabase.rpc('get_photo_ops_latest_sales');
      salesRowsRaw = List<Map<String, dynamic>>.from(response);
    } catch (error) {
      salesWarningCode = 'photo_ops_sales_load_failed';
      salesWarningDetail = error.toString();
    }

    final sales = summarizePhotoOpsSales(
      activeStoreId: activeStoreId,
      rows: salesRowsRaw,
    );

    var attendanceSummary = <Map<String, dynamic>>[];
    var inventorySummary = <Map<String, dynamic>>[];
    var recentAttendanceRaw = <Map<String, dynamic>>[];
    var inventoryCatalog = <Map<String, dynamic>>[];
    var payrollPreviewRaw = <StaffPayroll>[];
    String? attendanceWarningDetail;
    String? inventoryWarningDetail;
    String? payrollWarningDetail;

    await Future.wait<void>([
      () async {
        try {
          attendanceSummary = List<Map<String, dynamic>>.from(
            await supabase
                .from('v_store_attendance_summary')
                .select('store_id, user_id, work_date')
                .inFilter('store_id', accessibleStoreIds)
                .eq('work_date', today.toIso8601String().substring(0, 10)),
          );
        } catch (error) {
          attendanceWarningDetail = error.toString();
        }
      }(),
      () async {
        try {
          inventorySummary = List<Map<String, dynamic>>.from(
            await supabase
                .from('v_inventory_status')
                .select('store_id, item_id, needs_reorder')
                .inFilter('store_id', accessibleStoreIds)
                .eq('needs_reorder', true),
          );
        } catch (error) {
          inventoryWarningDetail = error.toString();
        }
      }(),
      () async {
        try {
          recentAttendanceRaw = await attendanceService.fetchLogs(
            storeId: activeStoreId,
            from: attendanceWindowStart,
            to: now.add(const Duration(days: 1)),
          );
        } catch (error) {
          attendanceWarningDetail ??= error.toString();
        }
      }(),
      () async {
        try {
          inventoryCatalog = await inventoryService.fetchIngredients(
            activeStoreId,
          );
        } catch (error) {
          inventoryWarningDetail ??= error.toString();
        }
      }(),
      () async {
        try {
          payrollPreviewRaw = await payrollService.calculatePayroll(
            storeId: activeStoreId,
            periodStart: monthStart,
            periodEnd: now,
          );
        } catch (error) {
          payrollWarningDetail = error.toString();
        }
      }(),
    ]);

    final recentAttendance = _attendanceRows(recentAttendanceRaw);
    final inventoryItems = _inventoryRows(inventoryCatalog);
    final inventoryAlerts = inventoryItems
        .where((row) => row.needsReorder)
        .take(10)
        .toList();

    final payrollPreview =
        payrollPreviewRaw
            .map(
              (row) => PhotoOpsPayrollRow(
                employeeName: row.userName,
                totalHours: row.totalHours,
                totalAmount: row.totalAmount,
                shiftCount: row.dailyRecords.length,
              ),
            )
            .toList()
          ..sort((a, b) => b.totalAmount.compareTo(a.totalAmount));

    return PhotoOpsDashboardData(
      kpi: PhotoOpsKpi(
        allAttendanceEvents: attendanceSummary.length,
        activeAttendanceEvents: attendanceSummary
            .where((row) => row['store_id']?.toString() == activeStoreId)
            .length,
        allInventoryAlerts: inventorySummary.length,
        activeInventoryAlerts: inventorySummary
            .where((row) => row['store_id']?.toString() == activeStoreId)
            .length,
        activePayrollEstimate: payrollPreviewRaw.fold<double>(
          0,
          (sum, row) => sum + row.totalAmount,
        ),
        activeStoreSales: sales.activeStoreSales,
        networkSales: sales.networkSales,
        activeStoreTransactions: sales.activeStoreTransactions,
        lastSalesPulledAt: sales.lastSalesPulledAt,
      ),
      recentAttendance: recentAttendance,
      inventoryAlerts: inventoryAlerts,
      inventoryItems: inventoryItems,
      payrollPreview: payrollPreview.take(10).toList(),
      salesSummary: sales.rows,
      salesWarningCode: salesWarningCode,
      salesWarningDetail: salesWarningDetail,
      attendanceWarningDetail: attendanceWarningDetail,
      inventoryWarningDetail: inventoryWarningDetail,
      payrollWarningDetail: payrollWarningDetail,
    );
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  List<PhotoOpsAttendanceRow> _attendanceRows(
    List<Map<String, dynamic>> rows,
  ) => rows.take(10).map((row) {
    final employeeRaw = row['store_employees'];
    var employeeName = 'Unknown';
    if (employeeRaw is Map) {
      employeeName = employeeRaw['full_name']?.toString() ?? 'Unknown';
    }
    return PhotoOpsAttendanceRow(
      employeeName: employeeName,
      type: row['type']?.toString() ?? '',
      loggedAt:
          DateTime.tryParse(row['logged_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }).toList();

  List<PhotoOpsInventoryRow> _inventoryRows(List<Map<String, dynamic>> rows) =>
      rows
          .take(100)
          .map(
            (row) => PhotoOpsInventoryRow(
              ingredientId:
                  row['ingredient_id']?.toString() ??
                  row['id']?.toString() ??
                  '',
              itemName: row['name']?.toString() ?? 'Unknown Item',
              currentStock: _toDouble(row['current_stock']),
              unit: row['unit']?.toString() ?? '-',
              reorderPoint: row['reorder_point'] == null
                  ? null
                  : _toDouble(row['reorder_point']),
              needsReorder: (row['needs_reorder'] as bool?) ?? false,
              supplierName: row['supplier_name']?.toString(),
            ),
          )
          .toList();
}

final photoOpsService = PhotoOpsService();
