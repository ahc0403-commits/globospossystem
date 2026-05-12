# QSC Issue Queue Second Slice — 2026-05-12

## Verdict

The first tracked QSC issue queue slice is already landed on `main` as a
read-only queue surface inside the existing review shell.

A second slice is allowed only if it remains **read-only** and improves queue
clarity rather than turning QSC review into an issue-management workflow.

## Current shipped baseline

The tracked first slice already provides:

- a read-only queue sourced from `public.v_office_qsc_issue_queue`
- severity/domain/photo/submission filtering
- a compact selected-item detail pane
- no new route or workspace
- no follow-up or review mutation changes

## Second-slice question

If operators still need a small follow-up improvement, the narrow question is:

> How can the tracked queue become easier to scan and interpret without adding
> follow-up creation, review mutation, or Office-style workflow logic?

## Allowed scope

The second slice may include only the following:

1. Queue readability improvements:
   - better density for issue rows
   - clearer grouping of severity, submission, and photo states
   - stronger empty/loading/error treatment
2. Lightweight read-only support signals:
   - compact queue summary counts by severity/status
   - “review focus” copy that explains why an issue is in the queue
   - store/date context improvements for selected issue detail
3. Small detail-pane polish:
   - better formatting for score/grade/timestamps
   - clearer evidence presence messaging
   - read-only surface hints about what requires follow-up outside this slice

## Explicitly out of scope

The second slice must continue to exclude:

- follow-up creation
- follow-up status mutation
- bulk review save
- supervisor review mutation
- Office bridge workflow logic
- new SQL migrations
- new RPCs
- new routes or standalone QSC workspaces
- analytics dashboard expansion

## Data contract boundary

The second slice should keep the same tracked boundary:

- `public.v_office_qsc_issue_queue`
- read-only Flutter service/provider/UI code only

No new database contract is required.

## UX boundary

The queue remains secondary to the tracked QSC review shell but must stay
visible and exception-first.

- queue remains visible while inspecting details
- queue detail remains compact
- operators should understand issue priority without opening another workspace

## Recommended implementation order

1. Add compact queue summary/support metrics.
2. Improve issue-row density and labels.
3. Polish the detail pane formatting and copy.
4. Extend contract coverage only if the new read-only boundary needs pinning.

## Stop conditions

Stop and redesign instead of extending this slice if:

- the UI needs write actions to be useful
- the queue needs SQL shape changes
- the feature starts to behave like an Office issue-management workspace
- analytics needs outweigh queue-first review needs

## Decision

Proceed only with a small read-only second slice.

If the product needs issue ownership, follow-up orchestration, or Office bridge
workflow, that should become a separate future feature rather than an extension
of the QSC issue queue read surface.
