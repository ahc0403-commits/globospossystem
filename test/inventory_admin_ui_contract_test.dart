import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'inventory admin surface uses the dedicated QSC inventory workspace',
    () {
      final admin = readRepoFile('lib/features/admin/admin_screen.dart');
      final screen = readRepoFile(
        'lib/features/inventory_purchase/inventory_purchase_screen.dart',
      );
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
      expect(
        screen,
        isNot(contains("Key('inventory_purchase_secondary_detail')")),
      );
      expect(screen, isNot(contains('initiallyExpanded: false')));
    },
  );
}
