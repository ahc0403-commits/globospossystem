# Toast-Style Operating Platform Standard

## 1. Purpose

This document is the top-level UI standard for the GLOBOSVN operating platform. It defines the visual, navigation, shell, and component direction for Office, POS, and Admin operational surfaces.

The goal is a light-first Toast-style B2B restaurant operations console optimized for fast ordering, store operations, manager review, inventory, staff, QC, reporting, and settings workflows. This is a product-quality benchmark, not a direct copy of Toast UI.

## 2. Source of Truth Priority

1. Business logic, permissions, auth, route paths where possible, i18n, Supabase contracts, and data contracts remain binding.
2. This Toast-style operating platform standard is the binding UI source of truth.
3. Existing screen layouts, old shell structure, old menu grouping, and legacy card/panel styling are not binding UI references.
4. Older documents that describe dark/admin-template or tablet/kiosk visual language are deprecated when they conflict with this standard.

## 3. Preserve vs Redesign Boundaries

Preserve:

- business logic and workflow state transitions
- auth and permission behavior
- RLS and Supabase integration
- route paths where possible
- i18n behavior and localized UI copy
- data contracts, calculations, and persistence semantics

Redesign:

- UX structure
- menu information architecture
- shell and navigation
- visual system and design tokens
- shared buttons, forms, tables, dialogs, badges, lists, and panels
- screen layout density and hierarchy
- workflow-specific action placement

## 4. Office/POS/Admin Unified Platform Principle

Office, POS, and Admin are one operating platform. Their data and responsibility boundaries may differ, but their visual language, operating shell, component system, spacing, badge semantics, form styling, table styling, and navigation logic should be unified.

Deliberry and other domain-specific flows keep their business boundaries. Those boundaries do not imply a separate visual system unless explicitly required by the workflow.

## 5. POS Runtime Principle

POS runtime is not a kiosk app and not a consumer tablet app. It is a fast B2B ordering and store-operations console.

POS screens should prioritize:

- rapid table/order/payment scanning
- dense but readable order entry
- clear unpaid, partial, paid, failed, refunded, preparing, ready, completed, and cancelled states
- obvious primary actions
- low-friction staff workflows
- manager-friendly operational visibility

Touch targets must remain usable, but tablet-first/kiosk visual language is not the default POS admin style.

## 6. Navigation IA Principle

Old menu grouping is not fixed IA. Navigation may be redesigned around operational jobs:

- service floor and table operations
- order entry and tickets
- cashier and payments
- kitchen production
- menu and availability
- inventory and purchasing
- staff and attendance
- QC and reviews
- reports and settings

Role and permission visibility must remain correct, but menu grouping, labels, nesting, and section order may change when it improves operational clarity.

## 7. Shell Principle

All operational surfaces should use one light-first Toast-style operations shell.

The shell should provide:

- store and workstation context
- role-aware navigation
- concise operational status
- primary workflow actions
- clear selected and active states
- compact top/context bars
- dense, stable content regions

Browser-like POS navigation, old AppShell requirements, dark admin sidebar defaults, and separate Office/POS visual shells are deprecated.

## 8. Work Surface Principle

Work surfaces should be designed for operations, not marketing or decorative dashboard presentation.

Prefer:

- tables and dense lists
- split panes
- action rails
- queue views
- compact forms
- status-first rows
- workflow headers
- low-shadow bordered surfaces

Use cards only when they represent repeated objects that benefit from object framing. Do not use card-heavy dashboards or panel-heavy admin layouts as the default.

## 9. Component Principle

Shared components should express the Toast-style operating platform standard:

- thin borders
- light-first white and warm-neutral surfaces
- minimal shadows
- radius generally 6-10px for operational surfaces
- pill radius only for badges
- clear active, selected, disabled, loading, empty, error, and offline states
- readable table rows and list rows
- strong status badges
- action hierarchy with primary, secondary, danger, and quiet actions

Component aliases may exist for migration safety, but new and migrated UI should use the current operating-platform primitives.

## 10. Deprecated Legacy Patterns

The following patterns are deprecated and must not be used as mandatory references for new or migrated UI:

- dark admin sidebar
- dark operational shell
- card-heavy dashboards
- panel-heavy admin layouts
- KPI-first summary bars
- oversized rounded cards
- heavy shadows
- browser-like POS navigation
- tablet/kiosk visual language as default POS admin style
- OrderWorkspace-only Toast exception
- old AppShell as mandatory structure
- old menu grouping as fixed IA
- Office/POS visually separated product language

## 11. Validation Checklist

Before accepting a UI migration, verify:

- Office/POS/Admin surfaces follow one Toast-style operating platform standard.
- The screen no longer treats legacy dark/admin-template UI as the visual baseline.
- The screen no longer depends on tablet/kiosk styling as the default admin/POS style.
- Business logic, permissions, auth, i18n, data contracts, route paths where possible, and Supabase behavior are preserved.
- Menu IA, shell, navigation, and component changes are intentionally redesigned for operational clarity.
- Tables, rows, badges, buttons, forms, dialogs, loading, empty, error, and offline states use shared platform primitives or token-compatible equivalents.
- Dense operational readability is maintained on desktop and tablet.
- The design avoids card-heavy dashboards, oversized rounded surfaces, heavy shadows, and browser-like POS controls unless explicitly justified by the workflow.
