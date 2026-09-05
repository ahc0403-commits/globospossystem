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
| 4. Promotion reads without synchronization writes | Implemented | 110 SQL assertions, 10 payment/recovery tests passed; final gate pending |
| 5. Realtime event-scoped refresh | Implemented | 73 financial API tests, 12 coalescer/realtime/payment tests, 29 display/kitchen contracts passed; final gate pending |
| 6. Measured indexes | Implemented | Production EXPLAIN captured read-only; isolated before/after and replay/rollback passed |
| 7. Measurement / isolated scale scenarios | Executed twice | A/B zero errors; initial C 61 failures, repeat C zero errors but p95 4.6–4.8 s; production capacity unverified |
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

## Item 4

Cashier reads no longer call `refresh_store_order_promotions`. Explicit promotion
edits/order mutations retain their synchronization. A private `promotion-boundaries`
cron runs once per minute, catches crossed start/end boundaries since its persisted
cursor, and synchronizes unfinished customer orders for affected stores in the current
Vietnam business day. A transaction advisory lock prevents overlapping ticks. Cursor
and discount updates commit together; a failed tick does not advance the cursor.
Unchanged synchronization emits no discount DML/live events. The private cursor write
is one small update per tick, independent of screen count.

The previously documented claim that no feedback loop was proven was incorrect:
`order_discounts.pos_live_event_trigger` emits `pos_live_events` in the `orders` domain,
and the cashier listener reloads orders. This trigger was confirmed in production.
The new read path breaks that loop rather than relying solely on idempotent writes.

The payment wrapper checks current promotion state inside the existing atomic payment
transaction. A boundary change rejects the attempt with `PROMOTION_PRICE_CHANGED`
before delegation. The client performs one explicit preparation RPC, rereads, and
leaves the attempt failed for cashier review. It never automatically resubmits a
charge. Existing scoped/VAT/payment implementation and partial-payment semantics
remain in the preserved delegate; MISA remains asynchronous.

Limits: displayed boundary changes can lag one cron interval plus execution/delivery
time. This is not a new versioned client quote protocol: it detects a boundary the
database has not synchronized yet, and preserves the pre-existing handling of a
client quote stale relative to an already updated database. The SQL harness tests
the real promotion SQL and scoped wrapper with a settlement spy, not a complete
production payment database. Existing financial engine regression tests remain required.

## Item 5

Kitchen raw events collect affected order IDs for 100 ms. They fetch only those IDs
in batches of at most 50 plus the 12-row completed history. Unknown-ID events trigger
a complete reconciliation. Failed delta reads force the next reconciliation to be
complete. Deletes remove missing cached rows. The real SDK wire fixture proves 30
events for one ticket result in two reads and preserve 250 unrelated tickets.

Kitchen/cashier refreshes serialize, retaining at most one pending follow-up. Scope
generations prevent old reads/callbacks from publishing after A→B→A store switches
or disposal. A successful channel join/reconnect performs one catch-up read to close
the query/subscription gap. Cashier fallback polling stops only when all three
channels are healthy. Cashier still refetches its scoped list per coalesced event;
it has not been converted to a complete ID-delta protocol.

The shared live signal uses a fixed 350 ms window, so continuous traffic cannot
postpone refresh indefinitely. Merging different domains retains the actual domain
set; merging different stores retains an unknown/full scope, not only the last store.
Global report events request aggregate rows only for affected stores; settings or
unknown/mixed-store events reconcile the complete scope. A date change invalidates
pending patches. Existing catalogs are not reloaded on ordinary financial events.
Connection count is not reduced by request coalescing. Emergency KDS v2 is not enabled
by these changes; existing legacy/shadow mode keeps its five-second safety polling.

## Item 6

Production read-only EXPLAIN artifacts: `measurements/20260905-production-index-before.json`.
The queue read scans all fulfillment items to return one queue, matching the lateral
lookup in `20260901130000_operational_order_business_day_scope.sql`. The new partial
`(queue_id,created_at,order_item_id) WHERE is_cancelled=false` index restricts that
lookup. Cancelled rows do not burden this index. Existing session/order indexes
serve different predicates and are retained.

`payments_store_created_id(restaurant_id,created_at,id)` supports the actual store,
half-open date, and keyset-order predicates in financial inputs and reports. It
includes both revenue and service payments. Production currently scans the store's
older payments and filters them by date. The local optimizer still preferred the
old store-only index for a densely clustered 30-day history; a selective day over
180 retained days used the new index. No planner settings were forced.

Only these two measured indexes are added. Existing orders, external sales, hourly
rule and Photo indexes are retained. The migration has a 3-second lock timeout and
30-second statement timeout; preflight refuses relations above 64 MiB, which require
a separately reviewed concurrent-build procedure. Replay, verification, rollback,
and reapplication are exercised in the disposable harness.

`scripts/check_repo.sh` runs the index-only mode in CI as well; the longer read-load
scenarios are recorded experiments and are not a flaky throughput gate.

## Item 7 methodology and limits

Run `bash scripts/test_scalability_isolated.sh /tmp/pos-scalability-measurements`.
The script creates and removes its own Docker network/Postgres/PostgREST containers;
it refuses non-loopback HTTP targets and unrelated container names. PostgreSQL is
limited to 2 CPUs/2 GiB, PostgREST to 1 CPU/512 MiB with a ten-connection pool.
Each scenario seeds its own store count, 1,000 payments/orders per store over 30 days,
100 delivery rows, 30 Photo days and 400 fulfillment items. Reports request one day.

For 20 seconds, 50/300/1,000 virtual users each keep at most one request in flight,
with five seconds of think time and initial arrivals spread over one second. The
mix is 70% extracted queue-item reads, 20% actual detailed report RPC, 10% actual
all-store aggregate RPC. This is a closed-loop read test, not simultaneous open
connections for every virtual user or a sustained maximum-throughputput benchmark.
Every successful response is checked against exact seeded rows/financial totals.

Artifacts contain request counts, response bytes, p50/p95/p99, errors, maximum
in-flight requests, container CPU/memory samples, and interval DB/statements/WAL
snapshots. Docker CPU 100% represents one core; the DB limit is 200%. Monitor/control
queries are included in DB snapshots, and nested pg_stat_statements calls must not
be summed as independent HTTP requests. The host also runs other local containers;
these measurements do not represent a dedicated Supabase compute instance.

Not measured by this harness: full emergency KDS RPC chains, real production RLS
cost, Realtime connection/message fan-out, order/payment writes and lock contention,
mobile network latency, Vercel requests, or billable egress. These remain explicit
production/staging acceptance metrics before declaring 50/100-store capacity or
choosing a compute upgrade. No VPS migration or Supabase replacement is required
by the evidence gathered so far.

## Release gate

All staged source must pass `scripts/check_repo.sh`, then exact pushed-head GitHub
checks. Merge the complete reviewed stack through PR #456 retargeted to `main`,
wait for the exact fresh-main Photo Objet check,
and apply each unapplied migration through `scripts/deploy_pos_production.sh` with
its preflight/verify artifacts. Web release also requires the existing fixed-account
login smoke and Auth hygiene checks. Source, DB, web, and operational verification
are reported separately. As of this checkpoint no production changes from this task
have been applied; fixed-account smoke credentials were requested securely.

The live Vercel project was linked to production branch `main` with no ignored
build command or automatic-deployment override. Merging intermediate stack branches
would publish clients requiring unapplied RPCs. `vercel.json` therefore disables
automatic Git deployments for `main` only, preserving feature-branch previews.
The final merged tree contains this guard before any new production client can be
published. CLI deployment remains through the required production wrapper after DB
verification. See [Vercel Git configuration](https://vercel.com/docs/project-configuration/git-configuration#git.deploymentenabled).

Measured results and raw artifacts: [scenario comparison](measurements/scalability-20260905/README.md).
