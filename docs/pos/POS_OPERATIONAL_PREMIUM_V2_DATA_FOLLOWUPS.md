# POS Operational Premium V2 Data Follow-Ups

Date: 2026-06-11
Scope: Deferred data-dependent ideas from Phase 2 empty states.

This document authorizes no backend, Supabase, RLS, Office, WeTax, payment RPC,
or provider-contract work. It records the data that would be required later so
Phase 2 can remain frontend-only.

## Deferred Items

| Screen | Deferred item | Data/provider required |
|---|---|---|
| Waiter | Per-table oldest-open elapsed time when the currently loaded table/order data does not already include it | Store-scoped active-order opened-at field exposed through the existing order/table preview contract |
| Cashier | Last completed payment in the "no payable orders" state | `PaymentState` would need to retain completed payment history or load a scoped payment-history summary |
| Kitchen | Today served ticket count and historical throughput in empty lanes | `KitchenState` would need a scoped served-ticket aggregate or completed-ticket history |
| Tables | Per-table revenue, last-order amount, or last-order age in the no-selection inspector | Admin tables would need read-only order summary data beyond `TablesState.tables` |
| Inventory | Explanation for zero recommendations such as missing recipe links, consumption coverage gaps, or supplier catalog coverage | Recommendation diagnostics from the inventory recommendation query/provider |

## Built In Phase 2

- Cashier no-payable state uses existing connectivity and `paymentProvider.loadOrders`.
- Kitchen empty lanes use existing lane titles/counts and render as slim rails.
- Admin Tables no-selection inspector uses only status counts and occupied
  tables already present in `TablesState.tables`.
- Inventory zero-recommendation state uses the current recommendation snapshot,
  existing order summary status counts, and existing recommendation/manual-order
  actions.
