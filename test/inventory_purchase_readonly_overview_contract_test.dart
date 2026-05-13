import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('tracked inventory workspace exposes a bounded purchase-order runtime path', () {
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
    expect(tab, contains('Top attention items'));
    expect(tab, contains('Supplier Attention Ordering'));
    expect(tab, contains('Receiving Readiness Summary'));
    expect(tab, contains('Receiving Blockers Detail'));
    expect(tab, contains('Inventory Mutation Readiness Phase'));
    expect(tab, contains('Inventory Runtime Path'));
    expect(tab, contains('Approval Runtime Path'));
    expect(tab, contains('Receiving Runtime Path'));
    expect(tab, contains('Approval Handoff'));
    expect(tab, contains('Receiving Confirmation Readiness'));
    expect(tab, contains('Stock Mutation Guardrail'));
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
    expect(tab, contains('Receiving readiness'));
    expect(tab, contains('Received lines'));
    expect(tab, contains('Pending lines'));
    expect(tab, contains('Attention lines'));
    expect(tab, contains('Affected PO'));
    expect(tab, contains('Impacted suppliers'));
    expect(tab, contains('Oldest wait'));
    expect(tab, contains('Next hint'));
    expect(tab, contains("'healthy'"));
    expect(tab, contains("'watch'"));
    expect(tab, contains("'risk'"));
    expect(tab, contains("'critical'"));
    expect(
      tab,
      contains(
        'Higher-risk supplier lines are shown first so receipt pending, price-up, or overdue lead-time items surface before stable lines.',
      ),
    );
    expect(
      tab,
      contains(
        'Review inbound receiving posture before opening receipt history or line provenance detail.',
      ),
    );
    expect(
      tab,
      contains(
        'Operators should review attention lines first; this summary remains read-only and does not confirm receipts or mutate stock.',
      ),
    );
    expect(
      tab,
      contains(
        'Read the current receiving blockers without opening receipt confirmation, supplier approval, or stock mutation workflows.',
      ),
    );
    expect(
      tab,
      contains(
        'Use these guardrails to confirm POS remains responsible for visibility, readiness, and operator checklist coverage before any Office-owned approval, receipt confirmation, or stock mutation workflow is considered.',
      ),
    );
    expect(
      tab,
      contains(
        'POS keeps the approval handoff visible only. Office remains the execution owner for purchase-order approval, and this surface does not expose approval actions or supplier-response mutations.',
      ),
    );
    expect(
      tab,
      contains(
        'Tracked inbound quantities stay operator-facing signals only. This phase does not mutate stock, does not connect payment, order, or menu mutation flows, and does not transfer Office-owned execution into POS.',
      ),
    );
    expect(
      tab,
      contains(
        'Open only the action states that the current POS runtime can support truthfully. Approval remains Office-owned, while receiving is enabled only when the backend receipt contract can safely update stock.',
      ),
    );
    expect(
      tab,
      contains(
        'The purchase order is ready for Office review, but POS does not execute approval. Operators can verify readiness and hand off the order to the Office-owned workflow only.',
      ),
    );
    expect(
      tab,
      contains(
        'The receipt confirmation contract exists and can update stock truthfully for the remaining quantity. Use the runtime action only when the inbound goods are physically verified.',
      ),
    );
    expect(tab, contains('Ready to approve'));
    expect(tab, contains('Approved'));
    expect(tab, contains('Ready to receive'));
    expect(tab, contains('Received / closed'));
    expect(tab, contains('Check Approval Handoff'));
    expect(tab, contains('Confirm Remaining Receipt'));
    expect(tab, contains('Office-owned execution'));
    expect(
      tab,
      contains(
        'Backend truth already shows this order as fully received. POS keeps the final state visible without sending another receipt confirmation.',
      ),
    );
    expect(tab, contains('Execution owner Office'));
    expect(tab, contains('POS role Visibility and checklist only'));
    expect(tab, contains('Approval handoff'));
    expect(tab, contains('Stock mutation unavailable'));
    expect(tab, contains('Domain boundary Payment / order / menu untouched'));
    expect(tab, contains('Receiving delayed beyond expected arrival window.'));
    expect(
      tab,
      contains('purchase order line(s) still waiting supplier confirmation'),
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
    expect(provider, contains('class InventoryPurchaseRecommendationRunState'));
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
    expect(provider, contains('enum InventoryPurchaseRuntimeResultKind'));
    expect(provider, contains('class InventoryPurchaseRuntimeResult'));
    expect(provider, contains('class InventoryPurchaseApprovalRuntimeState'));
    expect(provider, contains('inventoryPurchaseApprovalRuntimeProvider'));
    expect(provider, contains('class InventoryPurchaseReceivingRuntimeState'));
    expect(provider, contains('inventoryPurchaseReceivingRuntimeProvider'));
    expect(provider, contains('confirmRemainingReceipt'));
    expect(provider, contains('markCancelled'));
    expect(
      provider,
      contains(
        'approval execution stays Office-owned. POS records the handoff boundary and does not call Office approval mutation here.',
      ),
    );
    expect(
      provider,
      contains(
        'Receipt confirmation was cancelled before any backend mutation was sent.',
      ),
    );
    expect(
      provider,
      contains(
        'POS cannot confirm receipt or mutate stock before the backend order reaches an approved or ordered state.',
      ),
    );

    expect(service, contains('fetchInventoryPurchaseDashboard'));
    expect(service, contains("'get_inventory_purchase_dashboard'"));
    expect(service, contains('runInventoryPurchaseRecommendation'));
    expect(service, contains("'run_inventory_purchase_recommendation'"));
    expect(service, contains('fetchLatestInventoryPurchaseRecommendationRun'));
    expect(service, contains('fetchInventoryPurchaseRecommendationLines'));
    expect(service, contains('createPurchaseOrdersFromRecommendation'));
    expect(service, contains('fetchRecentInventoryPurchaseOrders'));
    expect(service, contains('fetchInventoryPurchaseOrderDetail'));
    expect(service, contains('confirmInventoryPurchaseReceipt'));
    expect(service, contains("'confirm_inventory_purchase_receipt'"));
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
        'This slice may create recommendation snapshots and supplier-grouped purchase orders, but approval stays Office-owned and receiving runs only through the tracked backend receipt contract.',
      ),
    );
    expect(
      tab,
      contains(
        'Track receipt readiness and already recorded inbound quantities before deciding whether the backend receipt contract is ready to run.',
      ),
    );
    expect(tab, isNot(contains('InventoryPurchaseScreen')));
    expect(tab, isNot(contains('office_approve_inventory_purchase_order')));
    expect(tab, isNot(contains('Confirm Receipt')));
    expect(tab, isNot(contains('Approve Purchase Order')));
    expect(tab, isNot(contains('Run Supplier Approval')));
    expect(tab, isNot(contains('Update Stock Now')));
    expect(tab, isNot(contains('Execute Approval')));
    expect(tab, isNot(contains('Run Stock Mutation')));
    expect(
      service,
      isNot(contains('office_get_inventory_purchase_order_detail')),
    );
    expect(service, isNot(contains('office_approve_inventory_purchase_order')));
  });
}
