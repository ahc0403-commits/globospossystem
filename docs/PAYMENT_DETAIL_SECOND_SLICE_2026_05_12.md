# Payment Detail Second Slice — 2026-05-12

## Verdict

`payment_detail` first slice is already landed and contract-covered.

The next safe slice should remain **read-only** and focus on information
density, not new mutation behavior.

## Current Tracked State

- `main` includes:
  - `/payments/:paymentId` route
  - cashier handoff after tracked post-payment steps
  - minimal read-only payment detail screen
  - contract coverage for route + handoff + read-only boundaries
- Baseline at planning time:
  - `git status --short`: clean
  - `flutter analyze`: PASS
  - `flutter test`: PASS

## What The First Slice Already Solves

The current tracked page already answers the minimum operational question:

> Can an authorized operator open a payment record and inspect basic payment,
> order, e-invoice, and proof state?

That question is now covered.

## Why A Second Slice Might Still Be Useful

The current screen is intentionally sparse.

If operators need a denser operational view, the next safe improvement is to
make the same tracked data easier to scan, without introducing new workflows.

## Second Slice Goal

Improve readability and operator usefulness while keeping the page strictly
read-only.

The second slice should answer this narrower follow-up question:

> Can the existing tracked payment detail page expose the same trusted data more
> clearly, without adding new async mutations or vendor-portal duplication?

## Safe Inclusions

### 1. Better visual grouping

Allowed:

- clearer status emphasis for payment / e-invoice / proof state
- stronger distinction between IDs, timestamps, and operational statuses
- compact layout improvements using tracked UI primitives only

### 2. Existing tracked fields only

Allowed:

- reordering or better labeling of fields already returned by
  `paymentService.fetchPaymentDetail(...)`
- clearer handling of missing/null values
- more operator-friendly formatting for timestamps and amounts

### 3. Passive external link treatment

Only if it uses already-returned `lookup_url` safely:

- render lookup URL more clearly
- optionally expose an explicit “open vendor portal” style link/button

This still must not duplicate vendor portal behavior.

## Explicit Exclusions

These remain out of scope for the second slice:

- resend-email action
- red invoice mutation actions
- PDF generation/download behavior beyond existing vendor portal usage
- e-invoice retry / re-dispatch flows
- broader payment history explorer
- inventory purchase integration
- admin sidebar signal integration
- quarantined runtime shell patterns

## Guardrails

- stay read-only
- do not widen SQL or RPC scope
- do not make payment success depend on this screen
- do not add vendor workflow duplication
- do not restore quarantined runtime files

## Recommended PR Shape

If a second slice is implemented, keep it to one small PR:

1. visual/readability improvements inside `payment_detail_screen.dart`
2. no router changes
3. no cashier flow changes
4. update or extend `payment_detail_contract_test.dart` only if the new
   contract needs to be pinned

## Stop Condition

If there is no clear operator pain beyond the current first slice, do not build
the second slice yet.

In that case, the better next target is to move on to the next redesign area
rather than polishing payment detail unnecessarily.
