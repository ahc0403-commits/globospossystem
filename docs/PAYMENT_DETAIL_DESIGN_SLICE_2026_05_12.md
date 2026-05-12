# Payment Detail Design Slice — 2026-05-12

## Verdict

`payment_detail` is the first fresh tracked redesign target after quarantined
WIP recovery.

The first implementation slice must stay narrow:

1. route contract
2. cashier entry point
3. minimal read-only payment detail screen

Everything else should wait.

## Baseline

- Branch at time of design: `audit/payment-detail-design-slice`
- Tracked repo state:
  - `git status --short`: clean before this docs-only change
  - `flutter analyze`: PASS
  - `flutter test`: PASS
- Recovery state:
  - quarantined WIP recovery is complete
  - direct restore of quarantined `payment_detail_screen.dart` is disallowed

## Tracked Truth Available Today

### Existing tracked data surface

Tracked payment data already exists:

- `/Users/andreahn/globos_pos_system/lib/core/services/payment_service.dart`
  - `fetchPaymentDetail(String paymentId)`

### Existing tracked permission surface

Tracked route gating already anticipates payment detail access:

- `/Users/andreahn/globos_pos_system/lib/core/utils/role_routes.dart`
  - `location.startsWith('/payments/')` is already allowed for:
    - `admin`
    - `cashier`

### Existing tracked cashier workflow

Tracked cashier screen already contains payment completion and payment-proof
flow:

- `/Users/andreahn/globos_pos_system/lib/features/cashier/cashier_screen.dart`

### Missing tracked integration

Tracked router still lacks a payment detail route:

- `/Users/andreahn/globos_pos_system/lib/core/router/app_router.dart`
  - no `'/payments/:paymentId'`

Tracked cashier flow also does not navigate to a payment detail screen after
payment completion.

## First Slice Goal

Create a small tracked payment detail path that is read-only and operationally
useful without reopening quarantined runtime complexity.

The first slice should answer only this question:

> After a payment is created, can an authorized cashier or admin open a tracked
> detail page for that payment and inspect core payment/e-invoice state?

## First Slice Inclusions

### 1. Route contract

Add a tracked route:

```text
/payments/:paymentId
```

Allowed roles remain aligned with existing tracked `role_routes.dart` behavior:

- `cashier`
- `admin`
- `brand_admin`
- `store_admin`
- `super_admin` if needed through existing admin/system behavior

### 2. Cashier entry point

Define one explicit tracked navigation handoff from cashier flow into payment
detail.

This should happen from an already successful tracked payment path, not from a
new speculative workflow.

### 3. Minimal read-only screen contract

The first tracked screen should be read-only and limited to data already
returned by tracked `fetchPaymentDetail(...)`.

Recommended minimum sections:

- payment summary
  - amount
  - method
  - settlement status
- order summary
  - order id
  - table / order status if already present in payload
- e-invoice summary
  - job status
  - issuance status
  - lookup URL if already present
- proof summary
  - proof required / proof captured

## First Slice Exclusions

These must stay out of the first tracked implementation:

- resend-email action if it depends on non-tracked service behavior
- advanced portal console panels
- quarantined Toast/Pos-specific console shell
- broader payment history browser
- route/mount work for inventory purchase
- admin sidebar badge integration

## Why This Slice Is Safe

- narrow route addition
- uses existing tracked payment service
- does not depend on quarantined inventory or SQL WIP
- does not require adopting the failed quarantined screen wholesale
- creates a clean seam for later enhancement

## Design Guardrails

- do not copy the quarantined `payment_detail_screen.dart` verbatim
- do not add speculative PDF/email/e-invoice mutation controls unless already
  supported cleanly by tracked services
- do not change payment completion semantics
- do not make WeTax availability a payment completion dependency

## Recommended Next Implementation PR Shape

When implementation starts, keep the first PR as small as possible:

1. add route
2. add minimal screen
3. add one cashier navigation handoff
4. add only the smallest supporting tests needed for tracked truth

## After This Slice

If the first tracked slice lands cleanly, later follow-up phases may evaluate:

- richer e-invoice status panels
- safer resend behavior if supported by tracked service contract
- admin-side deep links into payment detail

But those should be separate tracked slices, not part of the first landing.
