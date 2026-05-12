# Overall Surface Readiness Review — 2026-05-12

## Baseline

- branch: `codex/overall-surface-readiness-review`
- review date: `2026-05-12`
- baseline source: tracked `main` after `feat(pos): add kitchen operational readonly detail (#101)`
- verification status:
  - `flutter analyze`: PASS
  - `flutter test`: PASS
  - `git status --short`: clean before this docs-only review

## Executive Verdict

The current tracked POS baseline is already strong enough to stop widening the
new read-only operational surfaces for now.

Across the last sequence of tracked slices, the repo now has stable,
test-backed read-only/operator-visibility coverage in the highest-risk
operational areas without reopening quarantined WIP or violating the project
constraints in `CLAUDE.md`.

That means the next step does not need to be "add more surfaces everywhere."
The next step should be a deliberate choice between:

1. stop here and preserve the current green baseline, or
2. open exactly one more read-only follow-up where there is still an obvious
   first-slice gap.

## What Is Already Sufficient

### Payment Detail

- status: sufficient for current tracked scope
- reason:
  - route mounted
  - cashier handoff wired
  - screen remains read-only
  - contract coverage exists
- conclusion:
  - no immediate need for a third slice unless product feedback identifies a
    concrete information gap

### Inventory Purchase

- status: sufficient for current tracked scope
- reason:
  - read-only purchase overview exists inside the tracked inventory shell
  - second-slice detail block exists
  - no dependency on quarantined inventory runtime shell
- conclusion:
  - do not widen into mutation, Office review, or standalone workspace without
    a separate product decision

### Attendance Payroll

- status: sufficient for current tracked scope
- reason:
  - payroll preview exists
  - PIN gate exists
  - compact breakdown detail exists
- conclusion:
  - read-only trust boundary is good enough; no immediate need to expand into
    edit or approval behavior

### QSC Issue Queue

- status: sufficient for current tracked scope
- reason:
  - queue list exists
  - compact detail pane exists
  - second-slice readability/support metrics already landed
- conclusion:
  - hold at read-only unless there is a product-level decision to introduce
    follow-up creation or Office-side workflow changes

### Reports Operational Attention

- status: sufficient for current tracked scope
- reason:
  - operational attention block exists
  - second-slice support metrics and explanatory copy exist
  - tracked report summary fields are reused cleanly
- conclusion:
  - no immediate pressure to widen reports further

### Kitchen Operational Attention

- status: sufficient for current tracked scope
- reason:
  - first slice added read-only attention signals
  - second slice added oldest-wait and handoff-readiness detail
  - no kitchen status mutation logic was widened
- conclusion:
  - current kitchen read-only surface is sufficient for now

## What Is Not Yet Complete

### Delivery Settlement

- status: useful, but not yet at parity with the other read-only surfaces
- current state:
  - first slice exists
  - attention metrics and focus/boundary copy exist
- gap:
  - unlike kitchen, reports, inventory, attendance, and QSC, delivery has not
    yet received a compact second-slice readability/detail pass
- conclusion:
  - if we continue implementation now, this is the cleanest next target

### Quarantined Runtime / SQL / Test WIP

- status: intentionally out of active recovery scope
- conclusion:
  - do not reopen quarantined recovery work as part of next feature progress
  - continue treating those artifacts as archive/redesign references only

## Recommended Next Action

If we continue building immediately, the best next slice is:

### Delivery Settlement Second Slice

- type: small tracked implementation PR
- boundary:
  - still read-only
  - still inside existing `delivery_settlement_tab.dart`
  - no route/workspace expansion
  - no SQL/RLS/RPC/migration changes
  - no statement-generation or deposit-confirmation workflow changes
- likely content:
  - compact support metrics
  - clearer "follow-up focus" and readiness explanation
  - one small detail layer for pending/calculated/disputed distribution

## What Should Not Be Done Next

- do not reopen quarantined `inventory_purchase` runtime files
- do not restore `admin_sidebar_signal_provider`
- do not widen `payment_detail` into resend / red-invoice mutation flows
- do not widen attendance into edit/approval workflows
- do not add Office workflow logic into QSC or inventory slices
- do not introduce SQL or migration work just to support UI polish

## Final Recommendation

The current tracked baseline is already sufficient to pause.

If we want one more safe forward move, make it exactly one small
`Delivery Settlement` read-only second slice.

If we do not have a strong product reason for that slice right now, the better
decision is to stop here and preserve the current clean, green, verified main
baseline.
