# Scalability plan — phase 2: stop unchanged promotion writes

This additive migration starts from phase 1C, draft PR #452, at
`a5fdc39149e0ea93e6c9472ef613c15f6ec32e89`. Work is isolated from the original
workspace's uncommitted files. It replaces only `sync_active_order_promotion`;
it does not change frontend polling, financial calculation rules, or payment.

## Confirmed behavior and scope decision

**HIGH — cashier reads repeatedly rewrite unchanged discounts.**
`PaymentNotifier.loadOrders` calls `refresh_store_order_promotions` before
reading payable orders. That RPC loops over every unfinished customer order in
the store, including older orders. The effective sync implementation in
`20260817110000_menu_scoped_promotion_integrity.sql` always updated an existing
scheduled discount and deleted/reinserted all its allocation lines. This also
occurred on eligible order-item status changes and repeated campaign saves.

**Correction from the 2026-09-05 follow-up:** the earlier inspection missed the
indirect feed. `20260805090000_pos_live_events_all_domains.sql` installs
`pos_live_event_trigger` on `order_discounts`, invoking
`emit_pos_live_event('orders')`. The production trigger was confirmed read-only
on 2026-09-05. `CashierScreen._refreshFromLiveEvent` listens to that feed and calls
`PaymentNotifier.loadOrders` again. A closed read → discount write → live event →
read path is therefore established in both source and deployed trigger metadata.
Phase 2's unchanged-DML suppression breaks repeated unchanged writes, but removing
the mutation from the read path remains necessary. Measured amplification magnitude
is still not inferred from the existence of this path.

Deleting the refresh RPC from reads would change behavior: there is no separate
promotion start/end scheduler in the implementation. This phase retains that
entry point and makes unchanged reconciliation write-free at the row-DML level.
It does **not** complete full read/write separation or reduce the RPC count.
That larger change needs a separately validated time-boundary refresh/payment
contract, including an idle connected cashier and partial payments.

## Implementation

The existing eligibility, VAT, whole-VND rounding, and largest-remainder line
allocation formulas are retained. Desired allocations are calculated before
writing and compared with the persisted data in stable order-item-ID order.
Comparison covers store, item, menu, campaign, original line gross, percentage,
and allocated discount, together with all existing header fields the function
maintains. Comparing only the total would miss equal-value menu replacements
or changes in allocation proportions.

- Identical header and allocations: return the existing discount without
  INSERT, UPDATE, or DELETE; preserve IDs and timestamps.
- Header-only change, such as campaign name: update the header only.
- Allocation-only change or repair: replace allocation lines without updating
  an unchanged header.
- Genuine changes: retain atomic header/allocation persistence and the existing
  allocation-total check. Expiry or disable voids once and retains history.
- Existing manual/coupon discounts, completed/cancelled/staff-meal orders,
  store checks, channel filtering, and internal function privileges are retained.

The existing active-discount `FOR UPDATE` lock remains. No new order lock or
advisory lock is introduced because payment and item-mutation paths already
have their own lock ordering. Row locking can still touch buffers/WAL: zero
row DML is not a claim of zero physical writes, zero query work, or zero cost.

No historical migration, payment wrapper/anchor, QR pricing, Office coupling,
MISA dispatch, settlement function, or closing schedule is edited. No index,
subscription, API endpoint, cron job, or external infrastructure is added.

## Verification

`bash scripts/test_promotion_sync_sql.sh` creates and removes its own disposable
Supabase PostgreSQL 17 container, with no host port or production credentials.
It loads actual historical discount/promotion DDL, refresh and item-change
functions, and the full menu-scoped promotion migration before the new migration.
The baseline switch `PROMOTION_TEST_BASELINE=1` excludes the new migration and
reproduces the unchanged-refresh failure. Row triggers count actual DML.

For one active order with two allocated lines, 20 unchanged cashier refreshes
produce 100 discount/allocation row mutations in the old function and zero in
the new function. These are synthetic fixture results, not production savings.

Checks include exact timestamps/IDs, header-only edits, equal-total menu and
allocation changes, quantity changes, missing/corrupted allocations, rollback
on allocation failure, real campaign save/disable entry points, schedule
boundaries, manual/coupon preservation, service/cancelled-item exclusion,
completed/cancelled/staff-meal preservation, QR/POS channel selection, 24 legacy
calculation parity cases, caller/store denial, authenticated cashier execution,
concurrent refreshes with an observed lock wait, and migration reapplication.

The payment wrapper's database definition is compared before and after migration.
This fixture intentionally raises if its stub payment anchor is invoked; it
does not claim end-to-end payment settlement verification. Existing repository
payment/QR/delivery regression tests remain the broader source regression gate.
The harness is included in `scripts/check_repo.sh` and therefore GitHub CI.

## Remaining risks and measurement

- The refresh RPC still scans all unfinished customer orders per load; N+1-like
  server work, client duplicate loads, polling, and read volume remain for later
  batching/realtime phases. There is no reduction in connection count here.
- The existing race when concurrent syncs both see **no active discount** is
  unchanged; the unique-active index prevents duplicates but one transaction can
  fail. The concurrency test covers an existing active discount, not all payment,
  item-change, campaign-save, or first-creation interleavings.
- Existing pricing rejects some fractional-VND lines at 100% discount when
  whole-VND rounding would allocate more than a line's gross. Both old and new
  functions fail atomically in the parity test. Changing that financial policy
  is outside this persistence optimization and should be handled separately.
- Start/end transitions still depend on the existing refresh or item-change
  entry points. This does not introduce guaranteed wall-clock scheduling.
- Production capacity and savings: **measurement required**. Compare sync/refresh
  calls and duration (p50/p95/p99), rows scanned, discount/line DML, WAL bytes,
  DB CPU, buffer reads/dirties, lock waits/deadlocks, realtime messages, and
  egress under matched order/item counts. JSON comparison adds CPU/memory work
  per order; assess the net result instead of claiming a cost percentage.

## Release state and rollout

- Implemented in source: yes.
- Local full verification: `bash scripts/check_repo.sh` passed: static analysis,
  1,279 Flutter tests, 19 payroll and 29 financial-input SQL/API tests,
  91 promotion SQL assertions, 22 Deno tests, 60 Node tests, dependency audit,
  secret scan, deployment/SQL shell fixtures, and the web release build.
  The ordinary Flutter run's 50 skips include the SQL/API groups subsequently
  executed by their harnesses. Existing optional Wasm dry-run/font warnings
  remain; the standard web build succeeded.
- Exact-head GitHub checks: required; consult the stacked draft PR.
- Migration applied to production: no.
- Production deployed / operationally verified: no / no.

After review and exact-head CI, an authorized release must use the production
wrapper, the matching preflight/verify scripts, and earlier phase prerequisites.
No bulk business-data rewrite is required. On a pilot store, check an unchanged
refresh, campaign save/disable, start/end boundary, item edit, manual discount,
and payment while observing row changes and lock metrics. If rollback is needed,
restore the previous sync function through a reviewed forward migration; that
restores repeated writes but requires no reversal of valid discount data.

The next planned performance phase is KDS/customer-display polling. Full
promotion read/write separation remains explicitly outstanding as described above.
