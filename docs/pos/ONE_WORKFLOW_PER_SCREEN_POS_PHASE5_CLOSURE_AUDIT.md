# One Workflow Per Screen POS Phase 5 Closure Audit

Date: 2026-05-15

This document closes the POS "One Workflow Per Screen" redesign work against the
fixed interpretation:

> One screen must have one primary job. Supporting actions required to complete
> that primary job may remain on the same screen. Secondary detail must be
> disclosed on demand. Separate workflows must move out of default visibility.

## Closure Status

| Phase | Status | Evidence |
|---|---|---|
| Phase 0 - Criteria Lock | PASS | `ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md` defines the audit gates and explicitly prevents feature-level over-splitting. |
| Phase 1 - Contract Mapping | PASS | Major screens are mapped with Primary Job, Supporting Actions, Secondary Detail, Separate Workflows, Should Remain, and Should Move. |
| Phase 2 - Live POS Safety | PASS | Waiter, OrderWorkspace, Kitchen, and Admin Tables now expose role-safe primary jobs by default. |
| Phase 3 - Cashier Completion | PASS | Cashier Payment Execution keeps payment-completion supporting actions together and removes daily summary/report style work from the default checkout job. |
| Phase 4 - Manager/Admin Density | PASS | Reports, Inventory, Attendance, Staff, QC, Settings, E-Invoice, and Delivery Settlement now use primary-job headers, queues, and secondary disclosure for dense detail. |
| Phase 5 - Verification | PASS | `flutter analyze`, `flutter test`, `flutter build web`, source checks, and browser render checks passed. |

## Primary Job Contract Applied

| Area | Primary Job | Supporting Actions Kept | Secondary Detail Moved |
|---|---|---|---|
| Waiter floor | Select or continue service for one table. | Filter table, enter guests, continue order, start order. | Order history and sent kitchen detail. |
| Order taking | Complete item entry for the selected table. | Category browse, add item, quantity, notes, cart review, send. | Sent kitchen items and prior detail. |
| Cashier payment | Complete payment for the selected order. | Payment method, discount/coupon, item correction, split payment, receipt, retry, proof, red invoice capture. | Daily summary, report-like metrics, proof/e-invoice diagnostics. |
| Kitchen | Decide and execute the next cooking ticket. | Queue scan, select ticket, start/ready item, read notes. | Served history and non-execution diagnostics. |
| Admin tables | Configure table layout or monitor table state in the selected mode. | Add table, edit position, save layout, status filter. | Waiter ordering, kitchen item cycling, payment execution. |
| Menu admin | Maintain menu catalog and availability. | Add/edit category, add/edit item, availability toggle. | Inventory analysis and advanced recipe detail. |
| Inventory | Complete the selected inventory work step. | Catalog, recipe, stock count, purchase/receiving step controls. | Runtime diagnostics and report-like detail. |
| Reports | Review historical performance for a period. | Date range, KPI review, export. | Operational signals and closing detail. |
| Attendance | Review attendance records. | Date/staff filter, record scan, exception check. | Payroll detail and diagnostics. |
| Staff | Maintain staff directory/profile records. | Search, add staff, activate/deactivate, open profile. | Attendance/payroll/permission history. |
| E-Invoice | Resolve or monitor invoice exceptions. | Filter queue, retry, open portal, mark resolved. | Raw refs, portal metadata, timestamps. |
| QC | Resolve QC follow-up exceptions by default. | Filter follow-ups, update follow-up status. | Analytics, weekly board, template configuration detail. |
| Settings | Edit selected store/system configuration. | Save/reset store settings, profile label, PIN, printer test. | Audit trace and system diagnostics. |
| Delivery settlement | Resolve or confirm delivery settlement items. | Filter settlement status, inspect item, confirm received. | Aggregate settlement reporting. |

## Cashier Non-Split Confirmation

Cashier Payment Execution was not split by feature. The following remain inside
the payment-completion screen because they are supporting actions:

- Payment method selection
- Discount/coupon adjustment
- Menu cancellation or quantity correction needed before payment
- Split payment
- Receipt output
- Failed payment retry
- Proof attachment
- Guest-requested red invoice capture

The following remain separate workflows and are not default checkout work:

- Daily closing
- Sales reports
- Staff settlement
- Refund approval management
- Menu settings
- Inventory analysis
- Operational exception monitoring

## Resolved UX Problems

1. Admin Tables no longer defaults to a cross-role console for waiter ordering,
   kitchen status cycling, payment, and table setup.
2. Waiter now starts from the dining floor/table decision instead of a mixed
   order-management surface.
3. OrderWorkspace keeps sent kitchen items as secondary detail, so item entry
   and order review stay focused.
4. Cashier no longer treats daily summary/report work as equal to payment
   execution.
5. Kitchen separates queue scanning from selected ticket execution.
6. Inventory reduces the giant dashboard feeling with selected work-step
   surfaces and secondary runtime detail.
7. Reports keep period analysis primary and move operational signals out of
   default hierarchy.
8. E-Invoice is exception-queue first instead of raw diagnostics first.
9. QC defaults to follow-up exceptions; analytics and review-heavy material are
   disclosed on demand.
10. Settings now reads as configuration work, not a mixed dashboard of store
    config, printer, PIN, audit, and system operations.

## Role Boundary Closure

| Role | Closed Boundary |
|---|---|
| Waiter | Table selection, order taking, and order review stay separate from payment and kitchen execution. |
| Cashier | Payment queue/execution keeps checkout supporting actions but excludes reports, closing, and manager exception monitoring. |
| Kitchen | Kitchen queue/execution owns cooking status changes; waiter/admin/cashier surfaces do not expose kitchen item cycling by default. |
| Admin | Configuration screens are grouped by work step and avoid default live-operation control. |
| Manager | Reports, closing, e-invoice, delivery settlement, QC, and monitoring signals are separated by primary job or moved behind secondary disclosure. |

## Source Checks

| Check | Result |
|---|---|
| `rg "PosPageHeader|PosStatCard|PosToolbar|AppPanel\\(|WebSidebarLayout\\(" lib/features lib/widgets lib/core/ui/toast` | PASS. Only `lib/core/ui/toast/toast_primitives_extended.dart` contains legacy component definitions. No feature surface uses them. |
| `git diff --name-only -- supabase docs/vendor` | PASS. No Supabase migrations, schema files, RLS, edge functions, or vendor docs changed. |
| Payment workflow source | PASS. Cashier still uses existing payment execution and keeps `PaymentProofModal` and `RedInvoiceModal` in checkout. |
| Kitchen workflow source | PASS. Kitchen still uses the tracked kitchen status mutation path; UI hierarchy changed, not backend workflow semantics. |
| Delivery settlement source | PASS. Existing `confirm_delivery_settlement_received` RPC call is preserved; aggregate reporting is secondary detail. |
| E-Invoice source | PASS. Existing `einvoice_jobs`, `admin_retry_einvoice_job`, and `admin_mark_resolved_einvoice_job` paths are preserved. |

## Runtime Contract Confirmation

Untouched:

- DB schema
- Supabase migrations
- RLS policies
- RPC definitions
- Edge functions
- Auth route contract
- Payment completion backend anchor
- Kitchen backend mutation contract
- WeTax vendor lifecycle

UI-facing compatibility code exists in `menu_service`, `tables_service`,
`tables_provider`, and `table_provider` to keep existing admin table/menu UI
actions working across legacy/current store parameter names and normalized floor
layout fields. These changes do not add new database schema, new RPC contracts,
or new backend mutations.

## Verification Results

| Command | Result |
|---|---|
| `flutter analyze` | PASS. No issues found. |
| `flutter test` | PASS. 94 tests passed. |
| `flutter build web` | PASS. Built `build/web`. Existing warnings remain for `image-4.3.0` Wasm dry-run checks and CupertinoIcons font discovery. |
| Browser render check | PASS. Admin Settings and Delivery Settlement rendered from `build/web`; QC render was checked after the QC phase. |

## Contract Tests Added Or Extended

- `test/pos_primary_job_contract_test.dart`
- `test/waiter_floor_layout_contract_test.dart`
- `test/cashier_waiter_workspace_i18n_contract_test.dart`
- `test/kitchen_operational_attention_contract_test.dart`
- `test/admin_table_selection_contract_test.dart`
- `test/menu_admin_ui_contract_test.dart`
- `test/inventory_admin_ui_contract_test.dart`
- `test/reports_admin_ui_contract_test.dart`
- `test/attendance_admin_ui_contract_test.dart`
- `test/staff_admin_ui_contract_test.dart`
- `test/einvoice_admin_ui_contract_test.dart`
- `test/qc_admin_ui_contract_test.dart`
- `test/settings_admin_ui_contract_test.dart`
- `test/delivery_settlement_attention_contract_test.dart`
- `test/legacy_ui_compatibility_budget_test.dart`

## Remaining Risk

| Risk | Status | Handling |
|---|---|---|
| Real Supabase seed data may expose empty queues or load errors during local render. | LOW | UI shows operational empty/error states; backend was not changed. |
| Some secondary detail still lives inside expanded panels rather than separate routes. | ACCEPTED | This matches the primary-job rule because secondary detail is not default-visible. |
| Full production visual QA on tablet/macOS hardware remains manual. | LOW | Web build and browser render passed; touch target/layout standards are captured in the Toast-style UX standard. |

## Closure Decision

Phase 0 through Phase 5 are closed for the POS primary-job UI refactor scope.
The work is ready for final human review, commit staging, and any product-owner
visual pass on real devices.
