# QSC Issue Queue Design Slice — 2026-05-12

## Verdict

The next fresh tracked feature after Attendance payroll is a read-only QSC issue
queue surface.

This feature should not start as a new workflow shell, Office bridge rewrite, or
mutation-heavy QC tool. The first slice should stay narrow: expose the current
problem queue more clearly for POS operators using tracked read models that
already exist in the repo.

## Why this is the next target

Three conditions are already true:

1. The repo owns tracked QSC read models and wrapper views.
2. Existing QSC screens already handle review context, but not a dedicated
   queue-first issue surface.
3. The queue contract is already documented in POS-owned docs without requiring
   new SQL to begin a read-only UI slice.

That makes QSC issue queue a better next feature than reopening quarantined WIP
or widening Payroll into a workflow system.

## First-slice question

The narrow question for the first tracked slice is:

> How can POS operators scan unresolved QSC problems in one queue-first surface
> without introducing new write behavior or a separate workspace?

## Shell decision

The first slice should stay inside the existing tracked QSC review workspace.

- no new route
- no new standalone QSC dashboard shell
- no Office app implementation

The most natural host is the tracked
`/Users/andreahn/globos_pos_system/lib/features/qc/qc_review_screen.dart`
surface, because it already owns QSC-oriented operator context and filtering.

## Data-source decision

The first slice may read the tracked queue wrapper:

- `public.v_office_qsc_issue_queue`

This is acceptable because:

- the view is already tracked in POS migrations
- it is additive and read-only
- it already encodes severity and issue selection rules
- using it avoids new SQL for the first UI slice

This does **not** mean POS is rebuilding the Office bridge. POS is only reusing
its own tracked read model.

## Allowed first-slice scope

The first slice may include only:

1. A read-only issue queue list using tracked queue columns:
   - store name
   - category
   - criteria text
   - check date
   - severity
   - photo status
   - submission status
   - sv review status
   - followup status
2. Lightweight queue filters:
   - severity
   - qsc domain
   - submission status
   - photo status
3. A compact selected-item detail pane using already-exposed row fields:
   - note
   - evidence photo URL presence
   - score / grade
   - created / submitted time
4. Contract coverage that proves the slice stays read-only and depends on the
   tracked queue view.

## Explicitly out of scope

The first slice must continue to exclude:

- follow-up creation
- follow-up status mutation
- bulk review save
- supervisor score mutation
- Office bridge code
- new SQL/RLS/RPC/migrations
- separate QSC route or workspace
- analytics / weak-point dashboards

## UX boundary

This should be queue-first and exception-first.

- left side: current QSC issue queue
- right side: selected issue detail
- queue context must remain visible while inspecting the selected issue
- metrics may support the queue, but must not replace it

## Service/provider boundary

The first slice may introduce a fresh tracked read-only service/provider pair if
needed, but only for queue reads.

Allowed:

- `fetchQscIssueQueue(...)`
- a read-only provider for filter + selected issue state

Not allowed:

- mutation helpers
- write orchestration
- background sync

## Recommended implementation order

1. Add a read-only queue fetch layer.
2. Add queue + detail UI inside the tracked QSC review shell.
3. Add contract coverage for queue-view dependency and read-only boundary.

## Stop conditions

Stop and redesign instead of extending this first slice if:

- the UI needs follow-up creation to be useful on day one
- the queue requires SQL shape changes
- the queue clearly belongs in a new workspace instead of the existing review
  shell
- Office-specific bridge concerns start leaking into the POS runtime

## Decision

Proceed with a read-only QSC issue queue first slice inside the existing tracked
QSC review surface.

Do not open mutation behavior until the read-only queue proves useful and
stable.
