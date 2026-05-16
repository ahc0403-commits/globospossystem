import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'inventory purchase workspace follows the approved POS and Office boundary',
    () {
      final screen = readRepoFile(
        'lib/features/inventory_purchase/inventory_purchase_screen.dart',
      );
      final provider = readRepoFile(
        'lib/features/inventory/inventory_provider.dart',
      );
      final service = readRepoFile('lib/core/services/inventory_service.dart');
      final documentService = readRepoFile(
        'lib/features/inventory_purchase/inventory_purchase_document_service.dart',
      );
      final design = readRepoFile('docs/inventory_purchase_office_design.md');

      expect(design, contains('[BOUNDARY DECISION - 2026-05-15]'));
      expect(
        design,
        contains(
          'Office approval/return/reject/update is implemented only in the Office app.',
        ),
      );
      expect(design, contains('POS/Admin은 나머지 4개 승인 범위'));

      expect(screen, contains('class InventoryPurchaseScreen'));
      expect(screen, contains('재고/발주 관리 대시보드'));
      expect(screen, isNot(contains('get_inventory_stock_status')));
      expect(screen, contains('inventoryPurchaseOverviewProvider'));
      expect(screen, contains('inventoryPurchaseStockStatusProvider'));
      expect(screen, contains('inventoryPurchaseRecommendationRunProvider'));
      expect(
        screen,
        contains('inventoryPurchaseRecommendationSnapshotProvider'),
      );
      expect(
        screen,
        contains('inventoryPurchaseRecommendationAdjustmentProvider'),
      );
      expect(screen, contains('inventoryPurchaseOrderCreationProvider'));
      expect(screen, contains('inventoryPurchaseOrderSummaryProvider'));
      expect(screen, contains('inventoryPurchaseSupplierCatalogProvider'));
      expect(screen, contains('inventoryPurchaseProductCatalogProvider'));
      expect(screen, contains('inventoryPurchaseNewMenuProvider'));
      expect(screen, contains('recipeProvider'));
      expect(screen, contains('추천 발주 생성'));
      expect(screen, contains('추천 수량 조정'));
      expect(screen, contains('공급처별 발주 생성'));
      expect(screen, contains('직접 발주 등록'));
      expect(screen, contains('반복 발주'));
      expect(screen, contains('반복 발주 등록'));
      expect(screen, contains('발주서 출력/PDF'));
      expect(screen, contains('입고 확정'));
      expect(screen, contains('실사 입력'));
      expect(screen, contains('소진 데이터 갱신'));
      expect(screen, contains('소진량 추이'));
      expect(screen, contains('카테고리별 소진 비중'));
      expect(screen, contains('소진 이상 알림'));
      expect(screen, contains('class _ConsumptionTrendChart'));
      expect(screen, contains('class _ConsumptionShareList'));
      expect(screen, contains('BarChart('));
      expect(screen, contains('거래처 등록'));
      expect(screen, contains('제품 등록'));
      expect(screen, contains('공급처 품목 연결'));
      expect(screen, contains('레시피 라인 추가'));
      expect(screen, contains('신메뉴 등록'));
      expect(screen, contains('inventoryPurchaseDocumentService'));
      expect(screen, contains('Office 승인은 Office 전용'));
      expect(screen, contains('ToastMetricStrip('));
      expect(screen, contains('ToastResponsiveBody('));
      expect(
        screen,
        isNot(contains("Key('inventory_purchase_secondary_detail')")),
      );
      expect(screen, isNot(contains('initiallyExpanded: false')));
      expect(
        screen,
        isNot(contains('office_approve_inventory_purchase_order')),
      );
      expect(screen, isNot(contains('office_return_inventory_purchase_order')));
      expect(screen, isNot(contains('office_reject_inventory_purchase_order')));
      expect(screen, isNot(contains('office_update_inventory_purchase_order')));
      expect(screen, isNot(contains("from('payments')")));
      expect(screen, isNot(contains("from('orders')")));
      expect(screen, isNot(contains("from('tables')")));
      expect(screen, isNot(contains('supabase.')));
      expect(screen, isNot(contains('.rpc(')));

      expect(provider, contains('class InventoryPurchaseOverviewState'));
      expect(provider, contains('class InventoryPurchaseStockStatusState'));
      expect(provider, contains('inventoryPurchaseStockStatusProvider'));
      expect(
        provider,
        contains('class InventoryPurchaseRecommendationRunState'),
      );
      expect(provider, contains('inventoryPurchaseRecommendationRunProvider'));
      expect(
        provider,
        contains('class InventoryPurchaseRecommendationSnapshotState'),
      );
      expect(
        provider,
        contains('inventoryPurchaseRecommendationSnapshotProvider'),
      );
      expect(
        provider,
        contains('class InventoryPurchaseRecommendationAdjustmentState'),
      );
      expect(
        provider,
        contains('inventoryPurchaseRecommendationAdjustmentProvider'),
      );
      expect(provider, contains('class InventoryPurchaseOrderCreationState'));
      expect(provider, contains('inventoryPurchaseOrderCreationProvider'));
      expect(provider, contains('createRepeat'));
      expect(provider, contains('class InventoryPurchaseOrderSummaryState'));
      expect(provider, contains('inventoryPurchaseOrderSummaryProvider'));
      expect(provider, contains('class InventoryPurchaseSupplierCatalogState'));
      expect(provider, contains('inventoryPurchaseSupplierCatalogProvider'));
      expect(provider, contains('class InventoryPurchaseProductCatalogState'));
      expect(provider, contains('inventoryPurchaseProductCatalogProvider'));
      expect(provider, contains('class InventoryPurchaseNewMenuState'));
      expect(provider, contains('inventoryPurchaseNewMenuProvider'));
      expect(provider, contains('class InventoryPurchaseStockAuditState'));
      expect(provider, contains('inventoryPurchaseStockAuditProvider'));
      expect(provider, contains('class InventoryPurchaseCostAnalysisState'));
      expect(provider, contains('inventoryPurchaseCostAnalysisProvider'));
      expect(provider, contains('class InventoryPurchaseApprovalRuntimeState'));
      expect(
        provider,
        contains('class InventoryPurchaseReceivingRuntimeState'),
      );
      expect(
        provider,
        contains(
          'approval execution stays Office-owned. POS records the handoff boundary and does not call Office approval mutation here.',
        ),
      );
      expect(
        provider,
        isNot(contains('office_approve_inventory_purchase_order')),
      );
      expect(provider, isNot(contains("from('payments')")));
      expect(provider, isNot(contains("from('orders')")));
      expect(provider, isNot(contains("from('tables')")));

      expect(service, contains('fetchInventoryPurchaseDashboard'));
      expect(service, contains("'get_inventory_purchase_dashboard'"));
      expect(service, contains('fetchInventoryStockStatus'));
      expect(service, contains("'get_inventory_stock_status'"));
      expect(service, contains('runInventoryPurchaseRecommendation'));
      expect(service, contains("'run_inventory_purchase_recommendation'"));
      expect(
        service,
        contains('fetchLatestInventoryPurchaseRecommendationRun'),
      );
      expect(service, contains('fetchInventoryPurchaseRecommendationLines'));
      expect(service, contains('updateInventoryRecommendationLineAdjustment'));
      expect(
        service,
        contains("'update_inventory_recommendation_line_adjustment'"),
      );
      expect(service, contains('createPurchaseOrdersFromRecommendation'));
      expect(service, contains("'create_purchase_orders_from_recommendation'"));
      expect(service, contains('createManualInventoryPurchaseOrder'));
      expect(service, contains("'create_manual_inventory_purchase_order'"));
      expect(service, contains('createRepeatInventoryPurchaseOrder'));
      expect(service, contains("'create_repeat_inventory_purchase_order'"));
      expect(service, contains('saveInventoryStockAudit'));
      expect(service, contains("'save_inventory_stock_audit'"));
      expect(service, contains('fetchInventoryCostAnalysis'));
      expect(service, contains("'get_inventory_cost_analysis'"));
      expect(service, contains('refreshInventoryDailyConsumption'));
      expect(service, contains("'refresh_inventory_daily_consumption'"));
      expect(service, contains('fetchRecentInventoryPurchaseOrders'));
      expect(service, contains('fetchInventoryPurchaseOrderDetail'));
      expect(service, contains('confirmInventoryPurchaseReceipt'));
      expect(service, contains("'confirm_inventory_purchase_receipt'"));
      expect(service, contains('fetchInventorySuppliers'));
      expect(service, contains("'upsert_inventory_supplier'"));
      expect(service, contains("'set_inventory_supplier_status'"));
      expect(service, contains('fetchInventoryProducts'));
      expect(service, contains("'upsert_inventory_product'"));
      expect(service, contains("'set_inventory_product_active'"));
      expect(service, contains('fetchInventorySupplierItems'));
      expect(service, contains("'upsert_inventory_supplier_item'"));
      expect(service, contains("'set_inventory_supplier_item_active'"));
      expect(service, contains('fetchMenuCategories'));
      expect(service, contains('createInventoryMenuWithRecipe'));
      expect(service, contains("'create_inventory_menu_with_recipe'"));
      expect(
        service,
        isNot(contains("rpc('office_approve_inventory_purchase_order'")),
      );
      expect(
        service,
        isNot(contains("rpc('office_return_inventory_purchase_order'")),
      );
      expect(
        service,
        isNot(contains("rpc('office_reject_inventory_purchase_order'")),
      );
      expect(
        service,
        isNot(contains("rpc('office_update_inventory_purchase_order'")),
      );

      expect(
        documentService,
        contains('class InventoryPurchaseDocumentService'),
      );
      expect(documentService, contains('Printing.layoutPdf'));
      expect(documentService, contains('PdfGoogleFonts.notoSansKRRegular'));
      expect(documentService, contains('Office 승인/반려/수정은 Office 앱에서만 처리합니다.'));
      expect(
        documentService,
        isNot(contains('office_approve_inventory_purchase_order')),
      );
    },
  );
}
