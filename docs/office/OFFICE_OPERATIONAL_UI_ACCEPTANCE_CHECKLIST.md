# Office Operational UI Acceptance Checklist

Use this checklist for every Office UI redesign PR.

Primary authority:

- [Toast Operational UI Source of Truth](TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md)

## Source-Of-Truth Gate

- [ ] The PR cites `docs/office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md` as the
      active UI standard.
- [ ] No deprecated UI standard document is presented as active guidance.
- [ ] Any feature-specific plan still points back to the active Office source
      of truth.

## Workflow Gate

- [ ] The surface is queue-first.
- [ ] The selected item or context remains explicit.
- [ ] Primary actions are visible without opening decorative detail first.
- [ ] Optional detail stays subordinate to queue and action flow.
- [ ] Dashboard/KPI panels, if present, support action and do not lead the
      layout.

## Visual Gate

- [ ] The surface follows one light-first operational language.
- [ ] Dense tables, lists, split panes, or comparable operational surfaces are
      preferred over card-heavy or panel-heavy defaults.
- [ ] Status, urgency, loading, empty, error, disabled, and offline states are
      explicit and consistent.
- [ ] Old dark-admin, tablet-first, kiosk-first, or browser-like chrome is not
      the baseline visual reference.

## Non-Regression Gate

- [ ] Business logic is unchanged.
- [ ] Auth and permissions are unchanged.
- [ ] Backend/runtime/RLS/Supabase mutation behavior is unchanged.
- [ ] Data contracts and calculations are unchanged.
- [ ] i18n behavior and route continuity remain correct where expected.

## Search Gate

- [ ] Repo search does not leave dashboard/KPI/card-heavy/AppShell/dark/admin
      shell/CRUD-first standards active outside deprecated or historical
      context.
- [ ] Any remaining non-archive keyword hit is either an explicit anti-baseline
      warning or a retained implementation symbol, not a source-of-truth file.
- [ ] `source of truth` for Office UI resolves back to the Office source-of-
      truth document, not to an older standard file.

## Verdict Rule

- PASS only when legacy UI standards remain in deprecated/history/archive
  context, or are called out only as forbidden patterns / retained
  implementation symbols, and the active redesign guidance is singular.
- FAIL when any active file still instructs UI work through dashboard/KPI/card-
  heavy/AppShell/dark/admin-shell/CRUD-first baseline rules.
