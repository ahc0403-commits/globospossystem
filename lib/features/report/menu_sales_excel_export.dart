import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import 'menu_sales_analytics.dart';

List<int> buildMenuSalesAnalyticsWorkbook({
  required MenuSalesAnalytics analytics,
  required MenuSalesAnalyticsParams params,
}) {
  final dateFormat = DateFormat('dd/MM/yyyy');
  final excel = Excel.createExcel();
  final menuSheet = excel['Menu Sales'];

  menuSheet.appendRow([
    TextCellValue(
      'POS menu details only. External delivery, Photo sales, service charges, and non-menu amounts are excluded.',
    ),
  ]);
  menuSheet.appendRow([
    TextCellValue('Period'),
    TextCellValue(
      '${dateFormat.format(params.startDate)} ~ ${dateFormat.format(params.endDate)}',
    ),
  ]);
  menuSheet.appendRow([
    TextCellValue('Scope'),
    TextCellValue(params.scope.rpcValue),
  ]);
  menuSheet.appendRow([
    TextCellValue('Orders'),
    IntCellValue(analytics.summary.orderCount),
    TextCellValue('Menus Sold'),
    IntCellValue(analytics.summary.soldMenuCount),
  ]);
  menuSheet.appendRow([
    TextCellValue('Quantity Sold'),
    IntCellValue(analytics.summary.soldQuantity),
    TextCellValue('Menu Sales Amount'),
    DoubleCellValue(analytics.summary.menuSalesAmount),
  ]);
  menuSheet.appendRow([
    TextCellValue('Unallocated Refund/Void Count'),
    IntCellValue(analytics.summary.unallocatedAdjustmentCount),
    TextCellValue('Unallocated Refund/Void Amount'),
    DoubleCellValue(analytics.summary.unallocatedAdjustmentAmount),
  ]);
  menuSheet.appendRow([
    TextCellValue('Combo Quantity Sold'),
    IntCellValue(analytics.summary.comboSoldQuantity),
    TextCellValue('Combo Menu Sales Amount'),
    DoubleCellValue(analytics.summary.comboMenuSalesAmount),
  ]);
  final topCombo = analytics.topCombo;
  menuSheet.appendRow([
    TextCellValue('Top Combo'),
    TextCellValue(topCombo?.displayName ?? ''),
    TextCellValue('Top Combo Sales Amount'),
    DoubleCellValue(topCombo?.menuSalesAmount ?? 0),
  ]);
  menuSheet.appendRow([TextCellValue('')]);
  menuSheet.appendRow([
    TextCellValue('Rank'),
    TextCellValue('Menu'),
    TextCellValue('Quantity Sold'),
    TextCellValue('Orders'),
    TextCellValue('Menu Sales Amount'),
    TextCellValue('Quantity Share (%)'),
    TextCellValue('Revenue Share (%)'),
    TextCellValue('Peak Hour (HCM)'),
    TextCellValue('Dine-in Qty'),
    TextCellValue('Takeaway Qty'),
    TextCellValue('POS Delivery Qty'),
    TextCellValue('Identity Quality'),
    TextCellValue('Name Changed In Period'),
    TextCellValue('Combo'),
  ]);
  final menuRows = analytics.sortedRows(MenuSalesSort.quantity);
  for (var index = 0; index < menuRows.length; index++) {
    final row = menuRows[index];
    menuSheet.appendRow([
      IntCellValue(index + 1),
      TextCellValue(row.displayName),
      IntCellValue(row.soldQuantity),
      IntCellValue(row.orderCount),
      DoubleCellValue(row.menuSalesAmount),
      DoubleCellValue(row.quantityShare),
      DoubleCellValue(row.revenueShare),
      TextCellValue('${row.peakHour.toString().padLeft(2, '0')}:00'),
      IntCellValue(row.dineInQuantity),
      IntCellValue(row.takeawayQuantity),
      IntCellValue(row.deliveryQuantity),
      TextCellValue(row.identityQuality),
      BoolCellValue(row.nameChangedInPeriod),
      BoolCellValue(row.isCombo),
    ]);
  }

  final hourlySheet = excel['Menu by Hour'];
  hourlySheet.appendRow([
    TextCellValue('Timezone'),
    TextCellValue('Asia/Ho_Chi_Minh'),
    TextCellValue('Time Basis'),
    TextCellValue('Last revenue payment per completed POS order'),
  ]);
  hourlySheet.appendRow([
    TextCellValue('Hour'),
    TextCellValue('Quantity Sold'),
    TextCellValue('Menu Sales Amount'),
    TextCellValue('POS Orders'),
  ]);
  for (final hour in analytics.hourRows) {
    hourlySheet.appendRow([
      TextCellValue('${hour.hour.toString().padLeft(2, '0')}:00'),
      IntCellValue(hour.soldQuantity),
      DoubleCellValue(hour.menuSalesAmount),
      IntCellValue(hour.orderCount),
    ]);
  }
  hourlySheet.appendRow([TextCellValue('')]);
  hourlySheet.appendRow([
    TextCellValue('Top Menu Rank'),
    TextCellValue('Menu'),
    TextCellValue('Hour'),
    TextCellValue('Quantity Sold'),
    TextCellValue('Menu Sales Amount'),
  ]);
  for (final row in analytics.topMenuHourRows) {
    hourlySheet.appendRow([
      IntCellValue(row.rank),
      TextCellValue(row.displayName),
      TextCellValue('${row.hour.toString().padLeft(2, '0')}:00'),
      IntCellValue(row.soldQuantity),
      DoubleCellValue(row.menuSalesAmount),
    ]);
  }

  excel.delete('Sheet1');
  return excel.encode() ?? <int>[];
}
