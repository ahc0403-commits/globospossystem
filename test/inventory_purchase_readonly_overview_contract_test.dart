import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'tracked inventory workspace exposes a bounded recommendation and purchase-order workflow surface',
    () {
      final tab = readRepoFile('lib/features/admin/tabs/inventory_tab.dart');
      final provider = readRepoFile(
        'lib/features/inventory/inventory_provider.dart',
      );
      final service = readRepoFile('lib/core/services/inventory_service.dart');

      expect(tab, contains('Purchase Overview'));
      expect(tab, contains('Purchase Review Detail'));
      expect(tab, contains('Approval Gap'));
      expect(tab, contains('Review Focus'));
      expect(tab, contains('Inventory Recommendation Trigger'));
      expect(tab, contains('Generate Recommendation Snapshot'));
      expect(tab, contains('Recommendation Status'));
      expect(tab, contains('Latest Recommendation Snapshot'));
      expect(tab, contains('Refresh Recommendation Snapshot'));
      expect(tab, contains('Create Purchase Orders'));
      expect(tab, contains('Latest Purchase Order Creation'));
      expect(tab, contains('Recent Purchase Orders'));
      expect(tab, contains('Purchase Order Detail'));
      expect(tab, contains('Receipt Visibility'));
      expect(tab, contains('Receipt status'));
      expect(tab, contains('Readiness'));
      expect(tab, contains('Latest receipt'));
      expect(tab, contains('Refresh Selected Order'));
      expect(
        tab,
        contains(
          'Select a recent purchase order card above to inspect line-level detail.',
        ),
      );
      expect(tab, contains('Refresh Purchase Orders'));
      expect(tab, contains('inventoryPurchaseOverviewProvider'));
      expect(tab, contains('inventoryPurchaseRecommendationRunProvider'));
      expect(tab, contains('inventoryPurchaseRecommendationSnapshotProvider'));
      expect(tab, contains('inventoryPurchaseOrderCreationProvider'));
      expect(tab, contains('inventoryPurchaseOrderSummaryProvider'));
      expect(tab, contains('inventoryPurchaseOrderDetailProvider'));
      expect(tab, contains('Refresh Purchase Overview'));

      expect(provider, contains('class InventoryPurchaseOverviewState'));
      expect(provider, contains('inventoryPurchaseOverviewProvider'));
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
      expect(provider, contains('class InventoryPurchaseOrderCreationState'));
      expect(provider, contains('inventoryPurchaseOrderCreationProvider'));
      expect(provider, contains('class InventoryPurchaseOrderSummaryState'));
      expect(provider, contains('inventoryPurchaseOrderSummaryProvider'));
      expect(provider, contains('class InventoryPurchaseOrderDetailState'));
      expect(provider, contains('inventoryPurchaseOrderDetailProvider'));

      expect(service, contains('fetchInventoryPurchaseDashboard'));
      expect(service, contains("'get_inventory_purchase_dashboard'"));
      expect(service, contains('runInventoryPurchaseRecommendation'));
      expect(service, contains("'run_inventory_purchase_recommendation'"));
      expect(
        service,
        contains('fetchLatestInventoryPurchaseRecommendationRun'),
      );
      expect(service, contains('fetchInventoryPurchaseRecommendationLines'));
      expect(service, contains('createPurchaseOrdersFromRecommendation'));
      expect(service, contains('fetchRecentInventoryPurchaseOrders'));
      expect(service, contains('fetchInventoryPurchaseOrderDetail'));
      expect(service, contains("'inventory_recommendation_runs'"));
      expect(service, contains("'inventory_recommendation_lines'"));
      expect(service, contains("'create_purchase_orders_from_recommendation'"));
      expect(service, contains("'inventory_purchase_orders'"));
      expect(service, contains("'inventory_purchase_order_lines'"));
      expect(service, contains("'inventory_receipts'"));
      expect(service, contains("'inventory_receipt_lines'"));
      expect(service, contains('supplier_item:inventory_supplier_items'));
      expect(
        tab,
        contains(
          'This slice may create recommendation snapshots and supplier-grouped purchase orders, but it still does not approve receipts or mutate stock.',
        ),
      );
      expect(
        tab,
        contains(
          'Track receipt readiness and already recorded inbound quantities without opening receipt confirmation.',
        ),
      );
      expect(tab, isNot(contains('InventoryPurchaseScreen')));
      expect(tab, isNot(contains('office_approve_inventory_purchase_order')));
      expect(tab, isNot(contains('confirmInventoryPurchaseReceipt')));
      expect(
        service,
        isNot(contains('office_get_inventory_purchase_order_detail')),
      );
    },
  );
}
