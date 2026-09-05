# Scalability plan — phase 3: KDS and customer-display polling

This phase starts from phase 2, draft PR #453, at
`4a4ddccfe111d837c142aac530bc051adb39b0d4`. Implementation is isolated from the
original workspace's uncommitted files. It changes client read scheduling and
subscription lifecycle handling; there is no new migration or dependency.

## Confirmed behavior

- `EmergencyFulfillmentNotifier` in legacy/shadow mode ran a full refresh every
  second even when its Postgres Changes channel was subscribed. An ordinary
  assigned-store refresh uses five RPCs: sync configuration, station snapshot,
  today's completed orders, station timings, and fulfillment mode. Pending
  outbox writes and shadow observations can add calls. The existing in-flight
  guard prevented parallel full refreshes, but bursts could produce an immediate
  refresh and a trailing refresh. Polling could bypass snapshot retry backoff.
- `CustomerDisplayNotifier` read one indexed store row every second in both
  connection states. Its Realtime handler already applies complete rows locally.
  Slow HTTP reads had no in-flight guard, so timer ticks/manual retries could
  overlap. Store ID alone did not distinguish an old A response after A → B → A.
- The separate traditional `KitchenNotifier` already stops polling while
  connected and uses a 15-second disconnected fallback. Its screen's one-second
  elapsed-time display timer is local UI work, not a database read. Its completed
  history still fetches more rows than the screen needs; phase 4 will address
  query shape rather than changing this timer.
- KDS v2 active mode already uses bootstrap, private Broadcast, durable deltas,
  and a 30-second configuration watchdog. It does not use the legacy one-second
  snapshot poll. This phase preserves mode selection and rollout defaults.

## Implementation and latency policy

| Path | Connected, successful reads | Disconnected, successful reads |
| --- | --- | --- |
| Emergency legacy/shadow snapshot | Every 5 seconds | Every 1 second |
| Customer display store row | Every 5 seconds | Every 1 second |

Connection means the relevant channel reports subscribed; it does not prove
event delivery. Full display rows and known KDS item progress still apply on
arrival without an HTTP read. KDS events requiring a full snapshot share a
100-millisecond window measured from the first event; a continuous stream cannot
keep postponing that window. Subscription/reconnection requests reconciliation
to cover the snapshot/subscription gap. Existing full-refresh single-flight and
revision checks remain in place.

Customer-display reads now allow one in-flight request per store generation.
Explicit refresh signals arriving during that request coalesce into one pending
refresh; polling ticks skip busy reads. Successive signals during the follow-up
can request another sequential refresh. Switching stores creates a new
generation: an old network request may finish, but cannot publish into the new
generation or clear its in-flight state. Late HTTP successes/errors cannot
overwrite a newer Realtime revision. Receipt duration remains 10 seconds.

KDS retry delays remain 2/5/15 seconds, and polling/event refreshes now respect
the pending retry. Customer-display failures use the larger of the connection
interval and the 2/5/15-second failure delay. Manual retry and reconnection can
request an immediate attempt. Both screens retain their last successful state
on read failure. Disposed subscriptions ignore late callbacks; KDS v2 cursor
storage completion cannot create channels after disposal.

**Latency tradeoff:** if events silently disappear while the channel remains
subscribed, the next safety poll is up to 5 seconds away, plus actual HTTP/server
latency. Errors/backoff or a busy request can extend recovery. This is not a
one-second delivery guarantee. Foreground device behavior must be checked in a
pilot before releasing broadly, especially new-order alarms and handoffs.

## Verification

`test/display_polling_test.dart` uses the actual Supabase Dart client against a
local HTTP/WebSocket fixture with synthetic rows and Phoenix channel messages.
It verifies request scheduling, payload reconciliation, and lifecycle handling;
it does not execute database SQL/RLS or represent real device/network performance.

Observed regression cases:

| Fixture | Before | After |
| --- | --- | --- |
| Connected, idle, 10-second observation after startup | 10 snapshot/row reads per screen | 2 per screen |
| Customer display: one held read plus 20 simultaneous retries | 21 reads while held | 1 while held, then 1 coalesced follow-up |
| KDS: 20 queue events in one burst | 2 complete refreshes | 1 complete refresh |

The 80% reduction applies to periodic safety reads in this fixture. It excludes
startup/reconnect loads, event-driven reads, outbox writes, shadow observations,
receipt-link requests, and active-v2 traffic. It is not an estimate of total DB
load, realtime traffic, or infrastructure bills. No connection count reduction
is claimed.

The 18 new tests also cover direct event application without HTTP, silently
missed events, failed joins, channel loss/reconnection, failure backoff, manual
recovery, stale successes/errors, empty/delete payloads, store switching, foreign
store rows, disposal during HTTP/cursor storage, and legacy/shadow/active
compatibility. Existing display, KDS, digital-fulfillment, and repository tests
remain required gates.

## Remaining work and operational measurement

- Legacy refresh still performs five RPCs and still loads full station/history
  data. Query batching, history bounds, and N+1/report aggregation are phase 4.
- Realtime subscription count and event fan-out are unchanged. A busy station
  can still request frequent sequential full snapshots. A sustained-event
  workload and silent event-loss detection need separate measurement.
- Active-v2 flags are not enabled by this client change. Promotion read/write
  separation and all phase 2 limitations remain as documented there.
- For 10/50/100-store scenarios, measure screen/device counts, actual orders and
  event rates, per-RPC calls and p50/p95/p99 latency, rows/bytes returned, DB CPU,
  buffer reads, active connections, Realtime messages/lag/reconnects, egress,
  outbox retries, and order-to-screen/alarm latency. Capacity and total savings:
  **measurement required**. Concurrent users alone do not determine those values.

## Release state and rollout

- Implemented in source: yes.
- Local full verification: `bash scripts/check_repo.sh` passed: static analysis,
  1,297 Flutter tests, 19 payroll and 29 financial-input SQL/API tests,
  91 promotion SQL assertions, 22 Deno tests, 60 Node tests, dependency audit,
  secret scan, deployment/SQL shell fixtures, and the web release build.
  The ordinary Flutter run's 50 skips include the SQL/API groups subsequently
  executed by their harnesses. Existing optional Wasm dry-run/font warnings
  remain; the standard web build succeeded.
- Exact-head GitHub checks: required; consult the stacked draft PR.
- New database migration: none; earlier stack prerequisites still apply.
- Production deployed / operationally verified: no / no.

After review and exact-head CI, an authorized release must use the existing
production wrapper. On a pilot store, verify normal new orders, partial/full
handoffs, payment-display updates, receipt expiry, reconnect catch-up, silent
event loss, slow/error responses, and closing/reopening the screen. Compare
latency and request metrics under the same workload before expanding. Client
rollback restores the prior polling policy without any data rollback. The next
planned phase is N+1/full-query/client-aggregation reduction.
