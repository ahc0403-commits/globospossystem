# One Workflow Per Screen POS Implementation Sequence

Date: 2026-05-15
Scope: UI refactor priority only. Do not change backend, DB schema, Supabase, RPC, RLS, auth, permissions, provider/state contracts, order workflow, payment workflow, kitchen workflow, cashier workflow, waiter workflow, or runtime contracts.

Fixed interpretation:

- "One Workflow Per Screen" means one primary job per screen.
- Supporting actions required to complete that primary job remain on the same screen.
- Do not split Cashier Payment Execution into tiny feature screens.
- Split only separate workflows with a different primary job.

## Priority Criteria

Priority is based on:

1. Most frequent store-operator screens
2. Real-time order/payment/kitchen impact
3. Current information overload severity
4. Role boundary ambiguity
5. Distance from Toast-style role-first POS

## Priority Overview

| Priority | Redesign Target | Main Role | Decision | Why First |
|---|---|---|---|---|
| P0 | Admin Tables role-boundary split | Admin / Waiter / Cashier / Kitchen | 분리 | This tab can perform table admin, order taking, kitchen item status change, payment, transfer, and cancel in one place. It is the highest role-boundary risk. |
| P1 | Waiter Table Selection -> Order Taking -> Order Review | Waiter | 분리 | Waiter flow is high-frequency and directly affects service speed. |
| P2 | Cashier Payment Queue -> Payment Execution -> Unresolved Evidence/Exception Follow-up | Cashier | 분리 | Payment is real-time and revenue-critical. Payment-completion supporting actions stay together; daily summary/reports/approval workflows move out. |
| P3 | Kitchen Queue -> Kitchen Execution | Kitchen | 분리 | KDS is real-time. Queue scanning should not be crowded by item-level execution detail. |
| P4 | Inventory giant tab split | Admin / Manager | 분리 | Largest information overload surface. Needs catalog/count/purchasing/receiving/report separation. |
| P5 | Reports -> Operational Monitoring -> Daily Closing | Manager | 분리 | Reports currently mix analytics, exceptions, and closing. Daily close needs one work step. |
| P6 | E-Invoice and Payment Detail exception cleanup | Manager / Cashier | 축소 | Good queue foundation, but raw diagnostics and multiple actions should be secondary. |
| P7 | Delivery Settlement queue/report split | Manager | 분리 | Settlement execution and aggregate reporting are mixed. |
| P8 | Staff / Attendance / Payroll / Permission split | Admin / Manager | 분리 | Medium-frequency back-office work, but sensitive permission/payroll tasks need clear boundaries. |
| P9 | QC template/review/follow-up split | Admin / Manager | 분리 | Feature-first tabs should become configuration, review, and exception work steps. |
| P10 | Settings hierarchy reduction | Admin | 축소 | Lower operational urgency, but should still remove audit/system noise from default config. |

## P0 - Admin Tables Role-Boundary Split

Files:
- `lib/features/admin/tabs/tables_tab.dart`
- `lib/widgets/order_workspace.dart`
- `lib/features/waiter/waiter_screen.dart`
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/kitchen/kitchen_screen.dart`

Problem:
- Admin Tables currently combines table layout configuration, live table operations, order workspace, kitchen sent-item status updates, payment execution, transfer, cancellation, and audit trace.

Target:
- `Table Layout Configuration`: add/edit/delete/reposition tables.
- `Table Operations Monitor`: read-only or limited table state overview.
- Route order work to waiter flow.
- Route payment work to cashier flow.
- Route kitchen item progression to kitchen flow.

Success Criteria:
- Admin default table screen has no payment action.
- Admin default table screen has no kitchen item status cycle action.
- Layout edit mode is separated from service operation mode.
- Table status monitoring still works with existing state.

Risk:
- Medium. The current tab directly invokes several operational callbacks. Split UI must preserve existing callback wiring and permission checks without changing behavior.

## P1 - Waiter Flow Split

Files:
- `lib/features/waiter/waiter_screen.dart`
- `lib/widgets/order_workspace.dart`
- `lib/features/table/floor_layout.dart`

Problem:
- Table selection and order entry are close, but once the order panel opens, order taking, sent item detail, edit/cancel, transfer, and send review are mixed.

Target:
- `Table Selection`: table-first queue/grid.
- `Order Taking`: menu/category/cart only.
- `Order Review`: confirm and send to kitchen.

Success Criteria:
- A waiter can identify the current step in 3 seconds.
- Order Taking has no payment action.
- Sent kitchen items are compact read-only detail unless editing is explicitly opened.
- Review/send has at most two primary actions.

Risk:
- Medium. Requires decomposing `OrderWorkspace` while keeping order callbacks unchanged.

## P2 - Cashier Payment Flow Split

Files:
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/cashier/payment_proof_modal.dart`
- `lib/features/cashier/red_invoice_modal.dart`
- `lib/features/payment/payment_detail_screen.dart`

Problem:
- Payment execution is mixed with some non-payment workflows, especially daily summary/report-like work and manager/admin approval surfaces.
- The correction is not to remove every supporting action from Payment Execution. Payment method, discount/coupon, menu cancellation, quantity adjustment, split payment, receipt, failed payment retry, proof attachment, and guest-requested red invoice capture are part of completing payment.

Target:
- `Payment Queue`: payable orders only.
- `Payment Execution`: selected order, amount due, method, pay action, and payment-completion supporting actions.
- `Unresolved Evidence / E-Invoice Follow-up`: only missing, failed, deferred, stuck, correction, or cancellation cases.
- `Refund / Void / Exception`: approval/review handling separate from normal checkout.
- `Daily Closing / Reports / Staff Settlement`: manager workflows outside cashier checkout.

Success Criteria:
- Payment Execution primary actions are Pay Now and Back to Queue, with supporting actions subordinate.
- Proof and red invoice capture remain available when required to complete checkout.
- Missing/failed/deferred proof or e-invoice issues move to follow-up/exception.
- Daily summary is not a cashier default action surface.
- Existing payment processing path is unchanged.

Risk:
- Medium to high because payment UX must remain legally and operationally correct. Do UI relocation only, no mutation changes, and avoid over-separating payment-completion supporting actions.

## P3 - Kitchen Queue and Execution Split

Files:
- `lib/features/kitchen/kitchen_screen.dart`
- `lib/widgets/order_workspace.dart` if removing non-kitchen sent-item status controls

Problem:
- Kitchen lanes are useful, but ticket cards show full detail and item rows act as hidden status controls.

Target:
- `Kitchen Queue`: compact ticket lanes and delayed attention queue.
- `Kitchen Execution`: selected ticket drawer/panel with explicit item actions.

Success Criteria:
- Queue cards stay compact and scannable.
- Full item list appears only for selected ticket.
- Item status actions are explicit.
- Delayed tickets have a dedicated attention grouping.

Risk:
- Medium. Preserve exact status transition behavior.

## P4 - Inventory Work-Step Split

Files:
- `lib/features/admin/tabs/inventory_tab.dart`
- `lib/core/router/app_router.dart` if adding routes

Problem:
- One file/screen contains ingredient catalog, recipe mapping, physical count, stock movements, reports, purchase recommendation, purchase orders, receiving, readiness checks, blockers, provenance, and supplier history.

Target:
- `Ingredient Catalog`
- `Recipe Configuration`
- `Stock Count`
- `Stock Movement`
- `Purchase Queue`
- `Receiving Execution`
- `Inventory Reports`
- `Inventory Exceptions`

Success Criteria:
- Catalog screen has no purchase/receiving report diagnostics.
- Physical count screen has one count task.
- Receiving screen has one receipt confirmation task.
- Reports do not contain execution controls as default content.

Risk:
- High due to file size and dense state. Use incremental extraction and avoid touching provider/service logic.

## P5 - Reports, Operational Monitoring, Daily Closing Split

Files:
- `lib/features/admin/tabs/reports_tab.dart`
- `lib/features/admin/providers/daily_closing_provider.dart` only for presentation state if required
- `lib/core/router/app_router.dart` if adding routes

Problem:
- Reports contain revenue analysis, operational exceptions, proof/e-invoice/WT08 signals, quick ranges, export, and daily closing code path.

Target:
- `Reports`: historical analysis and export.
- `Operational Monitoring`: live exceptions and attention queues.
- `Daily Closing`: blocker checklist and close action.

Success Criteria:
- Reports have no close-today primary action.
- Operational exceptions are queue-first.
- Daily Closing shows blockers before close action.
- Existing `DailyClosingService` behavior is unchanged.

Risk:
- Medium. Daily close rules must stay exactly as implemented.

## P6 - E-Invoice and Payment Detail Cleanup

Files:
- `lib/features/admin/tabs/einvoice_tab.dart`
- `lib/features/payment/payment_detail_screen.dart`

Problem:
- E-invoice queue is promising, but raw detail and multiple secondary actions are too visible. Payment detail is DB-like for cashier use.

Target:
- E-invoice remains an exception queue.
- Payment detail becomes status-first with raw diagnostics collapsed.

Success Criteria:
- One status-derived primary action dominates each exception.
- Copy ref, portal metadata, raw IDs, job timestamps, and proof URLs move to expandable detail.
- Cashier sees evidence status without manager diagnostics by default.

Risk:
- Low to medium. Mostly visual hierarchy and detail disclosure.

## P7 - Delivery Settlement Split

Files:
- `lib/features/delivery/screens/delivery_settlement_tab.dart`

Problem:
- Settlement action queue and aggregate settlement reporting are mixed.

Target:
- `Delivery Settlement Queue`: unsettled/pending/disputed/statement items and confirm action.
- `Delivery Settlement Report`: historical/aggregate settlement metrics.

Success Criteria:
- Confirm received appears only on selected settlement execution item.
- Aggregate report no longer competes with at-risk settlement queue.
- Disputes are grouped as attention items.

Risk:
- Low to medium if current provider actions remain unchanged.

## P8 - Staff, Attendance, Payroll, Permission Split

Files:
- `lib/features/admin/tabs/staff_tab.dart`
- `lib/features/admin/tabs/attendance_tab.dart`

Problem:
- Staff directory mixes attendance, permissions, activation, creation. Attendance mixes review and payroll unlock/export.

Target:
- `Staff Directory`
- `Permission Review`
- `Attendance Exception Review`
- `Payroll Preview / Export`

Success Criteria:
- Permission change is not a casual staff-detail side action.
- Payroll unlock/export is not shown as routine attendance review content.
- Attendance exceptions are queue-first.

Risk:
- Medium due to permission sensitivity. Keep existing permission checks.

## P9 - QC Split

Files:
- `lib/features/admin/tabs/qc_tab.dart`

Problem:
- QC template configuration, weekly review, cell/image detail, and follow-up resolution live as one feature tab set.

Target:
- `QC Template Configuration`
- `Weekly QC Review`
- `QC Follow-up Exceptions`

Success Criteria:
- Template editing is not mixed with follow-up resolution.
- Follow-up queue is action-first.
- Weekly review detail opens only after selecting a record/cell.

Risk:
- Medium. The state can remain; UI should be split by work step.

## P10 - Settings Reduction

Files:
- `lib/features/admin/tabs/settings_tab.dart`

Problem:
- Store config, profile naming, payroll PIN, receipt printer, audit/system, and logout share one settings surface.

Target:
- Keep settings as Admin Configuration.
- Reduce default KPIs.
- Move audit/system diagnostics and logout to secondary placement.
- Rename or clarify payment/payroll PIN section to prevent cashier-payment confusion.

Success Criteria:
- Settings reads as configuration, not operational dashboard.
- Each category has one form/action focus.
- System/audit detail is not default noise.

Risk:
- Low. Mostly hierarchy and naming.

## Suggested Delivery Plan

### Phase 1 - Live POS Safety

1. Split Admin Tables role-boundary surface.
2. Split `OrderWorkspace` into waiter-focused order taking/review pieces.
3. Split Cashier payment execution from daily summary/reporting/approval workflows while preserving payment-completion supporting actions in the same screen.
4. Split Kitchen queue from execution drawer.

Reason:
- These are live service surfaces with the highest operational impact.

### Phase 2 - Manager Control

1. Extract Daily Closing from Reports.
2. Extract Operational Monitoring from Reports/E-Invoice/Delivery/Inventory signals.
3. Reduce Payment Detail and E-Invoice raw diagnostics.

Reason:
- Manager work should become exception-first and closing-safe.

### Phase 3 - Back-Office Density

1. Split Inventory work steps.
2. Split Staff/Attendance/Payroll/Permission.
3. Split QC.
4. Reduce Settings hierarchy.

Reason:
- These are lower-frequency than live service, but currently create the largest back-office cognitive load.

## First Redesign Target

The first redesign target should be:

`lib/features/admin/tabs/tables_tab.dart` plus the `OrderWorkspace` usage inside it.

Why:

- It crosses Waiter, Cashier, Kitchen, and Admin roles in one screen.
- It includes high-impact live mutations through a configuration/admin surface.
- Splitting it reduces role confusion before any visual polish.
- It forces the project to extract `OrderWorkspace` into real work-step components, which then benefits Waiter and Cashier redesigns.

If the team chooses to start strictly from the most-used frontline screen, the first frontline target should be:

`lib/features/waiter/waiter_screen.dart` plus `lib/widgets/order_workspace.dart`.

## Implementation Guardrails

Do:

- Keep every provider/service call intact.
- Extract UI components around existing callbacks.
- Preserve current permission checks.
- Preserve supporting actions that complete the same primary job.
- Use existing route guards and role home behavior.
- Hide detail progressively before removing UI affordances.
- Add UI tests only around screen composition and action visibility.

Do not:

- Change DB schema.
- Change Supabase functions/tables/storage.
- Change RPC signatures.
- Change RLS.
- Change auth or permissions.
- Change payment mutation behavior.
- Change order status transition behavior.
- Change kitchen workflow semantics.
- Change cashier/waiter workflow contracts.
- Introduce new backend mutation paths.
- Over-split Cashier Payment Execution into feature-level screens.

## 100% Completion Criteria

The POS one-primary-job improvement is complete only when all criteria below are true:

1. The five `docs/pos` audit/architecture/standard/sequence documents use the primary-job interpretation.
2. `docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md` lists every audited major screen with the required classification fields.
3. Every major screen passes the eight audit gates: Primary Job, Supporting Actions, Separate Workflow, Secondary Detail, Role Boundary, 3-Second Operator, Action Hierarchy, and Workflow Safety.
4. Waiter, Cashier, Kitchen, Admin, and Manager screens have no default-visible separate workflows inside another primary job.
5. Cashier Payment Execution keeps payment-completion supporting actions in the same screen.
6. Admin Tables no longer exposes normal waiter/cashier/kitchen primary jobs as default admin table configuration content.
7. Reports, Daily Closing, Operational Monitoring, Staff Settlement, Refund Approval, Menu Settings, and Inventory Analysis are separated by primary job.
8. Secondary detail is moved behind drawer, expand, modal, or selected detail panel.
9. Existing provider/service/RPC/backend mutation paths are unchanged.
10. `flutter analyze` passes.
11. `flutter test` passes.
12. Role contract tests or equivalent UI checks prove primary job boundaries remain stable.

## Phase 0-5 Closure Plan

| Phase | Closure Output | Must Pass |
|---|---|---|
| Phase 0 - Criteria Lock | Audit gate table and primary-job interpretation are present in docs. | No document implies feature-level over-splitting. |
| Phase 1 - Contract Mapping | Every major screen has `Primary Job`, `Supporting Actions`, `Secondary Detail`, `Separate Workflows`, `Should remain`, and `Should move`. | Cashier Payment Execution non-split rule is explicit. |
| Phase 2 - Live POS Safety | Admin Tables, Waiter, OrderWorkspace, and Kitchen stop exposing cross-role primary jobs by default. | Existing order/kitchen mutations are reused, not changed. |
| Phase 3 - Cashier Completion | Cashier Payment Queue/Execution/Follow-up respect primary-job boundaries. | Payment supporting actions remain in execution; reports/closing/approval leave checkout. |
| Phase 4 - Manager/Admin Density | Reports, Daily Closing, Operational Monitoring, Inventory, Staff/Attendance, QC, Settings are separated by primary job or reduced by disclosure. | Secondary detail is behind drawer/expand/modal/detail. |
| Phase 5 - Verification | Analyze, tests, role contract tests, and source checks pass. | Backend/workflow untouched confirmation is true. |

Closure evidence is recorded in
`docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PHASE5_CLOSURE_AUDIT.md`.
