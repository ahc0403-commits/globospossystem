# Scalability plan — phase 4A: aggregate multi-store reports

This independently reviewable phase starts from phase 3, draft PR #454, at
`d18a28e91498e87f306598c9862093e518a461bd`. It replaces the transaction-reading
path in `SuperAdminNotifier.loadAllReports` with one scoped aggregate RPC.
The original workspace's uncommitted files are preserved in a separate worktree.

Phase 4 is split into global report aggregation (this change), payroll hourly-rule
batching, and bounded kitchen history/query improvements. The individual store
report's detailed charts/issues/export have different data requirements and remain
separate work. This is not completion of every N+1/query-shape issue in the audit.

## Findings and implementation

**HIGH — per-store requests and complete raw inputs for a totals-only screen.**
Previously the global report read Photo Objet daily rows, then separately read
payments and external sales for each store. Each dataset used phase 1B's complete
500-row pages and first/final count/hash checks. This avoided silent truncation
but still transferred transaction rows and repeatedly traversed period data.

`get_store_revenue_summary(uuid[], date, date)` now aggregates all requested
stores in the database. Payments, completed revenue-bearing external sales,
and Photo Objet daily totals are combined with `UNION ALL`, then grouped by
store. Joining aggregate totals back to the requested IDs includes stores with
zero activity. It returns one compact row per requested store in scalar JSON,
so PostgREST's outer row cap cannot silently truncate the store totals.

The scope is explicitly bounded to 1–500 distinct, non-null store IDs. An empty
screen selection is handled locally without a request. Oversized/invalid scopes
fail rather than return a partial report or automatically split snapshots.
Dates are inclusive calendar dates; SQL derives the first Ho Chi Minh midnight
and exclusive midnight after the final date. Period length remains governed by
the existing UI; a long period still entails proportional database work.

All three sources are read in one statement snapshot. The function is
`STABLE SECURITY INVOKER`: it retains table/view SELECT grants and RLS, checks
the existing accessible-store scope with the established super-admin exception,
and grants EXECUTE only to `authenticated`. It adds no business-data writes,
index, trigger, publication, cron job, or new infrastructure.

**CONFIRMED — preserved calculation rules.**

- Payment sales use `amount_portion`, including zero, and fall back to `amount`
  only when the allocation is null. Received cash remains a separate concept.
- Only a case-insensitive exact `delivery` order channel enters POS delivery;
  null/absent orders and other channels remain dine-in, as before.
- External delivery includes only completed rows with `is_revenue = true`.
- Photo Objet subtracts service from gross and clamps at zero per store/day,
  after the existing view has combined that day's inputs. It does not clamp each
  raw sale or clamp only after combining all days.
- Non-revenue payments remain excluded. Null, zero, negative and fractional
  amounts preserve the existing arithmetic. SQL uses numeric sums; Flutter
  continues using doubles to display/store the compact totals.

`StoreRevenueSummaryService` validates protocol version, dates, store count,
exact store membership/uniqueness, and finite required amounts before exposing
any totals. The notifier retains stale-request guards and clears old exportable
totals on a new request or error. A missing RPC displays an error and never
falls back to loading raw transactions. Sorting and summing the bounded set of
store rows remain client-side; transaction-level aggregation is removed here.

## Reproduction and verification

The existing disposable PostgreSQL 17/PostgREST 14 harness now applies the new
preflight, migration and verification scripts. It reapplies the migration to
check idempotence. `PGRST_DB_MAX_ROWS=100` remains enabled. No production or Office
database is used. Underlying relation/RLS fixtures are synthetic; the actual
migration, Supabase Dart client, services and report notifiers execute in tests.

With 100 requested stores and 501 rows in each of the payment, external-sale and
Photo Objet input datasets in one store, the previous notifier makes **204 report
data requests**. The new notifier makes **1**, receives **100 aggregate rows**,
and produces the same total. This excludes the separate store/brand/entity
catalog requests needed to initialize the screen. It is a fixture result, not
a production cost or DB CPU estimate.

The financial SQL/API suite adds 25 cases covering:

- One request for the 100-store reproduction and complete zero-activity results
  for 1, 10, 50 and 500 stores despite the 100-row outer API cap.
- Parity against complete legacy inputs across 1,500 rows and multiple stores,
  mixed channels, null/zero/fractional/negative values, exclusions and same-day
  Photo Objet combinations. Existing split-payment and microsecond-boundary
  reconciliation tests continue to run for both report providers.
- Selected/empty scopes, mixed unauthorized scope rejection, unassigned-store
  access for super-admin, underlying RLS and revoked SELECT privileges.
- Invalid scopes/dates, truncated/duplicate/foreign rows, wrong date/version/count,
  invalid amounts, stale success/error, selection invalidation and disposal.
- A missing-RPC response clears old totals and triggers no raw-data fallback.
- Concurrent commits to all three sources while the aggregate is held at the
  Photo Objet branch: the in-flight result contains the old values consistently;
  the next request contains the new values. A disposable advisory lock and view
  predicate create the observed overlap only in the test database.

Local full verification: `bash scripts/check_repo.sh` passed static analysis,
1,297 Flutter tests, 19 payroll and 54 financial SQL/API tests, 91 promotion SQL
assertions, 22 Deno tests, 60 Node tests, dependency audit, secret scan,
deployment/SQL shell fixtures and the web release build. The ordinary Flutter
run's 75 skips include SQL/API cases executed by their subsequent harnesses.
Existing optional Wasm dry-run/font warnings remain; the standard web build passed.
Required exact-head GitHub checks: consult the stacked draft PR.

## Remaining risks, measurement and next actions

**MEDIUM — DB scan cost remains workload-dependent.** One HTTP RPC is not one
physical read. RLS, joins, the Photo Objet view, date predicates, aggregation,
and concurrent reporting all consume DB work. Measure actual statement plans,
scanned rows, buffer reads, DB CPU, p50/p95/p99 duration, temp/sort bytes, response
bytes and client memory under matched period/store/order counts. Evaluate
indexes from those plans in the planned index phase; none are added here.

**MEDIUM — metadata and other consumers remain separate.** This RPC aggregates
the store IDs supplied by the existing loaded/selected catalog. It does not fix
`loadAllRestaurants`/brand/entity catalog pagination, discover omitted stores,
or change filter semantics. Their existing row-cap exposure remains a follow-up.
It also does not remove payroll's per-part-timer wage-rule lookup or the kitchen
completed-history overfetch. Those are the next independently reviewable changes.

For 10/50/100 selected stores, this report-data path is one RPC per load and one
returned row per store. Traffic additionally depends on report openings, date
changes, concurrent reporters, catalog reads and data volume. Overall fleet
capacity, database CPU, realtime load, egress and bills: **measurement required**.
There are no realtime connection/message changes in this phase.

## Release state and rollout

- Implemented in source: yes.
- Migration applied to production: no.
- Production client deployed / operationally verified: no / no.

Apply `20260905040000_store_revenue_summary.sql` with its companion preflight and
verification before releasing this client, after review and exact-head CI, using
the existing authorized production wrapper and earlier stack prerequisites.
For a pilot, compare each store and global totals for a closed period containing
split payments, delivery, Photo Objet service amounts and a zero-activity store.
Verify a limited user's denied scope and compare request/response/DB metrics.

Client rollback may leave this read-only RPC unused; it requires no business-data
rollback and restores the slower complete-input path. Do not claim deployment
or operational savings from the local fixture. Next: payroll hourly-rule N+1
elimination, followed by bounded kitchen history and remaining detailed reports.
