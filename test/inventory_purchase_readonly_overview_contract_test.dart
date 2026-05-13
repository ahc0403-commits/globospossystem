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
      expect(tab, contains('Order Attention Banner'));
      expect(tab, contains('Supplier Attention Ordering'));
      expect(tab, contains('Receipt Visibility'));
      expect(tab, contains('Recent Receipts'));
      expect(tab, contains('Receipt Line Provenance'));
      expect(tab, contains('Supplier Context History'));
      expect(tab, contains('Receipt status'));
      expect(tab, contains('Readiness'));
      expect(tab, contains('Latest receipt'));
      expect(tab, contains('Recent unit'));
      expect(tab, contains('Recent order'));
      expect(tab, contains('Recent received'));
      expect(tab, contains('Current unit'));
      expect(tab, contains('Price drift'));
      expect(tab, contains('Base factor'));
      expect(tab, contains('Min order'));
      expect(tab, contains('Lead time'));
      expect(tab, contains('Lead-time risk'));
      expect(tab, contains('Supplier risk'));
      expect(tab, contains('Preferred supplier item'));
      expect(tab, contains('Fallback supplier item'));
      expect(
        tab,
        contains(
          'Review receipt history in timeline form without opening receipt confirmation or stock mutation workflows.',
        ),
      );
      expect(
        tab,
        contains(
          'Inspect the selected receipt line-by-line to understand ordered quantity, accepted quantity, rejected quantity, and recommendation provenance without opening any mutation workflow.',
        ),
      );
      expect(
        tab,
        contains(
          'Review recent purchase and receipt history for the same supplier item without opening approval, receipt confirmation, or stock mutation workflows.',
        ),
      );
      expect(tab, contains('Price drift unavailable'));
      expect(tab, contains('Lead-time risk unavailable'));
      expect(tab, contains('Supplier risk summary unavailable'));
      expect(tab, contains('Order attention'));
      expect(
        tab,
        contains(
          'Review the current order-level risk posture before scanning individual line supplier signals.',
        ),
      );
      expect(tab, contains('Attention rank'));
      expect(tab, contains('Escalation lines'));
      expect(tab, contains('Watch lines'));
      expect(
        tab,
        contains(
          'Higher-risk supplier lines are shown first so receipt pending, price-up, or overdue lead-time items surface before stable lines.',
        ),
      );
      expect(
        tab,
        contains(
          'No prior supplier history is visible for the current purchase-order lines.',
        ),
      );
      expect(
        tab,
        contains('Select a receipt above to inspect receipt line provenance.'),
      );
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
      expect(service, contains("copy['line_count']"));
      expect(service, contains("copy['accepted_quantity_base']"));
      expect(service, contains("copy['line_details']"));
      expect(service, contains("line['supplier_history']"));
      expect(service, contains("'recommendation_run_id'"));
      expect(service, contains('supplier_item:inventory_supplier_items'));
      expect(
        service,
        contains('purchase_order:inventory_purchase_orders!inner('),
      );
      expect(service, contains("'last_receipt_at'"));
      expect(service, contains("'lead_time_days'"));
      expect(service, contains("'is_preferred'"));
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
