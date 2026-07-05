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
      final numberUtils = readRepoFile(
        'lib/core/utils/number_input_utils.dart',
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
      expect(screen, contains('l10n.inventoryPurchaseDashboardTitle'));
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
      expect(screen, contains('l10n.inventoryPurchaseGenerateRecommendation'));
      expect(
        screen,
        contains('l10n.inventoryPurchaseRecommendationAdjustment'),
      );
      expect(screen, contains('l10n.inventoryPurchaseCreateSupplierOrders'));
      expect(screen, contains('l10n.inventoryPurchaseManualOrder'));
      expect(screen, contains('l10n.inventoryPurchaseRepeatOrder'));
      expect(screen, contains('l10n.inventoryPurchaseCreateRepeatOrder'));
      expect(screen, contains('l10n.inventoryPurchasePrintPdf'));
      expect(screen, contains('l10n.inventoryPurchaseReceiveTitle'));
      expect(screen, contains('l10n.inventoryPurchaseStockAuditInput'));
      expect(screen, contains("Key('pending_stock_audit_preview')"));
      expect(screen, contains('StatefulBuilder('));
      expect(screen, contains('_countValidStockAuditLines'));
      expect(screen, contains('_stockAuditPreviewLines'));
      expect(screen, contains('_parseStockAuditQuantity'));
      expect(screen, contains('parseDecimalInput(factorController.text)'));
      expect(screen, contains('parseDecimalInput(unitPriceController.text)'));
      expect(screen, contains('parseIntInput(leadTimeController.text)'));
      expect(numberUtils, contains(".replaceAll(',', '')"));
      expect(screen, contains('class _StockAuditPendingPreview'));
      expect(screen, contains('onChanged: (_) => setDialogState(() {})'));
      expect(screen, contains('l10n.inventoryPurchaseRefreshConsumption'));
      expect(screen, contains('l10n.inventoryPurchaseConsumptionTrendTitle'));
      expect(
        screen,
        contains('l10n.inventoryPurchaseConsumptionShareByCategory'),
      );
      expect(screen, contains('l10n.inventoryPurchaseConsumptionAlerts'));
      expect(screen, contains('class _ConsumptionTrendChart'));
      expect(screen, contains('class _ConsumptionShareList'));
      expect(screen, contains('BarChart('));
      expect(screen, contains('l10n.inventoryPurchaseAddSupplier'));
      expect(screen, contains('l10n.inventoryPurchaseAddProduct'));
      expect(screen, contains('l10n.inventoryPurchaseLinkSupplierItem'));
      expect(screen, contains('l10n.inventoryPurchaseAddRecipeLine'));
      expect(screen, contains('l10n.inventoryPurchaseNewMenuTitle'));
      expect(screen, contains('inventoryPurchaseDocumentService'));
      expect(screen, contains('l10n.inventoryPurchaseOfficeApprovalOnly'));
      expect(screen, contains('ToastMetricStrip('));
      expect(screen, contains('ToastResponsiveBody('));
      expect(screen, contains('ToastResponsiveScrollBody('));
      expect(screen, contains('constraints.hasBoundedHeight'));
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
      expect(documentService, contains('rootBundle.load(AppFonts.assetPath)'));
      expect(documentService, contains('l10n.inventoryPurchasePdfOfficeNote'));
      expect(
        documentService,
        isNot(contains('office_approve_inventory_purchase_order')),
      );
    },
  );
}
