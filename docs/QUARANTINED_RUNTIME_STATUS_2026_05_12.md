# ARCHIVE — Quarantined Runtime Status — 2026-05-12

This file is preserved as pre-lock recovery evidence only.

Do not use it as the current UI standard or redesign entry point.

Use these documents instead:

- [Toast Operational UI Source of Truth](office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md)
- [Office Operational UI Redesign Master Plan](office/OFFICE_OPERATIONAL_UI_REDESIGN_MASTER_PLAN.md)
- [Legacy UI Standards Re-Audit](office/LEGACY_UI_STANDARDS_REAUDIT.md)

Historical note:

- keep this file for provenance around the quarantined-runtime classification
  pass

## Verdict

None of the remaining quarantined runtime Flutter files should be restored as-is.

The runtime WIP set is not a safe restore slice. It belongs in one of these
three lanes instead:

1. `archive`
2. `redesign`
3. `staged_reimplementation`

## Baseline

- Branch at time of audit: `audit/quarantined-runtime-status`
- Tracked repo state:
  - `git status --short`: clean before this docs-only change
  - `flutter analyze`: PASS
  - `flutter test`: PASS
- Scope:
  - docs-only audit
  - no runtime restore
  - no SQL restore
  - no test restore

## Runtime Inventory

Quarantined runtime files:

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/admin/providers/admin_sidebar_signal_provider.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/inventory_purchase/inventory_purchase_provider.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/inventory_purchase/inventory_purchase_screen.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/inventory_purchase/inventory_purchase_service.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/payment/payment_detail_screen.dart`

Related failed-restore quarantine:

- `/Users/andreahn/globos_pos_system_failed_runtime_slice_2026_05_12`

## File 1: `payment_detail_screen.dart`

### Current reading

- defines a full-screen payment detail workflow
- depends on:
  - `paymentService.fetchPaymentDetail(...)`
  - `einvoiceService.resendInvoiceEmail(...)`
  - POS/Toast UI primitives from `app_primitives.dart`
  - navigation shell components such as `AppNavBar`

### Known failure evidence

Previous runtime restore trial already failed during `flutter analyze`.

Primary blockers recorded earlier:

- missing POS/Toast UI primitives in current tracked runtime surface
- service/API drift around `resendInvoiceEmail`
- no tracked router mount / cashier navigation path

### Status

- classification: `redesign_or_staged_reimplementation`
- restore decision: `NO-RESTORE`

## Files 2–4: `inventory_purchase_*`

### Current reading

The inventory purchase trio is substantial and internally connected:

- `inventory_purchase_service.dart`
  - depends on `pdf`, `printing`, `shared_preferences`
  - implements purchase-order, dashboard, audit, and reporting behaviors
- `inventory_purchase_provider.dart`
  - builds a dedicated state management layer over the service
- `inventory_purchase_screen.dart`
  - mounts a large mobile/desktop workflow using POS/Toast primitives and
    admin-scoped store state

### Known failure evidence

Previous runtime restore trial failed during `flutter analyze`.

Primary blockers:

- missing UI primitives in current tracked runtime surface
- missing package/dependency alignment for `pdf` / `printing`
- no tracked admin-shell mount for this feature
- unresolved SQL/runtime lineage behind inventory purchase contracts

### Status

- classification: `staged_reimplementation_only`
- restore decision: `NO-RESTORE`

These files are too large and too cross-cutting to be treated as a tiny restore
candidate.

## File 5: `admin_sidebar_signal_provider.dart`

### Current reading

- computes admin QC, delivery, and inventory alert counts
- imports:
  - tracked QC service
  - tracked delivery models
  - quarantined `inventory_purchase_service.dart`

### Interpretation

This file has little standalone value because:

- it depends directly on quarantined inventory purchase runtime
- it is only useful if matching sidebar consumers exist
- the broader admin shell does not currently justify restoring this in
  isolation

### Status

- classification: `archive_or_redesign`
- restore decision: `NO-RESTORE`

## Queue Decision

The quarantined runtime queue should no longer be treated as “find the smallest
restore candidate.”

It should now be treated as “decide future ownership model.”

Recommended ownership model:

| File/group | Best lane |
| --- | --- |
| `payment_detail_screen.dart` | redesign or staged reimplementation |
| `inventory_purchase_provider.dart` | staged reimplementation |
| `inventory_purchase_screen.dart` | staged reimplementation |
| `inventory_purchase_service.dart` | staged reimplementation |
| `admin_sidebar_signal_provider.dart` | archive or redesign |

## What This Means

At this point, the evidence-only audits have narrowed the remaining WIP story:

- contract-test restore path is effectively closed
- quarantined SQL/snippet restore path is closed
- runtime restore path is also closed

So future work should not be framed as “restore quarantined WIP.”

It should be framed as one of:

1. archive old WIP as historical reference
2. design a fresh tracked implementation plan
3. reimplement small verified slices from current tracked truth

## Next Safe Action

Stay in docs-only planning mode or move to a fresh implementation design phase.

The next best evidence step is:

- a final summary document that declares the quarantined WIP recovery process
  complete and transitions the repo from recovery audit into redesign planning

## Explicit Non-Action

- No quarantined runtime file was restored.
- No SQL migration or snippet was restored.
- No contract test was restored.
- No asset or config file was restored.
- No commit was created from any quarantined runtime file in this step.
