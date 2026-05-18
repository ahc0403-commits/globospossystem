# One Workflow Per Screen POS Primary Job Contract

Date: 2026-05-15
Scope: UI contract only. No backend, DB schema, Supabase, RPC, RLS, auth, permission, provider/state, payment/order/kitchen workflow, or runtime contract change is allowed.

## Fixed Interpretation

"One Workflow Per Screen" means one primary job / 업무 목적 per screen. It does not mean one feature per screen.

Allowed on the same screen:

- Supporting actions required to complete the primary job
- Small corrections needed before completing the job
- Confirmation, retry, print, attach, search, filter, and select actions when they serve the same job

Must move to a separate screen:

- Work with a different primary job
- Manager/admin approval and review flows not required for the current job
- Reports, closing, settlement, configuration, and monitoring tasks
- Raw diagnostics and audit details that are not needed to act now

Required fields:

- Primary Job
- Supporting Actions
- Secondary Detail
- Separate Workflows currently mixed in
- Should remain on same screen
- Should move to separate screen

## Audit Gates

Every redesigned screen must pass these gates before Phase 5 can be closed.

| Gate | Pass Condition | Fail Example |
|---|---|---|
| Primary Job Gate | The screen has one sentence that explains why the screen exists. | A screen exists for table setup, order entry, payment, and kitchen status at the same time. |
| Supporting Actions Gate | Actions on the screen directly complete the primary job. | Moving receipt/proof out of payment execution when they are required to complete checkout. |
| Separate Workflow Gate | Work with another primary job is moved out of the default surface. | Cashier payment screen shows daily close, sales report, staff settlement, or refund approval management. |
| Secondary Detail Gate | Logs, raw IDs, diagnostics, history, and audit trace are hidden by default. | Payment detail defaults to portal IDs and raw tax metadata before status/next action. |
| Role Boundary Gate | Default screen actions belong to the current operator role. | Admin table configuration exposes normal waiter order taking, cashier payment, or kitchen item progression. |
| 3-Second Operator Gate | A trained operator can identify the current job in 3 seconds. | Dashboard cards and mixed action groups make the next action ambiguous. |
| Action Hierarchy Gate | At most two dominant primary actions are visible; supporting actions are subordinate. | Pay, report, close day, refund approval, and monitoring actions all appear with equal weight. |
| Workflow Safety Gate | Existing backend and workflow contracts remain untouched. | UI split changes RPC, RLS, provider ownership, payment mutation, or order/kitchen status semantics. |

## Contract Table

| Screen / File | Primary Job | Supporting Actions | Secondary Detail | Separate Workflows currently mixed in | Should remain on same screen | Should move to separate screen |
|---|---|---|---|---|---|---|
| Waiter `/waiter`<br>`lib/features/waiter/waiter_screen.dart` | Select or continue service for a table. | Filter/scan tables, select table, enter guest count, open active order, start order. | Table history, full order history, transfer detail, audit trace. | Full order editing can appear immediately after table selection through `OrderWorkspace`. | Table grid, table state, guest prompt, selected-table summary, start/continue order. | Payment execution, kitchen item status control, manager cancellation approval, reports. |
| Waiter Order Taking<br>`lib/widgets/order_workspace.dart` in waiter context | Complete item entry for the selected table. | Browse categories, add item, adjust quantity, remove unsent item, add notes/modifiers, review cart. | Sent kitchen items, previous order history, advanced item detail, audit trace. | Sent item correction, table transfer, order cancellation, and kitchen status can compete with menu/cart entry. | Menu browser, available/sold-out signal, unsent cart, subtotal, review/send entry. | Payment, kitchen execution, admin table layout, manager exception monitoring. |
| Waiter Order Review / Send<br>`lib/widgets/order_workspace.dart` review state | Confirm the order and send it to kitchen. | Review unsent items, edit before send, remove item, confirm notes/modifiers, send to kitchen, offline queue confirmation. | Sent history, cancellation reason, transfer table, audit trace. | If all order management actions remain visible, review becomes a general order console. | Review list, validation warning, send action, back-to-edit action. | Payment, kitchen item execution, daily reports, admin configuration. |
| Shared `OrderWorkspace` component<br>`lib/widgets/order_workspace.dart` | Provide role-specific order workspace composition. | Expose only callbacks required by the current role/context. | Optional sent item summary, exception drawer, debug trace. | Waiter, cashier, kitchen, and admin action sets are all possible through the same component API. | Smaller role-specific compositions: taking, review, payment, read-only summary. | Cross-role default UI, kitchen status control outside kitchen, payment outside cashier/payment job. |
| Cashier Payment Queue<br>`lib/features/cashier/cashier_screen.dart` | Select the next order to pay. | Search/filter payable orders, select order, skip/hold, refresh queue. | Full item list, receipt/proof/e-invoice history, daily totals. | Daily summary and manager-like metrics can compete with payment queue. | Payable order list, amount due, table/order id, readiness status, selected order summary. | Daily closing, sales report, staff settlement, refund approval management, operational monitoring. |
| Cashier Payment Execution<br>`lib/features/cashier/cashier_screen.dart` | Complete payment for the selected order. | Select payment method, apply discount/coupon, cancel menu item before payment, adjust quantity before payment, split payment, print receipt, retry failed payment, attach proof, capture guest-requested red invoice details. | Full tax portal diagnostics, proof history, raw payment IDs, long item history, audit trace. | Daily summary, sales report, staff settlement, refund approval management, menu settings, inventory analysis, operational exception monitoring. | Amount due, payment method, discount/coupon, item correction needed for payment, split payment, receipt, retry, proof attachment, red invoice capture when part of checkout. | Daily closing, sales reports, staff settlement, refund approval queue, unresolved proof queue, e-invoice exception queue, operational monitoring. |
| Payment Proof Modal<br>`lib/features/cashier/payment_proof_modal.dart` | Attach proof required to complete or validate the current payment. | Capture, retake, save, defer/skip when allowed. | Policy explanation, previous proof history, proof storage URL, audit trace. | Missing/failed/deferred proof follow-up after payment. | Required proof capture during checkout. | Missing/deferred proof follow-up queue and manager overdue review. |
| Red Invoice Modal<br>`lib/features/cashier/red_invoice_modal.dart` | Capture guest-requested red invoice information for checkout. | Yes/no request, tax code lookup, company/address/email entry, submit, back. | Portal diagnostics, job IDs, correction/cancellation history, raw tax metadata. | E-invoice failure handling, correction/cancellation lifecycle, manager exception review. | Red invoice request and required guest/company fields when part of checkout. | Failed/stuck e-invoice queue, WeTax portal exception, correction/cancellation management. |
| Payment Detail<br>`lib/features/payment/payment_detail_screen.dart` | Review one payment/evidence/invoice record. | Read status, open linked proof/e-invoice detail, inspect completion state. | Raw IDs, CQT status, portal refs, timestamps, proof URL, job diagnostics. | Manager exception review and cashier receipt/proof follow-up can be blended. | Status-first read-only payment detail and concise evidence status. | Raw diagnostics drawer, exception queue, report/closing context. |
| Kitchen Queue<br>`lib/features/kitchen/kitchen_screen.dart` | Decide which kitchen ticket needs work next. | Scan lanes, open ticket, identify delay, refresh queue, group by status. | Full modifiers, item history, served history, long notes, audit trace. | Item-level execution is currently embedded inside ticket cards. | New/Cooking/Ready/Delayed lanes, ticket summary, elapsed time, priority signal. | Full item execution panel, stock-out request handling, manager reports. |
| Kitchen Execution<br>`lib/features/kitchen/kitchen_screen.dart` selected ticket state | Complete cooking progress for one selected ticket. | Start item, mark item ready, mark ticket ready when valid, read modifiers/notes, handle retry/tap mistakes. | Served history, original order metadata, manager delay analytics. | Queue scanning can remain too visible during item execution. | Selected ticket, item statuses, explicit item actions, notes/modifiers needed to cook. | Reports, inventory analysis, cashier/order payment states. |
| Admin Shell<br>`lib/features/admin/admin_screen.dart` | Navigate to the correct admin/manager work area. | Switch admin section, switch scoped store, access grouped nav, language/store controls. | Full page content, raw counts, audit/system diagnostics. | Live operations, configuration, monitoring, reports, exceptions all appear as feature tabs. | Role/work-step grouped navigation and scoped store context. | Child-screen primary jobs should not all be visible as equal feature tabs on mobile. |
| Admin Tables<br>`lib/features/admin/tabs/tables_tab.dart` | Configure or monitor dining tables depending selected mode. | Add table, edit layout, save/reset layout, filter status, select table for monitor. | Audit trace, order history, layout diagnostics. | Waiter order taking, kitchen item status update, payment execution, table transfer, order cancellation. | Table layout configuration and table operations monitor, clearly separated by mode. | Normal waiter order flow, cashier payment flow, kitchen execution, manager cancellation/exception handling. |
| Admin Menu<br>`lib/features/admin/tabs/menu_tab.dart` | Configure menu categories/items or manage live availability when explicitly in that mode. | Add/edit category, add/edit item, toggle availability, filter/search category/items. | Recipe mapping, price history, audit trace, advanced option groups. | Live sold-out management and menu configuration share the same surface without a primary job switch. | Menu configuration actions; availability toggle only if the primary job is availability management. | Inventory analysis, recipe management if it grows beyond menu setup, reports. |
| Admin Staff<br>`lib/features/admin/tabs/staff_tab.dart` | Manage staff directory/profile records. | Search/filter staff, add staff, activate/deactivate, open staff detail, edit profile. | Attendance history, permission history, audit trace. | Permission review and attendance review are blended into directory detail. | Directory/profile management and status maintenance. | Permission review, attendance exception review, payroll. |
| Admin Attendance<br>`lib/features/admin/tabs/attendance_tab.dart` | Review attendance records and attendance exceptions. | Date/staff filter, search, inspect log, export attendance when tied to review. | Photo records, kiosk diagnostics, detailed payroll math, audit trace. | Payroll preview/export/unlock can compete with attendance review. | Attendance records, exception signals, date/staff filters. | Payroll preview/export, staff settlement, daily closing. |
| Admin Inventory<br>`lib/features/admin/tabs/inventory_tab.dart` | Complete one inventory work step at a time. | Depends on selected step: edit ingredient, edit recipe, count stock, record receiving/disposal, create purchase order, confirm receipt. | Runtime readiness, provenance, supplier history, transaction logs, diagnostics. | Ingredient catalog, recipe mapping, stock count, receiving/disposal, purchase recommendation, PO creation, receipt confirmation, and reports are all in one giant tab. | The selected inventory step and its required supporting actions. | Separate catalog, recipe config, stock count, stock movement, purchase queue, receiving execution, inventory reports, inventory exceptions. |
| Admin QC<br>`lib/features/admin/tabs/qc_tab.dart` | Complete one QC work step: template configuration, weekly review, or follow-up resolution. | Add/edit/reorder template, inspect weekly cell/image, filter follow-ups, update follow-up status depending selected step. | Image detail, full history, analytics, audit trace. | Template config, weekly review, analytics, and follow-up resolution live together as a feature page. | Current QC step and required supporting actions. | Separate QC template config, weekly review, follow-up exceptions, reports. |
| Admin Settings<br>`lib/features/admin/tabs/settings_tab.dart` | Edit store/system configuration. | Save/reset store settings, edit profile label, manage PIN, test printer, save category form. | Audit trace, raw system diagnostics, session/logout. | Store config, permission profile, payroll PIN, printer hardware, audit/system/logout are visually equal. | Selected configuration category and save/test actions. | Audit/system diagnostics drawer, session/logout placement, payment operations. |
| Manager Reports<br>`lib/features/admin/tabs/reports_tab.dart` | Understand historical performance for a selected period. | Select date range, apply quick range, view KPIs/charts/tables, export report. | Raw rows, proof/e-invoice exception detail, audit trace, closing history. | Operational monitoring and daily closing code paths appear near report analysis. | Sales/order/payment/channel analysis and export. | Daily closing, operational exception queue, proof/e-invoice follow-up, staff settlement. |
| Manager Daily Closing<br>`lib/features/admin/tabs/reports_tab.dart` current closing section | Decide whether today can be closed and execute close. | Review blockers, inspect warnings, close today, read close result. | Historical close table, detailed report analytics, raw service errors. | Daily closing is currently coupled to report analysis. | Closing checklist, blockers, close action, close result. | Reports, operational monitoring, inventory analysis, staff settlement detail. |
| Manager E-Invoice<br>`lib/features/admin/tabs/einvoice_tab.dart` | Resolve e-invoice exceptions or monitor invoice queue state. | Filter status, select issue, retry/process, open portal, mark resolved when allowed. | Raw ref IDs, CQT status, job timestamps, portal metadata, copy ref. | Normal payment proof/receipt review and raw diagnostics can crowd exception resolution. | Exception queue, selected issue summary, one status-derived next action. | Payment execution, sales reports, daily closing, raw diagnostics drawer. |
| Manager Delivery Settlement<br>`lib/features/delivery/screens/delivery_settlement_tab.dart` | Resolve or confirm delivery settlement items. | Filter settlement status, inspect settlement, confirm received, review dispute state. | Aggregate settlement metrics, history trend, mini metrics, audit trace. | Aggregate reporting and settlement execution are mixed. | Settlement queue, unsettled/pending/disputed items, confirm action. | Delivery settlement report, daily closing summary, staff settlement. |
| Manager Operational Monitoring | Identify what needs manager attention now. | Filter exception type, open item, assign/review, mark followed up when allowed. | Raw logs, historical reports, diagnostics, audit trace. | Signals are currently scattered through Reports, E-Invoice, Delivery, Inventory, Attendance, QC. | Exception queues and next actions. | Historical reports, configuration forms, normal cashier/waiter/kitchen execution. |

## Cashier Payment Execution Non-Split Rule

The following are not separate workflows when the primary job is "complete payment":

- Payment method selection
- Discount/coupon application
- Menu cancellation required before payment
- Quantity adjustment required before payment
- Split payment
- Receipt printing
- Failed payment retry
- Proof attachment
- Guest-requested red invoice capture

These must stay available in the payment execution experience, visually subordinate to amount due and Pay Now.

The following are separate workflows:

- Daily closing
- Sales report
- Staff settlement
- Refund approval management
- Menu settings
- Inventory analysis
- Operational exception monitoring
- Failed/stuck e-invoice lifecycle beyond checkout
- Missing/deferred proof queue beyond checkout

## Completion Contract

The UI improvement is not complete until:

1. Every row above is reflected in the updated UI or implementation plan.
2. Every row passes all eight Audit Gates.
3. No screen exposes a separate workflow as a default primary job.
4. Supporting actions needed to complete the same job remain available.
5. Secondary detail is hidden by default.
6. Cashier Payment Execution keeps the non-split rule.
7. Admin Tables stops exposing normal waiter/cashier/kitchen execution as table configuration content.
8. `flutter analyze` and `flutter test` pass after each implementation phase.
