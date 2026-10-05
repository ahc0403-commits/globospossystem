# Procurement v2 shared contract (C0)

Status: implementation contract; feature activation is separate from source delivery.

## Authority
POS is the authoritative PR, commercial PO, supplier master and stock store. Office owns review/dispatch operations and accounting projections, invoices, AP/payments and replenishment schedules. Preserve restaurants/restaurant_id and Office store-to-POS mapping. General Office expense purchases are not inventory PRs.

## Envelope
Version 2 JSON; store_id always identifies the POS store at the POS boundary. Office translates scope before calling. Commands carry action, record_id, expected_version, idempotency_key, payload. Only the trusted service-role Office bridge may supply office_actor; POS actors come from auth.uid(). Actor identifiers are namespaced by authority and never coerced into foreign auth.users FKs. Record the actual authenticated principal and approval phase.

## Lifecycle
PR policy 1 retains the existing draft -> submitted -> office_review -> senior_review (conditional) -> approved -> allocated contract. New requests created while three_stage_required is enabled snapshot policy 2: draft -> submitted (Store Manager Adjust/approval) -> brand_review (Brand Manager Agree) -> office_review (buyer Approval) -> senior_review (conditional) -> approved -> allocated. The requester cannot approve policy 2, and store/brand/buyer/senior approvers must be distinct. Explicit HR person mappings also prevent the same person approving through different Auth systems. Names and emails do not establish identity. Returned requests retain history and resubmit a new revision. Changes to selected commercial terms invalidate brand/monetary approval. Purchase policy requires explicit configuration; missing thresholds never imply automatic approval.
PO: immutable issued version -> sent -> confirmed, with receipt progress separate. Existing inventory_purchase_orders.status remains compatible for fulfillment; workflow_version=2 selects the new command contract. V1 commands cannot change v2 documents. Supplier confirmation is required for v2 receiving.
Receiving: accepted quantities alone affect inventory, once, for stock-classified lines. Nonstock/asset receipt and return evidence never creates stock transactions. Classification, conversion and VAT are frozen to the order. Each policy-2 receipt compares against its remaining-quantity snapshot; cumulative accepted quantity cannot exceed the remainder. Corrections/returns are explicit events, never silent confirmed-row edits. An issue resolution must reference an actual confirmed follow-up receipt, actual cancelled remainder, or an Office-validated posted supplier credit adjustment.
Accounting: source order/receipt/line IDs plus immutable revision. Invoice line allocations cannot exceed uninvoiced accepted quantities. A line mismatch blocks AP/payment even if header totals match. Existing invoice-evidence and Finance gates remain authoritative.
Known v2 sources remain required even when their cache is missing. Policy-2 financial hashes cover immutable commercial terms and accepted/returned lines, not channel-payment metadata. A POS nonmonetary status mirror reports invoice/payable/hold/settlement counts and requires review when its version differs or observation is older than ten minutes; it never authorizes payment. Shopee payment evidence enforces caps and holds supplier AP until native Office settlement is reconciled. Native advance clearing and employee-specific reimbursement mapping remain pending; a recorded evidence row is not a payment or journal.
Scheduling: Office creates suggestions, never autonomous purchases/payments. Repeated execution of a store/item/policy/cycle produces one suggestion/request. Missing/stale inventory and unresolved open requests require review.

## Safety and deployment
Capability defaults disabled. Additive DB migrations precede bridge, UI and per-store enablement. Same key + same payload returns original result; same key + different payload fails. Stale versions fail. All commands verify scope and server-owned allowed actions. Preserve stock/payment invariants, legacy ongoing orders and unrelated work. Deploy only through each project's established gates, with exact SHA evidence and explicit distinction between source, applied migration, deployment and operational UAT.
new_requests_enabled pauses new PR creation without disabling in-flight processing. Policy-1 approval/accounting hashes remain compatible after migration. Supplier PO exports use a price-free allowlist; PR exports contain frozen estimates, and internal priced PO exports require price permission. Private export object names include source and file SHA-256 hashes so translated/regenerated outputs do not overwrite prior evidence.

## Bounded reads (2026-10-05)

The default workspace API returns PR/PO summaries (20, maximum 50), catalog pages (200), and one selected detail. Quotes/receipts are paged at 20, issues/returns at 50, and audit events at 100 with keyset cursors. Creation-date filters use Asia/Ho_Chi_Minh. Demand, supplier history and legacy repair evidence are explicit opt-ins. Large one-to-many relations are aggregated before joins. Office summary reads batch at most 100 stores/200 orders; snapshots and accounting-status mirrors batch at most 50 POs. Missing or foreign-scope batch results fail without per-row fallbacks. Atomic writes and their exact retry keys remain per document.

See [implementation evidence](/Users/andreahn/globos_pos_system/docs/implementation/pos_procurement_process_implementation_20261005.md) and [operator SOP](/Users/andreahn/globos_pos_system/docs/operations/pos_procurement_sop_20261005.md) for current limits, migration sequence and rollout prerequisites.

## Required behavioral fixtures
Per-line over/short receipt; post-order master change; replay/mismatched replay; cross-store read/write; Office actor attribution; returned revision; quote repricing -> reapproval; split supplier allocation race; same-total/different-line invoice; double invoicing partial receipts; return/credit correction; scheduled repeat/stale stock/bridge timeout.

## Native recognition and payment evidence
Nonstock invoice lines require an actual active postable expense account. Asset/CCDC lines require a same-store native registration and acquisition clearing account; invoice recognition and subsequent native capitalization must not debit asset cost twice. Native input-VAT posting retains canonical scope/document enrichment.

Channel payments are evidence records, not money execution. Employee payments bind an actual Office workforce employee and original advance. Office reconciliation consumes only posted native journals, signed cash-voucher lineage or actual advance-settlement receipts, validates store/employee/accounts/document/remaining amounts, and refreshes the canonical payable from real supplier offsets plus native payments. Employee reimbursement does not pay supplier AP again. Pre-invoice company cash/refunds do not manufacture AP. Reversals restore payable balances. Exact logical retries recover the original proof; mismatched amounts fail.

Role roster records explicit identity/responsibility, validity and deputy reasons; it does not grant/revoke native Auth permissions. Production activation requires confirmed actual roster and native authority, followed by operator UAT.
