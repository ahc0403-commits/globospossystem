# ADR-001: Isolated finance and fulfillment for direct delivery

Date: 2026-08-21
Status: Accepted for implementation

## Context

Direct delivery is paid before kitchen preparation. The existing POS lifecycle completes an order inside `process_payment` and existing KDS state changes operate on `orders` and `order_items`. Adding a prepaid exception to those existing functions would put dine-in, takeaway, QR, inventory, cutoff, printing, and MISA behavior at risk.

## Decision

- Before cashier approval, only new `direct_order_*` data exists.
- Cashier approval creates a tableless delivery financial order using currently valid core values and calls the unchanged `process_payment` function.
- All financial lines are payable, the order is completed, inventory is deducted, and MISA is enqueued by the existing function exactly once.
- A new direct-delivery fulfillment ticket is created in the same transaction but becomes visible only after commit.
- Kitchen progress mutates only the new fulfillment ticket and never mutates the completed POS order or its items.
- Existing QR, cashier queue, KDS, print routing, payment, cutoff, promotion, MISA, and report objects are frozen for V1.

## V1 eligibility

- Storefront flag enabled explicitly.
- Store fulfillment mode is `pos_print`.
- No active emergency fulfillment session.
- No active scheduled promotion.
- Approval occurs before 21:30 Asia/Ho_Chi_Minh.
- Bank and delivery-fee tax/accounting policy is approved.

## Consequences

- Existing POS behavior does not need a source-specific branch.
- Financial recognition happens at manual bank-transfer approval, before food preparation.
- Kitchen status is intentionally separate from the financial order status.
- Direct delivery has a dedicated kitchen route and analytics RPC.
- Existing receipt/MISA treatment of a `service_charge` item remains authoritative; accounting rejection of that treatment blocks rollout.
- Printing is optional and isolated. Direct KDS remains the source of truth.

## Rejected alternatives

- Pre-create an unpaid POS order before approval.
- Store a paid order in a non-completed state.
- Modify `process_payment`, order recalculation, item status, cutoff, or current KDS functions.
- Add a new existing-core item type or order source constraint value.
- Merge direct delivery into Deliberry external settlement.
