# P4 — Inspection and discrepancy handling

V2 receipt submission requires line-level specification, quality, packaging, expiry and (for cold-storage products) measured/accepted temperature. Photos use the existing scoped private receipt storage path and are validated server-side. Physical received, accepted and rejected quantities stay separate; a failed inspection cannot post accepted stock. Supplier confirmation is required before submission and verification. Existing independent accountant verification remains.

Confirmed discrepancies create an Office follow-up record. Scoped Office commands record completed additional-delivery/exchange/credit/cancellation evidence, and cancel only unreceived remainder. Confirmed stock can be returned by POS inventory accounting; the return ledger and stock reduction are atomic and replay-safe. Original receipts and commercial PO snapshots are retained.

SQL regression covers rejected QC, partial receiving, stock return/replay, remainder cancellation, and receiving price privacy, in addition to existing scope and concurrency checks. UI analysis passes. Production migration/deployment not performed.
