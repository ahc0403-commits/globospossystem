# Procurement v2 shared contract (C0)

Status: implementation contract; feature activation is separate from source delivery.

## Authority
POS is the authoritative PR, commercial PO, supplier master and stock store. Office owns review/dispatch operations and accounting projections, invoices, AP/payments and replenishment schedules. Preserve restaurants/restaurant_id and Office store-to-POS mapping. General Office expense purchases are not inventory PRs.

## Envelope
Version 2 JSON; store_id always identifies the POS store at the POS boundary. Office translates scope before calling. Commands carry action, record_id, expected_version, idempotency_key, payload. Only the trusted service-role Office bridge may supply office_actor; POS actors come from auth.uid(). Actor identifiers are namespaced by authority and never coerced into foreign auth.users FKs. Record the actual authenticated principal and approval phase.

## Lifecycle
PR: draft -> submitted -> office_review -> senior_review (conditional) -> approved -> allocated. Returned requests retain history and resubmit a new revision. Quote changes invalidate monetary approval. Purchase policy requires explicit configuration; missing thresholds never imply automatic approval.
PO: immutable issued version -> sent -> confirmed, with receipt progress separate. Existing inventory_purchase_orders.status remains compatible for fulfillment; workflow_version=2 selects the new command contract. V1 commands cannot change v2 documents. Supplier confirmation is required for v2 receiving.
Receiving: accepted quantities alone affect inventory, once. Line-level outstanding quantity drives completion. Conversion and VAT are frozen to the order. Corrections/returns are explicit events, never silent confirmed-row edits.
Accounting: source order/receipt/line IDs plus immutable revision. Invoice line allocations cannot exceed uninvoiced accepted quantities. A line mismatch blocks AP/payment even if header totals match. Existing invoice-evidence and Finance gates remain authoritative.
Scheduling: Office creates suggestions, never autonomous purchases/payments. Repeated execution of a store/item/policy/cycle produces one suggestion/request. Missing/stale inventory and unresolved open requests require review.

## Safety and deployment
Capability defaults disabled. Additive DB migrations precede bridge, UI and per-store enablement. Same key + same payload returns original result; same key + different payload fails. Stale versions fail. All commands verify scope and server-owned allowed actions. Preserve stock/payment invariants, legacy ongoing orders and unrelated work. Deploy only through each project's established gates, with exact SHA evidence and explicit distinction between source, applied migration, deployment and operational UAT.

## Required behavioral fixtures
Per-line over/short receipt; post-order master change; replay/mismatched replay; cross-store read/write; Office actor attribution; returned revision; quote repricing -> reapproval; split supplier allocation race; same-total/different-line invoice; double invoicing partial receipts; return/credit correction; scheduled repeat/stale stock/bridge timeout.
