# Inventory Purchase Second Slice — 2026-05-12

## Verdict

The second tracked slice for `inventory_purchase` should remain **read-only**
 and should **not** invoke recommendation-run creation, purchase-order
 creation, or Office review mutations.

The goal of the second slice is to make the first overview more actionable
 without turning it into a workflow surface.

## Current Tracked Baseline

The first tracked slice already landed on `main`:

- `/Users/andreahn/globos_pos_system/lib/features/admin/tabs/inventory_tab.dart`
- `/Users/andreahn/globos_pos_system/lib/features/inventory/inventory_provider.dart`
- `/Users/andreahn/globos_pos_system/lib/core/services/inventory_service.dart`
- `/Users/andreahn/globos_pos_system/test/inventory_purchase_readonly_overview_contract_test.dart`

That baseline added a read-only purchase overview inside the existing
 `Inventory Report` tab and kept the current admin inventory shell intact.

## What The Second Slice Should Solve

The next question is not “can the user mutate purchase state?”

It is:

> Can an admin user understand why the purchase overview matters, using
> tracked read-only detail and existing inventory signals, without starting a
> recommendation run or entering an Office-style purchase workflow?

## Allowed Scope

The second slice may add **read-only detail expansion** such as:

- clearer explanation of low-stock risk meaning
- scoped breakdown of submitted vs approved purchase totals
- store-scoped explanatory detail under the overview cards
- read-only drill-down into already-tracked inventory risk/report context

It may also improve:

- layout density
- labels and copy
- section grouping
- “what to review next” guidance text

## Explicitly Not Allowed

The second slice must still **not**:

- call `public.run_inventory_purchase_recommendation`
- create draft purchase orders
- edit purchase orders
- confirm receipts
- mutate stock
- add supplier/product/recipe CRUD
- add Office approval/reject/return flows
- replace `InventoryTab`
- import quarantined runtime files
- add admin sidebar signal integration

## RPC Boundary

For the second slice, the safe tracked boundary is:

- continue using `public.get_inventory_purchase_dashboard`
- optionally combine with already-tracked read inventory signals already shown
  in the inventory workspace

Unsafe for this slice:

- `public.run_inventory_purchase_recommendation`
  because it creates a recommendation run and recommendation lines
- any purchase-order mutation RPC
- any receipt confirmation RPC

## Recommended UI Shape

Keep the second slice inside the existing `Inventory Report` surface.

Preferred shape:

1. retain the current overview cards
2. add a compact read-only detail block below them
3. use descriptive copy and scoped metrics instead of new workflows
4. avoid new top-level tabs unless the report surface becomes too crowded

## Recommended Test Boundary

If implementation starts, the matching test should stay small and assert only:

- the read-only detail surface exists
- the tracked shell remains `InventoryTab`
- no recommendation-run call is introduced
- no purchase mutation surface is introduced

## Stop Condition

If the team cannot add meaningful detail without invoking
 `run_inventory_purchase_recommendation` or new mutation RPCs, the second slice
 is still too large and should stop at the first-slice overview.
