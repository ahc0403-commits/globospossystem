# Discount + Staff Meal V1 — Revised Implementation Plan

Date: 2026-07-04
Status: PRODUCTION DEPLOYED 2026-07-06 (DB + Vercel; pilot smoke still required)
Supersedes: the draft plan reviewed 2026-07-04 (approach A retained; details corrected)
Binding contracts: `ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03.md`,
CLAUDE.md §4 (payment never depends on e-invoice vendor), §7 invariants.

## 0. Verdict on the draft plan

Approach A (audited manual discount + staff-meal order purpose, no promotion
engine) is the right call and is retained. The draft is NOT implementable as
written — the following claims/gaps were verified against prod
(`ynriuoomotxuwhuxxmhj`) and the working tree today:

| # | Draft claim / gap | Verified reality | Consequence |
|---|---|---|---|
| C1 | "fill MISA payload `dc_rate`/`dc_amt`" | These fields are not part of the active POS→MISA line snapshot path. Legacy schema/vendor references may exist, but the live MISA line snapshot is built by the meinvoice trigger from `order_items` columns `vat_rate, vat_amount, total_amount_ex_tax, paying_amount_inc_tax` (20260630000000:346-364) | Discount must flow through the order_items VAT columns that `process_payment` writes. No active payload work exists or is needed |
| C2 | plan referenced `supabase/schema.sql:6202` as process_payment source | `process_payment` was redefined on prod 2026-07-03 (`20260703010000`, adds the `ORDER_NOT_PAYABLE` all-items-ready guard). **No repo file is the live source** | The discount migration MUST be generated from live `pg_get_functiondef(process_payment)` and MUST preserve the I3 guard |
| C3 | "SERVICE payments are is_revenue=false" | True, but SERVICE is stored as `method='OTHER'` (`v_payment_method_storage`); `payments_method_check` does not allow 'SERVICE' | Reports/queries must aggregate by `is_revenue` + `order_purpose`, never `method='SERVICE'` |
| C4 | draft modifies payment totals but keeps client-supplied `p_amount` | current RPC only checks `p_amount > 0` | With discounts this becomes exploitable/error-prone. Server must recompute payable/paid totals, derive remaining due, allow partial splits up to that due, and reject invalid or over-remaining amounts |
| C5 | no rule for items changing after a discount is applied | `add_items_to_order` demotes serving→confirmed (recalc contract) | Define: discount applies only to `serving` orders; ANY item mutation auto-voids the active discount |
| C6 | rounding/proration unspecified | two VAT pricing modes live (`vat_pricing_mode` exclusive/inclusive), per-line VAT math in RPC | Exact allocation + rounding rules specified below (§4.4) |
| C7 | no EXECUTE/RLS hardening for new objects | F-1 lesson: `recalc_order_status` shipped callable-by-anyone | Every new RPC gets explicit REVOKE/GRANT; `order_discounts` is RPC-write-only |
| C8 | "photo upload success before discount" | POS offline rule blocks critical ops offline; PaymentProofService has an offline QUEUE | Discounts are **blocked offline** (no queued proofs); reuse upload code path, not the queue |
| C9 | separate `complete_staff_meal_order` RPC proposed | `process_payment('SERVICE')` already: validates all-items-done (I3), deducts inventory, completes order, releases table, `is_revenue=false` skips e-invoice | **Drop the extra RPC.** Staff meals close via `process_payment` with method `SERVICE` |
| C10 | staff meal flow unverified against lifecycle contract | I3 guard applies: SERVICE close requires all items ready/served | Intended behavior; no exception path needed |
| C11 | — | `restaurant_settings` = `id, restaurant_id, payroll_pin, settings_json, updated_at` (verified) | `settings_json.discount_manager_pin_hash` is valid; agree payroll_pin is not reused |
| C12 | staff-meal orders "kitchen처럼 흐른다"만 언급 | cashier queue is `status='serving'` only — staff-meal orders WILL appear there (that's their close path) | Cashier needs a staff-meal badge + SERVICE preselected; hiding them would orphan the close path |

## 1. V1 scope (pinned)

**In**: order-level manual/coupon/promotion-labelled discount (one active per
order), manager-PIN approval, mandatory proof photo, discounted VAT columns →
e-invoice automatic; staff-meal orders (`order_purpose='staff_meal'`),
tableless creation, kitchen badge, SERVICE close, report split.

**Out (explicitly)**: promotion/coupon engines, item-level discounts,
stacking, post-payment discount changes (refund/void domain — existing
payment adjustments from 43ca5a6), offline discount queueing, Office app
changes, staff-meal approval workflows beyond PIN.

## 2. Data model

### 2.1 `order_discounts` (new table)

```sql
CREATE TABLE public.order_discounts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id   uuid NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  order_id        uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  discount_type   text NOT NULL CHECK (discount_type IN ('promotion','coupon','manual')),
  discount_mode   text NOT NULL CHECK (discount_mode IN ('amount','percent')),
  discount_value  numeric(12,2) NOT NULL CHECK (discount_value > 0),
  discount_amount numeric(12,2) NOT NULL CHECK (discount_amount >= 0), -- resolved at apply time, re-resolved at payment
  reason          text,
  coupon_code     text,
  proof_storage_path text NOT NULL,           -- V1: proof is mandatory
  applied_by      uuid NOT NULL REFERENCES auth.users(id),
  approved_via    text NOT NULL DEFAULT 'manager_pin',
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','voided','consumed')),
  void_reason     text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
-- exactly one live discount per order
CREATE UNIQUE INDEX order_discounts_one_active
  ON order_discounts(order_id) WHERE status = 'active';
CREATE INDEX order_discounts_store_day ON order_discounts(restaurant_id, created_at);
ALTER TABLE order_discounts ENABLE ROW LEVEL SECURITY;
-- SELECT: store-scoped staff. INSERT/UPDATE/DELETE: none (RPC-only via SECURITY DEFINER).
```

`percent` bounds enforced in RPC: `0 < value <= 100`. `amount` capped at the
order's payable total at apply time and re-capped at payment time.

Status meanings: `active` (applies to next payment) → `consumed` (payment
succeeded with it) or `voided` (manual void / auto-void on item mutation).

### 2.2 `orders.order_purpose` (new column)

```sql
ALTER TABLE orders ADD COLUMN order_purpose text NOT NULL DEFAULT 'customer'
  CHECK (order_purpose IN ('customer','staff_meal'));
```

(No `service` value in V1 — the draft's third value has no consumer; add
later if a real flow needs it. `sales_channel` untouched.)

### 2.3 Manager PIN

`restaurant_settings.settings_json ->> 'discount_manager_pin_hash'`
(bcrypt via pgcrypto `crypt()`), written only by
`set_discount_manager_pin(p_store_id, p_pin)` (admin/store_admin/super_admin).
Admin settings reads status through `has_discount_manager_pin(p_store_id)` so
the hash itself is not exposed to Flutter. Approval is verified only
server-side inside `apply_order_discount` / `create_staff_meal_order`. Failed
attempts write an `audit_logs` row (`discount_pin_rejected`); V1 has no
lockout (decision: audit-only — add lockout later if pilot shows abuse).

## 3. RPC surface (all SECURITY DEFINER, all with the standard
role + `user_accessible_stores` + store-match guard; all end with
`REVOKE ALL ... FROM PUBLIC, anon;` + `GRANT EXECUTE ... TO authenticated,
service_role;` — F-1 lesson)

### 3.1 `apply_order_discount(p_order_id uuid, p_store_id uuid, p_type text, p_mode text, p_value numeric, p_reason text, p_coupon_code text, p_proof_storage_path text, p_manager_pin text) RETURNS order_discounts`

Guards, in order:
1. actor role IN ('cashier','admin','store_admin','super_admin') AND
   (admin-tier OR `'discount_apply' = ANY(extra_permissions)`);
2. PIN verifies against `discount_manager_pin_hash` (missing hash ⇒
   `DISCOUNT_PIN_NOT_CONFIGURED`);
3. order `FOR UPDATE`, must be `status='serving'` (payable stage only) —
   `DISCOUNT_ORDER_NOT_PAYABLE` otherwise;
4. `p_proof_storage_path` non-empty (`DISCOUNT_PROOF_REQUIRED`);
5. no existing `active` discount (`DISCOUNT_ALREADY_ACTIVE` — void first);
6. compute `discount_amount` from the CURRENT payable total (see §4.4);
   `amount` mode capped at total; percent `0<v<=100`;
7. insert row + `audit_logs('apply_order_discount', …)`.

### 3.2 `void_order_discount(p_discount_id uuid, p_store_id uuid, p_reason text) RETURNS order_discounts`

Cashier-with-permission/admin; only `active` rows; only while the order is
not `completed` (post-payment reversal = payment-adjustment domain). Audit.

### 3.3 Auto-void hook (inside existing RPCs, same migration)

`add_items_to_order`, `cancel_order_item`, `edit_order_item_quantity`:
after their mutation + recalc, run
`UPDATE order_discounts SET status='voided', void_reason='order_items_changed' WHERE order_id=… AND status='active'`
+ audit row. (Keeps C5 invariant: an active discount always matches the
item set it was approved for.)

### 3.4 `create_staff_meal_order(p_store_id uuid, p_items jsonb, p_staff_user_id uuid, p_reason text, p_manager_pin text) RETURNS orders`

- actor role IN ('waiter','cashier','admin','store_admin','super_admin');
  PIN required (same hash — one manager code for both features in V1);
- item validation identical to `create_order` (menu ownership,
  `is_available`, quantity>0);
- inserts `orders(restaurant_id, table_id=NULL, status='pending',
  order_purpose='staff_meal', notes=p_reason, created_by=auth.uid())` +
  items (`label`/`display_name` from menu, like create_order);
- **no table occupancy** (table_id NULL — verified nullable);
- `details` in audit carries `p_staff_user_id`;
- flows through the normal lifecycle: kitchen lanes → recalc → `serving` →
  cashier closes with `process_payment(order, store, total, 'SERVICE')`.

### 3.5 `set_discount_manager_pin` / `clear_discount_manager_pin` / `has_discount_manager_pin`

Admin-tier only; bcrypt hash into settings_json; audit set/clear (never log
the pin). `has_discount_manager_pin` returns only boolean status for the admin
settings UI.

### 3.6 `process_payment` — single modification point (see §4)

Regenerated **from live `pg_get_functiondef`** (not from any repo file),
preserving verbatim: the I3 `ORDER_NOT_PAYABLE` guard, SERVICE→OTHER
mapping, vat_pricing_mode branches, service-charge synthesis, inventory
deduction, table release, and the completed-order meInvoice trigger boundary.
Do not insert into legacy `einvoice_jobs` from this RPC.

## 4. Payment math (the part the draft left undefined)

### 4.1 Insertion point

Inside `process_payment`, after the order lock + I3 guard and BEFORE the
per-line VAT loop:

```sql
SELECT * INTO v_discount FROM order_discounts
WHERE order_id = p_order_id AND status = 'active'
FOR UPDATE;
```

### 4.2 Re-resolution at payment time

- `percent`: `v_discount_total := ROUND(v_undiscounted_inc_total * value/100, 0)`
  (recomputed — item set may legally differ only via voiding, but re-resolve
  defensively).
- `amount`: `v_discount_total := LEAST(value, v_undiscounted_inc_total)`.

This requires the undiscounted inc-tax total first ⇒ restructure the line
loop into two passes: pass 1 computes each line's undiscounted inc-tax
amount (existing mode formulas), pass 2 applies allocation and writes
columns. (Service-charge synthesis stays between passes, computed on
UNDISCOUNTED food/alcohol subtotals — pinned decision: service charge is not
discounted in V1.)

### 4.3 Server-side amount validation (C4)

The server computes the discounted payable total, subtracts prior paid
amounts, and derives `remaining_due`. Negative payments, non-positive payments
while amount remains due, overpayments, and non-zero payments after the order
is fully paid are rejected with `PAYMENT_AMOUNT_INVALID` or
`PAYMENT_AMOUNT_EXCEEDS_REMAINING`. Partial payments are allowed while
`p_amount <= remaining_due`; the order completes only when total paid reaches
the recomputed payable total. SERVICE payments validate identically and remain
non-revenue for staff meals.

### 4.4 Per-line allocation + rounding (both VAT modes)

Allocate `v_discount_total` across menu_item lines proportionally to their
undiscounted inc-tax amounts, using **largest-remainder** so the allocated
sum equals the discount exactly:

```
share_i   = floor(discount_total * line_inc_i / total_inc)
remainder = discount_total - Σ share_i   → +1 to lines with the largest
                                            fractional parts until exhausted
line_inc'_i = line_inc_i - share_i
```

Then derive per-line columns from the DISCOUNTED inc amount with the
existing mode math:
- exclusive mode: `pretax' = ROUND(line_inc' / (1 + rate/100))`,
  `vat' = line_inc' - pretax'`;
- inclusive mode: same formula (inc is the basis in both; the modes differ
  upstream in how `unit_price` maps to inc — reuse the live branch verbatim
  and only substitute the discounted inc).

Write `total_amount_ex_tax = pretax'`, `vat_amount = vat'`,
`paying_amount_inc_tax = line_inc'` — the meinvoice trigger snapshot (C1)
then carries discounted values with zero extra work. Finally
`UPDATE order_discounts SET status='consumed', discount_amount = v_discount_total`.

Rounding unit: whole VND (`ROUND(x, 0)`) to match MISA integer amounts —
note the live RPC uses `ROUND(…, 2)`; keep 2dp if that is what the live
body does (decide by reading the live prosrc during implementation; the
allocation algorithm is unit-agnostic).

## 5. Client changes (Flutter)

| Surface | Change |
|---|---|
| `payment_total_calculator.dart` | add `discountTotal` input term; quote returns `subtotal / discount / payable` |
| `payment_provider.dart` | select `order_discounts(status,discount_amount,discount_mode,discount_value)` with the serving query; expose to quote + UI |
| `cashier_screen.dart` | 할인 버튼 (visible iff `discount_apply` in extraPermissions or admin-tier); modal: type/mode/value/reason/coupon/photo/PIN; 원금·할인·결제금액 3줄 표시; staff-meal 배지 + SERVICE preselect when `order_purpose='staff_meal'` |
| `DiscountProofService` | reuse PaymentProofService upload code; new `discount-proofs` bucket; NO offline queue — offline ⇒ 버튼 비활성 + 안내 (C8) |
| staff-meal 진입 | admin 또는 waiter 화면 상단 액션(결정 §8-D2) → 메뉴 선택 재사용(OrderWorkspace 재사용 불가 시 간이 선택 시트) → `create_staff_meal_order` |
| `kitchen_screen.dart` / `kitchen_provider.dart` | select `order_purpose`; staff-meal 배지 on ticket |
| `staff_tab.dart` | `discount_apply` 권한 체크박스 (기존 extra_permissions UI 패턴) |
| `settings_tab.dart` / `PinService` | admin payment-protection panel exposes discount manager PIN boolean status + set/clear actions using `has_discount_manager_pin` / `set_discount_manager_pin` / `clear_discount_manager_pin`; client never receives or hashes this PIN because the RPC stores bcrypt via `crypt()` |
| reports / `get_cashier_today_summary` | discount_total(당일 consumed 합), staff_meal count/total (`order_purpose` join; SERVICE는 method='OTHER' 저장이므로 절대 method로 집계하지 않음 — C3) |
| l10n | 신규 문자열 en/ko/vi 3종 동시 추가 (하드코딩 금지 — H4 교훈) |

Storage migration: `discount-proofs` bucket + policies (authenticated
store-scoped SELECT/INSERT via path prefix `tax_entity_id/store_id/…`;
no authenticated UPDATE/DELETE policy because uploaded proofs are audit
evidence).

## 6. Migration / PR split (1-PR-1-risk)

0. **선행**: 2026-07-04 lib 수정 5건(메뉴 정렬·주방 분류 등) 재배포가 먼저.
   이 기능 브랜치는 그 위에서 시작.
1. **M1 (DB, 1 migration)**: `order_discounts` + RLS + `orders.order_purpose`
   + PIN RPCs + `apply/void_order_discount` + `create_staff_meal_order` +
   auto-void hooks patched into the three mutation RPCs (regenerated from
   live prosrc) + REVOKE/GRANT block. Idempotent-guarded.
2. **M2 (DB, 1 migration)**: `process_payment` two-pass discount math +
   `p_amount` validation (regenerated from live prosrc; I3 guard assert in
   the Gate-2 extension before/after).
3. **M3**: storage bucket + policies.
4. **PR-C1 (Flutter)**: calculator + provider + cashier discount modal + proof service.
5. **PR-C2 (Flutter)**: staff-meal creation UI + kitchen/cashier badges + staff tab permission + reports.
6. Docs: this plan → update PRIMARY_JOB_CONTRACT rows for cashier/kitchen/waiter staff-meal supporting actions.

Rollout order is DB-first (M1–M3 are additive/no-op for the current client:
old client sends no discount, RPC math with no active discount is identical
— verify with regression scenario T0 below), then client PRs.

## 7. Test matrix (Gate-2-style SQL contract test, extend
`supabase/tests/` with `discount_staff_meal_contract_test.sql`, same
exception-rollback harness)

| # | Scenario | Expect |
|---|---|---|
| T0 | payment with NO discount, before/after M2 | identical totals/columns (regression) |
| T1 | percent 10% on serving order, 2 lines, pay exact | line columns discounted, Σ allocation = discount, payment ok, discount `consumed` |
| T2 | amount > total | capped at total; expected amount = 0-able? (min payable 0 ⇒ `p_amount=0` conflicts with `p_amount>0` guard → pin decision: cap at total − 0 keeps guard; if fully discounted, expected=0 and guard must allow 0 for discounted payments — implement `p_amount >= 0` only when a discount covers total) |
| T3 | wrong PIN / missing PIN config | `DISCOUNT_PIN_REJECTED` / `DISCOUNT_PIN_NOT_CONFIGURED`; audit row |
| T4 | no `discount_apply` permission (plain cashier) | forbidden |
| T5 | cross-store apply | forbidden |
| T6 | order not serving (pending/confirmed/completed) | `DISCOUNT_ORDER_NOT_PAYABLE` |
| T7 | second active discount | `DISCOUNT_ALREADY_ACTIVE` |
| T8 | apply → `add_items_to_order` | discount auto-`voided`, order demoted (recalc), payment uses no discount |
| T9 | invalid payment amount | negative/non-positive amount while due, over-remaining amount, or non-zero amount after zero due rejected with `PAYMENT_AMOUNT_INVALID` / `PAYMENT_AMOUNT_EXCEEDS_REMAINING`; partial split payments below remaining due stay `serving` |
| T10 | staff meal: create (no table) → kitchen ready → SERVICE close | order `completed`, payment `is_revenue=false, method='OTHER'`, inventory deducted, **no meinvoice job** (trigger fires only for revenue — assert), no table touched |
| T11 | staff meal close attempt with pending item | `ORDER_NOT_PAYABLE` (I3 preserved) |
| T12 | discount consumed → meinvoice snapshot columns | line snapshot carries discounted `vat_amount`/`paying_amount_inc_tax` |
| T13 | proof path empty | `DISCOUNT_PROOF_REQUIRED` |
| T14 | percent bounds (0, 101) | rejected |
| T15 | discount proof storage ACL | authenticated can SELECT/INSERT scoped proofs, but no ALL/UPDATE/DELETE proof policy exists |
| T16 | discount manager PIN setup path | admin settings can fetch status and call set/clear RPCs; cashier/waiter flows no longer depend on manual SQL setup |

Plus: `dart analyze`, calculator unit tests (rounding/allocation mirror of
§4.4), existing contract suite green, Gate 3 smoke re-run (badges keyed:
`cashier_discount_button`, `staff_meal_badge` for future assertions).

## 8. Decisions needed from Hyochang (defaults proposed)

- D1 service charge 할인 대상 제외 (기본: 제외) — §4.2
- D2 직원식 생성 진입점: admin 화면 vs waiter 화면 액션 (기본: waiter 상단
  액션 + 권한 무관, PIN이 게이트)
- D3 전액 할인(0원 결제) 허용 여부 (기본: 허용, T2 규칙)
- D4 PIN 실패 잠금: V1 audit-only (기본) vs 5회/60초 잠금

## 9. Explicit non-risks (verified today)

- e-invoice: 컬럼 경유 자동 전파 (C1) — payload 작업 없음.
- staff meal은 기존 SERVICE 경로 그대로 — `payments` CHECK 변경 불필요 (C3).
- `orders.table_id` nullable — 스키마 변경 불필요.
- 신규 기능은 recalc/lifecycle 계약과 충돌 없음 (serving-only apply + auto-void가 정합성 보장).
