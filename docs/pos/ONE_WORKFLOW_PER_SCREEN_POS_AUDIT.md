# One Workflow Per Screen POS Audit

Date: 2026-05-15
Scope: Flutter UI structure under `lib/` only
Rule: no backend, schema, Supabase, RPC, RLS, auth, permission, provider/state, order, payment, kitchen, cashier, waiter, or runtime contract change is proposed here.

## Audit Standard

The audit uses this operating principle:

> Page = Work Step, not Page = Feature.

Fixed interpretation:

- "One Workflow Per Screen" means one primary job / 업무 목적 per screen.
- It does not mean one feature or one button per screen.
- Supporting actions required to complete that primary job may remain on the same screen.
- Secondary detail should be hidden until needed.
- Separate workflows are the only items that must move to another screen.

Each POS screen should let the operator understand the primary job within 3 seconds. Default visible information should be only what is needed to complete that job. Secondary detail, logs, historical data, configuration, raw IDs, and audit traces should move to drawer, expand, modal, or a dedicated back-office screen. A live operator screen should expose at most two dominant primary actions at one moment, while supporting actions can remain available in controlled areas if they directly complete the same primary job.

Required screen classification format:

- Primary Job:
- Supporting Actions:
- Secondary Detail:
- Separate Workflows currently mixed in:
- Should remain on same screen:
- Should move to separate screen:

## High-Level Findings

1. `OrderWorkspace` is the largest cross-role mixing point. It can support order taking, order review, sent-item editing, kitchen status cycling, table transfer, cancellation, and payment depending on caller.
2. `Admin Tables` is the clearest role-boundary violation. It combines table layout administration with waiter order creation, kitchen item status changes, payment execution, and order cancellation.
3. `CashierScreen` is generally payment-first. Payment method selection, discount/coupon, menu cancellation, quantity adjustment, split payment, receipt printing, failed payment retry, and proof attachment are supporting actions for the primary job "complete payment" and can remain together. Daily closing, sales reports, staff settlement, refund approval management, menu settings, inventory analysis, and operational exception monitoring must move out.
4. `KitchenScreen` is close to a queue-first KDS, but ticket cards expose queue state, item detail, and execution mechanics in the same card.
5. `InventoryTab` is a giant back-office application inside one tab: ingredient catalog, recipe mapping, receiving, waste, count, purchase recommendation, purchase orders, receiving confirmation, reports, and runtime diagnostics.
6. `ReportsTab` mixes report consumption, operational exception monitoring, quick date navigation, export, and daily closing code paths.
7. `StaffTab` and `AttendanceTab` combine directory/review/payroll/permission workflows that should be separate manager/admin work steps.
8. Several admin screens read like dense data viewers rather than action-first Toast-style operating screens.

## Role: Waiter

### `/waiter` - Waiter Screen

Files:
- `lib/features/waiter/waiter_screen.dart`
- `lib/widgets/order_workspace.dart`
- `lib/features/table/floor_layout.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Table status scanning, table selection, guest count, active order loading, order panel display. |
| Mixed Workflows | Table selection and order taking are mostly separated visually, but the selected table immediately opens the generic `OrderWorkspace`, where order creation, review, sent item correction, cancellation, and send-to-kitchen are present together. |
| Role Boundary Issue | Waiter-specific surface is acceptable, but the shared `OrderWorkspace` also supports cashier and admin behaviors. The waiter screen inherits a component whose mental model is broader than waiter work. |
| Operator Confusion | On wide layouts the table grid and order editor are both primary. The operator may not know whether the current step is table selection, menu entry, order review, or sending. |
| Information Overload | KPI cards for total, occupied, available, and selected table appear before the action surface. These are useful, but they compete with the immediate question: which table needs service now? |
| Action Overload | Within the order workspace, the operator may see add item, increment, decrement, edit sent item, cancel sent item, transfer table, cancel order, send to kitchen, and status controls depending state. |
| Detail Overexposure | Sent kitchen items, pending cart items, order total, table transfer, cancellation, and possible item status operations appear in the same panel. |
| Visual Hierarchy Problem | The table grid is strong, but the order panel becomes a multi-purpose console once selected. Primary action is not always the only dominant action. |
| Recommended Split | Split into `Table Selection`, `Order Taking`, and `Order Review / Send`. Keep sent kitchen status in a compact read-only strip or drawer, not inside the default taking surface. |

### `OrderWorkspace` - Shared Order Console

Files:
- `lib/widgets/order_workspace.dart`
- Callers include `waiter_screen.dart` and `admin/tabs/tables_tab.dart`.

| Field | Audit |
|---|---|
| Current Screen Purpose | Reusable menu browser plus current order panel. |
| Mixed Workflows | Menu browsing, cart creation, sent item review, sent item cancellation, sent item quantity editing, table transfer, order cancellation, send-to-kitchen, payment method selection, and payment execution. |
| Role Boundary Issue | Waiter, cashier, kitchen, and admin concerns are exposed through one component API. `canManageSentItems` and `showPaymentActions` turn the same UI into different role tools. |
| Operator Confusion | The same visual pattern can mean "take order", "fix an order", "manage kitchen item status", or "pay order" depending entry point. |
| Information Overload | Menu grid, categories, cart lines, sent lines, totals, offline state, order metadata, and action zones compete in one panel. |
| Action Overload | More than two meaningful actions can be visible: send, cancel, transfer, payment, item edit, item cancel, item status change. |
| Detail Overexposure | Sent items and pending cart items are both first-level content. Operational detail that belongs in review/edit is visible during order taking. |
| Visual Hierarchy Problem | The cart and sent items can have similar weight, so "what can I do now?" is not obvious. |
| Recommended Split | Extract `OrderTakingWorkspace`, `OrderReviewPanel`, `SentItemReadOnlySummary`, `OrderExceptionDrawer`, and `PaymentExecutionPanel`. Keep the provider contracts unchanged. |

## Role: Cashier

### `/cashier` - Cashier Screen

Files:
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/cashier/payment_proof_modal.dart`
- `lib/features/cashier/red_invoice_modal.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Show payable orders, select order, run payment, print receipt, collect proof, optionally collect red invoice details, show daily summary. |
| Mixed Workflows | Payment queue and payment execution are valid cashier work. Receipt handling, proof attachment, red invoice request/capture, reprint, retry, discount/coupon, quantity adjustment, split payment, and menu cancellation can be supporting actions if they complete the same payment. Cashier daily summary, staff settlement, refund approval management, sales report, and operational monitoring are separate workflows. |
| Role Boundary Issue | Cashier screen includes manager-like daily summary and admin-only service/cancel flows. These are valid permissions but should not dominate the cashier default moment. |
| Operator Confusion | The selected order view is payment-first, but after payment the user may enter proof and e-invoice flows before the payment task feels complete. |
| Information Overload | Empty state shows multiple KPI cards. Selected state shows order lines, payment rail, method tiles, proof/offline messaging, receipt/reprint and admin actions. |
| Action Overload | The issue is not that payment supporting actions exist; the issue is when non-payment workflows such as daily summary, reporting, settlement, and approval management share the same visual priority. |
| Detail Overexposure | Proof/red invoice detail is acceptable when required for payment completion, but raw tax portal diagnostics and long audit detail should remain secondary. |
| Visual Hierarchy Problem | Payment amount should remain dominant; supporting actions should be grouped below it without competing as separate primary jobs. |
| Recommended Split | Keep payment-completion supporting actions inside `Payment Execution`. Move only unresolved follow-up queues, refund approval management, daily closing, reports, staff settlement, and operational monitoring to separate screens. Keep payment mutation path unchanged. |

### Payment Proof Modal

File:
- `lib/features/cashier/payment_proof_modal.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Capture or save payment proof photo as part of completing card/pay payment. |
| Mixed Workflows | Proof capture is not a separate workflow when required for payment completion. Only unresolved/missing proof after checkout becomes follow-up/exception work. |
| Role Boundary Issue | Cashier proof capture is valid. Manager follow-up is only needed for missing, failed, or overdue proof. |
| Operator Confusion | "Skip for now", "Capture/Retake", and "Save Proof" all compete immediately after checkout. |
| Information Overload | Descriptive guidance text is useful for policy but slows a fast checkout surface. |
| Action Overload | Three actions are visible in a modal after an already completed payment. |
| Detail Overexposure | Proof policy text should be secondary or standardized. |
| Visual Hierarchy Problem | It reads like an operational policy form rather than a fast cashier checkpoint. |
| Recommended Split | Keep required proof capture in Payment Execution. Move only missing/failed/deferred proof cases to a `Proof Follow-up Queue`. |

### Red Invoice Modal

File:
- `lib/features/cashier/red_invoice_modal.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Ask if red invoice is needed and collect tax company details. |
| Mixed Workflows | Red invoice request/capture can support payment completion when needed by the guest. Portal failure, correction, cancellation, or unresolved issuance becomes separate exception work. |
| Role Boundary Issue | Cashier can collect required payment evidence. Manager/admin owns unresolved tax portal exceptions and approvals. |
| Operator Confusion | The payment task shifts into tax identity data entry. |
| Information Overload | Tax code, lookup, company name, address, email, cc, validation and submission are high-density form work. |
| Action Overload | Yes/no, lookup, back, submit, error handling. |
| Detail Overexposure | Tax detail should not be visible unless red invoice is requested. |
| Visual Hierarchy Problem | The modal forces a back-office quality form into a checkout moment. |
| Recommended Split | Keep red invoice request/capture with Payment Execution when it is part of checkout. Move only unresolved portal failures, corrections, cancellations, and diagnostics to E-Invoice exception handling. |

### `/payments/:paymentId` - Payment Detail

File:
- `lib/features/payment/payment_detail_screen.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Read-only payment, order, e-invoice, proof, and portal status snapshot. |
| Mixed Workflows | Payment audit, evidence review, portal diagnostics, and exception review appear together. |
| Role Boundary Issue | Cashier may only need receipt/proof state; manager/admin needs full exception and raw IDs. |
| Operator Confusion | It is unclear whether this is a cashier follow-up screen, audit detail, or manager exception screen. |
| Information Overload | Payment summary, order summary, e-invoice summary, proof summary, job IDs, CQT status, portal IDs, timestamps. |
| Action Overload | Few mutation actions, but many detail sections create cognitive action load. |
| Detail Overexposure | Raw IDs, tax portal metadata, and proof URL are first-level details. |
| Visual Hierarchy Problem | Signal cards help, but below them the page becomes a DB-like evidence view. |
| Recommended Split | Make default view a `Payment Follow-up Detail`; move raw e-invoice/proof diagnostics to expandable manager/admin sections. |

## Role: Kitchen

### `/kitchen` - Kitchen Screen

File:
- `lib/features/kitchen/kitchen_screen.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | KDS queue with New Orders, Cooking, and Complete/Ready lanes. |
| Mixed Workflows | Queue scanning, order detail reading, item-level execution, readiness handoff, and delay detection are mixed in each card. |
| Role Boundary Issue | Mostly kitchen-only. However, status cycling by tapping item rows is an execution workflow embedded in queue browsing. |
| Operator Confusion | The screen hints that tapping items advances status, but there is no single explicit primary action per ticket. |
| Information Overload | KPI cards, three lanes, ticket headers, item lists, modifiers/notes, elapsed time, summary status, priority colors. |
| Action Overload | Every item row can be an action. A busy ticket can expose many hidden primary actions. |
| Detail Overexposure | Full item detail is visible in the queue card instead of a selected execution panel. |
| Visual Hierarchy Problem | Lane status is clear, but action hierarchy inside cards is less clear than a Toast-style queue-first KDS. |
| Recommended Split | Keep `Kitchen Queue` as lane/list scanning. Open `Kitchen Execution` drawer/panel for selected ticket item progression. Add separate delayed/attention queue. |

## Role: Admin

### `/admin` - Admin Shell

File:
- `lib/features/admin/admin_screen.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Role-based admin navigation across operations, back office, exceptions, and settings. |
| Mixed Workflows | Live operations, configuration, reports, attendance, inventory, QC, delivery settlement, and e-invoice exceptions live under one shell. |
| Role Boundary Issue | Admin shell includes waiter/cashier-like operational tabs through `TablesTab` and manager exception tabs. |
| Operator Confusion | Sidebar groups help, but the top-level model is still "feature tabs" rather than "work steps". |
| Information Overload | Mobile bottom navigation can expose many admin tabs at once. |
| Action Overload | Action overload is delegated to child tabs. |
| Detail Overexposure | Child tabs expose raw operational, report, and configuration detail. |
| Visual Hierarchy Problem | Group labels are useful, but live operation and back-office work have similar visual weight. |
| Recommended Split | Keep shell, but regroup by role-first work mode: `Live Operations`, `Configuration`, `Monitoring`, `Reports`, `Exceptions`. Hide work-step screens behind focused entries. |

### Admin Tables Tab

File:
- `lib/features/admin/tabs/tables_tab.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Table management, floor layout operation/editing, selected table order workspace, and payment from admin. |
| Mixed Workflows | Table layout admin, table status monitoring, order taking, sent item kitchen status update, payment execution, table transfer, order cancel, audit trace. |
| Role Boundary Issue | Severe. Waiter, kitchen, cashier, and admin work are all reachable from one admin tab. |
| Operator Confusion | The same tab can mean "edit floor map", "serve table", "change kitchen item status", or "collect payment". |
| Information Overload | KPI cards, filters, grid/list switch, operation/edit mode, add table, save/reset layout, delete table, audit trace, order workspace. |
| Action Overload | Many primary-level controls are visible before selecting any single work step. |
| Detail Overexposure | Order detail and admin layout detail share the same first-level surface. |
| Visual Hierarchy Problem | Configuration controls and live operations have comparable weight. |
| Recommended Split | Split into `Table Layout Configuration`, `Table Operations Monitor`, and route table order work to the waiter order flow. Remove kitchen/payment execution from admin default UI while preserving existing callbacks behind role-appropriate screens. |

### Menu Tab

File:
- `lib/features/admin/tabs/menu_tab.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Category and menu item management with item availability switch. |
| Mixed Workflows | Menu configuration and live availability/sold-out control are mixed. Decorative surface tabs suggest options/menu groups but the visible work remains category/item management. |
| Role Boundary Issue | Admin configuration and manager live availability operations can be separated. |
| Operator Confusion | Availability toggle is operational; add/edit category/item is configuration. They answer different questions. |
| Information Overload | KPI cards, category list, item list, availability switch, edit/add actions, audit trace. |
| Action Overload | Add category, add item, edit item, toggle availability, possible future surface tabs. |
| Detail Overexposure | Configuration and operating availability are equally exposed. |
| Visual Hierarchy Problem | Category and item panes are good, but live availability lacks a dedicated fast-scanning board. |
| Recommended Split | Keep `Menu Configuration`; add or separate `Menu Availability Board` for sold-out and quick operational toggles. |

### Staff Tab

File:
- `lib/features/admin/tabs/staff_tab.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Staff directory, status, attendance preview, permission change, activation/deactivation, add staff. |
| Mixed Workflows | Directory management, permission review, attendance review, account activation, and staff creation. |
| Role Boundary Issue | Admin config and manager people-operations review are mixed. |
| Operator Confusion | Selecting a staff member can lead to permission, attendance, status, or profile work. |
| Information Overload | KPIs, filters, directory list, detail metrics, quick actions, today's attendance logs. |
| Action Overload | Change permission, view attendance, activate/deactivate, add staff. |
| Detail Overexposure | Attendance logs are visible inside the staff detail context. |
| Visual Hierarchy Problem | Directory and review actions have similar emphasis. |
| Recommended Split | Split into `Staff Directory`, `Permission Review`, and `Attendance Review` entry points. |

### Attendance Tab

File:
- `lib/features/admin/tabs/attendance_tab.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Attendance logs, staff/date filters, payroll preview/export. |
| Mixed Workflows | Attendance monitoring and payroll processing are mixed. |
| Role Boundary Issue | Manager payroll review is more sensitive than routine attendance review. |
| Operator Confusion | A user reviewing attendance can also unlock/run payroll from the same screen. |
| Information Overload | Date filters, staff filter, search, KPI cards, attendance table, payroll summary, kiosk/photo/payroll status cards. |
| Action Overload | Payroll preview, download, unlock PIN, date changes, filters, row review. |
| Detail Overexposure | Payroll state is first-level while the user may only need attendance exceptions. |
| Visual Hierarchy Problem | Attendance table and payroll panel compete as primary. |
| Recommended Split | Split into `Attendance Exception Review` and `Payroll Preview / Export`. |

### Inventory Tab

File:
- `lib/features/admin/tabs/inventory_tab.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Ingredient management, recipe management, physical count, inventory report, purchase recommendations, purchase orders, receiving, transaction history. |
| Mixed Workflows | Catalog config, recipe config, stock receiving, waste/disposal, physical count execution, report review, purchase recommendation generation, PO creation, receipt confirmation, supplier/provenance diagnostics. |
| Role Boundary Issue | Admin configuration, manager purchasing, and operator stock execution are all in one tab. |
| Operator Confusion | The tab can mean "edit an ingredient", "count stock", "run purchase recommendations", "receive goods", or "read inventory report". |
| Information Overload | Multiple tab surfaces, KPI cards, many sections, recommendation snapshots, purchase orders, detail panels, readiness/blocker/runtime diagnostics. |
| Action Overload | Add ingredient, edit, receiving, disposal, add recipe, start count, save count line, generate recommendation, create PO, confirm receipt. |
| Detail Overexposure | Runtime readiness, blockers, provenance, supplier history, receipt visibility, and purchase detail are default-level report content. |
| Visual Hierarchy Problem | Everything reads important. The screen is closer to a full ERP module than a Toast-style POS work step. |
| Recommended Split | Split into `Ingredient Catalog`, `Recipe Configuration`, `Stock Count`, `Stock Movement`, `Purchase Queue`, `Receiving Execution`, and `Inventory Reports`. |

### QC Tab

File:
- `lib/features/admin/tabs/qc_tab.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | QC surface, template management, weekly review, follow-up tracking. |
| Mixed Workflows | QC dashboard, template configuration, inspection review, image/cell detail review, follow-up exception resolution. |
| Role Boundary Issue | Admin template config and manager operational follow-up are mixed. |
| Operator Confusion | Tabs help, but all QC work lives as one feature page rather than one work step per screen. |
| Information Overload | Weekly grids, dialogs, follow-up cards, template reorder/edit, analytics and filters. |
| Action Overload | Add/edit templates, reorder, cell detail, image detail, follow-up status updates, filters. |
| Detail Overexposure | Inspection cell/image detail and follow-up detail can be too close to the default list. |
| Visual Hierarchy Problem | The tab structure is feature-first. Queue urgency is not the dominant entry. |
| Recommended Split | Split into `QC Template Configuration`, `Weekly QC Review`, and `QC Follow-up Exceptions`. |

### Settings Tab

File:
- `lib/features/admin/tabs/settings_tab.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Store settings, profile/permission naming, payment/payroll PIN, receipt printer, system/audit/logout. |
| Mixed Workflows | Store configuration, permission profile edit, payment protection, receipt hardware, audit trace, logout. |
| Role Boundary Issue | Admin config and system/audit operations mix with user session action. |
| Operator Confusion | Category list is clear, but "payment" contains payroll PIN and may not match cashier payment language. |
| Information Overload | KPIs plus several unrelated configuration categories. |
| Action Overload | Save/reset store, save profile, change/delete PIN, printer test, test print, logout. |
| Detail Overexposure | Audit trace/system state should be secondary. |
| Visual Hierarchy Problem | Configuration and operational diagnostics share the same shell. |
| Recommended Split | Keep as admin configuration, but reduce default KPIs and move audit/system diagnostics to secondary detail. |

## Role: Manager

### Reports Tab

File:
- `lib/features/admin/tabs/reports_tab.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Revenue reports, date range analysis, operational signals, export, quick ranges, daily sales table, daily closing code path. |
| Mixed Workflows | Reports, operational exception monitoring, proof/e-invoice/WT08 readiness, export, quick date navigation, daily closing. |
| Role Boundary Issue | Manager reporting, cashier evidence follow-up, and closing operations are mixed. |
| Operator Confusion | A manager opening reports may see urgent operational exceptions and closing-oriented signals in the same analysis view. |
| Information Overload | KPI cards, insight tiles, split content, hourly graph, breakdowns, exception section, daily table, quick ranges. |
| Action Overload | Date range, lookup, download, quick ranges, follow-up cues, close-today code path. |
| Detail Overexposure | Operational exceptions are first-level in a report surface rather than an exception queue. |
| Visual Hierarchy Problem | Historical analytics and immediate action signals compete. |
| Recommended Split | Split into `Reports`, `Operational Monitoring`, and `Daily Closing`. |

### E-Invoice Tab

File:
- `lib/features/admin/tabs/einvoice_tab.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | E-invoice issue queue, status filters, selected issue detail, retry/open portal/mark resolved actions. |
| Mixed Workflows | Exception queue, issue execution, portal diagnostics, raw reference handling. |
| Role Boundary Issue | Manager/admin exception handling is appropriate, but cashier payment detail can overlap with it. |
| Operator Confusion | Queue and raw diagnostic detail are both first-level; the next action is not always the only dominant action. |
| Information Overload | Queue list, status filters, KPIs, amount cards, rows of metadata, raw ref/status, portal action. |
| Action Overload | Process issue, retry, open tax portal, mark resolved, copy ref, download. |
| Detail Overexposure | Raw ref IDs and portal metadata should be hidden until needed. |
| Visual Hierarchy Problem | Exception urgency is good, but execution actions need clearer priority. |
| Recommended Split | Keep as `E-Invoice Exception Queue`; move raw diagnostics to drawer and expose one primary action based on status. |

### Delivery Settlement Tab

File:
- `lib/features/delivery/screens/delivery_settlement_tab.dart`

| Field | Audit |
|---|---|
| Current Screen Purpose | Delivery settlement attention, unsettled revenue, aggregate summary, settlement list/detail, confirm received. |
| Mixed Workflows | Settlement queue, aggregate reporting, dispute attention, confirmation execution, history detail. |
| Role Boundary Issue | Manager settlement execution and report-style summary are mixed. |
| Operator Confusion | The screen can mean "what is at risk?", "which statement needs action?", or "what is our aggregate delivery settlement trend?". |
| Information Overload | Attention banner, summary cards, filter chips, unsettled card, aggregate summary, expansion tiles, details. |
| Action Overload | Filter, inspect expansion, confirm received, review dispute, read aggregate metrics. |
| Detail Overexposure | Settlement metrics and detail are visible before the operator selects a single settlement task. |
| Visual Hierarchy Problem | Queue and report summary compete. |
| Recommended Split | Split into `Delivery Settlement Queue` and `Delivery Settlement Report`. |

## Cross-Cutting Violations

| Violation | Evidence |
|---|---|
| Order creation and order status checking are mixed | `OrderWorkspace` shows new cart and sent kitchen items together. |
| Payment execution and settlement/reporting are mixed | `CashierScreen` includes daily summary; `ReportsTab` contains payment/evidence exceptions and closing code path. |
| Kitchen queue and detail are mixed | `KitchenScreen` ticket cards show full item lists and use item rows as status actions. |
| Admin screen resembles DB/control surface | `InventoryTab`, `ReportsTab`, `PaymentDetailScreen`, and `Admin TablesTab` expose raw operational details, logs, diagnostics, IDs, and many actions. |
| Primary actions exceed two | `OrderWorkspace`, `Admin TablesTab`, `InventoryTab`, `CashierScreen`, `EInvoiceTab`, and `DeliverySettlementTab`. |
| Role-first navigation is incomplete | Admin can reach waiter/cashier/kitchen actions through `TablesTab`; cashier can access manager-like daily summary; reports includes exception follow-up. |

## Recommended First Split Candidates

1. `Admin TablesTab` because it crosses all live POS roles in one admin tab.
2. `OrderWorkspace` because it is reused as a multi-role work console.
3. `CashierScreen` because checkout speed depends on keeping payment-completion supporting actions together while removing daily summary/reporting/approval workflows.
4. `KitchenScreen` because queue scanning and item execution should be visually separated.
5. `InventoryTab` because it is the largest admin/back-office overload surface.

## Primary Job Contract

The detailed per-screen contract table is maintained in `docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md`. That document is now the governing classification for:

- Primary Job
- Supporting Actions
- Secondary Detail
- Separate Workflows currently mixed in
- Should remain on same screen
- Should move to separate screen
