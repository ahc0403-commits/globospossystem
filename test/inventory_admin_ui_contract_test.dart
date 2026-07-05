import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('inventory admin surface uses the dedicated QSC inventory workspace', () {
    final admin = readRepoFile('lib/features/admin/admin_screen.dart');
    final screen = readRepoFile(
      'lib/features/inventory_purchase/inventory_purchase_screen.dart',
    );
    final service = readRepoFile('lib/core/services/inventory_service.dart');
    final koArb = readRepoFile('lib/l10n/app_ko.arb');

    expect(
      admin,
      contains(
        "import '../inventory_purchase/inventory_purchase_screen.dart';",
      ),
    );
    expect(admin, contains('const InventoryPurchaseScreen()'));
    expect(admin, isNot(contains('const InventoryTab()')));
    expect(screen, contains('l10n.inventoryPurchaseDashboardTitle'));
    expect(screen, contains('l10n.inventoryPurchaseStockStatusTitle'));
    expect(screen, contains('l10n.inventoryPurchaseManagementTitle'));
    expect(screen, contains('l10n.inventoryPurchaseHistoryTitle'));
    expect(screen, contains('l10n.inventoryPurchaseSupplierManagementTitle'));
    expect(screen, contains('l10n.inventoryPurchaseProductManagementTitle'));
    expect(screen, contains('l10n.inventoryPurchaseRecipeManagementTitle'));
    expect(screen, contains('l10n.inventoryPurchaseConsumptionTitle'));
    expect(screen, contains('l10n.inventoryPurchaseCostAnalysisTitle'));
    expect(screen, contains('l10n.inventoryPurchaseStockAuditTitle'));
    expect(screen, contains('l10n.inventoryPurchaseNewMenuTitle'));
    expect(
      koArb,
      contains('"inventoryPurchaseDashboardTitle": "재고/발주 관리 대시보드"'),
    );
    expect(koArb, contains('"inventoryPurchaseStockStatusTitle": "재고 현황"'));
    expect(koArb, contains('"inventoryPurchaseManagementTitle": "발주 관리"'));
    expect(koArb, contains('"inventoryPurchaseHistoryTitle": "발주 내역"'));
    expect(
      koArb,
      contains('"inventoryPurchaseSupplierManagementTitle": "거래처 관리"'),
    );
    expect(
      koArb,
      contains('"inventoryPurchaseProductManagementTitle": "제품 관리"'),
    );
    expect(
      koArb,
      contains('"inventoryPurchaseRecipeManagementTitle": "레시피 관리"'),
    );
    expect(koArb, contains('"inventoryPurchaseConsumptionTitle": "소진량 분석"'));
    expect(koArb, contains('"inventoryPurchaseCostAnalysisTitle": "원가 분석"'));
    expect(koArb, contains('"inventoryPurchaseStockAuditTitle": "실재고 실사"'));
    expect(koArb, contains('"inventoryPurchaseNewMenuTitle": "신메뉴 등록"'));
    expect(screen, contains('ToastMetricStrip('));
    expect(screen, contains('_PurchaseRecommendationGrid'));
    expect(
      screen,
      contains('Future<_RecommendationRunInput?> _showRecommendationRunDialog'),
    );
    expect(
      screen,
      contains('inventory_purchase_recommendation_target_days_field'),
    );
    expect(
      screen,
      contains('inventory_purchase_recommendation_as_of_date_field'),
    );
    expect(screen, contains('inventory_purchase_recommendation_submit_action'));
    expect(screen, contains('targetStockDays: input.targetStockDays'));
    expect(screen, contains('asOfDate: input.asOfDate'));
    expect(screen, contains("Key('inventory_purchase_create_order_action')"));
    expect(
      screen,
      contains("Key('inventory_purchase_zero_recommendations_panel')"),
    );
    expect(screen, contains('class _RecommendationTotalsBand'));
    expect(screen, contains('class _RecommendationEmptyPanel'));
    expect(screen, contains('PosActionTile('));
    expect(screen, contains('PosAmountAnchor('));
    expect(screen, contains('PosNumericText.qtyUnit'));
    expect(screen, contains('PosNumericText.unitPrice'));
    expect(screen, contains('PosNumericText.lineAmount'));
    expect(screen, contains('PosNumericText.amountLarge'));
    expect(screen, contains('l10n.inventoryPurchaseEffectiveOrderUnit'));
    expect(screen, contains('l10n.inventoryPurchasePackUnit'));
    expect(screen, contains('l10n.inventoryPurchaseUnitPrice'));
    expect(screen, contains('l10n.inventoryPurchaseEstimatedAmount'));
    expect(
      screen,
      contains('l10n.inventoryPurchasePendingOfficeApprovalCount'),
    );
    expect(screen, contains('_recommendationEstimatedAmount'));
    expect(screen, contains("_string(order['status']) == 'submitted'"));
    expect(service, contains("line['supplier_item'] = supplierItem"));
    expect(
      service,
      contains("line['order_unit'] = supplierItem['order_unit']"),
    );
    expect(
      service,
      contains(
        "line['order_unit_quantity_base'] =\n          supplierItem['order_unit_quantity_base']",
      ),
    );
    expect(
      service,
      contains("line['unit_price'] = supplierItem['unit_price']"),
    );
    expect(service, contains("line['estimated_amount'] ="));
    expect(
      service,
      contains(
        "line['adjusted_order_units'] ?? line['recommended_order_units']",
      ),
    );
    expect(
      koArb,
      contains('"inventoryPurchaseEffectiveOrderUnit": "적용 주문 단위"'),
    );
    expect(koArb, contains('"inventoryPurchasePackUnit": "팩/박스 기준량"'));
    expect(koArb, contains('"inventoryPurchaseEstimatedAmount": "예상 금액"'));
    expect(koArb, contains('"inventoryPurchaseZeroRecommendationTitle"'));
    expect(koArb, contains('"inventoryPurchaseCreateOrderActionHelper"'));
    expect(
      screen,
      isNot(contains("Key('inventory_purchase_secondary_detail')")),
    );
    expect(screen, isNot(contains('initiallyExpanded: false')));
  });
}
