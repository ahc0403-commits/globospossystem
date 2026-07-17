# Toast-Style POS Operational UX Standard

Date: 2026-05-15
Scope: POS operation UI standard for Flutter redesign. This standard does not request backend, workflow, permission, or provider changes.

## Core Principle

Toast-style POS is role-first, queue-first, dense, and action-first. It avoids decorative dashboards and avoids "everything-on-one-screen" surfaces.

"One Workflow Per Screen" is fixed to mean one primary job per screen, not one feature per screen. Supporting actions required to complete that primary job are allowed on the same screen.

Every screen must pass this test:

1. Can the operator identify the current work step within 3 seconds?
2. Is there one primary job for the screen?
3. Are there at most two primary actions visible at once?
4. Are supporting actions directly required to complete the same primary job?
5. Are logs, history, diagnostics, and configuration kept secondary?

## Role-First Navigation

Navigation should start from the operator role, not from a feature list.

Recommended role entries:

- Waiter: tables, order taking, order review
- Cashier: payment queue, payment execution, payment follow-up
- Kitchen: kitchen queue, ticket execution
- Manager: operational monitoring, exceptions, daily closing, reports
- Admin: configuration, staff/permission, menu/table/store settings

Rules:

- A role should not see another role's primary action by default.
- Admin may supervise, but admin screens should not become waiter/cashier/kitchen execution screens.
- Manager screens should focus on exceptions and closing, not normal frontline execution.
- Global navigation should be present but visually secondary during live service.

## Table-First Waiter Flow

Waiter flow starts with tables, not menu items.

Required structure:

- Table Selection is the first waiter surface.
- Table state must be scannable through table number, color/status, and concise labels.
- Starting or continuing an order should be the next clear action after table selection.
- Order Taking should show menu/category/cart only.
- Order Review should be a separate confirmation step before sending to kitchen.

Do not:

- Show payment execution inside the waiter default order-taking screen.
- Show kitchen item status controls in waiter order entry.
- Put full order history in the default table grid.
- Use large dashboard cards above the table grid unless they directly change the next waiter action.

## Queue-First Kitchen Flow

Kitchen flow starts with tickets.

Required structure:

- Default view is a ticket queue.
- Tickets are grouped by status: New, Cooking, Ready, Delayed/Attention.
- Ticket cards are compact and must show table, elapsed time, item count, and short summary.
- Full item detail opens in an execution panel or drawer.
- Item status changes should be explicit actions, not hidden row behavior only.

Do not:

- Make every item row in the queue card a hidden primary action.
- Show manager/report metrics as default KDS content.
- Mix stock-out/change requests with normal ticket detail unless grouped as attention items.

## Payment-First Cashier Flow

Cashier flow starts with payable orders and amount due.

Required structure:

- Default view is Payment Queue.
- Selecting an order opens Payment Execution.
- Payment Execution must prioritize amount due and method selection.
- Payment Execution may include all supporting actions required to complete payment: payment method selection, discount/coupon, menu cancellation, quantity adjustment, split payment, receipt printing, failed payment retry, proof attachment, and guest-requested red invoice capture.
- Missing/deferred proof, failed e-invoice, refund approval, void approval, correction/cancellation lifecycle, staff settlement, daily closing, sales reports, and operational monitoring are separate workflows.
- Daily summaries should be manager/closing views, not the default cashier work surface.

Do not:

- Mix payment execution with settlement reports.
- Show full tax/e-invoice diagnostics during normal checkout.
- Expose admin cancellation as a first-level cashier action unless the current user is explicitly in an exception flow.
- Split payment-completion supporting actions into separate screens when they are needed to finish the same checkout.

## Exception-First Manager Flow

Manager flow starts with what needs attention.

Required structure:

- Operational Monitoring should show unresolved exceptions by type and age.
- Daily Closing should show blockers first, close action second.
- Reports should analyze history and link to exceptions without becoming the exception workspace.
- Manager exception detail can expose raw IDs and audit data, but only after drill-in.

Exception types:

- Payment failed
- Refund/void review
- Missing proof
- E-invoice failed or stuck
- Delivery settlement dispute
- Inventory receiving blocker
- Low stock/out of stock
- Attendance/payroll exception
- QC follow-up
- Delayed kitchen order

## Dense Layout

POS density should support fast scanning, not visual heaviness.

Rules:

- Prefer lists, lanes, compact rows, and split workspaces.
- Keep repeated cards compact with consistent height.
- Avoid oversized hero sections in operating screens.
- Use whitespace to group work, not to create marketing-style composition.
- Keep KPI cards small and only show them when they affect the current decision.

## Large Touch Targets

Dense does not mean tiny.

Rules:

- Primary touch targets should be large enough for fast service use.
- Table tiles, kitchen ticket rows, payment method tiles, and queue rows should have stable dimensions.
- Icon-only controls need tooltips on desktop/tablet.
- Destructive actions need clear confirmation and should not sit next to high-frequency positive actions.

## Status Color Semantics

Use color as operating language, not decoration.

Recommended semantics:

- Green: ready, complete, available, safe to proceed
- Amber: waiting, needs review, unsent, low stock, warning
- Red: failed, blocked, delayed, void/refund risk, out of stock
- Blue: in progress, external/pending, cooking, syncing
- Neutral: closed, historical, inactive, no action needed

Rules:

- A color must mean the same thing across roles.
- Do not invent decorative color palettes per screen.
- Avoid more than one dominant alert color on a normal state screen.
- Use text and icon/state labels with color, not color alone.

## Fast Scanning Typography

Typography must support speed.

Rules:

- Large type is reserved for operational totals: amount due, ticket table number, closing status.
- Queue rows use compact, consistent text hierarchy.
- Avoid long explanatory paragraphs in live operator screens.
- Prefer concise labels: Ready, Cooking, Missing Proof, Failed Invoice.
- Do not use negative letter spacing.
- Do not scale font size with viewport width.

## Action Placement

Actions should live where the operator's hand and eye expect them.

Rules:

- Each screen has at most two primary visible actions.
- Primary action stays fixed in a predictable bottom/right area on tablet/desktop.
- Secondary actions go into overflow, drawer, or detail panel.
- Destructive actions are separated from primary actions.
- Queue rows can have one quick action only when it is the obvious next step.

Examples:

- Order Review: Send to Kitchen, Back to Edit
- Payment Execution: Pay Now, Back to Queue
- Kitchen Execution: Start Items, Mark Ready
- Daily Closing: Close Today, Review Blockers

## Split Workspace

Split workspace is allowed when each side has a clear job.

Recommended split patterns:

- Waiter: table/menu area + current cart
- Kitchen: queue lanes + selected ticket execution
- Cashier: payment queue + selected payment execution
- Admin: configuration list + selected config form
- Manager: exception queue + selected exception detail

Rules:

- The left side should usually be selection/queue.
- The right side should be execution/detail for one selected item.
- Avoid putting two unrelated execution modes side by side.
- On mobile, convert split workspace to sequential screens.

## Mobile / Tablet / macOS 대응

### Mobile

- Use one work step per full screen.
- Keep sticky bottom action bar for primary actions.
- Avoid dense multi-pane dashboards.
- Use modal/drawer only for short secondary detail.

### Tablet

- Use split workspace for queue/detail.
- Keep touch targets large.
- Use fixed action rails for payment/order/kitchen execution.
- Avoid too many tabs in a bottom nav.

### macOS / Desktop

- Use lanes, lists, and side panels.
- Support keyboard focus and hover tooltips.
- Keep global navigation visible but low emphasis during live work.
- Do not use desktop width to expose more unrelated workflows.

## No Decorative Color

Operating screens should not use color for decoration.

Rules:

- No gradient-heavy dashboards.
- No decorative blobs/orbs/background treatments.
- No screen-specific decorative palettes.
- Status color must map to operational meaning.
- Brand color can support navigation and primary action but should not overwhelm status semantics.

## No Card-Heavy Dashboard

Cards are useful for repeated operational items, not as a default page layout.

Allowed:

- Table tiles
- Kitchen tickets
- Payment queue rows
- Exception queue items
- Compact metric cards when directly tied to action

Avoid:

- Many large KPI cards before the work surface
- Nested cards inside cards
- Dashboard cards that only describe the system
- Report-style cards in live waiter/cashier/kitchen screens

## No Everything-On-One-Screen Pattern

This pattern is not acceptable for POS operation:

- Queue plus edit form plus report plus history plus settings plus diagnostics
- Order taking plus payment plus kitchen status plus cancellation
- Reports plus exceptions plus daily close
- Inventory catalog plus purchase orders plus receiving plus reports
- Staff directory plus attendance plus payroll plus permissions

Replacement pattern:

- Queue -> Select -> Act -> Optional Detail
- Configuration -> Select Area -> Edit -> Save
- Report -> Select Period -> Read -> Export
- Exception -> Select Item -> Resolve -> Audit Detail

## Primary Action Limit

At any visible moment:

- 1 primary action is ideal.
- 2 primary actions are allowed when the pair is natural.
- 3 or more dominant primary actions means the screen is mixing work steps.
- Supporting actions can remain visible or reachable when they complete the same primary job and are visually subordinate.

Secondary actions should move to:

- Overflow menu
- Detail drawer
- Expand section
- Confirmation modal
- Dedicated exception/configuration screen

## Screen Acceptance Checklist

Before approving a POS screen:

- The screen has exactly one purpose.
- The role is obvious.
- The operator question is visible in the layout.
- Default information is action-critical.
- Primary actions are limited to two.
- Secondary detail is hidden by default.
- Queue grouping is status-based.
- Execution area is for one selected item.
- Status colors follow the shared semantics.
- Mobile/tablet/desktop layouts do not expose extra workflows just because there is space.
- No backend or workflow contract change is required to implement the UI split.
