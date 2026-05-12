# Reports Operational Read Model Slice — 2026-05-12

## Verdict

After the QSC issue queue second slice, the next fresh tracked target should be
a read-only operational enhancement inside the existing Reports workspace.

This should not become a new workflow shell or a settlement-management system.
The first slice should stay narrow and use the already-tracked reports provider
and read models.

## Why this is the next target

Three conditions are already true:

1. `ReportsTab` already exists as a tracked admin workspace.
2. `report_provider.dart` already computes operational summary, breakdowns, and
   export support from tracked POS data.
3. The current surface is strong on totals, but still leaves room for a more
   operator-friendly “what needs attention” read model.

That makes Reports a safer next target than reopening archived/quarantined WIP
or widening QSC into mutation behavior.

## First-slice question

The narrow question for the first slice is:

> How can the tracked Reports workspace expose a clearer operational attention
> layer without adding new routes, workflow mutation, or SQL/RPC changes?

## Shell decision

The first slice must stay inside the existing tracked Reports shell:

- no new route
- no standalone reporting workspace
- no new export workflow

The natural host is:

- `/Users/andreahn/globos_pos_system/lib/features/admin/tabs/reports_tab.dart`

## Data boundary

The slice should continue using only the existing tracked report provider:

- `/Users/andreahn/globos_pos_system/lib/features/report/report_provider.dart`

Allowed first-slice inputs are only the currently-tracked summary fields such
as:

- missing proof photo counts
- failed e-invoice job counts
- WT08 comparable/reported counts
- hourly and daily breakdowns
- payment method breakdown

No new SQL, RLS, RPC, or migration changes are allowed.

## Allowed first-slice scope

The first slice may include only:

1. A compact “Operational Attention” block that surfaces already-tracked risk:
   - missing proof photo count
   - failed e-invoice job count
   - WT08 report coverage context
   - payment-proof completion percentage
2. Lightweight read-only prioritization copy:
   - what needs immediate follow-up
   - what looks healthy
   - what can be audited later
3. Better grouping of existing report sections so summary and operational risk
   are easier to scan.

## Explicitly out of scope

The first slice must continue to exclude:

- daily close mutation
- WeTax retry/re-dispatch actions
- payroll workflow logic
- inventory workflow logic
- audit-log mutation
- new exports beyond the existing Excel action
- new SQL/RLS/RPC/migrations
- Office coupling changes

## UX boundary

This slice should remain summary-first and operator-readable.

- keep totals and period controls intact
- add an attention/readiness layer above or near summary
- do not turn Reports into a case-management screen

## Recommended implementation order

1. Add the operational attention/readiness summary block.
2. Reuse tracked summary fields only.
3. Add a small contract test pinning the read-only boundary and tracked field
   usage.

## Stop conditions

Stop and redesign instead of extending this slice if:

- the UI requires new backend fields to be useful
- the feature starts needing workflow actions instead of read-only signals
- the Reports shell becomes crowded enough to require a separate workspace

## Decision

Proceed with a small read-only operational read-model slice inside the tracked
Reports workspace.
