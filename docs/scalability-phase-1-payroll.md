# Scalability plan — phase 1A: complete payroll attendance

## Scope and status

This is the first isolated implementation of the September 2026 improvement
sequence: correctness → feedback loops → KDS/polling → N+1/full reads → realtime
→ measured indexes → load tests → infrastructure decisions.

The branch starts from production source `6341b3b3059ed0e896da585f28ddf4c7a84362c4`
and preserves its holiday-pay calculation. The original workspace's unrelated
uncommitted changes are excluded.

| Gate | Status |
| --- | --- |
| Payroll attendance implementation | Implemented in this branch |
| Isolated PostgreSQL/PostgREST verification | 19 tests passed |
| Failed/stale-refresh UI verification | Passed: cached export is cleared, retry recalculates, and invalidated requests cannot export |
| Local full repository checks | Passed: `bash scripts/check_repo.sh`, including web release build |
| Required GitHub Actions | Consult the exact-head PR check; local results do not close the release gate |
| Production migration applied | No |
| Production client deployed | No |
| Production operational verification | No |

## Reproduction and change

The calculator previously reused `get_attendance_logs_with_names`, whose limit
is 500. A fixture containing 502 attendance events for 251 daily shifts produced
250 daily records. The existing test fake had ignored the limit; it now models
the display limit, and the calculator explicitly selects the complete-data path.

`get_payroll_attendance_page` adds a payroll-only read API. Each request contains
at most 500 attendance rows, ordered by `(logged_at, id)`, in a JSON envelope.
The scalar envelope prevents PostgREST's outer response row limit from silently
cutting a page. A lookahead row identifies whether another page exists, so an
exact multiple of 500 does not require an extra empty request.

The first page includes the input count and a revision over the scoped attendance
rows and joined employee/user row versions. The final page recomputes these from
its statement snapshot. Concurrent insertion, deletion, or editing fails the
whole calculation. This is an optimistic completeness check, not a persistent
MVCC snapshot or a transaction across wages, allowances, and staff queries.

The client retains raw timestamp strings as cursors, checks scope, time range,
ordering, repeated IDs, revision, and final count, and exposes no partial result.
There is no retry loop or fallback to the truncated display RPC. The attendance
screen clears an earlier preview when recalculating; a failure leaves a retry
action rather than a cached export. Request generations also prevent a read
invalidated by a store, date-range, or attendance refresh from restoring/exporting
stale results. Export filenames retain the calculated period. Existing generic payroll failure text is
used. The display RPC and all payroll arithmetic remain unchanged.

## Verification

`bash scripts/test_payroll_attendance_postgrest.sh` creates and destroys its own
Docker network, PostgreSQL 17.6 container, and PostgREST v14.5 container. It does
not use production credentials or existing POS/Office databases. Its `auth.uid`
header stub exists only in the synthetic `payroll_test` database fixture and
must never be applied to an application database.

The fixture applies the real old display migration and new payroll migration as
the `postgres` migration role. The preflight and verification SQL run too.
Tests use the actual Dart service and Supabase SDK through PostgREST configured
with a **100-row response cap**:

- 0, 499, 500, 501, and 1,500 rows, including timestamp ties across page boundaries;
- unchanged display cap and complete payroll results;
- inclusive start/exclusive end and store isolation;
- editing/deleting already-read rows, backdated insertion, and employee changes;
- forbidden roles, out-of-scope stores, malformed cursors, and revoked access;
- changed revision, truncated final page, empty continuation, and duplicate IDs.

The harness is included in `scripts/check_repo.sh`, so the normal Flutter test
suite's environment-based skip does not omit SQL/API verification from CI.
Docker, Flutter, and curl are required. Test database identifiers and passwords
are synthetic fixture constants.

The final local repository run passed static analysis, 1,279 Flutter tests
(21 reported skips), the 19 SQL/API tests, Deno checks/tests, 60 Node tests,
dependency audit/secret scan, deployment/SQL shell fixtures, and the web release
build. The ordinary Flutter invocation skips this environment-dependent SQL/API
group; the following harness step runs it against real PostgreSQL/PostgREST.

## Request and resource implications

For N attendance rows, payroll attendance takes `max(1, ceil(N / 500))` HTTP RPC
requests. The complete calculator still makes three auxiliary reads plus a
per-part-timer hourly-rule read. These are intentionally separate later work.
RPC requests are not the same as SQL statement counts: each page also checks
authorization and store scope, and the first/final pages scan the selected input
to calculate the revision. A single-page result needs only one revision scan.

The revision scans are O(N) in the requested store/period; the client still holds
O(N) attendance rows for existing wage arithmetic. This fixes silent truncation,
not all payroll scaling costs. No new indexes or infrastructure sizing claims
are included. Measure rows per pay period, RPC count and bytes, p50/p95 latency,
DB total execution time/CPU, memory, and changed-input failures before deciding
on server aggregation or a different snapshot scheme.

## Rollout and rollback

1. Complete repository checks and required GitHub Actions on the exact pushed SHA.
2. Use the repository production release wrapper and its required review gates.
   Apply `20260905010000_payroll_complete_attendance.sql` before the new client;
   its companion preflight and verification scripts are provided.
3. Verify one permitted store's payroll with more than 500 known events against
   an independently counted complete source. Check other-store access remains
   denied and normal display queries retain their existing contract.
4. Compare the RPC count, duration, transferred bytes, and payroll totals during
   the first limited rollout before proceeding to the next change.

The migration is additive. A client rollback can leave the unused RPC installed,
without touching attendance data. An old client reintroduces the known 500-row
payroll limit: do not treat its exports as complete for affected periods. A
rollback or failed migration is not permission to bypass release gates.

## Remaining sequence

| Step | Next independently reviewable change |
| --- | --- |
| 1B — correctness | Reconcile report totals against complete source data; preserve timezone, refunds, service items, and existing close contracts. Inspect allowance/staff response caps separately. |
| 2 — feedback loops | Make promotion refresh idempotent, then remove writes from the read path; verify unchanged reads emit no mutation events. |
| 3 — KDS/polling | Fix measured query-plan issues, then reduce repeated full reads with overlap protection and tested reconnect recovery. |
| 4 — query shape | Batch per-employee/per-store reads, server-side report aggregation, bounded completed-order history. |
| 5 — realtime | Consolidate lifecycle and refresh ownership; refresh only affected scope/IDs and verify recovery. |
| 6 — indexes | Add only indexes justified by final query plans and measured workload. |
| 7 — scale gates | Test 10/50/100 stores with 50/300/1,000 concurrent users using measured screen/device/order mixes. |
| 8 — capacity | Decide compute sizing or platform changes from those measurements. |

For each step: reproduce → implement a small change → regression checks →
exact-head release checks → limited rollout → operational comparison. Minimal
before/after instrumentation accompanies each step; fleet load testing remains
after the structural changes. No capacity or cost result is inferred from store
counts alone.
