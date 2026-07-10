# Pilot Full-System Test Plan (v2)

Date: 2026-07-09
Supersedes: the order/payment/print-centric draft discussed in chat.
Scope: full POS + back-office readiness before real-hardware pilot
(PC ×1, kitchen tablet ×1, printers ×4, waiter phones, customer QR).

## 0. Verified current state (prod `ynriuoomotxuwhuxxmhj`, 2026-07-09)

Facts checked live before this plan was written:

| Item | State | Consequence |
|---|---|---|
| QR migration (tables + 4 RPCs + `orders.order_source`) | **Applied to prod** | QR gate can run against prod |
| `printer_destinations` | **0 rows** | No print routing can succeed anywhere; Gate 2 must create them |
| `table_qr_tokens` | **0 rows** | No QR ordering possible until admin generates tokens |
| `tables.floor_label` | **All stores 1F only** | 2F/3F routing untestable until pilot store gets real floor data |
| `print_jobs` history | 6 failed / 4 cancelled, **0 completed ever** | Print path has never been device-verified; agent never ran live |
| pgTAP extension | Available, **not installed** | 5 of 7 SQL contract tests cannot run on prod as-is |
| `brands.code='globos_default'` | **Absent on prod** | pgTAP test fixtures insert 0 rows on prod → false failures |
| Prod web build | Static asset hashes match local `.vercel/output`; QR markers are present | `/#/qr/:token`, cashier QR badges, admin QR dialog, and print station UI are live |
| meInvoice dispatch | Flag false, 0 config rows, no cron | Payment already provably vendor-independent; out of pilot scope |
| All 23 Dart test files + 4 SQL test files named in draft | **Exist** | Command list is valid, but incomplete (see Gate 1) |

## 1. Gate 0 — Scope freeze + deploy baseline

Owner: Claude (verify), Hyochang (approve deploy).

1. E-invoice issuance is out of pilot scope. Payment independence is already
   enforced (async queue + catch-all trigger + `meinvoice_dispatch_enabled=false`).
2. Production is already serving the QR-capable build: live static asset
   hashes match local `.vercel/output`, and `main.dart.js` contains
   `qr_order_screen`, `admin_table_qr_dialog`, `cashier_qr_order_badge`,
   and `print_station_root`.
3. Because this was a prebuilt Vercel artifact deployment, Vercel metadata
   does not prove a git commit SHA. Treat asset hashes + live route checks as
   the deployment evidence, or optionally redeploy once before the pilot to
   create a clean timestamped baseline.
4. Baseline verification (Claude): live HTTP 200 on app URL, `/#/qr/<dummy>`
   route renders the Flutter app shell (invalid-token state inside the app,
   not a platform 404), cashier queue visually loads.

Pass: production static assets match the approved local build; `/qr` route live.

## 2. Gate 1 — Automated verification (Claude)

### 2.1 Static + full Dart contract suite

```bash
flutter analyze
flutter test
```

Run the **entire** `test/` suite, not the hand-picked 23. The draft list
omitted at least: `discount_staff_meal_contract_test.dart`,
`service_item_exclusion_contract_test.dart`,
`waiter_floor_layout_contract_test.dart`, `router_role_guard_test.dart`,
`permission_route_parity_contract_test.dart`, i18n contract tests, and the
security/RLS contract tests. The full suite is cheap (pure contract tests)
and removes selection bias. Any failure = Gate 1 fail.

### 2.2 SQL contract tests — LOCAL stack, not prod

The pgTAP tests (`order_lifecycle`, `print_routing`, `discount_staff_meal`,
`service_item_exclusion`, `photo_objet_pos`) require the pgTAP extension
(not installed on prod) and a `brands.code='globos_default'` seed row
(absent on prod). Running them with a prod `DB_URL` produces false failures
from silently-empty fixtures. Therefore:

```bash
supabase start
supabase db reset   # applies all migrations + seed
DB_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
for f in order_lifecycle print_routing qr_table_ordering \
         discount_staff_meal service_item_exclusion store_closure; do
  psql "$DB_URL" -f "supabase/tests/${f}_contract_test.sql" || exit 1
done
```

Additionally, `qr_table_ordering_contract_test.sql` is prod-safe
(single-transaction rollback, self-contained fixtures) and MUST also be run
once against prod to prove the applied migration behaves identically there.

Pass: all scenarios PASS locally + QR SQL test PASS on prod.

### 2.3 Integration smoke (strongest automated E2E)

```bash
flutter test integration_test/full_multi_account_smoke_test.dart -d chrome
```

Covers waiter create/cancel → kitchen status cycle → cashier targeted
payment → durable queue-removal assert, plus login-block accounts. The
draft plan omitted this file entirely; it is the only automated test that
exercises the real multi-role chain.

## 3. Gate 2 — Master data provisioning (Hyochang, Claude verifies)

Name **one pilot store** explicitly (no AKJ store exists on prod yet — if
the pilot venue is AKJ, the store + staff + tax entity must be onboarded
first). Required outputs, each verifiable by SQL:

1. Floors and tables: real `floor_label` values (1F/2F/3F as the venue
   actually is — prod currently has 1F only) and real table numbers.
2. `printer_destinations`: 5 logical rows for 4 physical printers (kitchen,
   receipt, and 1F/2F/3F floor routes). The cashier printer IP is registered
   twice with `floor` and `receipt` purposes. Every row uses a fixed IP,
   correct `purpose` + `floor_label`, and `is_active=true`.
   Currently **0 rows exist** — this is the single biggest data gap.
3. Staff accounts per role (waiter/kitchen/cashier/admin) with store scope;
   login matrix re-run via `scripts/pilot_gate1_login_matrix.sh`.
4. Menu: real categories/items/prices, VAT fields populated, `is_available`
   and `is_visible_public` set per item (QR menu = public subset).
5. QR tokens: `admin_generate_table_qr` for every table; print + laminate.
   Currently **0 tokens exist**.
6. Inventory: real ingredients, units, opening stock, thresholds; suppliers
   and purchase-order units.
7. Attendance: kiosk device signed in, staff enrolled.

Claude verification: one SQL report asserting counts > 0 and shape for each
of the above on the pilot store, plus cross-store leak spot-check (pilot
staff cannot read another store's rows).

## 4. Gate 3 — Browser dry-run, virtual devices (Hyochang drives, Claude monitors DB)

Viewport-matched runs on the deployed build: PC width (cashier + admin),
tablet width (kitchen), phone width (waiter), phone (customer QR).

Sales-floor sequence (repeat ×3, including one cancel and one split payment):

1. Waiter: seat guests → order 2 items (1F) → add 1 item after first send.
2. Customer QR: scan real token on a different table → order 1 public item
   → verify it lands on the **correct table**, QR badge visible in kitchen
   and cashier; replay the same `client_order_id` (refresh + resubmit) →
   no duplicate order.
3. Kitchen: receive both orders, cycle statuses to ready/served; verify
   completed orders leave active lanes.
4. Cashier: order search by code/table, pay one order cash, one split
   (cash+card), refund path once; `ORDER_NOT_PAYABLE` guard on a
   not-yet-ready order.
5. Print: every step above must enqueue the right `print_jobs` rows
   (kitchen/floor/confirmation copy types, correct destination). Claude
   asserts rows in DB even though no physical printer exists yet;
   NO_DESTINATION failures are a Gate 2 regression, not acceptable noise.

Back-office sequence (same day):

6. Attendance: clock-in/out for two staff via kiosk; admin sees records;
   payroll preview renders coherent hours.
7. Inventory: restock one ingredient, record one waste; stock reflects both.
8. Purchase: create PO → receive partial → receive remainder → stock and
   PO status consistent.
9. QC: run one checklist, flag one issue, resolve it.
10. Reports: sales report matches the day's payments (amount and count);
    open-orders report empty after all orders closed.
11. Daily close: verify the 00:00 Asia/Ho_Chi_Minh boundary assigns
    today's sales to today (contract test covers logic; human verifies the
    report reads correctly).

Pass: every step succeeds without console errors; Claude's DB assertions
all hold; no cross-store rows visible at any point.

## 5. Gate 4 — Real-hardware pilot (Hyochang, on site)

Prerequisite: Gates 0–3 all green. New verifications only (do not re-test
logic already proven in Gate 3):

1. 4 printers on fixed IPs; print agent claims and prints real paper for
   kitchen/floor/confirmation/receipt copies; reprint works; auto-cutter,
   font size, Vietnamese diacritics legible.
2. PC runs cashier + print station simultaneously; sleep disabled; recovery
   after browser refresh mid-shift.
3. Kitchen tablet at the actual kitchen location: Wi-Fi strength, touch
   targets, readability at arm's length.
4. Waiter personal phones: per-staff login, order speed on small screens,
   behavior on network drop (order retry, no duplicates).
5. Customer phone: scan laminated QR from the actual table position
   (lighting/angle), order end-to-end, confirmation slip prints at cashier.
6. One full business-day simulation ending in daily close + Z-report-style
   reconciliation: payments Σ == report Σ == cash drawer expectation.
7. Usability log: every point where a staff member needed an explanation.

## 6. No-Go criteria (unchanged from draft, plus two)

Any of the following blocks go-live:

- Order/payment/kitchen/print core-flow failure
- Attendance records missing or not attributable per staff
- Inventory/receiving quantities wrong after PO cycle
- Post-receiving stock vs report mismatch
- QR order landing on the wrong table
- Cross-store data exposure
- Duplicate payment, over-refund, duplicate order
- Daily close totals ≠ payments − refunds
- **NEW:** any print job stuck with NO_DESTINATION at a configured store
- **NEW:** QR replay (same client_order_id) creating a second order

## 7. Explicit exclusions

- E-invoice issuance (MISA AppID blocked; Viettel pending vendor onboarding)
- Store closure flow (already contract-verified 13/13; not a pilot activity)
- Office app coupling beyond read-only spot-check (Section 5 of CLAUDE.md)
