import '../../core/services/attendance_service.dart';
import '../../core/services/inventory_service.dart';
import '../../core/services/payroll_service.dart';
import '../../main.dart';

class PhotoOpsKpi {
  const PhotoOpsKpi({
    required this.allAttendanceEvents,
    required this.activeAttendanceEvents,
    required this.allInventoryAlerts,
    required this.activeInventoryAlerts,
    required this.activePayrollEstimate,
  });

  final int allAttendanceEvents;
  final int activeAttendanceEvents;
  final int allInventoryAlerts;
  final int activeInventoryAlerts;
  final double activePayrollEstimate;
}

class PhotoOpsAttendanceRow {
  const PhotoOpsAttendanceRow({
    required this.employeeName,
    required this.type,
    required this.loggedAt,
    this.photoUrl,
  });

  final String employeeName;
  final String type;
  final DateTime loggedAt;
  final String? photoUrl;
}

class PhotoOpsInventoryRow {
  const PhotoOpsInventoryRow({
    required this.itemName,
    required this.currentStock,
    required this.unit,
    this.reorderPoint,
    required this.needsReorder,
    this.supplierName,
  });

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

class PhotoOpsDashboardData {
  const PhotoOpsDashboardData({
    required this.kpi,
    required this.recentAttendance,
    required this.inventoryAlerts,
    required this.payrollPreview,
  });

  final PhotoOpsKpi kpi;
  final List<PhotoOpsAttendanceRow> recentAttendance;
  final List<PhotoOpsInventoryRow> inventoryAlerts;
  final List<PhotoOpsPayrollRow> payrollPreview;
}

class PhotoOpsService {
  Future<PhotoOpsDashboardData> loadDashboard({
    required String activeStoreId,
    required List<String> accessibleStoreIds,
  }) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final monthStart = DateTime(now.year, now.month, 1);
    final attendanceWindowStart = today.subtract(const Duration(days: 6));

    final results = await Future.wait([
      supabase
          .from('v_store_attendance_summary')
          .select('store_id, user_id, work_date')
          .inFilter('store_id', accessibleStoreIds)
          .eq('work_date', today.toIso8601String().substring(0, 10)),
      supabase
          .from('v_inventory_status')
          .select('store_id, item_id, needs_reorder')
          .inFilter('store_id', accessibleStoreIds)
          .eq('needs_reorder', true),
      attendanceService.fetchLogs(
        storeId: activeStoreId,
        from: attendanceWindowStart,
        to: now.add(const Duration(days: 1)),
      ),
      inventoryService.fetchIngredients(activeStoreId),
      payrollService.calculatePayroll(
        storeId: activeStoreId,
        periodStart: monthStart,
        periodEnd: now,
      ),
    ]);

    final attendanceSummary = List<Map<String, dynamic>>.from(results[0] as List);
    final inventorySummary = List<Map<String, dynamic>>.from(results[1] as List);
    final recentAttendanceRaw = List<Map<String, dynamic>>.from(results[2] as List);
    final inventoryCatalog = List<Map<String, dynamic>>.from(results[3] as List);
    final payrollPreviewRaw = results[4] as List<StaffPayroll>;

    final recentAttendance =
        recentAttendanceRaw.take(10).map((row) {
          final userRaw = row['users'];
          String employeeName = 'Unknown';
          if (userRaw is Map<String, dynamic>) {
            employeeName = userRaw['full_name']?.toString() ?? 'Unknown';
          }
          return PhotoOpsAttendanceRow(
            employeeName: employeeName,
            type: row['type']?.toString() ?? '',
            loggedAt:
                DateTime.tryParse(row['logged_at']?.toString() ?? '') ??
                DateTime.now(),
            photoUrl: row['photo_url']?.toString(),
          );
        }).toList();

    final inventoryAlerts =
        inventoryCatalog
            .where((row) => (row['needs_reorder'] as bool?) ?? false)
            .take(10)
            .map(
              (row) => PhotoOpsInventoryRow(
                itemName: row['name']?.toString() ?? 'Unknown Item',
                currentStock: _toDouble(row['current_stock']),
                unit: row['unit']?.toString() ?? '-',
                reorderPoint:
                    row['reorder_point'] == null
                        ? null
                        : _toDouble(row['reorder_point']),
                needsReorder: (row['needs_reorder'] as bool?) ?? false,
                supplierName: row['supplier_name']?.toString(),
              ),
            )
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
        activeAttendanceEvents:
            attendanceSummary
                .where((row) => row['store_id']?.toString() == activeStoreId)
                .length,
        allInventoryAlerts: inventorySummary.length,
        activeInventoryAlerts:
            inventorySummary
                .where((row) => row['store_id']?.toString() == activeStoreId)
                .length,
        activePayrollEstimate: payrollPreviewRaw.fold<double>(
          0,
          (sum, row) => sum + row.totalAmount,
        ),
      ),
      recentAttendance: recentAttendance,
      inventoryAlerts: inventoryAlerts,
      payrollPreview: payrollPreview.take(10).toList(),
    );
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }
}

final photoOpsService = PhotoOpsService();
