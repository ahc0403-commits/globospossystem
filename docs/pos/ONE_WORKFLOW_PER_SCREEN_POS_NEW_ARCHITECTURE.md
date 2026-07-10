# One Workflow Per Screen POS New Architecture

Date: 2026-05-15
Scope: proposed Flutter UI architecture only. Existing POS logic and backend/runtime contracts must remain unchanged.

## Architecture Principle

Each screen is a work step. A work step is defined by one primary job, not by one isolated feature. Supporting actions required to complete that primary job remain on the same screen. Details, logs, diagnostics, and unrelated workflows are secondary or separate.

Fixed classification fields for each major screen:

- Primary Job
- Supporting Actions
- Secondary Detail
- Separate Workflows currently mixed in
- Should remain on same screen
- Should move to separate screen

## Table Selection

## Role
Waiter

## Purpose
Select the table that needs service now.

## Primary Operator Question
Which table should I open or continue serving?

## Default Visible Information
- Floor/table grid
- Table number/name
- Table state: available, occupied, waiting for order, needs attention
- Guest count only when required to start a table
- Compact active order indicator if the table already has an order

## Primary Actions
- Open Table
- Start Order

## Secondary Detail
- Table transfer
- Full order history
- Audit trace
- Advanced filters

## Queue Structure
- Needs Attention
- Occupied / In Progress
- Available
- Optional floor/zone grouping

## Execution Structure
No full order editor in the default table selection surface. Selecting a table opens Order Taking or a compact table detail drawer with one next action.

## Status Signals
- Available: neutral/green
- In order: amber
- Sent to kitchen: blue
- Needs cashier or manager attention: red
- Selected table: high-contrast outline, not a new color family

## Suggested Components
- `WaiterTableQueue`
- `TableStatusTile`
- `TableAttentionStrip`
- `GuestCountPrompt`

## Files to Change
- `lib/features/waiter/waiter_screen.dart`
- `lib/features/table/floor_layout.dart`
- `lib/widgets/order_workspace.dart`

## Risk
Low if this is a UI split only. Keep the existing table/order providers and call the same load/start order callbacks.

## Order Taking

## Role
Waiter

## Purpose
Add items for the selected table.

## Primary Operator Question
What does this table want to order now?

## Default Visible Information
- Selected table and guest count
- Menu categories
- Menu items with availability
- Current unsent cart
- Running subtotal

## Primary Actions
- Review Order
- Clear / Back

## Secondary Detail
- Sent kitchen items
- Previous order history
- Item notes/modifiers beyond first-level choices
- Table transfer
- Cancel order

## Queue Structure
Not a queue screen. Menu categories should scan quickly; unavailable items should be visually suppressed or clearly disabled.

## Execution Structure
Two-pane on tablet/desktop: menu browser left, current cart right. On mobile: menu first with sticky cart summary and Review action.

## Status Signals
- Available menu item: normal
- Unavailable: muted with sold-out label
- Cart changed: subtle unsent badge
- Required modifier missing: warning

## Suggested Components
- `OrderTakingWorkspace`
- `MenuCategoryRail`
- `MenuItemGrid`
- `UnsentCartPanel`
- `SentItemsSummaryStrip`

## Files to Change
- `lib/widgets/order_workspace.dart`
- `lib/features/waiter/waiter_screen.dart`
- `lib/features/admin/tabs/tables_tab.dart` only to stop using the full order workspace as admin default

## Risk
Medium. The UI can reuse current callbacks, but the shared workspace must be decomposed carefully so order mutation logic stays untouched.

## Order Review

## Role
Waiter

## Purpose
Confirm the unsent cart before sending it to kitchen.

## Primary Operator Question
Is this order correct and ready to send?

## Default Visible Information
- Table
- Unsent items grouped by category or preparation station
- Quantity, item name, notes/modifiers, line total
- Order subtotal
- Any availability or required-note warnings

## Primary Actions
- Send to Kitchen
- Back to Edit

## Secondary Detail
- Full sent item history
- Cancel order
- Table transfer
- Audit trace

## Queue Structure
Not queue-based. It is a confirmation step after Order Taking.

## Execution Structure
Single focused review panel. Warnings appear above the item list. Send action stays fixed at the bottom/right.

## Status Signals
- Ready to send: primary action enabled
- Needs correction: warning banner, disabled send
- Offline queued: neutral warning with queue message

## Suggested Components
- `OrderReviewPanel`
- `OrderValidationBanner`
- `KitchenSendActionBar`

## Files to Change
- `lib/widgets/order_workspace.dart`
- `lib/features/waiter/waiter_screen.dart`

## Risk
Low to medium. No order workflow change is required if `sendOrder` callback remains unchanged.

## Kitchen Queue

## Role
Kitchen

## Purpose
Show which tickets need kitchen attention.

## Primary Operator Question
What ticket should the kitchen work on next?

## Default Visible Information
- New tickets
- Cooking tickets
- Ready/handoff tickets
- Table number
- Elapsed time
- Item count and short item summary
- Delay/priority signal

## Primary Actions
- Open Ticket
- Mark Ticket Ready, only when all items are ready or the ticket state allows it

## Secondary Detail
- Full item list
- Item notes/modifiers
- Item-level status changes
- Served history
- Delay diagnostics

## Queue Structure
- New
- Cooking
- Ready for Handoff
- Delayed / Attention

## Execution Structure
Queue cards remain compact. Selecting a ticket opens Kitchen Execution in a side panel/drawer.

## Status Signals
- New: amber
- Cooking: blue
- Ready: green
- Delayed: red
- Served/closed: neutral

## Suggested Components
- `KitchenLane`
- `KitchenTicketCard`
- `KitchenDelayQueue`
- `KitchenTicketSummary`

## Files to Change
- `lib/features/kitchen/kitchen_screen.dart`

## Risk
Low. The same kitchen provider and item status callbacks can be reused. Main risk is preserving touch target speed.

## Kitchen Execution

## Role
Kitchen

## Purpose
Progress items on one selected kitchen ticket.

## Primary Operator Question
What should I mark started or ready on this ticket?

## Default Visible Information
- Selected ticket header
- Items grouped by status: Pending, Preparing, Ready
- Notes/modifiers for the selected ticket only
- Elapsed time and priority

## Primary Actions
- Start Selected Items
- Mark Selected Items Ready

## Secondary Detail
- Served history
- Original order metadata
- Waiter/order notes beyond kitchen action

## Queue Structure
The execution panel is opened from Kitchen Queue. It should not show all tickets.

## Execution Structure
Selectable item rows with explicit action buttons. Avoid hidden "tap row to advance" as the only action pattern.

## Status Signals
- Pending: amber outline
- Preparing: blue fill or left stripe
- Ready: green
- Delayed: red badge in header

## Suggested Components
- `KitchenExecutionDrawer`
- `KitchenItemStatusList`
- `KitchenBulkActionBar`

## Files to Change
- `lib/features/kitchen/kitchen_screen.dart`
- `lib/widgets/order_workspace.dart` if sent item status controls are removed from non-kitchen callers

## Risk
Medium. UI-only split is possible, but item status interaction must preserve existing status transition rules exactly.

## Payment Queue

## Role
Cashier

## Purpose
Select the next payable order.

## Primary Operator Question
Which order needs payment now?

## Default Visible Information
- Payable orders
- Table/order number
- Amount due
- Time since order ready/payment requested
- Payment readiness or blocked state

## Primary Actions
- Open Payment
- Hold / Skip

## Secondary Detail
- Full order line details
- Receipt/proof/e-invoice history
- Daily totals
- Manager override actions

## Queue Structure
- Ready to Pay
- Waiting / In Progress
- Needs Follow-up
- Failed / Exception

## Execution Structure
Queue left, selected payment summary right on wide screens. On mobile, queue first and selected payment as next screen.

## Status Signals
- Ready: green/neutral strong
- Waiting: blue
- Follow-up: amber
- Failed/blocked: red

## Suggested Components
- `PaymentQueueList`
- `PaymentQueueRow`
- `PaymentReadinessBadge`

## Files to Change
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/admin/tabs/tables_tab.dart`
- `lib/widgets/order_workspace.dart`

## Risk
Low. Existing payable order loading can remain unchanged.

## Payment Execution

## Role
Cashier

## Purpose
Complete payment for one selected order.

## Primary Operator Question
What must I do to complete this payment now?

## Default Visible Information
- Amount due
- Table/order number
- Payment method choices
- Essential order summary
- Connectivity/offline warning if it affects payment
- Any payment-completion blocker, such as required proof or failed retry state

## Primary Actions
- Pay Now
- Back to Queue

Supporting actions that remain on this screen:

- Select payment method
- Apply discount/coupon
- Cancel a menu item when needed before payment completion
- Adjust quantity when needed before payment completion
- Split payment
- Print receipt
- Retry failed payment
- Attach proof
- Capture guest-requested red invoice details when it is part of checkout

## Secondary Detail
- Full item list
- Discount/coupon/adjustment audit detail
- Receipt print history
- Proof image/history after completion
- Red invoice portal diagnostics
- Admin cancel/service actions

## Queue Structure
Entered from Payment Queue only. Do not show unrelated daily report data.

## Execution Structure
Amount and method rail dominate the screen. Payment-completion supporting actions sit in controlled sections below or beside the amount/method area. After success, return to queue or show a compact completion state. Only unresolved, failed, deferred, or approval-required evidence/invoice items become follow-up queue work.

## Status Signals
- Selected method: high-contrast selected state
- Payment processing: disabled actions and progress state
- Offline queued: amber
- Payment failed: red with retry path

## Suggested Components
- `PaymentExecutionPanel`
- `PaymentMethodSelector`
- `PaymentActionBar`
- `PaymentResultCheckpoint`

## Files to Change
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/cashier/payment_proof_modal.dart`
- `lib/features/cashier/red_invoice_modal.dart`

## Risk
Medium. Payment mutation path must remain exactly as today. Do not over-separate payment-completion supporting actions.

## Receipt / Proof / E-Invoice Follow-Up

## Role
Cashier / Manager

## Purpose
Complete or review unresolved payment evidence after normal payment completion cannot fully finish the evidence/invoice task.

## Primary Operator Question
What payment evidence or invoice exception still needs completion?

## Default Visible Information
- Follow-up queue item
- Payment amount
- Missing proof or e-invoice status
- Deadline/urgency
- One next action

## Primary Actions
- Complete Evidence
- Mark Followed Up, where permissions allow

This screen must not pull normal proof attachment, receipt printing, or red invoice capture out of Payment Execution when those actions are needed to complete payment in the same checkout flow.

## Secondary Detail
- Full payment detail
- Raw job IDs
- Portal URLs
- Proof image URL
- Tax metadata

## Queue Structure
- Missing/deferred Proof
- Proof Save Failed
- E-Invoice Pending Too Long
- E-Invoice Failed
- Portal/Correction/Cancellation Required

## Execution Structure
Queue-first for unresolved cases. Full diagnostics open in drawer.

## Status Signals
- Missing: amber
- Failed: red
- Pending external portal: blue
- Completed: green

## Suggested Components
- `PaymentEvidenceQueue`
- `EvidenceDetailDrawer`
- `RedInvoiceFollowUpForm`

## Files to Change
- `lib/features/cashier/payment_proof_modal.dart`
- `lib/features/cashier/red_invoice_modal.dart`
- `lib/features/payment/payment_detail_screen.dart`
- `lib/features/admin/tabs/einvoice_tab.dart`

## Risk
Low to medium. The same evidence services can be called. Avoid changing payment or e-invoice submission semantics.

## Refund / Void / Exception Queue

## Role
Cashier / Manager / Admin

## Purpose
Resolve orders, payments, invoices, and settlements that cannot follow the normal path.

## Primary Operator Question
Which exception must I fix first?

## Default Visible Information
- Exception type
- Owner role
- Amount or affected table/order
- Age/urgency
- Required next step

## Primary Actions
- Open Exception
- Resolve / Retry, based on type and permission

## Secondary Detail
- Raw logs
- RPC/job IDs
- Audit trace
- Linked order/payment records
- Portal metadata

## Queue Structure
- Payment Failed
- Void / Cancel Review
- Refund Review
- Missing Proof
- E-Invoice Failed
- Delivery Settlement Dispute
- Inventory Receiving Blocker

## Execution Structure
Manager queue with type filters. Exception detail drawer exposes domain-specific action and diagnostics.

## Status Signals
- Failed/blocked: red
- Waiting external: blue
- Needs manager review: amber
- Resolved: green

## Suggested Components
- `OperationalExceptionQueue`
- `ExceptionTypeFilter`
- `ExceptionDetailDrawer`
- `ExceptionActionFooter`

## Files to Change
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/payment/payment_detail_screen.dart`
- `lib/features/admin/tabs/einvoice_tab.dart`
- `lib/features/delivery/screens/delivery_settlement_tab.dart`
- `lib/features/admin/tabs/inventory_tab.dart`
- `lib/features/admin/tabs/reports_tab.dart`

## Risk
Medium. This can be UI-only if it reads existing provider states and invokes existing domain actions without altering workflows.

## Daily Closing

## Role
Manager

## Purpose
Close today's operating day after required checks pass.

## Primary Operator Question
Can I close today safely?

## Default Visible Information
- Sales total
- Payment total by method
- Open orders/payments count
- Missing proof/e-invoice blockers
- Delivery settlement blockers
- Low-stock or inventory exception count, if required by current business rule

## Primary Actions
- Close Today
- Review Blockers

## Secondary Detail
- Full report tables
- Hourly analytics
- Historical closing records
- Audit trace

## Queue Structure
- Ready to Close
- Blocking Exceptions
- Warnings
- Closed History

## Execution Structure
Checklist plus one close action. Report charts are secondary links, not primary content.

## Status Signals
- Ready: green
- Warning: amber
- Blocked: red
- Already closed: neutral/blue

## Suggested Components
- `DailyClosingChecklist`
- `ClosingBlockerList`
- `CloseTodayActionBar`

## Files to Change
- `lib/features/admin/tabs/reports_tab.dart`
- `lib/features/admin/providers/daily_closing_provider.dart` only if presentation state needs reshaping, not business logic
- `lib/core/router/app_router.dart` if a dedicated route is added

## Risk
Medium. The existing `DailyClosingService` should be called unchanged. UI must not relax blocker rules.

## Admin Configuration Hub

## Role
Admin

## Purpose
Manage low-frequency store, menu, table, staff, permission, receipt, and system configuration.

## Primary Operator Question
Which configuration area do I need to change?

## Default Visible Information
- Configuration categories
- Last changed / needs attention badges
- Store context

## Primary Actions
- Open Configuration
- Save, only inside a selected configuration form

## Secondary Detail
- Audit trace
- Raw IDs
- Runtime diagnostics
- Logout/session actions

## Queue Structure
Not queue-based. Use category list and focused detail form.

## Execution Structure
List/detail on desktop. Category selection on mobile opens a full-screen form.

## Status Signals
- Changed/dirty: amber
- Saved: green
- Error: red
- Read-only/no permission: muted

## Suggested Components
- `AdminConfigHub`
- `ConfigCategoryList`
- `ConfigDetailPanel`
- `ConfigSaveBar`

## Files to Change
- `lib/features/admin/admin_screen.dart`
- `lib/features/admin/tabs/tables_tab.dart`
- `lib/features/admin/tabs/menu_tab.dart`
- `lib/features/admin/tabs/staff_tab.dart`
- `lib/features/admin/tabs/settings_tab.dart`
- `lib/features/admin/tabs/qc_tab.dart`

## Risk
Low to medium. Config forms can keep current services. Main work is navigation and hierarchy cleanup.

## Menu Availability Board

## Role
Manager / Admin

## Purpose
Quickly mark items available or unavailable during service.

## Primary Operator Question
What menu item must be sold out or restored now?

## Default Visible Information
- Items grouped by category
- Availability status
- Low-stock hint if already available in current state
- Search/category filter

## Primary Actions
- Mark Sold Out
- Restore Available

## Secondary Detail
- Price/category/edit form
- Historical changes
- Recipe mapping

## Queue Structure
- Available
- Sold Out
- Low Stock / Watch

## Execution Structure
Dense item list with one toggle action per item. Configuration editing opens separate Menu Configuration.

## Status Signals
- Available: green/neutral
- Sold out: red/muted
- Low stock: amber

## Suggested Components
- `MenuAvailabilityBoard`
- `AvailabilityItemRow`
- `SoldOutFilterBar`

## Files to Change
- `lib/features/admin/tabs/menu_tab.dart`
- `lib/features/admin/tabs/inventory_tab.dart` only if low-stock signal is linked through existing state

## Risk
Low if it uses existing menu availability update functions.

## Inventory Work Steps

## Role
Admin / Manager

## Purpose
Separate inventory configuration, counting, movement, purchasing, receiving, and reporting.

## Primary Operator Question
Depends on selected work step:
- Catalog: What item/recipe configuration needs editing?
- Count: What actual stock count must I enter?
- Movement: What stock receiving or disposal must I record?
- Purchase: What purchase order should I create or review?
- Receiving: What delivery should I confirm?
- Report: What inventory trend or exception should I understand?

## Default Visible Information
- Only the selected work-step list or form
- No purchase diagnostics in catalog
- No report charts in count execution

## Primary Actions
- Work-step specific action 1
- Work-step specific action 2

Examples:
- Count: Save Count, Finish Later
- Receiving: Confirm Receipt, Report Blocker
- Purchase Queue: Create PO, Open Recommendation

## Secondary Detail
- Runtime readiness
- Provenance
- Supplier history
- Transaction logs
- Recommendation diagnostics

## Queue Structure
- Low Stock
- Count Due
- Receiving Pending
- Purchase Recommendation Ready
- Purchase Order Pending
- Inventory Exception

## Execution Structure
Use separate screens or deep tabs with one work-step per tab. Avoid one report tab containing purchase, receipt, history, readiness, and diagnostics together.

## Status Signals
- Low stock: amber
- Out of stock: red
- Receiving pending: blue
- Confirmed: green
- Blocked: red

## Suggested Components
- `InventoryActionQueue`
- `StockCountWorkspace`
- `StockMovementForm`
- `PurchaseQueue`
- `ReceivingExecutionPanel`
- `InventoryReportView`

## Files to Change
- `lib/features/admin/tabs/inventory_tab.dart`
- `lib/core/router/app_router.dart` if split routes are added

## Risk
Medium to high because the current file is large and multi-domain. Keep every provider/service call intact; split UI composition first.

## Operational Monitoring

## Role
Manager

## Purpose
Show live operational risks that require attention.

## Primary Operator Question
What needs manager attention right now?

## Default Visible Information
- Exceptions by type
- Age/priority
- Owner role
- Required next action
- Store/day context

## Primary Actions
- Open Queue Item
- Assign / Mark Reviewed, where current permissions allow

## Secondary Detail
- Full report charts
- Raw logs
- Historical tables
- Configuration forms

## Queue Structure
- Orders Delayed
- Payment Follow-up
- Missing Proof
- E-Invoice Failed
- Delivery Settlement
- Inventory Low/Blocked
- Attendance/Payroll Exceptions
- QC Follow-up

## Execution Structure
Queue-first dashboard with small counts and direct links into dedicated exception detail screens.

## Status Signals
- Critical: red
- Needs review: amber
- Waiting external: blue
- Healthy: green/neutral

## Suggested Components
- `ManagerAttentionQueue`
- `AttentionTypeSection`
- `AttentionItemRow`
- `AttentionDetailDrawer`

## Files to Change
- `lib/features/admin/tabs/reports_tab.dart`
- `lib/features/admin/tabs/einvoice_tab.dart`
- `lib/features/delivery/screens/delivery_settlement_tab.dart`
- `lib/features/admin/tabs/inventory_tab.dart`
- `lib/features/admin/tabs/attendance_tab.dart`
- `lib/features/admin/tabs/qc_tab.dart`

## Risk
Medium. UI aggregation must read existing states without creating new backend contracts.

## Reports

## Role
Manager / Admin

## Purpose
Analyze historical performance, not execute live fixes.

## Primary Operator Question
What happened during this period?

## Default Visible Information
- Date range
- Revenue/order KPIs
- Channel/payment breakdown
- Hourly/daily trend
- Export action

## Primary Actions
- Apply Date Range
- Export Report

## Secondary Detail
- Operational exceptions
- Daily close action
- Payment proof/e-invoice details
- Full raw tables

## Queue Structure
Not a queue. It is an analysis screen.

## Execution Structure
Chart and summary first, tables second. Operational blockers link to Operational Monitoring.

## Status Signals
- Healthy period: neutral
- Data missing/loading: blue/neutral
- Exception references: amber/red link badges only

## Suggested Components
- `ReportsOverview`
- `ReportDateRangeBar`
- `RevenueTrendPanel`
- `ReportBreakdownPanel`
- `ReportExportAction`

## Files to Change
- `lib/features/admin/tabs/reports_tab.dart`

## Risk
Low if report provider and export code remain unchanged. Main change is hiding or relocating exception and closing content.
