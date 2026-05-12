# Reports Operational Second Slice — 2026-05-12

## Verdict

The first tracked Reports operational attention slice is already landed on
`main` as a read-only readiness layer inside the existing Reports shell.

A second slice is allowed only if it stays **read-only** and improves operator
clarity rather than turning Reports into a settlement workflow or retry queue.

## Current shipped baseline

The tracked first slice already provides:

- an `Operational Attention` block inside the existing Reports workspace
- readiness signals sourced from already-tracked report summary fields
- proof-photo, e-invoice, and WT08 attention context
- no new route or workspace
- no new SQL, RPC, RLS, or migration changes

## Second-slice question

If operators still need a small follow-up improvement, the narrow question is:

> How can the tracked Reports workspace become easier to scan and interpret
> without adding workflow mutation, WeTax dispatch actions, or backend
> contract changes?

## Allowed scope

The second slice may include only the following:

1. Readability improvements inside the existing Reports shell:
   - denser grouping of operational attention signals
   - clearer separation between healthy, warning, and follow-up states
   - stronger empty/loading/error treatment for the read-only attention layer
2. Lightweight read-only support signals:
   - compact readiness/support metrics derived from already-tracked summary
     fields
   - clearer “what needs follow-up now” copy
   - clearer “what can wait” or “what looks healthy” copy
3. Small detail polish:
   - improved labels for proof, e-invoice, and WT08 readiness
   - short explanatory rows for why a metric matters
   - better formatting for percentages/counts already exposed by the provider

## Explicitly out of scope

The second slice must continue to exclude:

- daily close mutation
- WeTax retry or dispatch actions
- proof-photo workflow mutation
- payroll workflow logic
- inventory workflow logic
- new Excel/export workflows beyond what is already tracked
- new SQL migrations
- new RPCs
- new routes or a standalone reports workspace
- Office bridge workflow logic

## Data contract boundary

The second slice should keep the same tracked boundary:

- `/Users/andreahn/globos_pos_system/lib/features/report/report_provider.dart`
- existing tracked report summary/read-model fields only

No new backend contract is required.

## UX boundary

Reports should remain summary-first and operations-friendly.

- keep the current period controls and main summary intact
- keep operational attention read-only
- improve scanability without making Reports behave like a task board

## Recommended implementation order

1. Add compact support/readiness metrics beside the operational attention block.
2. Improve labels and grouping for healthy versus follow-up states.
3. Add brief explanatory copy for the highest-risk signals.
4. Extend contract coverage only if the read-only boundary needs pinning.

## Stop conditions

Stop and redesign instead of extending this slice if:

- the UI needs new backend fields to be useful
- the feature starts to require workflow actions instead of read-only signals
- the Reports shell becomes crowded enough to justify a separate workspace
- WeTax or settlement operations begin to depend on direct user intervention

## Decision

Proceed only with a small read-only second slice.

If the product needs dispatch/retry controls, close workflow actions, or
cross-workspace orchestration, that should become a separate future feature
rather than an extension of the Reports operational read surface.
