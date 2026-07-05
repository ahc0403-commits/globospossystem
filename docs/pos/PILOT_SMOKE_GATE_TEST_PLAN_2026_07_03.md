# Pilot Smoke Gate — Test Plan

Date: 2026-07-03
Status: DRAFT — pending review
Source specs:
- `docs/pos/ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03.md` (invariants I1–I8, cancel contract)
- `docs/pos/STAFF_ACCOUNT_LOGIN_GATE_CONTRACT_2026_07_03.md` (AC1–AC8)
Existing assets reused:
- `scripts/check_pilot_auth_accounts.sh`, `scripts/smoke_pilot_login.sh`
- `integration_test/full_multi_account_smoke_test.dart`
- `docs/pos/POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md`
- `docs/manual_test/GLOBOS_POS_manual_verification_checklist_2026-05-19.md`

## Principle

"배포 완료"와 "파일럿 가능"을 분리한다. A deploy is pilot-ready only when
all four gates below pass, in order. Gate N failing blocks Gate N+1 —
no partial passes.

```
Gate 0  Account readiness      (script, ~seconds)   ← runs pre- AND post-deploy
Gate 1  Login matrix           (script, ~1 min)
Gate 2  Order lifecycle contract (SQL test, ~1 min)
Gate 3  Cross-screen E2E       (integration test, ~10 min)
Manual  Pilot dry-run checklist (human, ~20 min)    ← first pilot day only
```

---

## Gate 0 — Account Readiness (extends `check_pilot_auth_accounts.sh`)

Type: script (psql/service-role). Maps to AC8.

| # | Check | Pass Criteria | Failure Action |
|---|-------|---------------|----------------|
| 0.1 | Every email in `docs/manual_test/pos_required_pilot_auth_emails.txt` exists in `auth.users`, confirmed | all present | run provisioning repair path (deploy audit doc §repair); re-run gate |
| 0.2 | Matching `public.users` profile, `is_active = true` | all present | `create_staff_user` re-provision |
| 0.3 | `role` ∈ known role set (spec P0-3 constant) | no unknown roles | fix `users.role`; re-run |
| 0.4 | `app_metadata.accessible_store_ids` non-empty; every id exists in `restaurants` | non-empty, valid | run `refresh_user_claims(auth_id)`; if still empty → AC1 investigation |
| 0.5 | Pilot store has ≥1 `available` table and ≥1 `is_available` menu item | data present | seed pilot store data |
| 0.6 | No orders on pilot store stuck in `pending/confirmed/serving` older than 24h | zero stale orders | run `recalc_order_status` backfill or manual cancel |

Output contract: exit non-zero, print one line per failing account/check.

## Gate 1 — Login Matrix (extends `smoke_pilot_login.sh`)

Type: script (Supabase auth REST + profile fetch). Maps to AC2–AC7.
Today's script stops at "login API succeeds" — extend to assert the
resolved session, per account:

| # | Account | Assert | Spec |
|---|---------|--------|------|
| 1.1 | waiter@globos.test | login OK, `role=waiter`, `storeId` = pilot store, `accessible_store_ids` non-empty | AC2 |
| 1.2 | kitchen@globos.test | same shape, `role=kitchen` | AC2 |
| 1.3 | cashier@globos.test | same shape, `role=cashier` | AC2 |
| 1.4 | admin@globos.test | same shape, `role=admin` | AC2 |
| 1.5 | superadmin@globos.test | login OK, `role=super_admin` (store scope may be empty) | AC6 |
| 1.6 | fixture: scope-less waiter (test env only) | login REFUSED with `authErrorNoStoreScope` | AC3 |
| 1.7 | fixture: unknown-role account (test env only) | login REFUSED with `authErrorUnknownRole` | AC5 |
| 1.8 | fixture: deactivated account | login REFUSED with `authErrorAccountDeactivated` | AC7 |

1.6–1.8 are negative fixtures: create once in the pilot project with a
`zz.negative.*@globos.test` prefix, excluded from Gate 0's required list.
Failure action for any row: block deploy sign-off; file against the login
gate contract, not against individual screens.

## Gate 2 — Order Lifecycle Contract (new SQL test)

Type: automated SQL contract test (service-role psql script or Dart
contract test hitting RPCs; one transaction per scenario, rolled back or
run against seeded scratch data). This is the direct verification of
state-contract invariants I1–I5 — the layer where POS-006/008/024-class
bugs are actually caught. UI tests alone cannot pin these.

### Scenario A — Happy path

| Step | Action (RPC) | Assert After Step |
|------|--------------|-------------------|
| A1 | `create_order` (table T, 2 items) | order `pending`; items `pending`; table `occupied` (I5) |
| A2 | item1 → `preparing` | order `confirmed` |
| A3 | item1 → `ready`, item2 → `preparing`→`ready` | order `serving` (I2) |
| A4 | `process_payment` | order `completed`; payment row exists; table `available` (I3, I6) |
| A5 | any further item mutation | raises `ORDER_NOT_MUTABLE` (I1) |

### Scenario B — Add-mid-service (harness C1, the top pilot bug)

| Step | Action | Assert |
|------|--------|--------|
| B1 | reach `serving` as in A1–A3 | order `serving` |
| B2 | `add_items_to_order` (+1 item) | order drops to `confirmed` — NOT `serving`; new item `pending` |
| B3 | cashier payability query (`status='serving'`) | order NOT in queue |
| B4 | new item → `preparing` → `ready` | order back to `serving`; order IN queue |
| B5 | `process_payment` before B4 completes (item still `pending`) | raises `ORDER_NOT_PAYABLE` (I3) |

### Scenario C — Cancel paths (harness C2, H2)

| Step | Action | Assert |
|------|--------|--------|
| C1 | order with items `pending`+`preparing`; `cancel_order` | order `cancelled`; BOTH items `cancelled` (I4); table `available` (I5); audit rows exist (I7) |
| C2 | order with one `served` item; `cancel_order` default | raises `ORDER_HAS_SERVED_ITEMS` |
| C3 | same, `p_allow_served := true` | order `cancelled`; served item untouched; table released |
| C4 | `cancel_order_item` on a `ready` item | item `cancelled` (H2 fix); order status recalculated |
| C5 | cancel LAST active item via `cancel_order_item` | order auto-`cancelled`; table `available` |
| C6 | `cancel_order_item` on `served` item | raises `ITEM_NOT_CANCELLABLE` (I8) |
| C7 | two orders race on table release: cancel order-1 after order-2 opened on same table | table stays `occupied` (cancel releases only own occupancy) |

Failure action: any Scenario A–C failure = the state-contract migration is
wrong; do not proceed to Gate 3; fix migration, re-run Gate 2 only.

## Gate 3 — Cross-Screen E2E (promote existing integration test)

Type: `integration_test/full_multi_account_smoke_test.dart` against the
pilot backend. Changes needed:

1. **Promote from optional to required runbook step** (runbook §deploy
   verification, after `smoke_pilot_login.sh`). CI wiring is P2; operator
   execution is mandatory now.
2. Add assertions matching the new contract: after kitchen marks all items
   ready, cashier queue contains the order (was the C1 blind spot the old
   test could pass through by luck of timing); after payment, waiter table
   map shows the table available.
3. Add one cancel-path pass: waiter cancels an in-kitchen order → kitchen
   ticket disappears → table available.

| # | Flow | Pass Criteria |
|---|------|---------------|
| 3.1 | 5-role login + landing screen per role | each role reaches its home route |
| 3.2 | waiter: table → guests → add items → send | order visible in waiter's sent list |
| 3.3 | kitchen: ticket appears ≤15s, advance all items to ready | kitchen shows `serving` handoff done |
| 3.4 | cashier: order in queue, execute payment | success toast; order leaves queue |
| 3.5 | waiter: table released | table `available` on map |
| 3.6 | cancel path: new order → waiter cancels → kitchen ticket gone, table free | both screens consistent |
| 3.7 | daily closing flow (existing) | unchanged pass |

Failure action: screen-level bug — file against the owning screen with the
Gate 2 result attached (Gate 2 green + Gate 3 red = client-side filter/UI
defect by construction; that split is the point of the layering).

## Manual — Pilot Dry-Run Checklist (first pilot day, one pass)

Type: human, extends `GLOBOS_POS_manual_verification_checklist_2026-05-19.md`.
Only items automation can't judge:

- [ ] Button feedback: every save/create on the pilot's actual flows shows
      success/failure within 20s (spot-check inventory purchase screens —
      harness H5 fix verification)
- [ ] VI device: menu names render in expected language, no truncated
      names on waiter/kitchen tickets (harness H4/M — until i18n schema
      lands, verify pilot store menu names are entered in VI)
- [ ] Current Check entry point findable by a first-time waiter within 10s
- [ ] Error copy readable in the staff's language (AC3/AC5 messages)

## Runbook Integration

Insert into `POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md` after the existing
live-HTTP check:

```
7a. bash scripts/check_pilot_account_readiness.sh   # Gate 0
7b. bash scripts/smoke_pilot_login_matrix.sh        # Gate 1
7c. bash scripts/contract_order_lifecycle.sh        # Gate 2
7d. flutter test integration_test/full_multi_account_smoke_test.dart \
      --dart-define=... (pilot env)                 # Gate 3
```

Sign-off rule: deploy announcement may say "파일럿 가능" only with all
four gates green, output logs attached.

## Build Order (matches Priority Fix List dependencies)

1. Gate 0 + Gate 1 scripts — no product-code dependency; buildable TODAY
   against current behavior EXCEPT rows 1.6/1.7 (need login-gate contract
   implemented; mark `pending-spec` until then).
2. Gate 2 — depends on the state-contract migration (Priority Fix 1–2, 4).
   Write the test FIRST against the spec; it must fail on current main
   (reproduces C1/C2), then the migration makes it pass.
3. Gate 3 modifications — after Gate 2 is green once.

## Out of Scope

- CI scheduling / GitHub Actions wiring (P2 — operator-run is the gate)
- Load/latency testing, realtime 15s fallback tuning
- Office app boundary accounts (already covered in existing integration
  test, unchanged)
- i18n full 3-language scan automation (separate axis; manual spot-check
  above is the pilot-blocking subset)
