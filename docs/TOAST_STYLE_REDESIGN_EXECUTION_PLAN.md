# Toast-Style Redesign Execution Plan

This document defines the migration architecture and replacement strategy for moving the product to the Toast-style operating platform standard.

It does not authorize business logic, auth, permission, Supabase, i18n, route, or data-contract changes. It fixes the UI migration standard before broad screen refactors begin.

## 1. Current Legacy UI Inventory

| Legacy item | Current role | Why it conflicts with Toast standard | Migration target | Removal timing |
|---|---|---|---|---|
| `AppTheme` | Global Material theme and compatibility styling. | Still carries older global surface, card, chip, dialog, and admin-template assumptions. | Toast platform theme backed by shared operating tokens. | Phase 1 replacement, compatibility aliases removed in Phase 6. |
| `AppColors` | Shared color constants used across legacy screens. | Encourages old dark/admin and amber-first styling instead of a unified light-first operating palette. | Toast semantic tokens for canvas, surface, border, text, status, and workflow states. | Phase 1 deprecate, Phase 6 delete or keep as non-UI compatibility only. |
| `AppPanel` | Generic bordered panel wrapper. | Keeps panel-heavy layout as a default mental model. | `ToastWorkSurface`, `ToastSplitPane`, `ToastDenseList`, and form/dialog primitives. | Phase 3 replace usage, Phase 6 delete. |
| `SectionCard` | Local repeated section card pattern. | Reinforces card-heavy dashboards and decorative grouping. | Section rows, split panes, dense tables, and workflow headers. | Phase 3 replace, Phase 6 delete. |
| `KPIStatCard` | KPI summary card used by dashboards and reports. | Makes KPI-first dashboard layout the default instead of action queues. | Compact metric rows inside `ToastWorkflowHeader` or report tables. | Phase 3 replace, Phase 6 delete. |
| `SummaryBar` | Horizontal summary/KPI strip. | Prioritizes passive summaries over pending/action-first hierarchy. | `ToastFilterBar`, `ToastQueueTable`, and action-state summaries. | Phase 3 replace, Phase 6 delete. |
| Old `AppShell` | Existing shell/navigation container pattern. | Treats old shell structure as mandatory and blocks platform IA redesign. | `ToastShell` with unified Office/POS/Admin navigation and context bars. | Phase 2 replace, Phase 6 delete. |
| Dark sidebar | Legacy admin navigation chrome. | Directly conflicts with light-first operating shell and unified platform language. | `ToastSidebar` with light surface, dense nav, clear active states. | Phase 2 replace. |
| Browser-like POS topbar | Back/forward/home-style POS runtime chrome. | Feels like browser/tablet navigation instead of operations workflow control. | `ToastTopbar` with store, station, role, status, and primary actions. | Phase 2 replace. |
| Old nav grouping | Feature-tab grouping by legacy admin screens. | Preserves old IA instead of workflow and pending/action-first grouping. | Workflow grouping for POS and Office navigation. | Phase 2 replace. |
| Panel/card-heavy layout | Default dashboard/admin composition. | Creates low-density decorative surfaces and hides action priority. | Tables, queues, split panes, dense lists, and action rails. | Phase 3 and Phase 4 replace. |
| Tablet-first POS layout | Large controls and kiosk/tablet visual treatment. | POS must be tablet-compatible, not tablet-designed. | Enterprise operations console optimized for speed and density. | Phase 4 replace. |
| Floor-canvas assumptions | Table map fixed around visual canvas/table cards. | Locks tables into a spatial card UI when queue/list/detail may be faster. | Toast table map, queue, list/detail split, or hybrid workflow. | Phase 4 replace where workflow benefits. |
| Old dialog/form/table primitives | Per-screen styling and inconsistent density. | Fragments component language and creates admin-template remnants. | `ToastDialog`, `ToastCompactForm`, `ToastQueueTable`, `ToastDenseList`. | Phase 3 replace, Phase 6 delete. |

## 2. New Toast Platform Architecture

The new platform primitives are shared across Office, POS, and Admin. Domain boundaries remain in data, permissions, and workflows, not in visual language.

### `ToastShell`

The top-level operating platform frame. It owns responsive layout, navigation regions, top context, and stable work-surface placement.

### `ToastSidebar`

Light-first dense navigation for operational workflows. It supports role-aware visibility, clear selected states, compact section grouping, and pending/action indicators.

### `ToastTopbar`

Context and action bar for store, station, role, status, language, offline state, and primary workflow actions. It replaces browser-like POS navigation.

### `ToastWorkSurface`

Primary content container for operational work. It favors thin borders, low shadow, stable density, table/list readability, and clear action placement.

### `ToastQueueTable`

Dense queue/table primitive for orders, payments, kitchen, inventory, staff attendance, QC reviews, reports, and operational task lists.

### `ToastSplitPane`

Master/detail or queue/detail layout primitive for workflows where users scan one side and act on the other.

### `ToastActionRail`

Compact vertical or horizontal action zone for primary, secondary, destructive, and quiet actions.

### `ToastCompactForm`

Dense form primitive with consistent field height, label hierarchy, validation, disabled state, and localized text behavior.

### `ToastStatusBadge`

Shared status badge for order, payment, kitchen, inventory, attendance, QC, auth, and operational states.

### `ToastWorkflowHeader`

Header for the current operational job. It shows title, context, status, filters, and top-priority actions without becoming a KPI-first dashboard.

### `ToastDenseList`

High-readability row/list primitive for staff, inventory, menu, table, payment, and settings surfaces.

### `ToastFilterBar`

Compact filter/search/sort/status control strip for operational tables and queues.

### `ToastDialog`

Shared modal/dialog primitive for confirmation, payment, editing, upload, refund, QC review, settings, and destructive actions.

## 3. Preserve vs Replace Matrix

| Preserve | Replace |
|---|---|
| business logic | shell |
| auth | navigation |
| permissions | tokens |
| Supabase | spacing |
| route paths where possible | typography |
| i18n | radius |
| data contracts | elevation |
| state transitions | card/panel structure |
| calculations | workflow layout |
| RLS behavior | menu IA |
| provider behavior | POS runtime chrome |
| realtime subscriptions | queue/table/detail surface |

## 4. Navigation IA Redesign

Navigation is organized around operational jobs, not implementation features. Feature grouping is forbidden as the primary IA model when it obscures action priority.

### POS Navigation

- Orders
- Tables
- Payments
- Kitchen
- Inventory
- Staff
- Reports
- Settings

### Office Navigation

- Operations
- Accounting
- HR
- Inventory
- Quality
- Reports
- Admin

### Grouping Philosophy

- Prefer workflow grouping over feature grouping.
- Prefer pending/action-first hierarchy over passive module lists.
- Separate manager review workflows from operator execution workflows.
- Keep dense operational navigation with clear active, selected, disabled, and permission-hidden states.
- Preserve role and permission behavior while allowing menu labels, order, grouping, and nesting to change.

## 5. Work Surface Philosophy

Operational screens must answer: what needs action now?

Do not lead with dashboard-first or KPI-first composition. Metrics can support decisions, but they should not displace queues, exceptions, worklists, and current operational state.

Prefer:

- action queue 중심
- split-pane 중심
- list/detail workflow 중심
- compact density
- scanability 우선
- status-first rows
- primary action clarity
- stable table/list row heights

Avoid:

- decorative overview dashboards as the default
- KPI-first summary bars as the main surface
- oversized cards for ordinary operational rows
- panel-heavy composition that fragments the workflow
- large empty surfaces without actionable state

## 6. POS Runtime Redesign

### Current Problems

- kiosk/tablet 느낌
- browser-like navigation
- oversized controls
- card-heavy ordering
- floor/table UI that can over-prioritize spatial cards over action speed
- payment/order surfaces that can feel like separate screens instead of one fast workflow

### New Standard

POS runtime must feel like an enterprise operations console for fast service, not a consumer tablet app.

The POS runtime should provide:

- fast ordering workflow
- dense product access
- ticket rail
- split order/payment workflow
- visible table/order/payment/kitchen state
- operator speed priority
- manager-readable exceptions and statuses
- tablet compatibility without tablet-designed visual language

The order workflow should make the next action obvious: select table/order, add products, review ticket, send to kitchen, collect payment, print or issue receipt, and resolve exceptions.

## 7. Migration Order

### Phase 1

- tokens
- typography
- spacing
- shell primitives

### Phase 2

- navigation
- topbar
- sidebar
- workflow headers

### Phase 3

- shared components
- forms
- dialogs
- tables
- lists
- badges

### Phase 4

- POS order workflow
- payments
- kitchen
- inventory

### Phase 5

- Office workflows
- HR
- accounting
- reports
- admin

### Phase 6

- legacy cleanup

## 8. Legacy Cleanup List

Final deletion or hard deprecation targets:

- `AppPanel`
- `SectionCard`
- `KPIStatCard`
- `SummaryBar`
- dark shell tokens
- old sidebar layout
- browser-like POS nav
- legacy spacing/radius/shadow system
- old AppShell-as-mandatory-structure assumptions
- old menu grouping as fixed IA
- per-screen dialog/form/table styling clusters

## 9. Validation Checklist

Before each migration phase is accepted, verify:

- no legacy shell
- no dark admin chrome
- no card-heavy dashboard
- no old nav grouping
- Office/POS visual consistency
- dense operational workflow
- i18n preserved
- permissions preserved
- Supabase preserved
- route stability maintained where possible
- auth behavior unchanged
- state transitions unchanged
- data contracts unchanged
- responsive desktop and tablet usability preserved

## 10. PASS Criteria

The migration passes only if the product clearly reads as a Toast-style operating platform:

- operational
- dense
- fast
- queue-driven
- workflow-centric
- light-first
- unified Office/POS/Admin language
- minimal decorative surfaces
- high scanability
- clear action hierarchy
- clear selected and active states
- consistent status language

The acceptance question is: does this look and behave like one unified restaurant operations platform for staff and managers, rather than a legacy admin template, kiosk app, or collection of unrelated modules?
