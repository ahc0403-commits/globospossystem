# POS Terminal Reference Redesign Baseline

Date: 2026-06-11
Plan: `docs/pos/POS_TERMINAL_REFERENCE_REDESIGN_IMPLEMENTATION_PLAN_2026_06_11.md`

## Baseline Screenshots

Existing real before screenshots:

- `screenshots/prod-waiter-after-login.png`
- `screenshots/prod-cashier-after-login.png`
- `screenshots/prod-kitchen-after-login.png`
- `screenshots/admin-composite-sidebar-01-tables-2026-05-18.png`
- `screenshots/admin-composite-sidebar-06-inventory-2026-05-18.png`

Reference redesign images:

- `design_artifacts/pos_reference_redesign_5/01_waiter_pos_reference.png`
- `design_artifacts/pos_reference_redesign_5/02_cashier_pos_reference.png`
- `design_artifacts/pos_reference_redesign_5/03_kitchen_pos_reference.png`
- `design_artifacts/pos_reference_redesign_5/04_table_pos_reference.png`
- `design_artifacts/pos_reference_redesign_5/05_inventory_pos_reference.png`

## Baseline Checks

Commands run on 2026-06-11:

```sh
flutter analyze
flutter test test/i18n_locale_contract_test.dart test/cashier_waiter_workspace_i18n_contract_test.dart test/waiter_floor_layout_contract_test.dart test/kitchen_operational_attention_contract_test.dart test/inventory_admin_ui_contract_test.dart
```

Result:

- `flutter analyze`: PASS, no issues found.
- Targeted tests: PASS, 32 tests passed.

## Manual QA Contract

The redesign is not accepted until these operator paths work after implementation:

- Waiter: select table, add item, change quantity, send order.
- Cashier: select order, choose payment method, confirm payment, preserve receipt/proof/red-invoice paths.
- Kitchen: progress an item from pending to preparing to ready to served.
- Tables: select table, edit layout, save layout, verify selected inspector.
- Inventory: verify each recommendation row exposes unit, order unit or pack unit, unit price, estimated amount, supplier/status when available.

## Regression Guardrails

- No backend, Supabase schema, RLS, auth, payment RPC, WeTax, settlement, or Office coupling changes are authorized by this redesign.
- Fixed labels must be localized.
- Stored menu, ingredient, supplier, and table data must render as stored.
- Money display must remain VND-only.
- Each screen refactor must be independently revertible.
