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
    expect(tab, contains('Inventory Operating Runtime Summary'));
    expect(tab, contains('Open PO Reconciliation Summary'));
    expect(tab, contains('Store-Level Inventory Action Queue'));
    expect(tab, contains('Supplier Receiving Bottleneck View'));
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
    expect(tab, contains('Inventory Runtime Closure'));
    expect(tab, contains('Receiving Execution Safety Layer'));
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
    expect(provider, contains('Received lines'));
    expect(provider, contains('Remaining lines'));
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
        'Keep the remaining purchase-order runtime understandable in one operational pass: approval handoff, receiving readiness, blockers, handoff target, and the last known runtime state all stay visible without leaving the POS inventory surface.',
      ),
    );
    expect(
      provider,
      contains(
        'The purchase order is ready for Office review, but POS does not execute approval. Operators can verify readiness and hand off the order to the Office-owned workflow only.',
      ),
    );
    expect(
      provider,
      contains(
        'The receipt confirmation contract exists and can update stock truthfully for the remaining quantity. Use the runtime action only when the inbound goods are physically verified.',
      ),
    );
    expect(
      tab,
      contains('Line-level risk / quantity / expected / received context:'),
    );
    expect(provider, contains('Ready to approve'));
    expect(provider, contains('Approved'));
    expect(provider, contains('Ready to receive'));
    expect(provider, contains('Received / closed'));
    expect(tab, contains('Check Approval Handoff'));
    expect(tab, contains('Confirm Remaining Receipt'));
    expect(tab, contains('onPressed: runtimeClosure.canCheckApproval'));
    expect(
      tab,
      contains(
        'onPressed: canConfirmReceipt && runtimeClosure.canConfirmReceipt',
      ),
    );
    expect(tab, contains('Office-owned execution'));
    expect(
      provider,
      contains(
        'Backend truth already shows this order as fully received. POS keeps the final state visible without sending another receipt confirmation.',
      ),
    );
    expect(tab, contains('Execution owner Office'));
    expect(tab, contains('POS role Visibility and checklist only'));
    expect(tab, contains('Blocked reasons'));
    expect(tab, contains('Runtime line context'));
    expect(tab, contains('Approval Handoff'));
    expect(tab, contains('runtimeSurface.blockedStateLabel'));
    expect(tab, contains('Domain boundary Payment / order / menu untouched'));
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
    expect(tab, contains('inventoryPurchaseRuntimeSurfaceProvider'));
    expect(tab, contains('inventoryPurchaseOperatingSummaryProvider'));
    expect(tab, contains('Refresh Purchase Overview'));
    expect(tab, contains('Next Operator Action'));
    expect(tab, contains('Operating blocked reasons'));
    expect(
      tab,
      contains(
        'Read the full inventory operating flow from one POS surface: recommendation runtime, latest snapshot state, purchase-order creation readiness, approval handoff, receiving readiness, selected purchase-order closure, blocked reasons, and the next operator action.',
      ),
    );
    expect(tab, contains('runtimeSurface.operationalPhaseLabel'));
    expect(tab, contains('runtimeSurface.readyStateLabel'));
    expect(tab, contains('runtimeSurface.blockedStateLabel'));
    expect(tab, contains('runtimeSurface.staleStateLabel'));
    expect(tab, contains('runtimeSurface.nextBestOperatorAction'));
    expect(tab, contains('runtimeSurface.receivedLineSummaryLabel'));
    expect(tab, contains('runtimeSurface.remainingLineSummaryLabel'));
    expect(tab, contains('runtimeSurface.receivingReadinessLabel'));
    expect(tab, contains('runtimeSurface.receiptVisibilityStatusLabel'));
    expect(tab, contains('runtimeSurface.lineContexts'));
    expect(tab, contains('runtimeSurface.receivingSafety'));
    expect(tab, contains('summary.reconciliationSummary'));
    expect(tab, contains('summary.actionQueue'));
    expect(tab, contains('summary.supplierBottlenecks'));
    expect(tab, contains('Visible snapshot lines'));
    expect(tab, contains('Visible purchase orders'));
    expect(tab, contains('Blocked reasons '));
    expect(tab, contains('Recommended '));
    expect(tab, contains('Ordered '));
    expect(tab, contains('Received '));
    expect(tab, contains('Remaining '));
    expect(tab, contains('Delayed '));
    expect(tab, contains('summary.mismatchIndicatorLabel'));
    expect(tab, contains('Queue next action:'));
    expect(
      tab,
      contains(
        'Reduce duplicate receiving fear by showing the last runtime result, retry discipline, unknown outcome handling, and the next safe recovery step from provider truth.',
      ),
    );
    expect(
      tab,
      contains(
        'Use the provider-owned queue to see which open purchase orders need Office handoff, receiving, follow-up, or escalation first.',
      ),
    );
    expect(
      tab,
      contains(
        'Review supplier-grouped queue pressure so follow-up happens at the supplier bottleneck level, not only one line at a time.',
      ),
    );
    expect(
      tab,
      contains(
        'Review the current store-scoped recommendation-to-receiving posture before drilling into one purchase order.',
      ),
    );

    expect(provider, contains('class InventoryPurchaseOverviewState'));
    expect(provider, contains('class InventoryPurchaseOperatingSummary'));
    expect(provider, contains('class InventoryPurchaseActionQueueEntry'));
    expect(provider, contains('class InventoryPurchaseReconciliationSummary'));
    expect(
      provider,
      contains('class InventoryPurchaseSupplierBottleneckState'),
    );
    expect(provider, contains('class InventoryPurchaseReceivingSafetyState'));
    expect(provider, contains('class InventoryPurchaseRuntimeSurfaceState'));
    expect(provider, contains('buildInventoryPurchaseOperatingSummary'));
    expect(provider, contains('buildInventoryPurchaseActionQueue'));
    expect(provider, contains('buildInventoryPurchaseReconciliationSummary'));
    expect(provider, contains('buildInventoryPurchaseSupplierBottlenecks'));
    expect(provider, contains('buildInventoryPurchaseReceivingSafetyState'));
    expect(provider, contains('buildInventoryPurchaseRuntimeBlockerRows'));
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
    expect(provider, contains('class InventoryPurchaseRuntimeClosureSnapshot'));
    expect(provider, contains('buildInventoryPurchaseRuntimeClosureSnapshot'));
    expect(provider, contains('inventoryPurchaseRuntimeSurfaceProvider'));
    expect(provider, contains('inventoryPurchaseOperatingSummaryProvider'));
    expect(provider, contains('reconciliationSummary'));
    expect(provider, contains('actionQueue'));
    expect(provider, contains('supplierBottlenecks'));
    expect(provider, contains('receivedLineCount'));
    expect(provider, contains('blockedLineCount'));
    expect(provider, contains('pendingLineCount'));
    expect(provider, contains('attentionLineCount'));
    expect(provider, contains('expectedBase'));
    expect(provider, contains('receivedBase'));
    expect(provider, contains('acceptedBase'));
    expect(provider, contains('rejectedBase'));
    expect(provider, contains('draftReceiptCount'));
    expect(provider, contains('cancelledReceiptCount'));
    expect(provider, contains('latestReceiptStatus'));
    expect(provider, contains('latestReceiptAt'));
    expect(provider, contains('operationalPhaseLabel'));
    expect(provider, contains('operationalPhaseTone'));
    expect(provider, contains('operationalPhaseNarrative'));
    expect(provider, contains('approvalStateTone'));
    expect(provider, contains('approvalNarrative'));
    expect(provider, contains('receivingStateTone'));
    expect(provider, contains('receivingNarrative'));
    expect(provider, contains('receivingReadinessLabel'));
    expect(provider, contains('receivingReadinessTone'));
    expect(provider, contains('receivingReadinessNarrative'));
    expect(provider, contains('receiptVisibilityStatusLabel'));
    expect(provider, contains('receiptVisibilityStatusTone'));
    expect(provider, contains('receiptVisibilityNarrative'));
    expect(provider, contains('readyStateLabel'));
    expect(provider, contains('readyStateTone'));
    expect(provider, contains('blockedStateLabel'));
    expect(provider, contains('blockedStateTone'));
    expect(provider, contains('staleStateLabel'));
    expect(provider, contains('staleStateTone'));
    expect(provider, contains('nextBestOperatorAction'));
    expect(provider, contains('receivedLineSummaryLabel'));
    expect(provider, contains('remainingLineSummaryLabel'));
    expect(provider, contains('blockerRows'));
    expect(
      provider,
      contains('class InventoryPurchaseRuntimeLineContextState'),
    );
    expect(provider, contains('lineContexts'));
    expect(provider, contains('receivingSafety'));
    expect(provider, contains('runtimeClosure'));
    expect(provider, contains('Handoff target'));
    expect(provider, contains('Last runtime state'));
    expect(provider, contains('confirmRemainingReceipt'));
    expect(provider, contains('markCancelled'));
    expect(provider, contains('Handoff target Office approval queue'));
    expect(provider, contains('Handoff target POS receiving contract'));
    expect(provider, contains('Last runtime state none yet'));
    expect(provider, contains('Office handoff now'));
    expect(provider, contains('Ready to receive now'));
    expect(provider, contains('Blocked / supplier follow-up'));
    expect(provider, contains('Overdue / escalation'));
    expect(provider, contains('Mismatch delayed inbound'));
    expect(provider, contains('Mismatch recommendation not converted'));
    expect(provider, contains('Mismatch approval queue'));
    expect(provider, contains('Mismatch receiving backlog'));
    expect(provider, contains('Delayed inbound cluster'));
    expect(provider, contains('Approval handoff cluster'));
    expect(provider, contains('Receiving follow-up cluster'));
    expect(provider, contains('Retry discipline'));
    expect(provider, contains('Unknown outcome'));
    expect(provider, contains('Follow-up'));
    expect(provider, contains('Recommendation running'));
    expect(provider, contains('Latest snapshot visible'));
    expect(provider, contains('PO creation ready'));
    expect(
      provider,
      contains(
        'Refresh the purchase overview to load the current store-scoped operating baseline.',
      ),
    );
    expect(
      provider,
      contains(
        'Hand off the selected purchase order to Office and keep POS on readiness, blockers, and checklist duty only.',
      ),
    );
    expect(
      provider,
      contains(
        'Physically verify inbound goods, then use Confirm Remaining Receipt only if the tracked receipt contract still matches the remaining quantity.',
      ),
    );
    expect(
      provider,
      contains(
        'POS can prepare the purchase order for handoff, but Office still owns approval execution and the backend does not yet allow receipt confirmation.',
      ),
    );
    expect(
      provider,
      contains(
        'Approval truth already exists, so POS can use the tracked receipt contract after physical inbound verification while keeping approval execution outside POS.',
      ),
    );
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
    expect(
      provider,
      contains('Receiving delayed beyond expected arrival window.'),
    );
    expect(
      provider,
      contains('purchase order line(s) still waiting supplier confirmation'),
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
    expect(
      tab,
      isNot(contains("rpc('office_approve_inventory_purchase_order'")),
    );
    expect(tab, isNot(contains("from('payments')")));
    expect(tab, isNot(contains("from('orders')")));
    expect(tab, isNot(contains("from('tables')")));
    expect(tab, isNot(contains('supabase.')));
    expect(tab, isNot(contains('.rpc(')));
    expect(
      tab,
      isNot(contains('buildInventoryPurchaseRuntimeClosureSnapshot(')),
    );
    expect(tab, isNot(contains('buildInventoryPurchaseOperatingSummary(')));
    expect(tab, isNot(contains('_inventoryApprovalRuntimeStateLabel(')));
    expect(tab, isNot(contains('_inventoryApprovalRuntimeNarrative(')));
    expect(tab, isNot(contains('_inventoryReceivingRuntimeStateLabel(')));
    expect(tab, isNot(contains('_inventoryReceivingRuntimeNarrative(')));
    expect(tab, isNot(contains('_inventoryReceiptReadinessLabel(')));
    expect(tab, isNot(contains('_inventoryReceiptReadinessNarrative(')));
    expect(tab, isNot(contains('buildInventoryPurchaseActionQueue(')));
    expect(
      tab,
      isNot(contains('buildInventoryPurchaseReconciliationSummary(')),
    );
    expect(tab, isNot(contains('buildInventoryPurchaseSupplierBottlenecks(')));
    expect(tab, isNot(contains('buildInventoryPurchaseReceivingSafetyState(')));
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
    expect(
      service,
      isNot(contains("rpc('office_approve_inventory_purchase_order'")),
    );
    expect(
      provider,
      isNot(contains('office_approve_inventory_purchase_order')),
    );
    expect(provider, isNot(contains("from('payments')")));
    expect(provider, isNot(contains("from('orders')")));
    expect(provider, isNot(contains("from('tables')")));
  });
}
