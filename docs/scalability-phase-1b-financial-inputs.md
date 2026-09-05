# Scalability plan — phase 1B: complete financial inputs

## Scope and release state

This change continues [phase 1A](scalability-phase-1-payroll.md) from
`d6cf0d6f4ad90c835094bb54afc561d431ac8dc8` (draft PR #450). It is a separately
reviewable, stacked change. The original workspace and its uncommitted files
are untouched.

The implementation covers payroll staff, daily allowances and holidays,
`ReportNotifier.loadReport`, and `SuperAdminNotifier.loadAllReports`.
It does not claim to complete every report/export in the application.

| State | Evidence |
| --- | --- |
| Source implemented | This branch; additive read RPC and three consumers |
| Local SQL/API verification | 27 new tests and 19 phase-1A tests passed against disposable PostgreSQL/PostgREST |
| Full repository verification | Passed: `bash scripts/check_repo.sh`, including release web build |
| Required GitHub Actions | Must pass on the exact pushed head; consult the PR |
| Production migration applied | No |
| Production client deployed | No |
| Production operational verification | No |

## Reproduction and behavior

With 501 synthetic records and PostgREST's maximum response size set to 100,
the old direct staff, allowance, payment and Photo Objet view queries return
only 100 records. The old allowance input contains 2,000 units of meal allowance
instead of the complete 10,020. These are fixture values, not production metrics.

`get_financial_input_page` provides ten explicitly allowlisted projections.
Each scalar JSON response contains at most 500 rows, independent of the outer
PostgREST row limit. A native typed keyset and a lookahead row identify the next
page, including exact multiples of 500. Caller values use SQL bindings;
identifiers and query fragments come only from fixed SQL branches.

The function is `STABLE SECURITY INVOKER`. It retains the underlying table/view
SELECT grants and RLS. Explicit scope checks require accessible stores, with
the existing super-admin exception for unassigned stores. Only `authenticated`
receives EXECUTE; this does not grant any underlying table access.

The first and final pages count and hash the projected input in their respective
statement snapshots. An edit, deletion, insertion or aggregate-view value change
between these checkpoints rejects the dataset. The client checks the revision,
count, unique cursor keys and store scope, and returns no partial input.
There is no automatic retry or fallback to a truncated query.

Financial arithmetic is preserved, including `amount_portion` versus received
`amount`, Photo Objet gross minus service with a zero floor, separate service
totals, issue counts, and the existing cancellation-total RPC. Super-admin
reports retain their existing received-amount basis; this differs from the
store report's sales-portion basis and is not silently redefined here.

Super-admin timestamp bounds now use the same Ho Chi Minh calendar-date helper
as store reports: inclusive first midnight, exclusive next midnight. This fixes
the old timezone-less timestamps and the lost final fractional milliseconds.
The 23:00 cash close, restaurant cutoff/finalization and Photo Objet collection
schedules are untouched.

Both report providers clear previous totals when starting a new load or changing
the period. Errors leave no old exportable total. Request generations prevent
a slower old request from restoring a report for an invalidated period/store.

## Verification

Run `bash scripts/test_financial_inputs_postgrest.sh`. It creates and destroys
its own Docker network and PostgreSQL 17.6 / PostgREST 14.5 containers with
`PGRST_DB_MAX_ROWS=100`. It applies the real migrations plus companion preflight
and verification SQL. A synthetic fixture supplies relations and RLS; its
test-only auth header stub never touches a POS or Office database. The fixture
models role/scope behavior but is not a full production RLS-policy migration replay.

The tests use the actual Dart services/providers and Supabase SDK, covering:

- All ten projections with 0, 499, 500, 501 and 1,500 rows; native timestamp ties,
  multi-store view keys, exact page counts, and the original truncation reproduction.
- Payroll with 501 allowance rows and an additional employee without attendance;
  complete hours, meal allowance, parking allowance and pay. Only wage-policy
  lookup is stubbed; attendance and supplemental inputs traverse the real API.
- Complete report totals, received cash, service amounts, orders, cancelled-item
  counts, missing proof and e-invoice issues. Cancellation arithmetic itself is
  unchanged and covered by existing contracts; the fixture returns a fixed scalar.
- Super-admin access beyond explicit assignments and existing received-amount
  semantics; Ho Chi Minh midnight and microsecond boundaries in both reports.
- Existing scope/RLS restrictions, revoked access, active/revenue filters, and
  concurrent updates/deletes/backfills including changes in an aggregate view.
- Invalid source/range/cursor/page size; truncated, repeated, out-of-scope or
  inconsistent API pages; failed/stale report clearing and export suppression.

The final local full check passed static analysis, 1,279 Flutter tests, 19 existing
payroll SQL/API tests, 27 new financial-input SQL/API tests, 22 Deno tests, 60 Node
tests, dependency audit/secret scan, deployment/SQL shell fixtures and the web
release build. The ordinary Flutter run reported 48 skips, including the two
SQL/API groups that the subsequent mandatory harness steps execute. Build output
retained the existing optional Wasm dry-run and Cupertino font warnings; the
standard web release build succeeded.

Three existing source-contract tests needed adaptation: the report-only frozen
hash was renewed, and MISA read assertions now follow the RPC to the actual
`public.meinvoice_jobs` projection. Other frozen domain hashes remain intact.

The harness is mandatory in `scripts/check_repo.sh`. Normal `flutter test`
skips the environment-dependent group; the following harness step executes it.

## Resource costs and remaining limits

For a dataset of N projected rows, the client makes `max(1, ceil(N / 500))`
HTTP RPC calls. Each one-page dataset needs one full count/hash scan; a multi-page
dataset needs two. Page reads and RLS checks add SQL work beyond these scans.
Sorting, joined/view aggregation, and RLS can make the DB cost exceed a simple
row-count model. These scans deliberately trade additional reads for detection
of silent financial omissions. No cost saving or capacity figure is claimed.

Store reports still read seven datasets plus the cancellation scalar. Global
reports still make a Photo Objet read and two dataset reads per store. Payroll
still queries hourly rules per part-timer. Client memory remains proportional
to the full period input. Consequently, this is a correctness phase, not the
later N+1 or server-aggregation optimization.

The revision is an optimistic check per dataset, not a persistent MVCC snapshot
across all payroll/report sources. A change after a dataset's final checkpoint,
or one reverted to the same projected values, cannot be ruled out. Concurrent
changes across datasets can still create different observation times. Auditable
point-in-time reports require a later server snapshot/aggregation design.

Other consumers/exports, the global restaurant-list cap, the store-report POS
delivery-channel versus external-delivery rollup semantics, and differing
sales/received-amount definitions remain separate follow-up work. Do not claim
all report accuracy risks are resolved from this change alone.

Before rollout measure period row counts, RPC count/response bytes, p50/p95 time,
DB statement execution time/CPU, scanned rows/sorts/temp bytes, client memory,
and changed-input rejection frequency. Fleet load scenarios remain 10/50/100
stores with 50/300/1,000 concurrent users, with an explicitly measured mix of
screens, devices and order activity. Capacity and cost are **measurement required**.

## Rollout, rollback and next step

1. Review this stacked diff and its prerequisite PR #450; pass repository and
   exact-head GitHub checks before using the production release wrapper.
2. Apply `20260905020000_complete_financial_inputs.sql` before its consumers.
   Companion preflight/verification files use the release gate's naming scheme.
   A missing RPC must show a load error; do not deploy a truncated-read fallback.
3. In a limited authorized rollout, reconcile a closed period with more than the
   API row cap against an independent complete source. Verify manager/super-admin
   visibility, another store's denial, and report export period/sums.
4. Compare the metrics above and input-change errors before expanding rollout.

The migration adds only a read function. A rollback can leave it unused without
changing business data; rolling back the client restores the known truncation
risk, so affected-period exports must not be accepted as complete. No release,
database mutation, VPS move or infrastructure replacement is part of this work.

The next planned implementation is phase 2: remove promotion writes from the
read/refresh path and prove that unchanged reads produce no mutation/realtime
feedback. Phase 3 then targets KDS/polling; phase 4 targets server aggregation,
per-store/per-employee batching and bounded history. Realtime consolidation,
measured indexes and fleet load tests follow in that order.
