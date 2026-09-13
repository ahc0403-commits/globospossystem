# P1 receiving integrity

Implemented in additive migration 20260913140000. No production database was changed.

- Reproduced cross-line overdelivery incorrectly closing an underdelivered line against the previous implementation.
- Completion now evaluates each order line, including explicit cancelled remainder.
- Receipts calculate against captured conversion/VAT. Unrecoverable historical terms require review, never current-master inference.
- Positive receipts require a valid same-store stock mapping.
- Confirmation replay binds receipt, actor and payload hash. Different payloads are rejected.
- Actual price history reads confirmed accepted receipt lines without rewriting supplier contracts.

Validation: `bash scripts/test_procurement_v2.sh` passed the existing SQL and concurrent-session suite plus per-line completion, mutable-master, replay mismatch and missing-stock-map regressions. Historical correction UI, returns and explicit remainder cancellation are delivered with P4; the schema supports their line-level accounting.
