# ARCHIVE — Next Redesign Target Selection — 2026-05-12

This file is preserved as pre-lock redesign planning only.

Do not use it as the current UI standard or redesign entry point.

Use these documents instead:

- [Toast Operational UI Source of Truth](office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md)
- [Office Operational UI Redesign Master Plan](office/OFFICE_OPERATIONAL_UI_REDESIGN_MASTER_PLAN.md)
- [Legacy UI Standards Re-Audit](office/LEGACY_UI_STANDARDS_REAUDIT.md)

Historical note:

- keep this file for provenance around the 2026-05-12 target-selection pass

## Verdict

The best next tracked implementation target is `payment_detail`.

It is the smallest meaningful runtime slice that can be redesigned from current
tracked truth without reopening the entire quarantined recovery problem.

## Baseline

- Branch at time of selection: `audit/next-redesign-target`
- Tracked repo state:
  - `git status --short`: clean before this docs-only change
  - `flutter analyze`: PASS
  - `flutter test`: PASS
- Recovery state:
  - quarantined WIP recovery audit is complete
  - future work should start from tracked truth, not direct WIP restore

## Candidates Reviewed

### 1. `payment_detail`

Relevant tracked truth:

- `/Users/andreahn/globos_pos_system/lib/core/services/payment_service.dart`
  - `fetchPaymentDetail(...)` exists
- `/Users/andreahn/globos_pos_system/lib/core/utils/role_routes.dart`
  - `/payments/` access pattern exists for admin/cashier roles
- `/Users/andreahn/globos_pos_system/lib/features/cashier/cashier_screen.dart`
  - payment completion and proof flows already exist

Missing tracked pieces:

- `/Users/andreahn/globos_pos_system/lib/core/router/app_router.dart`
  - no `'/payments/:paymentId'` route
- tracked cashier flow does not navigate into a payment detail screen
- quarantined screen also showed service/API drift around resend behavior

Why it is still the best next target:

- the domain already exists in tracked runtime
- the missing integration boundary is narrow and understandable
- redesign can start from existing tracked payment data rather than from a huge
  cross-domain module

### 2. `inventory_purchase`

Relevant tracked truth:

- tracked DB-side inventory purchase migrations already exist under
  `supabase/migrations/20260506*`
- `/Users/andreahn/globos_pos_system/docs/inventory_purchase_office_design.md`
  already describes a larger intended system

Blocking reality:

- tracked `/Users/andreahn/globos_pos_system/lib/features/admin/admin_screen.dart`
  still mounts legacy `InventoryTab`
- quarantined runtime slice failed `flutter analyze`
- service depends on additional package/runtime surfaces (`pdf`, `printing`,
  POS/Toast UI primitives)
- scope is broad: dashboard, suppliers, purchase order flow, stock audit,
  reporting, mobile UX

Why it is not the best next target:

- too large for the first redesign slice after recovery
- too many integration points move at once
- likely needs staged decomposition before any implementation starts

### 3. `admin_sidebar_signal_provider`

Relevant tracked truth:

- QC service and delivery summary surfaces exist

Blocking reality:

- the quarantined provider imports quarantined `inventory_purchase_service.dart`
- no tracked consumer currently uses the provider
- value is secondary unless a redesigned admin shell explicitly needs the badge
  model

Why it is not the best next target:

- not a user-visible workflow by itself
- depends on unresolved runtime ownership decisions elsewhere
- likely belongs behind either archive or later redesign

## Ranking

| Candidate | Rank | Why |
| --- | --- | --- |
| `payment_detail` | 1 | Smallest meaningful tracked redesign slice |
| `inventory_purchase` | 2 | Valuable but too large; requires staged decomposition |
| `admin_sidebar_signal_provider` | 3 | Derivative feature; depends on other redesign decisions |

## Recommended Next Implementation Shape

The next implementation phase should begin with a **fresh tracked design**
for `payment_detail`, not a restore of the quarantined screen.

Suggested scope boundary:

1. define the tracked route contract for `/payments/:paymentId`
2. define the cashier navigation handoff into that route
3. confirm the exact tracked payment/einvoice fields that the first version may
   read
4. leave resend-email and advanced portal console behaviors for later if they
   are not already supported cleanly by tracked services

## What Not To Do

- do not restore the quarantined `payment_detail_screen.dart` verbatim
- do not bundle `inventory_purchase` into the same phase
- do not revive `admin_sidebar_signal_provider` first
- do not treat the redesign phase as a quarantined WIP merge

## Immediate Next Action

Open a docs-only planning slice for `payment_detail` that defines:

- route contract
- entry point from cashier flow
- minimal screen data contract
- explicit exclusions from the first implementation slice

That is the safest bridge from recovery audit into real tracked development.
