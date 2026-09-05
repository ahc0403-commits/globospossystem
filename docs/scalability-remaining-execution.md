# Remaining scalability execution

User authorized items 1–8, including production application, on 2026-09-05.
Worktree: `codex/scalability-remaining`; base `eed2beb8`, already includes the
latest main payroll scheduled-hours/holiday fix (`6341b3b3`). Original dirty
checkout and its untracked migration are preserved.

| Item | Source status | Verification / release status |
| --- | --- | --- |
| 1. Payroll wage-rule batching | Implemented | 19 payroll/unit contract tests; financial SQL/API suite 70 tests passed; not deployed |
| 2. Kitchen history bounds | Implemented | Bounded-history/active-page SDK fixture added; full release checks pending |
| 3. Detailed report aggregation, catalogs/cache | Implemented | 71 financial SQL/API tests; 18 catalog/report overlay tests; analyze passed; release checks pending |
| 4. Promotion reads without synchronization writes | Pending | Preserve time boundaries and payment semantics |
| 5. Realtime event-scoped refresh | Pending | Preserve reconnect, stale-response, lifecycle safety |
| 6. Measured indexes | Pending | Inspect production plans read-only; no speculative indexes |
| 7. Measurement / isolated scale scenarios | Pending | Never infer production capacity from synthetic throughput |
| 8. Production application | Pending | Exact-main GitHub checks and production wrapper required |

## Item 1

`get_payroll_hourly_rules` returns explicit coverage for at most 500 employee
IDs per request, including null for a missing rule. It uses the existing
workforce manager scope helper and invoker RLS/SELECT privileges. Only the eight
calculation inputs are projected. The client batches unique part-timer IDs and
fails without partial results on any missing/duplicate/malformed row or failed
batch. The existing single-employee method remains for independent edit screens.

Requests for P part-timers: P -> ceil(P/500), zero for an empty set. Actual
502-employee payroll fixture: two wage-rule RPCs, unchanged 501 hours and 61,623
fixture currency units including allowances. 70 real PostgreSQL/PostgREST tests
include API cap 100, missing rules, unauthorized stores/non-managers, revoked
SELECT, malformed responses, and failure in the second batch. Existing scheduled
start/night/holiday calculation is unchanged. Different batches are independent
statement snapshots; no new cross-input transactional payroll snapshot is claimed.

## Item 2

Completed history reads only 12 orders on the server, ordered by creation time
and ID descending (preserves existing creation-day/history semantics). Active
orders use ascending `(created_at,id)` keyset pages of at most 100 and terminate
on an empty page, so a lower API row cap does not truncate the queue. Both streams
are requested concurrently. Existing item sorting, cancelled-item exclusion,
active lane status rules, business-day bounds and actions remain.

The HTTP fixture imposes a 50-row API cap: all 251 active tickets plus only 12 of
1,000 completed tickets are returned. Failed/repeated pages never expose a partial
queue. The active queue is not a financial statement snapshot; concurrent order
status changes are reconciled by the operational refresh path. Embedded item
payload size still depends on items per visible ticket; this change bounds order
history, not arbitrary items in one ticket.

## Item 3

Detailed report uses one `get_store_report_summary` invoker RPC. Daily, hourly,
payment-method, service, cancellation and order counts use the same statement
snapshot and existing policy/RLS. Raw successful transactions are not sent to the
browser. Actionable missing-proof/MISA exception rows are retained for the existing
scrollable detail view; exception-only payload can still grow with unresolved work.
The frozen prior arithmetic lives only under `test/helpers/` for differential tests.
1,500 mixed-row fixtures preserve nullable/zero/negative allocations, mixed channels,
method normalization, proof percentages, daily team counts, Photo clamping, and IDs.

Store/brand/legal-entity catalogs use 100-row UUID keyset pages, explicit columns,
an empty terminal page and same-key in-flight request sharing. Mutation completions
force a fresh read after any in-flight read. Catalogs needed for global report scope
are loaded completely; failure clears the store list and invalidates old report scope.
Initial independent catalog streams run concurrently. Sales events no longer reload
all catalogs; settings/staff events still do. No persistent cross-user cache was added.

First full preflight stopped at four stale source-shape/hash contract expectations
(1,302 Flutter tests passed); these contracts were updated to track the new query
locations and bounded kitchen reads. Final full preflight is still required.
