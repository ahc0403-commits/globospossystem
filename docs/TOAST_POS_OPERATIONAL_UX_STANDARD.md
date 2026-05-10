# Toast POS Operational UX Standard

## Verdict

The current POS UX must move from a feature, CRUD, tablet-app, and menu-browsing model to a Toast-style operational workflow model.

POS is not a kiosk app. POS is not a consumer ordering UI. POS is an enterprise operations console for live restaurant execution.

The standard for every major POS screen is: what is waiting, what is blocked, what is delayed, what is unpaid, what is ready for the next operator action, and what must be resolved now.

## 1. Core POS Philosophy

POS exists to keep service moving under pressure. Its primary job is not browsing, configuration, or passive reporting. Its primary job is fast operational continuation across order entry, table state, kitchen prep, payment, and inventory constraints.

Priority order:

1. Speed
2. Queue
3. Urgency
4. Payment flow
5. Kitchen flow
6. Table state
7. Operator scanning

The POS interface must help staff scan current work quickly, continue an active workflow without losing context, and resolve exceptions before they affect service quality.

The default mental model is not "open a module and manage records." The default mental model is "select the next operational item, inspect status, take action, and continue."

## 2. Order Workflow UX

### Current Problem

The existing order experience is too close to menu browsing and grid-heavy product selection. That creates a consumer-ordering feel and slows down operator awareness when the restaurant is busy.

Problems to avoid:

- menu browsing as the first screen priority
- product grid as the dominant layout
- weak active-ticket hierarchy
- hidden payment readiness
- weak queue awareness
- unclear kitchen state after items are added

### New Standard

Order UX must be active-ticket centered.

The operator should always understand:

- which ticket is active
- what was added most recently
- what still needs modifier or quantity confirmation
- what has been sent to kitchen
- what is pending kitchen action
- whether the order is ready for payment
- whether the table has unpaid, split, failed, or delayed payment state

Required order workflow structure:

- left side: active queue, table/order list, or open tickets
- right side: selected ticket detail and next actions
- inline item actions for quantity, modifier, void, hold, send, and payment preparation
- persistent visibility of payment readiness and kitchen dispatch state
- rapid add flow that does not erase ticket context
- queue awareness for waiting, delayed, unpaid, and active tickets

The menu/product area supports the ticket workflow. It must not become the primary mental model of the POS.

## 3. Table UX

The table map is not a decorative floorplan. It is an operational state surface.

Table UX must prioritize:

- occupied
- waiting
- delayed
- unpaid
- merge/split
- issue

The operator should be able to scan the floor and immediately know which tables need action.

Table state must be stronger than spatial decoration. Floor position can help orientation, but the UI must first communicate service state, blockers, and next action.

Required table behavior:

- occupied tables show current order/payment/kitchen status
- waiting tables show age and urgency
- delayed tables are visually escalated
- unpaid tables are always discoverable
- merge and split workflows are direct, visible, and recoverable
- issue tables expose the reason, not only a generic warning

If a table map makes the floor look nice but hides operational urgency, it is the wrong UX.

## 4. Kitchen UX

Kitchen UX must be queue-first and exception-first. It should not behave like a passive list of tickets.

Priority order:

1. Delayed tickets
2. Blocked prep
3. SLA risk
4. Prep priority
5. Next action

Kitchen screens must answer:

- what is late
- what is about to be late
- what cannot be prepared
- what needs staff attention
- what should be prepared next
- what was changed or voided after dispatch

Required kitchen structure:

- delayed and SLA-risk tickets are surfaced above normal flow
- blocked prep includes reason, affected items, and resolution path
- ticket rows show elapsed time and prep priority
- next action is explicit: start, hold, bump, recall, mark ready, resolve blocker
- order changes are visible without forcing staff to open multiple screens

Kitchen UX is successful when the team can see risk before guests feel it.

## 5. Payment UX

Payment UX must be pending-first and failure-first. Payment is not a final modal at the end of ordering; it is an operational queue that affects table turnover and closeout.

Priority order:

1. Pending payments
2. Failed settlements
3. Retry queue
4. Unpaid tables
5. Split payment issues

The payment workspace must show:

- which tables or orders are unpaid
- which payments are pending
- which settlements failed
- which transactions need retry
- which split payments are incomplete
- what action is available now

Required payment structure:

- unpaid and failed states are visible before completed history
- retry actions are inline when safe
- split payments show payer/item/share completion state
- payment readiness is visible from order and table workflows
- payment failures preserve service continuity and expose recovery actions

Payment UX must reduce cashier hesitation. It must not bury failed or incomplete payments under reports, history, or generic dashboards.

## 6. Inventory UX

Inventory UX in POS is not a CRUD admin screen. It is an operational constraint system that protects ordering and prep.

Priority order:

1. Low stock
2. Blocked prep
3. Supplier issue
4. Incoming receiving
5. Purchase approval

The inventory workflow must show:

- what is low now
- what blocks menu availability or kitchen prep
- what supplier issue affects service
- what incoming stock needs receiving
- what purchase request needs approval
- what menu items should be limited, hidden, or marked unavailable

Required inventory structure:

- low-stock and blocked-prep queues first
- supplier and receiving exceptions visible in the same operational frame
- purchase approval tied to service impact, not only admin status
- menu availability impact shown inline
- record editing secondary to resolving stock risk

Inventory screens must help operators prevent service failure, not merely maintain item records.

## 7. Sidebar UX

The sidebar is an operational action system, not a static module directory.

Sidebar priorities:

- action-first
- pending-first
- urgency-first

Required sidebar behavior:

- navigation items may show pending counts, blocked states, and urgent alerts
- urgent work is visible without opening every screen
- labels should describe operational jobs, not implementation entities
- active workflow state must be clear
- permission rules remain binding, but visible items should be ordered by operational usefulness

Recommended POS sidebar groups:

- Orders
- Tables
- Payments
- Kitchen
- Inventory
- Staff
- Reports
- Settings

Counts and alerts should represent operational work, not vanity metrics.

## 8. Metric UX

Metrics in POS are not primarily KPI cards. They are operational signals.

Metrics should represent:

- operational signal
- alert
- queue load
- blocked state
- overdue action

Examples of valid POS metrics:

- unpaid tables
- delayed kitchen tickets
- pending payments
- failed settlements
- low-stock blockers
- waiting table age
- queue load by station
- overdue approvals

Examples of weak POS metrics:

- large passive revenue cards at the top of execution screens
- decorative KPI summaries that do not change operator action
- dashboard-only metrics that hide the current queue

Metric UX must answer "what should staff do next?" If a metric does not change action priority, it belongs in reporting, not the operational surface.

## 9. Queue-First Layout

All major POS screens must use a queue-first operating layout.

Default structure:

- left = queue/list
- right = detail/action
- inline action
- operator continuation

This applies to:

- order workspace
- table workflow
- kitchen queue
- payment flow
- inventory workflow
- staff execution surfaces
- exception review screens

The queue/list side is for scanning, selecting, filtering, and prioritizing. The detail/action side is for resolving the selected item without losing queue context.

Inline actions should handle frequent work directly in the row when the action is safe, reversible, or low-risk. Large modal interruptions should be reserved for genuinely complex, destructive, or legally significant workflows.

## 10. Deprecated UX Patterns

The following patterns are deprecated for POS operational UX:

- menu browsing first
- giant grids
- decorative floorplan
- passive dashboards
- CRUD inventory admin
- browser-like POS flow
- giant modals
- low-density lists

These patterns may exist temporarily during migration, but they are not design references for new or redesigned POS workflows.

Deprecated does not mean every old screen must be removed immediately. It means future POS work must not strengthen these patterns, and migration should steadily replace them with queue-first, workflow-first operational surfaces.

## 11. Migration Priorities

Migration must proceed in operational-impact order.

1. Order workspace
2. Table workflow
3. Kitchen queue
4. Payment flow
5. Inventory workflow
6. Sidebar urgency model
7. Metrics/action signals

### 1. Order Workspace

Rebuild the order workspace around active tickets, rapid add, kitchen dispatch state, and payment readiness.

### 2. Table Workflow

Convert table UX from decorative floorplan behavior into state-first service management with unpaid, delayed, waiting, merge/split, and issue visibility.

### 3. Kitchen Queue

Prioritize delayed tickets, SLA risk, blocked prep, and next actions before normal ticket display.

### 4. Payment Flow

Surface unpaid, pending, failed, retry, and split-payment states as an operational queue.

### 5. Inventory Workflow

Move inventory from record administration toward low-stock, prep-blocking, receiving, supplier, and approval workflows.

### 6. Sidebar Urgency Model

Add pending counts, blocked states, urgent alerts, and action-first ordering to POS navigation.

### 7. Metrics/Action Signals

Replace KPI-first cards with operational signals that directly affect queue priority and staff action.

## Core UX Principles

The POS must feel like a live service control room:

- every screen starts from current work
- every workflow preserves operator context
- every queue makes urgency visible
- every exception exposes a next action
- every metric supports operational prioritization
- every table, ticket, payment, kitchen, and stock state is scannable

The strongest POS screen is not the one with the most complete module UI. It is the one where a busy operator can immediately see what matters and continue service without hesitation.

## Deprecated POS UX Summary

Do not use consumer ordering, kiosk, browser, or passive admin mental models as POS targets.

Deprecated POS UX includes:

- browsing before ticket action
- product grids before active ticket context
- floorplan visuals before service state
- dashboards before work queues
- CRUD tables before stock risk
- modal-heavy action flows
- low-density decorative cards
- reports disguised as operations

## Workflow-First Structure

Every POS workflow should follow this structure:

1. Show the operational queue.
2. Highlight urgency, blockers, and overdue work.
3. Let the operator select an item without losing queue context.
4. Show detail and next action in the same workspace.
5. Complete or defer the action inline where possible.
6. Return the operator to the next highest-priority item.

This structure is binding for POS redesign unless a specific workflow has a documented reason to deviate.

## Migration Priority Summary

The first migration target is the order workspace because it is the highest-frequency operational surface and anchors table, kitchen, and payment flow. Table, kitchen, and payment should follow because they determine guest wait time, service recovery, and turnover. Inventory comes next because low stock and blocked prep directly affect order execution. Sidebar and metrics are then aligned so the shell itself becomes urgency-aware instead of module-first.
