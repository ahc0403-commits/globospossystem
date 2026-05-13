# Office Operational UI Redesign Master Plan

## Purpose

This plan starts after legacy UI standards are re-audited and locked down.
Its job is to sequence Office UI redesign work without reopening backend,
runtime, or contract scope.

Primary authority:

- [Toast Operational UI Source of Truth](TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md)

Audit prerequisite:

- [Legacy UI Standards Re-Audit](LEGACY_UI_STANDARDS_REAUDIT.md)

## Guardrails

- No backend/runtime/RLS/Supabase mutation redesign is authorized here.
- Preserve business logic, permissions, auth, i18n, and route continuity where
  possible.
- Treat widget names and old shell names as replaceable implementation details.
- Judge redesign work by workflow behavior, not by whether it reuses a specific
  class name.

## Phase 0: Standard Lock

- keep the source of truth single and explicit
- keep deprecated standard documents non-authoritative
- treat pre-lock redesign/recovery slice docs as archival context only
- ensure feature plans link back to the active Office source-of-truth document

Exit condition:

- only `docs/office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md` is the active UI
  standard

## Phase 1: Workflow Reframe

Map each Office surface into:

1. queue
2. selected context
3. primary actions
4. optional supporting detail

Questions every redesign slice must answer:

- what is the queue
- what is selected
- what action happens now
- what detail is genuinely secondary

## Phase 2: Shell And Navigation

- unify Office shell behavior with the shared operational model
- remove dashboard-first and CRUD-first framing
- make navigation role-aware, queue-aware, and dense
- expose status and priority without making summary cards the primary surface

## Phase 3: Shared Surface Patterns

- standardize tables, dense lists, split panes, badges, filters, dialogs, and
  action areas
- keep metrics in supporting positions only
- keep detail panels subordinate to queue and action flow

## Phase 4: Screen Rollout

Apply redesign slices screen-by-screen in the safest order:

1. highest-frequency operational queues
2. approval and review workflows
3. reporting or audit surfaces that still need operator action
4. settings and lower-frequency utilities

Each slice must stay independently reviewable and must pass the acceptance
checklist before the next slice starts.

## Phase 5: Validation And Cleanup

- re-run repo search for legacy UI standards
- confirm deprecated documents did not regain active authority
- confirm new feature plans still point to the active source of truth
- run `flutter analyze` and `flutter test`

## Done Definition

The redesign foundation is ready only when:

- the active standard is singular
- Office workflows clearly follow Queue -> Select -> Act -> Optional Detail
- no active document tells implementers to follow dashboard/KPI/card-heavy/dark
  admin baselines
- validation passes without backend or runtime contract drift
