# KDS stage attention and cashier menu cancellation

## Behavior

- Tray menus pulse after kitchen start until every started unit is marked ready.
- Floor menus pulse while food or floor-direct drinks remain ready to serve.
- Both board rows and menu details use the same one-second cycle (500 ms on,
  500 ms off). The initial snapshot starts the timer; arriving drinks no longer
  cancel it. Disposal stops it.
- Within each order card, unfinished menus preserve their original relative
  order and completed menus move below them. Kitchen completion here means
  started; tray means ready; floor means served. Whole-order FIFO/ready-sequence
  sorting and kitchen removal after tray completion are unchanged.
- Cashier uses the localized Menu cancellation action for paperless and normal
  orders. Worker progress does not disable it. It cancels the entire menu line,
  removes its charge using the existing ledger, and supports Undo.
- Cashier/management can cancel a served line on an unpaid mutable order.
  Waiters retain their served-item restriction. Existing payment and store-scope
  guards remain enforced.
- The old unserved-remainder action is removed from the client and its RPC is
  revoked for authenticated clients. Historical records are preserved.
- Undo reopens an entirely cancelled order before restoring the menu, so KDS
  sync triggers restore its food, combo components and direct drinks correctly.

## Database delivery

Apply `20260917100000_kds_menu_cancellation.sql` through the production deploy
script. Matching preflight, verification and rollback scripts are included.
`supabase/tests/kds_menu_cancellation_test.sql` runs in a transaction and rolls
back; it covers checked and unchecked service, combo food/drinks, cancellation
ledger, undo, cashier versus waiter, store scope and existing payment guards.

## Validation

- 96 focused Flutter tests passed, including timed widget checks and cashier
  cancel/undo interactions.
- Flutter static analysis and the release web build passed.
- Updated macOS/Linux visual baselines were reviewed and rechecked; focused
  tests also passed in the original working directory.
- Migration preflight, apply, verification, rollback, reapply and behavioral SQL
  tests passed against an isolated clone of the existing KDS schema.
- Production migration/application deployment has not been performed for this
  follow-up change.
