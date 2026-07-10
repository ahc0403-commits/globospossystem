# QR Table Ordering (자동완료형) V1 — Implementation Plan

Date: 2026-07-08
Status: PLAN (no code changes yet)
Idea reviewed: customer scans per-table QR → public mobile menu → 주문완료 →
order lands in POS/kitchen with NO staff approval and NO payment attached;
payment stays cashier-only.
Binding: `ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03.md`,
`PRINT_ROUTING_V1_PLAN_2026_07_04.md`, discount C5 / split-payment C4 rules
(deployed), store closure Layer 1, CLAUDE.md §4/§5/§7.

## 0. Verdict on the idea + verified premises

The flow is sound and maps cleanly onto what is already deployed. Verified
live today: `menu_items.is_visible_public` exists (draft was right to reuse
it); `orders.created_by` is NULLABLE (anonymous orders need no schema
change there); `print_jobs.copy_type` CHECK is `kitchen|floor|tray` (needs
widening); `enqueue_print_jobs` resolves table/floor internally from the
order (a new copy type routes with near-zero new code).

Rules the idea did not state but the deployed system REQUIRES:

| # | Gap | Deployed reality | Rule |
|---|---|---|---|
| Q1 | append during payment | split payments live: `remaining_due = total − Σ amount_portion` | **append is blocked once any payment row exists** on the live order → `QR_ORDER_PAYMENT_IN_PROGRESS`, customer sees "결제가 진행 중입니다. 직원을 불러주세요" |
| Q2 | append vs active discount | C5: any item mutation auto-voids the active discount | qr append does the same (`void_reason='order_items_changed'`) |
| Q3 | append vs serving | recalc demotes serving→confirmed on new pending items | intended: order drops out of cashier queue until kitchen finishes the added items — no special code, but the cashier-search UX must show non-serving orders' status (§6) |
| Q4 | closed store QR | closure Layer 1 pattern | token resolution requires `restaurants.is_active = true` |
| Q5 | server-side prices | C4 lesson: never trust client amounts | qr RPC reads price/label from `menu_items`; client sends only ids+qty |
| Q6 | staff RPC reuse | `create_order`/`add_items_to_order` require an authenticated actor row | anon can never call them; dedicated `qr_place_order` replicates the insert shape but MUST reuse the two shared primitives — `recalc_order_status` and `enqueue_print_jobs` — so lifecycle/printing can never drift |

Copy contract (pinned, from the idea — non-negotiable wording): customer
screen never says 결제/paid. Success copy = "주문이 접수되었습니다 / 직원이
주문확인서를 가져다 드립니다 / 결제는 식사 후 캐셔에서 진행해 주세요".
Confirm dialog = "주문을 완료하면 바로 주방으로 전달됩니다. 결제는 식사 후
캐셔에서 진행합니다. 주문하시겠습니까?". Slip footer = "This is not a
receipt. Payment at cashier only." Table name renders LARGE on both the QR
page header and the slip (misplaced-QR mitigation).

## 1. Architecture

```
customer phone (no login)
  └─ Flutter web public route /qr/<token>   [same Vercel app]
       ├─ qr_get_menu(token)      → store/table header + public menu   [RPC, GRANT anon]
       └─ qr_place_order(token, items, client_order_id)                [RPC, GRANT anon]
            ├─ token→table/store resolve (+store active, token active)
            ├─ branch: no live order → create | live order → append
            ├─ guards: payments-exist block, caps, throttle, idempotency
            ├─ shared: recalc_order_status(), enqueue_print_jobs()
            │     kitchen+floor ticket (delta) + NEW 'confirmation' slip
            └─ returns {order_code, batch_no, items, table, floor}
staff surfaces: kitchen lanes (+QR badge), print agent (new slip renderer),
cashier queue (+search by code/table), admin tables tab (+QR manage/rotate)
```

The token IS the credential. No auth session, no RLS changes for anon —
anon touches the database ONLY through the two `qr_*` SECURITY DEFINER
RPCs (F-1 discipline: every other function stays revoked from anon).

Why Flutter-web public route (not a separate site): zero new infra, reuses
l10n/theme/supabase client (web build already carries the anon key via
dart-define). Known cost: Flutter-web first-load weight on phones —
accepted for V1, revisit only if pilot shows real drop-off (§8-D2).

## 2. Data model (migration `202607100xxxxx_qr_table_ordering_v1.sql` —
number after live remote check, current max 20260709xxxxxx)

```sql
-- provenance for kitchen badge / reporting / abuse triage
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS order_source text NOT NULL DEFAULT 'staff'
  CHECK (order_source IN ('staff','qr'));

CREATE TABLE public.table_qr_tokens (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  table_id      uuid NOT NULL REFERENCES tables(id) ON DELETE CASCADE,
  token         text NOT NULL UNIQUE,          -- encode(gen_random_bytes(24),'base64') url-safe
  is_active     boolean NOT NULL DEFAULT true,
  created_by    uuid REFERENCES auth.users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  rotated_at    timestamptz
);
CREATE UNIQUE INDEX table_qr_tokens_one_active
  ON table_qr_tokens(table_id) WHERE is_active;   -- rotation = deactivate + insert

CREATE TABLE public.qr_order_batches (             -- idempotency + slip audit
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id   uuid NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  table_id        uuid NOT NULL REFERENCES tables(id) ON DELETE CASCADE,
  order_id        uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  batch_no        int  NOT NULL,
  client_order_id uuid NOT NULL UNIQUE,            -- customer-side idempotency key
  items_snapshot  jsonb NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- widen print copy types
ALTER TABLE public.print_jobs DROP CONSTRAINT print_jobs_copy_type_check;
ALTER TABLE public.print_jobs ADD CONSTRAINT print_jobs_copy_type_check
  CHECK (copy_type IN ('kitchen','floor','tray','confirmation'));
```

RLS: both new tables — staff store-scoped SELECT only, writes RPC-only
(the hardening pattern). Tokens are secrets: SELECT policy admin-tier only
(waiters don't need raw tokens).

## 3. RPC surface

### 3.1 `admin_generate_table_qr(p_table_id uuid) RETURNS table_qr_tokens`
admin/store_admin/super_admin + store guard. Deactivates any active token
for the table (sets rotated_at) and inserts a fresh
`encode(gen_random_bytes(24),'base64')` (url-safe translated) token. Audit
`qr_token_rotated`. Old paper QR dies instantly — rotation is the
lost/moved-stand remedy.

### 3.2 `qr_get_menu(p_token text) RETURNS jsonb` — GRANT anon
1. resolve token: `table_qr_tokens.is_active` JOIN `tables` JOIN
   `restaurants r ON r.is_active` (Q4); miss ⇒ `QR_TOKEN_INVALID` (one
   generic error — don't leak which part failed);
2. returns `{store_name, table_number, floor_label, categories:[…],
   items:[{id, name, price, category_id}]}` filtered
   `is_available AND is_visible_public`, **ordered ascending** (menu-order
   lesson), category list only where it has visible items.
No secrets in the response; prices are display-only (server re-reads at
order time, Q5).

### 3.3 `qr_place_order(p_token text, p_items jsonb, p_client_order_id uuid) RETURNS jsonb` — GRANT anon

Guard/step order (each numbered step is a test scenario in §7):
1. token resolve as 3.2 (`QR_TOKEN_INVALID`);
2. **idempotency**: `qr_order_batches.client_order_id` exists ⇒ return the
   stored result verbatim (same order_code/batch_no — double-tap safe);
3. input caps: 1..20 lines, qty 1..20 each, valid uuids
   (`QR_ITEMS_INVALID`);
4. **throttle**: last batch for this table < 20s ago ⇒ `QR_TOO_FREQUENT`
   (client shows "잠시 후 다시 시도해 주세요");
5. menu validation: every item belongs to this store AND `is_available`
   AND `is_visible_public` (`QR_MENU_ITEM_UNAVAILABLE`) — prices/labels
   read server-side (Q5);
6. table lock (`FOR UPDATE` on tables row), find live order
   (`pending|confirmed|serving`) on this table:
   - none → INSERT order (`status='pending'`, `created_by=NULL`,
     `order_source='qr'`, `order_purpose='customer'`) + occupy table —
     mirroring `create_order`'s insert shape (label/display_name from
     menu, `item_type='menu_item'`);
   - exists → **payments-exist check first** (Q1,
     `QR_ORDER_PAYMENT_IN_PROGRESS`), then append delta items, then
     auto-void active discount (Q2, same UPDATE+audit as
     add_items_to_order);
7. `PERFORM recalc_order_status(order_id)` — the single derivation point
   (serving-demotion Q3 falls out for free);
8. batch_no = existing kitchen-print batches for the order + 1 (aligns
   slip numbering with kitchen ticket batches);
9. `enqueue_print_jobs(order_id, ARRAY['kitchen','floor','confirmation'],
   delta_items, 'qr_batch_'||batch_no)` — exception-guarded as always
   (printing must never abort the order); confirmation routes to the
   table's FLOOR destination, kitchen fallback (§8-D1);
10. INSERT `qr_order_batches` row (idempotency record + snapshot);
11. audit `qr_place_order` {table, batch, item_count, client_order_id};
12. return `{order_code: short8(order_id), batch_no, table_number,
    floor_label, items:[{name, qty}]}`.

All three RPCs: explicit `REVOKE ALL FROM PUBLIC` then `GRANT EXECUTE TO
anon, authenticated` (3.2/3.3) / admin-tier pattern (3.1). Everything else
in the schema stays anon-revoked.

### 3.4 Existing functions touched
None rewritten. `enqueue_print_jobs` already resolves table/floor from the
order; only the copy_type CHECK (table-level) widens. If its internal
destination-purpose mapping is a CASE over copy types, extend
'confirmation'→'floor' (fallback kitchen) — regenerate from live prosrc.

## 4. Confirmation slip (print agent)

`ReceiptBuilder.buildConfirmationSlip(payload)` — exact layout from the
idea, all caps drawn from payload (agent has no DB access):

```
ORDER CONFIRMATION            ← double width
Table: {table} / {floor}      ← double width+height (misplaced-QR defense)
Order: {short8}   Batch: {n}
Time:  {local time}
──────────────────────────────
{qty} x {label}    (delta items only)
──────────────────────────────
Please bring this slip to cashier.
This is not a receipt.
Payment at cashier only.
```

Agent switch gains the 'confirmation' case; reprint works via the existing
`reprint_print_job` for free. **Operational prerequisite: printer
destinations + agent must be live (open item M-2) — without them the slip
lands as `NO_DESTINATION` failed jobs and the paper workflow (customer →
cashier) breaks. QR pilot gate = print routing setup complete.**

## 5. Flutter — customer surface

| Piece | Detail |
|---|---|
| route | `/qr/:token` added to router publicRoutes + `canAccessRouteForRole` null-role exception (only this prefix); no auth calls on this path |
| screen `qr_order_screen.dart` | mobile-first single column. Header: store name + **Table {n} / {floor} 대형 표기**. Category chips(가로) + item list(name, price, stepper). Bottom cart bar → sheet: lines, total(표시용, "결제 금액은 캐셔 기준" 캡션), 주문완료 버튼 |
| confirm dialog | pinned wording (§0), keys `qr_confirm_dialog`, `qr_confirm_submit` |
| submit | generate `client_order_id` uuid ONCE per cart; button disabled+spinner during await; error mapping: `QR_TOKEN_INVALID`→"QR이 유효하지 않습니다. 직원을 불러주세요", `QR_ORDER_PAYMENT_IN_PROGRESS`→결제 진행 중 안내, `QR_TOO_FREQUENT`→잠시 후 재시도, offline→재시도 버튼(같은 client_order_id 재사용 = 안전) |
| success screen | "주문이 접수되었습니다" + batch/order_code/아이템 요약 + "직원이 주문확인서를 가져다 드립니다 / 결제는 식사 후 캐셔에서" + "추가 주문하기"(카트 리셋, 새 client_order_id) |
| l10n | vi/ko/en 3종 동시(고객 표면은 VI 우선 검수); 메뉴명은 DB 원문(H4 기존 백로그와 동일 규칙) |

Staff surfaces:
- kitchen: `order_source` select + `QR` badge on ticket card;
- cashier: 큐 상단 검색 필드(주문코드 8자/테이블 번호, 클라이언트측 필터,
  key `cashier_order_search`) — 비-serving 주문은 큐에 없으므로 검색 미스
  시 "주방 진행 중일 수 있습니다" 힌트 (Q3);
- admin tables tab: 테이블 편집에 "QR 관리" — 토큰 생성/회전 + QR 표시
  다이얼로그(`qr_flutter` dep, URL = `https://globospossystem.vercel.app/#/qr/<token>`),
  회전 경고("기존 부착 QR 즉시 무효"); 인쇄는 브라우저 인쇄/스크린샷 V1;
- admin menu tab: `is_visible_public` 체크박스 노출(컬럼은 이미 존재).

## 6. Rollout (1-PR-1-risk)

1. **M1 (DB)**: §2 + §3 — old clients no-op (new RPCs unused, order_source
   default, CHECK superset). Verify with QR-SC0 regression (§7).
2. **C1 (Flutter, customer)**: route + screen + l10n.
3. **C2 (Flutter, staff)**: kitchen badge, cashier search, admin QR/menu
   toggles, agent slip renderer.
4. Ops gate: printer setup(M-2) 완료 → 테이블별 QR 생성·부착 → 파일럿.

## 7. Test matrix (`qr_table_ordering_contract_test.sql`, Gate-2 harness,
prod-safe rollback style with dynamic brand/tax fixture)

| # | Scenario | Expect |
|---|---|---|
| QR0 | staff flows regression | Gate 2 6/6 unchanged; `order_source` defaults 'staff' |
| QR1 | invalid/rotated token, closed store token | `QR_TOKEN_INVALID` (all three cases, same error) |
| QR2 | first order on free table | order pending, source='qr', created_by NULL, table occupied, kitchen+floor+confirmation jobs batch 1, qr_order_batches row |
| QR3 | idempotent replay (same client_order_id) | same order_code/batch, no second order/jobs |
| QR4 | append to live order | delta items pending, batch 2 slip, recalc ran |
| QR5 | append to serving order | demoted to confirmed (Q3) |
| QR6 | append with active discount | discount voided `order_items_changed` (Q2) |
| QR7 | append after partial payment | `QR_ORDER_PAYMENT_IN_PROGRESS` (Q1) |
| QR8 | hidden/unavailable menu item | `QR_MENU_ITEM_UNAVAILABLE`; qr_get_menu excludes it |
| QR9 | caps (21 lines / qty 21) & throttle <20s | `QR_ITEMS_INVALID` / `QR_TOO_FREQUENT` |
| QR10 | price tamper (client price ignored) | line unit_price = menu price |
| QR11 | anon cannot touch anything else | direct `create_order`/table selects as anon fail |
| QR12 | pay QR order at cashier | normal process_payment path; e-invoice enqueued (revenue) |

Flutter: router public-route test(비로그인으로 /qr 진입 시 /login 미리다이렉트),
screen contract test(문구 계약 — "결제 완료" 문자열 부재 단언 포함), slip
builder byte snapshot. `dart analyze`. Gate 3 확장(QR feature)은 V1 이후.

## 8. Decisions needed (defaults proposed)

- D1 확인서 출력 위치: 해당 층 프린터, 주방 폴백(기본) vs 주방 고정.
- D2 고객 페이지 기술: Flutter web 공개 라우트(기본) — 로딩 무게는 파일럿
  실측 후 재평가.
- D3 스로틀/캡: 배치당 20라인·라인당 수량 20·배치 간격 20초(기본).
- D4 고객 화면 기본 언어: 디바이스 로케일, VI 우선 검수(기본).
- D5 QR 물리 출력: V1 화면 표시+브라우저 인쇄(기본) vs 열프린터 QR 슬립
  (esc_pos QR 명령, V2).

## 9. Explicit non-risks (verified)

- 결제 무접점: qr RPC는 payments를 만지지 않음 — 결제는 기존
  process_payment 전용(스키마·수학 무변경).
- lifecycle/print/discount/split/closure와의 모든 접점은 기존 공유
  프리미티브(recalc, enqueue, auto-void, payments-exist 가드) 재사용으로
  해소 — 신규 병행 로직 없음.
- anon 노출면은 qr_get_menu/qr_place_order 2개뿐, 나머지 전부 기존
  REVOKE 상태 유지.
- Office 커플링·meinvoice 비동기 invariant 무접촉.
