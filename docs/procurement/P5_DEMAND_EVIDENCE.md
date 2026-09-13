# P5 — Demand evidence and stock reliability

The request workspace shows current stock and timestamp, minimum stock, 28 completed HCM-calendar days of recorded usage/waste, outstanding inbound quantities and pending unallocated PR quantities. Existing signed stock-ledger entries are normalized to consumption magnitude. Supplier-return movements are excluded from usage and remain signed stock decreases. Average received quantity and latest confirmed purchase price support review; price-sensitive output is redacted for orderers.

Multiple orderable products pointing at the same stock row are flagged, not treated as independent usable inventories. Stale/missing data remain explicit and block automatic confirmation in Office. Usage mode requires observation evidence; lack of transactions does not prove zero usage. Existing stock adjustment/count workflows remain authoritative for recording operational-consumable usage.

Tests cover signed usage/waste, exclusion of returns, shared-stock mappings, and unchanged legacy receiving. No sales-estimate value is silently substituted for recorded usage.
