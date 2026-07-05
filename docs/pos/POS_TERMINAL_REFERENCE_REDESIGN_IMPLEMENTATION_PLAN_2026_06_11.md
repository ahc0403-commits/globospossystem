# POS Terminal Reference Redesign Implementation Plan

Date: 2026-06-11
Status: Completed
Scope: Frontend UI implementation plan for the five highest-value POS operating surfaces.

This plan documents a staged implementation path for moving the current POS UI from generic card-based admin surfaces toward reference-informed restaurant POS workstations: order terminal, payment terminal, KDS, floor map, and inventory purchasing workstation.

This is a UI and interaction refactor plan. It does not authorize backend, Supabase schema, RLS, auth, payment RPC, WeTax, settlement, or Office coupling changes.

## Binding Constraints

- Preserve existing business logic, providers, services, RPC contracts, payment flow, WeTax async dispatch, RLS, and auth behavior.
- Do not rename or remove the POS `restaurants` table or its `id`, `name`, `address`, `is_active` columns.
- Do not alter the Office app coupling described in `CLAUDE.md`.
- Do not change payment completion semantics. Payment completion must not depend on WeTax availability.
- Use Vietnamese dong only for money display. Do not introduce KRW symbols.
- Fixed system labels must come from localization. Registered data names such as menu items, ingredient names, supplier names, and table names must remain as stored.
- Avoid decorative dashboards in live operator screens. Favor role-first, queue-first, dense, touchable POS workflows.
- No negative letter spacing in final UI styling.

## Think_A Step 1: Challenge The Problem

### What breaks if this is not built?

- Waiters cannot read table state, selected order, item quantities, and next action quickly enough during service.
- Cashiers see payment cards instead of a true payment terminal centered on amount due, tender, change, method, and confirmation.
- Kitchen users get a dashboard-like lane view instead of a KDS ticket board optimized for scanning ticket age and item quantities.
- Admin table management does not visually behave like a floor plan workspace.
- Inventory purchasing can appear decorative while missing unit, pack, unit price, recommended quantity, and estimated amount.
- Mixed fixed-label languages create user distrust and slow recognition, especially in a Vietnam deployment with multilingual data.

### Who needs this and how often?

| Role | Surface | Frequency | Primary job |
|---|---|---:|---|
| Waiter | Waiter order workspace | Constant during service | Select table, add menu items, send order |
| Cashier | Cashier payment workspace | Constant during checkout | Select payable order, collect payment, confirm |
| Kitchen | Kitchen screen | Constant during service | Scan tickets, progress item status |
| Admin / Manager | Tables tab | Daily / setup / monitoring | Manage floor layout and table state |
| Admin / Manager | Inventory tab | Daily / weekly | Review stock, create purchase orders |

### Is this the problem or a symptom?

The visual weakness is a symptom. The root problem is that key surfaces are not yet expressed as domain-specific POS workstations. A premium result will not come from shadows and colors alone; it requires each screen to expose the operator's primary job, required domain fields, and next action with POS-grade density.

## Think_A Step 2: Check Existing Solutions

The repo already contains the foundation needed for an incremental implementation:

- `lib/core/ui/pos_design_tokens.dart`
- `lib/core/ui/app_theme.dart`
- `lib/core/ui/toast/toast.dart`
- `lib/core/ui/toast/toast_primitives.dart`
- `lib/core/ui/toast/toast_primitives_extended.dart`
- `lib/widgets/order_workspace.dart`
- `lib/features/waiter/waiter_screen.dart`
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/kitchen/kitchen_screen.dart`
- `lib/features/admin/tabs/tables_tab.dart`
- `lib/features/admin/tabs/inventory_tab.dart`

Existing docs already define a role-first POS direction:

- `docs/pos/TOAST_STYLE_POS_OPERATIONAL_UX_STANDARD.md`
- `docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_IMPLEMENTATION_SEQUENCE.md`
- `docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md`

Therefore, the plan should extend the existing POS UI foundation rather than build a parallel UI platform.

## Think_A Step 3: Approach Comparison

| | A. Visual polish only | B. POS workstation refactor | C. Full design-system rewrite |
|---|---|---|---|
| Complexity build | Low | Medium | High |
| Complexity operate | Low | Medium | High |
| Reversibility | Easy | Screen-by-screen reversible | Difficult |
| Blast radius | Small but shallow | Controlled to five surfaces | App-wide |
| Schema cost | None | None by default | High risk of scope creep |
| Time to first usable version | Fast | Practical | Slow |
| Quality upside | Low | High | Uncertain |

Decision: choose B.

The implementation should add POS terminal primitives and refactor the five target screens one by one, without touching backend contracts.

## Think_A Step 4: Pressure Test

### First attack

The first likely failure is visual-only improvement that leaves domain gaps intact. The plan blocks this by defining per-screen required fields and failing inventory purchasing if unit, order unit, pack, unit price, and estimated amount are missing.

### Multi-tenant safety

All data must continue flowing through existing providers and services. No direct cross-tenant fetches, no service-role client in UI, no physical table/column rename.

### Failure path

Each screen must be independently revertible. Shared token changes must be additive first. If a screen refactor fails, revert that screen while keeping localization and test improvements.

### 10x data and 3 languages

Every screen must be checked with:

- 10x normal queue size
- Long menu names
- Long ingredient and supplier names
- Korean fixed labels
- Vietnamese fixed labels
- English fixed labels
- Vietnamese dong formatting
- Narrow tablet and mobile compact layouts

## Target Screens

| Priority | Screen | Current issue | Target archetype |
|---|---|---|---|
| P0 | Waiter order workspace | Generic menu/cart card layout | Touch order terminal |
| P1 | Cashier payment workspace | Card list and detail layout | Payment terminal |
| P2 | Kitchen screen | Lane dashboard | KDS ticket board |
| P3 | Admin tables tab | Admin grid feel | Floor map workstation |
| P4 | Inventory tab | Mixed admin/purchase surfaces | Inventory purchase workstation |

## Phase 0: Baseline And Evidence

Goal: capture the current state before implementation so later changes can be judged against real screens.

Tasks:

1. Capture current screenshots for the five target screens.
2. Record current `flutter analyze` result.
3. Record current relevant test result.
4. Save the latest reference redesign images as planning evidence.
5. Create or update a manual QA checklist for operator tasks.

Evidence paths already available:

- `design_artifacts/pos_reference_redesign_5/01_waiter_pos_reference.png`
- `design_artifacts/pos_reference_redesign_5/02_cashier_pos_reference.png`
- `design_artifacts/pos_reference_redesign_5/03_kitchen_pos_reference.png`
- `design_artifacts/pos_reference_redesign_5/04_table_pos_reference.png`
- `design_artifacts/pos_reference_redesign_5/05_inventory_pos_reference.png`

Acceptance:

- Five before screenshots exist.
- Five target after-reference images exist.
- Existing failing tests, if any, are documented separately from new regressions.

## Phase 1: Localization And Fixed Label Audit

Goal: remove fixed-label language mixing before visual refactors.

Primary files:

- `lib/features/admin/tabs/inventory_tab.dart`
- `lib/core/ui/toast/toast_vocabulary.dart`
- `lib/l10n/app_ko.arb`
- `lib/l10n/app_vi.arb`
- `lib/l10n/app_en.arb`

Known issues:

- Inventory tabs are keyed by English display strings:
  - `Ingredient Management`
  - `Recipe Management`
  - `Physical Count`
  - `Inventory Report`
- Toast vocabulary contains fixed English UI strings:
  - `Add Table`
  - `Start Prep`
  - `PROCESS PAYMENT`
  - `Nothing selected`
  - `No payable orders`

Implementation:

1. Replace tab display strings with stable internal enum or key values.
2. Resolve labels through `context.l10n`.
3. Move fixed strings from `toast_vocabulary.dart` into l10n or make call sites pass localized copy.
4. Keep stored data values untouched.
5. Add grep-based review to catch accidental hard-coded fixed labels.

Acceptance:

- No hard-coded English fixed labels remain in target screen presentation code.
- Data names still render as stored.
- `app_ko.arb`, `app_vi.arb`, and `app_en.arb` contain equivalent keys.
- `flutter gen-l10n` succeeds.

Suggested checks:

```sh
rg "Ingredient Management|Recipe Management|Physical Count|Inventory Report|PROCESS PAYMENT|Nothing selected|No payable orders|Start Prep|Add Table" lib
flutter gen-l10n
flutter test test/i18n_locale_contract_test.dart test/cashier_waiter_workspace_i18n_contract_test.dart
```

## Phase 2: POS Terminal Tokens

Goal: add visual tokens for true POS workstations without breaking existing Toast-style components.

Primary files:

- `lib/core/ui/pos_design_tokens.dart`
- `lib/core/ui/app_theme.dart`

Additive token groups:

- `PosTerminalColors`
  - dark terminal shell
  - light terminal shell
  - ticket paper
  - floor plan canvas
  - payment pad surface
- `PosDensity`
  - order row height
  - menu tile height
  - KDS ticket width/height
  - payment method tile size
  - floor table tile size
  - inventory row height
- `PosStatusPalette`
  - new order
  - preparing
  - ready/handoff
  - unpaid
  - delayed
  - low stock
  - blocked
- `PosMoneyText`
  - amount due
  - line item amount
  - compact VND label

Theme cleanup:

- Remove negative letter spacing from `app_theme.dart`.
- Keep Noto Sans KR for Korean readability.
- Use existing bundled/local font strategy where possible; do not introduce runtime font loading risk without testing.

Acceptance:

- Existing `AppColors` aliases still compile.
- Existing tests continue to compile.
- No global palette shift breaks unrelated admin screens.

Suggested checks:

```sh
flutter analyze
flutter test test/web_font_loading_contract_test.dart test/legacy_ui_compatibility_budget_test.dart
```

## Phase 3: Shared POS Primitives

Goal: create reusable components so each screen does not reinvent POS terminal structure.

Candidate file:

- `lib/core/ui/pos_terminal_primitives.dart`

Components:

| Component | Purpose |
|---|---|
| `PosTerminalShell` | Consistent workstation frame and safe padding |
| `PosStatusFilterBar` | Status/filter chips for KDS, cashier, inventory |
| `PosMoneyBlock` | Large VND amount block with label and optional subtext |
| `PosActionPad` | Payment/action tiles with fixed touch sizing |
| `PosTicketCard` | KDS ticket card with table, age, items, action |
| `PosDataGridRow` | Dense table row for cashier/inventory |
| `PosInspectorPanel` | Right-side selected item/table/order inspector |
| `PosFloorMapSurface` | Floor plan canvas wrapper with stable grid |

Rules:

- Primitives must be presentation-only.
- Primitives must not import feature providers.
- Primitives must accept text from callers, not hard-code fixed labels.
- Touch targets should remain at least 44 logical pixels.

Acceptance:

- New primitives have widget tests for overflow and basic rendering.
- Existing Toast primitives remain available.
- No screen logic moves into shared UI primitives.

## Phase 4: Waiter Order Terminal

Primary files:

- `lib/widgets/order_workspace.dart`
- `lib/features/waiter/waiter_screen.dart`
- `lib/features/table/floor_layout.dart`

Target structure:

- Left or right persistent order check panel:
  - selected table
  - guest count
  - elapsed time/status
  - current cart/sent items
  - subtotal/service fee/total
  - hold/cancel/send actions
- Top table status strip:
  - occupied
  - selected
  - warning/delayed
  - empty/reserved
- Main menu area:
  - category filter
  - search
  - menu item touch grid
  - menu item name as stored
  - VND price
  - add button

Logic to preserve:

- `onAddToCart`
- `onIncrementCartItem`
- `onDecrementCartItem`
- `onSendOrder`
- `onCancelOrder`
- `loadActiveOrder`
- offline queue messaging

Acceptance:

- Waiter can select table, add item, change quantity, send to kitchen.
- Payment action is not primary in waiter order taking.
- Menu names remain data-driven.
- Long menu names do not overlap price or add button.

Suggested checks:

```sh
flutter test test/waiter_floor_layout_contract_test.dart test/order_panel_close_session_contract_test.dart
flutter test test/cashier_waiter_workspace_i18n_contract_test.dart
```

## Phase 5: Cashier Payment Terminal

Primary file:

- `lib/features/cashier/cashier_screen.dart`

Target structure:

- Payment queue table:
  - order id
  - table
  - elapsed time
  - item count
  - status
  - amount
- Selected order inspector:
  - table and guests
  - subtotal
  - service fee
  - discount
  - due amount
- Payment pad:
  - received amount
  - quick tender buttons
  - payment methods
  - change
  - confirm payment
  - offline restriction notice

Logic to preserve:

- `processPayment`
- `paymentProofService`
- receipt printing
- red invoice modal
- payment method contract
- admin cancellation checks
- offline payment restrictions

Acceptance:

- Amount due is the visual anchor.
- Confirm payment is disabled until method/requirements are satisfied.
- Red invoice and proof flows remain available after successful payment path.
- Offline state blocks unsupported payment paths clearly.

Suggested checks:

```sh
flutter test test/payment_method_contract_test.dart test/payment_total_calculator_test.dart
flutter test test/cashier_receipt_print_contract_test.dart test/payment_split_contract_test.dart
flutter test test/pilot_red_invoice_smoke_contract_test.dart
```

## Phase 6: Kitchen KDS

Primary file:

- `lib/features/kitchen/kitchen_screen.dart`

Target structure:

- Top status filter:
  - all
  - new
  - preparing
  - handoff ready
  - delayed/attention
- Ticket board:
  - order id
  - table
  - elapsed time
  - item count
  - item quantities
  - status action
- Attention area:
  - oldest wait
  - delayed count
  - ready handoff count

Logic to preserve:

- `pending -> preparing -> ready -> served`
- alert sound
- flashing new order
- completed animation
- provider polling and load behavior

Acceptance:

- Kitchen can identify oldest order immediately.
- Ticket cards stay compact at 10x order count.
- Item status actions are explicit.
- No cashier/admin/report concepts appear in default KDS.

Suggested checks:

```sh
flutter test test/kitchen_operational_attention_contract_test.dart
flutter test test/provider_poll_guard_test.dart
```

## Phase 7: Admin Tables Floor Map

Primary files:

- `lib/features/admin/tabs/tables_tab.dart`
- `lib/features/table/floor_layout.dart`

Target structure:

- Left control rail:
  - total
  - occupied
  - reserved/waiting
  - empty
  - section filters
- Center floor map:
  - grid or room canvas
  - table tiles by actual layout data
  - selected/occupied/warning/empty states
- Right inspector:
  - selected table
  - seat count
  - status
  - recent order
  - assigned area/staff if available
  - layout save/move actions in edit mode only

Logic to preserve:

- `_draftLayoutByTableId`
- layout save/update flow
- table selection
- order panel opening behavior where still required
- admin audit trace

Acceptance:

- Floor map is the primary visual object.
- Layout editing and live order operations are visually distinct.
- Save layout only appears when relevant.
- Table tiles keep stable dimensions and do not shift on hover/selection.

Suggested checks:

```sh
flutter test test/admin_table_layout_editor_contract_test.dart
flutter test test/admin_table_selection_contract_test.dart
flutter test test/table_layout_model_contract_test.dart
```

## Phase 8: Inventory Purchase Workstation

Primary files:

- `lib/features/admin/tabs/inventory_tab.dart`
- `lib/features/inventory/inventory_provider.dart`

Target structure:

- KPI strip:
  - total stock value
  - estimated purchase amount
  - approval pending
  - risk items
- Purchase recommendation grid:
  - item
  - current stock with unit
  - minimum/par level
  - recommended quantity
  - order unit
  - pack unit
  - unit price
  - estimated amount
  - supplier
  - status
- Purchase order draft:
  - supplier grouped totals
  - line count
  - total estimated purchase
  - create purchase order action

Data audit:

Before UI implementation, confirm whether the current provider exposes:

- current stock quantity
- inventory unit
- order unit
- pack unit
- unit price
- supplier
- estimated line amount
- recommendation status

If data is missing:

- First use existing available fields with clear fallback.
- Do not add DB columns in this phase.
- Document missing data separately as a backend/product gap.

Acceptance:

- No recommendation row passes without unit, recommended quantity, unit price, and estimated amount visibility.
- VND format is consistent.
- Supplier grouping is visible if supplier data exists.
- Long item/supplier names truncate without hiding amount and unit.

Suggested checks:

```sh
flutter test test/inventory_admin_ui_contract_test.dart
flutter test test/inventory_purchase_office_contract_test.dart
flutter test test/inventory_purchase_readonly_overview_contract_test.dart
```

## Phase 9: Responsive And Language QA

Targets:

- Desktop 1366 x 768
- Tablet landscape
- Tablet portrait if supported
- Mobile compact fallback

Language/data scenarios:

- Korean system labels
- Vietnamese system labels
- English system labels
- Vietnamese menu data names
- Korean admin data names
- Long menu names
- Long ingredient names
- Long supplier names
- 10x queue volume

Required checks:

```sh
flutter analyze
flutter test
rg "₩|Office|Hall|Ingredient Management|Recipe Management|Physical Count|Inventory Report|PROCESS PAYMENT|Nothing selected" lib
```

Manual QA:

- Waiter: select table, add item, change quantity, send order.
- Cashier: select order, choose method, confirm payment, print receipt path.
- Kitchen: progress item from pending to preparing to ready to served.
- Tables: select table, edit layout, save layout, verify selected inspector.
- Inventory: verify each recommendation row includes unit, pack/order unit, unit price, estimated amount.

## Phase 10: Evidence And Closure

Deliverables:

- Updated screenshots for the five target screens.
- Before/after image board generated from real screens.
- Test summary.
- Known limitations list.
- Follow-up backlog for any missing inventory data fields.

Definition of done:

- All five screens meet the primary job test.
- Fixed labels are localized.
- Money is VND-only.
- No backend contract changes were required.
- No payment, RLS, Office coupling, or WeTax regression.
- 10x data and 3-language review completed.

## Rollback Strategy

Rollback must be screen-scoped:

1. Keep Phase 1 localization fixes unless they introduce compile issues.
2. Keep additive tokens unless they break unrelated screens.
3. Revert one feature screen at a time if behavior breaks.
4. Never rollback by resetting DB migrations or provider/service contracts.

## Implementation Order

1. Baseline screenshots and test record.
2. Localization and hard-coded label audit.
3. Add POS terminal tokens.
4. Add shared POS primitives.
5. Refactor waiter order terminal.
6. Refactor cashier payment terminal.
7. Refactor kitchen KDS.
8. Refactor admin tables floor map.
9. Refactor inventory purchase workstation.
10. Run responsive/language/10x-data QA.
11. Capture final screenshots and close with evidence.

## Open Questions

- Does the inventory provider currently expose order unit, pack unit, supplier, and unit price for every recommendation row?
- Should Korean or Vietnamese be the default fixed-label locale for the Vietnam deployment, or should this remain user-selectable only?
- Should the admin tables screen retain any live order operation shortcut, or should it fully route to waiter/cashier/kitchen role surfaces?
- Are payment quick tender values fixed per store, or should they be computed from amount due and local cash handling practice?

These questions should be answered before Phase 8 and before any implementation that would otherwise require schema changes.
