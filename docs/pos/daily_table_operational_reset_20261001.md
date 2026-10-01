# Daily table operational reset

The 1222 incident reproduced a previous-day QR order that remained occupied,
accepted today's additions, and was absent from the cashier's current-day list.
The new migration closes previous-day table operations using the server's
Asia/Ho_Chi_Minh date. BunsikClub Binh Thanh is the initial enabled store.

## Behavior

- No payment rows: cancel the order and items, preserving a before-image and
  system audit in `order_operational_closures`.
- Any payment rows: preserve order/item/payment financial facts, close only
  operations, and list the order for cashier/manager review. No automatic
  balance collection, refund, inventory reversal, or invoice cancellation.
- Cancel remaining KDS, ready-lot, packaging, and operational print work.
  Recorded quantities, completed prints, and pending/failed financial receipt
  jobs survive. Historical payment receipts can still be reprinted.
- Release occupied tables only when no current active order exists. Reserved
  tables, delivery orders, and stores without the policy are preserved.
- System cancellation amounts join the existing cancellation report total.

`table-operational-day-reset-0000-hcm` runs every five minutes, including
Vietnam midnight (17:00 UTC). POS and QR entry points catch up after missed
runs. Order locks, nonblocking reset serialization, and parent guards prevent
late payments/food events from reviving a closed operation. Locked rows retry.
The existing cutoff, sales finalization, and cash closing jobs are unchanged.

Cashiers can select a preparing table and clear its unpaid order with a reason.
Existing payment and permission protections remain in the cancellation RPC.
Previous-day offline requests are archived locally before removal from replay;
they are never merged automatically into today's new customer order.
Server business-day validation also works on deployed databases that lack the
optional client-mutation RPC/ledger, using the existing `create_order` fallback.
That legacy path retains its existing retry behavior without adding idempotency.

## Release and verification

Use a clean exact `origin/main` checkout whose exact SHA has a successful
`POS release contract` check. Apply through `scripts/deploy_pos_production.sh`
with `--migration supabase/migrations/20261001020000_daily_table_operational_reset.sql`.
The apply wrapper atomically installs the schema, enables only the initial
store, and catches up stale operations. The 1222 incident is rechecked under
lock; new payment facts abort its recovery for review.

Preflight, verification, and policy rollback scripts share the migration slug.
Verification checks the guarded selecting delegate when a takeout-availability
wrapper does not select orders itself. Both wrapper layouts are covered.
If guarded apply committed but post-commit verification failed, correct the
verification and use `scripts/resume_daily_table_operational_reset_verification.sh`
from a clean exact main with its required GitHub check successful. It repeats
the production source/target/check gates, verifies installed state, and registers
migration history without reapplying the schema or repeating the recovery.
Rollback stops the policy/cron while retaining closure history and guards;
it does not resurrect yesterday's customer orders.

Check policy `last_completed_date`, `last_success_at`, and `last_error` after
rollout. Confirm table 1222 is available, its original order is closed, payments
are unchanged, and the QR active-order RPC returns inactive. Check the next real
Vietnam midnight separately from the simulated boundary/concurrency tests.

Regression checks: isolated real legacy QR/cancel bodies, overdue statuses,
multi-day catch-up, today's additions on an old parent, partial payments,
inventory/invoice preservation, permissions, idempotency, stale restores and
late events; concurrent payment/QR/closure sessions; QR midnight and cashier
reason/review widgets; server-day cache and durable offline archiving.
