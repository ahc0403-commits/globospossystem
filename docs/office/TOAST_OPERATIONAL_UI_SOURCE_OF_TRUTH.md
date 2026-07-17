# Toast Operational UI Source of Truth

## Authority

This document is the single active UI source of truth for Office, POS, and
Admin operational redesign work in this repository.

Use this document first. Treat the following older documents as historical or
deprecated only:

- `docs/TOAST_STYLE_OPERATING_PLATFORM_STANDARD.md`
- `docs/TOAST_POS_OPERATIONAL_UX_STANDARD.md`
- `docs/TOAST_STYLE_REDESIGN_EXECUTION_PLAN.md`
- `docs/ui_ux_operational_refresh_plan.md`
- `docs/TOAST_SHELL_TRUTH_UP_2026_05_10.md`

Pre-lock redesign and recovery slice documents from `2026-05-12` remain
archival provenance only. They may inform scope history, but they do not define
today's UI baseline.

Companion documents:

- [Legacy UI Standards Re-Audit](LEGACY_UI_STANDARDS_REAUDIT.md)
- [Office Operational UI Redesign Master Plan](OFFICE_OPERATIONAL_UI_REDESIGN_MASTER_PLAN.md)
- [Office Operational UI Acceptance Checklist](OFFICE_OPERATIONAL_UI_ACCEPTANCE_CHECKLIST.md)

## Non-Negotiable Boundaries

Preserve:

- business logic and workflow semantics
- auth, permission, and route behavior where possible
- backend/runtime/RLS/Supabase mutation behavior
- i18n behavior and copy correctness
- data contracts, calculations, and persistence semantics

Redesign:

- information architecture
- navigation and shell composition
- visual hierarchy and density
- shared UI primitives, tokens, and interaction patterns

## Core Interaction Model

Every operational surface must follow this order:

1. Queue
2. Select
3. Act
4. Optional Detail

Interpretation:

- Queue comes first. The operator must see what needs attention now before
  seeing rich detail.
- Select comes second. The chosen row, job, ticket, exception, or store context
  must stay obvious.
- Act comes third. The next safe action must be visible without hunting through
  decorative sections.
- Optional Detail comes last. Detail supports the action; it does not displace
  the queue or primary action path.

## Operational UI Rules

- Prefer queue, list, table, split-pane, and detail-sidecar workflows.
- Keep metrics subordinate to the active queue or selected work item.
- Use one light-first operational language across Office, POS, and Admin.
- Favor dense but readable surfaces over decorative whitespace.
- Keep status, urgency, disabled, loading, empty, error, and offline states
  explicit and shared.
- Treat component names as implementation details. Behavior and hierarchy are
  authoritative; a specific widget name is not.

## Visual Design Rules

- Use a high-contrast light palette with dark text as the default operating
  baseline.
- Keep canvas, work surface, and selected-state contrast visually distinct
  through shared tokens rather than screen-local color invention.
- Use the shared accent color consistently for primary interactive elements and
  reserve success, warning, danger, and info colors for semantic state.
- Meet WCAG AA contrast targets for text and key UI communication surfaces.
- Do not rely on color alone to convey meaning; pair state color with labels,
  badges, icons, or other explicit signals.

## Legacy Patterns That Are Forbidden As Standards

Do not use any of the following as active design standards, source documents,
or baseline references:

- dashboard-first composition
- KPI-first composition
- card-heavy default layouts
- panel-heavy admin layouts
- dark admin shell as the baseline
- tablet-first or kiosk-first visual language as the baseline
- browser-like POS chrome as the baseline
- CRUD-first workspace structure
- old menu grouping as fixed IA
- `AppShell`, `TopContextBar`, `AppColors`, or similar symbols as mandatory UI
  standards
- separate Office/POS/Admin visual languages

## Current Code Reality Notes

Current runtime code still contains a mix of older and newer UI helpers. Those
symbols are implementation facts, not standard-setting authority.

Examples confirmed during this re-audit:

- `ToastShell` and `ToastTopbar` exist in
  `lib/core/ui/toast/toast_primitives_extended.dart`.
- `ToastShell` is used by
  `lib/features/auth/login_screen.dart`,
  `lib/features/onboarding/onboarding_screen.dart`,
  `lib/core/layout/web_sidebar_layout.dart`, and
  `lib/features/photo_ops/photo_ops_screen.dart`, and
  `lib/features/payment/payment_detail_screen.dart`.
- `ToastSidebar` plus `WebSidebarLayout` still define the tracked admin shell.
- `AppShell` still exists in `lib/core/ui/app_primitives.dart` as a retained
  compatibility primitive for tracked runtime paths. It is not the active
  shell for `lib/features/payment/payment_detail_screen.dart`.

None of the above symbols, by themselves, define the redesign standard.

## Redesign Gate

No Office redesign PR should claim compliance unless it also passes
[Office Operational UI Acceptance Checklist](OFFICE_OPERATIONAL_UI_ACCEPTANCE_CHECKLIST.md).
