# Inventory Purchase Design Slice — 2026-05-12

## Verdict

`inventory_purchase` is the next redesign target after `payment_detail`, but it
must not start as a direct restore of the quarantined runtime trio.

The first tracked slice should be **staged, read-heavy, and shell-preserving**.

## Current Tracked Truth

### Existing tracked admin mount

The tracked admin inventory workspace is still:

- `/Users/andreahn/globos_pos_system/lib/features/admin/tabs/inventory_tab.dart`

And it is mounted directly from:

- `/Users/andreahn/globos_pos_system/lib/features/admin/admin_screen.dart`

That mount must stay intact for the first slice.

### Existing tracked DB-side lineage

Tracked migrations already define a substantial inventory purchase domain:

- `20260506000000_inventory_purchase_office_contracts.sql`
- `20260506001000_inventory_purchase_bootstrap_seed.sql`
- `20260506002000_inventory_purchase_pos_native_access_fix.sql`
- `20260506003000_inventory_purchase_line_amount_fix.sql`
- `20260506004000_inventory_purchase_receipt_confirm.sql`
- `20260506005000_inventory_purchase_stock_audit_save.sql`
- `20260506006000_inventory_purchase_manual_order.sql`
- `20260506007000_inventory_supplier_management.sql`
- `20260506008000_inventory_product_management.sql`
- `20260506009000_inventory_recipe_management.sql`
- `20260506010000_inventory_consumption_refresh.sql`
- `20260506011000_inventory_cost_analysis.sql`
- `20260506012000_inventory_new_menu_registration.sql`

### Existing tracked design reference

The Office/POS domain design already exists:

- `/Users/andreahn/globos_pos_system/docs/inventory_purchase_office_design.md`

### Recovery audit constraint

The quarantined runtime files remain `NO-RESTORE`:

- `inventory_purchase_provider.dart`
- `inventory_purchase_screen.dart`
- `inventory_purchase_service.dart`

They were previously classified as `staged_reimplementation_only`, not direct
restore candidates.

## What Must Not Happen

The first tracked slice must **not**:

- replace `InventoryTab` with a restored `InventoryPurchaseScreen`
- import quarantined runtime files
- bundle supplier management, product management, recipe management, stock
  audit, and Office approval flows into one PR
- add admin sidebar signal integration
- reopen unclear SQL provenance work

## First Slice Goal

Create a narrow tracked bridge from the current admin inventory surface into the
already-tracked inventory purchase DB domain.

The first slice should answer only this question:

> Can an authorized admin user view a read-only inventory purchase overview and
> recommendation summary inside the tracked inventory workspace without
> replacing the existing shell?

## First Slice Shape

### 1. Keep the existing admin shell

Do not create a new top-level route or replace the mounted inventory tab.

Stay inside the existing tracked admin inventory workspace and add a new narrow
surface there.

### 2. Read-only purchase overview only

The first tracked runtime slice should limit itself to read-oriented purchase
visibility such as:

- purchase dashboard summary
- recommendation summary preview
- low-stock / suggested-order visibility

The most likely tracked RPC entry points are the already-covered DB contracts:

- `public.get_inventory_purchase_dashboard`
- `public.run_inventory_purchase_recommendation`

### 3. New tracked code may be small and local

If implementation starts, prefer:

- a small tracked service wrapper for read-only inventory purchase RPCs
- a small tracked provider/state holder
- a small read-only UI surface embedded in or launched from `InventoryTab`

Do not begin with a large standalone workspace shell.

## Explicit Exclusions

These must stay out of the first tracked slice:

- Office approval / reject / return mutation flows
- purchase order editing
- receipt confirmation / stock writeback flows
- supplier CRUD
- product CRUD
- recipe CRUD
- cost analysis detail pages
- stock audit session flows
- manual purchase order creation flows
- mobile-first purchase entry flows

## Why This Slice Is Safe

- preserves the current tracked admin mount
- uses already-tracked DB lineage rather than quarantined runtime ideas
- minimizes UI surface area
- avoids restoring the failed large runtime slice
- creates a clean seam for later staged expansion

## Recommended PR Shape

The first implementation PR for `inventory_purchase` should be as small as
possible:

1. add a read-only inventory purchase overview surface within the existing
   inventory workspace
2. wire only the minimum tracked read RPCs
3. add the smallest test coverage needed for the new surface
4. do not include Office mutations or stock-affecting actions

## Follow-up Order After The First Slice

Only after the read-only overview lands cleanly should later slices evaluate:

1. recommendation detail drill-down
2. draft purchase order creation
3. Office review status visibility
4. receipt confirmation and stock mutation flows

Each of those should remain separate tracked slices.

## Stop Condition

If the team cannot define a small read-only overview that stays inside the
existing tracked inventory shell, the first slice is still too large and should
be decomposed again before implementation begins.
