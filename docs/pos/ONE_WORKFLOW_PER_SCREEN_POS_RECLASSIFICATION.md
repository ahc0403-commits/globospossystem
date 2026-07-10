# One Workflow Per Screen POS Reclassification

Date: 2026-05-15
Scope: UI/work-step reclassification only. Existing POS logic, provider contracts, order/payment/kitchen workflows, Supabase, RPC, RLS, auth, and permissions remain untouched.

## Reclassification Rule

Existing screens are reclassified from feature pages into operator work steps:

- Table Selection
- Order Taking
- Order Review
- Kitchen Queue
- Kitchen Execution
- Payment Queue
- Payment Execution
- Refund / Void / Exception
- Daily Closing
- Admin Configuration
- Operational Monitoring
- Reports

Fixed interpretation:

- A work step is defined by one primary job, not by one isolated feature.
- Supporting actions that are necessary to complete the primary job remain on the same screen.
- Secondary detail is disclosed on demand.
- Separate workflows are moved only when they answer a different primary job.

Required classification for every screen:

- Primary Job
- Supporting Actions
- Secondary Detail
- Separate Workflows currently mixed in
- Should remain on same screen
- Should move to separate screen

Decision values:

- 유지: current screen can remain as the main work step with minor hierarchy reduction.
- 분리: screen contains multiple work steps and should be split.
- 통합: screen should become part of another work-step screen.
- 축소: screen should remain but hide secondary detail/actions by default.

## Current Screen Reclassification

| Existing Screen / File | Current Contents | Target Work Step(s) | Decision | Notes |
|---|---|---|---|---|
| `/waiter` - `lib/features/waiter/waiter_screen.dart` | Table grid, selected table, guest count, active order panel. | Table Selection, Order Taking, Order Review | 분리 | Keep route as waiter home if desired, but visually separate table choice from order-taking and review/send. |
| `OrderWorkspace` - `lib/widgets/order_workspace.dart` | Menu browse, cart, sent items, edit/cancel, send, transfer, payment options when enabled. | Order Taking, Order Review, Payment Execution, Refund / Void / Exception | 분리 | Shared component should become smaller role-specific compositions. Payment and kitchen-status controls should not be default waiter/admin content. |
| `/kitchen` - `lib/features/kitchen/kitchen_screen.dart` | KDS lanes, ticket cards, item rows, tap-to-advance statuses, delay signals. | Kitchen Queue, Kitchen Execution, Operational Monitoring | 분리 | Keep queue lanes. Move selected ticket execution to side panel/drawer. Make delayed orders an attention queue rather than implicit card color only. |
| `/cashier` - `lib/features/cashier/cashier_screen.dart` | Payable order list, selected order detail, payment method, payment run, discounts/coupons, cancellation/quantity adjustment when used to complete payment, split payment, receipt, proof, red invoice, daily summary. | Payment Queue, Payment Execution, Refund / Void / Exception, Daily Closing, Operational Monitoring | 분리 | Payment-completion supporting actions remain in Payment Execution. Move daily summary, staff settlement, refund approval management, reports, and operational monitoring out. |
| `PaymentProofModal` - `lib/features/cashier/payment_proof_modal.dart` | Proof capture, skip/defer, save. | Payment Execution, Refund / Void / Exception | 축소 | Required proof capture remains a Payment Execution supporting action. Missing/failed/deferred proof becomes follow-up/exception queue work. |
| `RedInvoiceModal` - `lib/features/cashier/red_invoice_modal.dart` | Red invoice choice and tax identity form. | Payment Execution, Refund / Void / Exception | 축소 | Guest-requested red invoice capture can remain in checkout. Portal failures, corrections, cancellations, and diagnostics move to e-invoice exception handling. |
| `/payments/:paymentId` - `lib/features/payment/payment_detail_screen.dart` | Payment, order, e-invoice, proof, raw IDs, portal status. | Refund / Void / Exception, Operational Monitoring | 축소 | Keep as read-only exception/evidence detail. Default should show status and next action, not raw diagnostics. |
| `/admin` shell - `lib/features/admin/admin_screen.dart` | Tables, Menu, Staff, Reports, Attendance, Inventory, QC, Settings, Delivery Settlement, E-Invoice. | Admin Configuration, Operational Monitoring, Reports, Refund / Void / Exception | 유지 | Shell can stay, but navigation should be role/work-step-first instead of feature-first. |
| `TablesTab` - `lib/features/admin/tabs/tables_tab.dart` | Table grid/list, layout edit, add/delete/save layout, selected table order workspace, payment, kitchen status, transfer/cancel. | Table Selection, Order Taking, Order Review, Payment Execution, Kitchen Execution, Admin Configuration | 분리 | Highest severity. Split table layout configuration from live table monitor. Route order/payment/kitchen actions to role-appropriate screens. |
| `MenuTab` - `lib/features/admin/tabs/menu_tab.dart` | Category management, item management, item availability toggle. | Admin Configuration, Operational Monitoring | 분리 | Keep menu/category CRUD as configuration. Create a manager availability board for sold-out/available toggles. |
| `StaffTab` - `lib/features/admin/tabs/staff_tab.dart` | Staff directory, staff detail, attendance preview, permission change, active/deactive, add staff. | Admin Configuration, Operational Monitoring | 분리 | Split staff directory/profile work from permission review and attendance review. |
| `AttendanceTab` - `lib/features/admin/tabs/attendance_tab.dart` | Attendance logs, date/staff filters, payroll preview/export, payroll unlock. | Operational Monitoring, Daily Closing, Reports | 분리 | Attendance exception review and payroll preview/export are separate manager work steps. |
| `InventoryTab` - `lib/features/admin/tabs/inventory_tab.dart` | Ingredient catalog, recipe mapping, receiving/disposal, physical count, inventory report, purchase recommendation, PO creation, receipt confirmation. | Admin Configuration, Operational Monitoring, Reports, Refund / Void / Exception | 분리 | Break into catalog/config, count execution, movement execution, purchasing queue, receiving execution, and inventory reports. |
| `QcTab` - `lib/features/admin/tabs/qc_tab.dart` | QC surface, template management, weekly view, follow-up. | Admin Configuration, Operational Monitoring, Reports, Refund / Void / Exception | 분리 | Template config, weekly review, and follow-up exception handling should become separate screens. |
| `SettingsTab` - `lib/features/admin/tabs/settings_tab.dart` | Store config, permission profile name, payroll PIN, receipt printer, audit/system/logout. | Admin Configuration | 축소 | Keep as admin configuration. Move audit/system diagnostics and logout away from primary settings hierarchy. |
| `ReportsTab` - `lib/features/admin/tabs/reports_tab.dart` | Revenue KPIs, hourly chart, breakdowns, exception signals, export, quick ranges, daily table, daily closing code path. | Reports, Operational Monitoring, Daily Closing | 분리 | Reports should analyze history. Exceptions and daily closing should be separate manager work steps. |
| `EInvoiceTab` - `lib/features/admin/tabs/einvoice_tab.dart` | E-invoice queue, filters, selected issue detail, retry/process/open portal/resolve/copy. | Refund / Void / Exception, Operational Monitoring | 축소 | Keep as exception queue. Hide raw diagnostics. One status-derived primary action should dominate. |
| `DeliverySettlementTab` - `lib/features/delivery/screens/delivery_settlement_tab.dart` | Settlement attention, unsettled revenue, aggregate summary, settlement list/detail, confirm received. | Daily Closing, Operational Monitoring, Reports | 분리 | Split settlement execution queue from aggregate settlement report. |

## Target Work Step Mapping

### Table Selection

Current sources:
- `waiter_screen.dart`
- `tables_tab.dart`
- `floor_layout.dart`

Decision:
- Waiter table selection: 유지 with reduced KPIs and stronger service-state grouping.
- Admin table layout: 분리 to configuration.
- Admin live table operations: 축소 to monitor only.

### Order Taking

Current sources:
- `order_workspace.dart`
- `waiter_screen.dart`
- `tables_tab.dart`

Decision:
- 분리. Build a waiter-only order taking screen with menu/category/cart only.
- Sent items should show as a read-only compact strip unless editing is explicitly opened.

### Order Review

Current sources:
- `order_workspace.dart`

Decision:
- 분리. The review/send step should answer: "Is this order ready to send to kitchen?"
- Primary actions: Send to Kitchen, Back to Edit.

### Kitchen Queue

Current sources:
- `kitchen_screen.dart`

Decision:
- 유지 with structure refinement. Keep New / Cooking / Ready lanes.
- Move detailed item progression to Kitchen Execution.

### Kitchen Execution

Current sources:
- `kitchen_screen.dart`
- `order_workspace.dart` when `canManageSentItems` is enabled.

Decision:
- 분리. Kitchen should own item progression. Admin/order surfaces should not show kitchen status controls by default.

### Payment Queue

Current sources:
- `cashier_screen.dart`
- `tables_tab.dart` when payment actions are enabled.

Decision:
- 유지 for cashier, remove from admin default.
- Queue should show only payable orders and urgency signals.

### Payment Execution

Current sources:
- `cashier_screen.dart`
- `order_workspace.dart` when `showPaymentActions` is enabled.

Decision:
- 분리 from non-payment workflows, not from payment-completion supporting actions.
- Payment method, discount/coupon, item cancellation, quantity adjustment, split payment, receipt printing, failed payment retry, and proof attachment can remain in this step when they directly complete payment.
- Daily closing, sales reports, staff settlement, refund approval management, menu settings, inventory analysis, and operational exception monitoring must not live in Payment Execution.

### Refund / Void / Exception

Current sources:
- `cashier_screen.dart`
- `payment_detail_screen.dart`
- `einvoice_tab.dart`
- `reports_tab.dart`
- `delivery_settlement_tab.dart`
- `inventory_tab.dart`

Decision:
- 분리. Exceptions need their own queues: payment exception, proof missing, e-invoice failed, delivery settlement issue, inventory receiving blockers.

### Daily Closing

Current sources:
- `reports_tab.dart`
- `cashier_screen.dart` daily summary
- `attendance_tab.dart` payroll preview/export
- `delivery_settlement_tab.dart`

Decision:
- 분리. Daily close should be a manager screen that consumes summary status from payment/proof/e-invoice/stock/staff but does not become a report dashboard.

### Admin Configuration

Current sources:
- `admin_screen.dart`
- `tables_tab.dart`
- `menu_tab.dart`
- `staff_tab.dart`
- `settings_tab.dart`
- `inventory_tab.dart`
- `qc_tab.dart`

Decision:
- 유지 shell, split child pages.
- Configuration should be low-frequency, form/list-detail oriented, and separate from live execution.

### Operational Monitoring

Current sources:
- `reports_tab.dart`
- `inventory_tab.dart`
- `attendance_tab.dart`
- `staff_tab.dart`
- `einvoice_tab.dart`
- `delivery_settlement_tab.dart`
- `kitchen_screen.dart`

Decision:
- 통합 conceptually into manager monitoring queues. Do not place every signal inside reports.

### Reports

Current sources:
- `reports_tab.dart`
- `inventory_tab.dart`
- `delivery_settlement_tab.dart`
- `attendance_tab.dart`

Decision:
- 축소 and specialize. Reports should answer historical/performance questions, not execute live fixes.

## Role-Based Reclassification Summary

| Role | Primary Work Steps | Screens to Keep | Screens to Split |
|---|---|---|---|
| Waiter | Table Selection, Order Taking, Order Review | Waiter home route | `OrderWorkspace` into taking/review/detail |
| Cashier | Payment Queue, Payment Execution, Payment Follow-up / Exception | Cashier route skeleton | Daily summary, staff settlement, refund approval management, reports, operational monitoring. Keep payment method, discount/coupon, item cancel, quantity adjust, split payment, receipt, retry, and proof attachment in Payment Execution. |
| Kitchen | Kitchen Queue, Kitchen Execution | Kitchen route lanes | Ticket card detail/execution, delayed-order queue |
| Admin | Admin Configuration | Admin shell | Tables, Menu, Staff, Attendance, Inventory, QC, Settings detail |
| Manager | Operational Monitoring, Reports, Daily Closing, Exceptions | E-invoice queue concept | Reports, delivery settlement, payment detail, inventory purchasing/receiving, attendance/payroll |

## Non-Goals

This reclassification does not request changes to:

- Database schema
- Supabase tables, functions, storage, or policies
- RPC signatures
- RLS
- Auth or permission model
- Provider/state contracts
- Order, payment, kitchen, cashier, or waiter business flows
- Backend mutations
- Runtime contract

The intended implementation path is UI composition and navigation restructuring around existing services/providers.
