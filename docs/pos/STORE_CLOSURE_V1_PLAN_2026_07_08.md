# Store Closure (폐업 처리) V1 — Implementation Plan

Date: 2026-07-08
Status: IMPLEMENTED + PROD DB APPLIED (`20260709000000_store_closure_v1`)
Supersedes: soft-deactivation analysis reviewed 2026-07-08
Binding: CLAUDE.md §5 (Office coupling: `restaurants.is_active` semantics must
stay), §4 (MISA portal owns post-issuance lifecycle),
`STAFF_ACCOUNT_LOGIN_GATE_CONTRACT_2026_07_03.md` (AC3 no-store-scope refusal).

## 0. Verdict on the draft analysis

The draft's inventory is accurate (deactivate button → `StoreService.deactivateStore`
→ `admin_deactivate_restaurant` → `is_active=false` + audit only; verified
live). One finding is **more severe than stated**:

| # | Draft claim | Verified reality (live prod) | Consequence |
|---|---|---|---|
| S1 | "기존 권한/claim이 남은 사용자가 비활성 매장을 **계속 보게 될** 가능성" | `user_accessible_stores()` filters `users.is_active` and `user_store_access.is_active` but **NOT `restaurants.is_active`** (live prosrc). This function is the store-scope guard inside EVERY mutation RPC | Staff of a deactivated store can not only *see* it — they can **keep creating orders, taking payments, applying discounts** at the "closed" store. This is the systemic hole; the client-side filter is secondary |
| S2 | auth_provider:288 no `is_active` filter | confirmed (`.from('restaurants').select(...).inFilter('id', storeIds)` — no filter) | closed store stays in the client store list until claims refresh |
| S3 | claims 정리 안 됨 | `refresh_user_claims` DOES filter `r.is_active` when building `accessible_store_ids` (live) — but **nothing calls it on deactivation** | the fix is orchestration (call refresh for affected users), not a claims-builder change |
| S4 | 열린 주문 미검증 | confirmed — `admin_deactivate_restaurant` has no open-order/occupied-table guard | closure RPC needs the guard |
| S5 | 프린터/연동 미정리 | confirmed — `printer_destinations.is_active`, pending `print_jobs` untouched | closure RPC deactivates destinations + cancels pending jobs |

Also verified: `user_accessible_stores`'s **fallback branch**
(`COALESCE(u.primary_store_id, u.restaurant_id)`) ignores store active state
too — the S1 fix must cover both branches.

## 1. Design decision (pinned)

Two-layer fix — a systemic guard + an orchestration RPC:

**Layer 1 (systemic): `user_accessible_stores()` gains a
`restaurants.is_active = true` join on BOTH branches.** One change closes the
S1 mutation hole for every existing and future RPC at once. Consequences to
accept knowingly:
- Store staff of a closed store lose ALL RPC access (mutations and
  uas-guarded reads). Their next login resolves zero stores → refused with
  `authErrorNoStoreScope` per AC3 — the correct closure UX (clear message,
  no broken screens).
- `super_admin` is unaffected (guards check `is_super_admin()` first) and
  retains full read access to historical data of closed stores.
- Historical reporting via RLS read policies (`get_user_store_id`-based)
  is unchanged for admins of OTHER stores; Office app reads `restaurants`
  directly with service_role — untouched.

**Layer 2 (orchestration): `admin_close_store(p_store_id uuid, p_reason text)`**
— super_admin only, single transaction:
1. lock store row; already-inactive ⇒ `STORE_ALREADY_CLOSED`;
2. guard: no orders in `('pending','confirmed','serving')` for the store ⇒
   else `STORE_HAS_OPEN_ORDERS` (list count in the error detail). No force
   flag in V1 — open orders must be settled/cancelled first, deliberately
   (§5-D1);
3. guard: no `tables.status='occupied'` (should be implied by #2 given
   invariant I5, but checked defensively; mismatch ⇒ same error);
4. `restaurants.is_active = false` (same column Office reads — semantics
   unchanged);
5. `UPDATE user_store_access SET is_active=false` for the store
   (`source_type` both kinds), count captured;
6. `PERFORM refresh_user_claims(u.auth_id)` for every affected user (loop
   over distinct users from step 5 + users with `restaurant_id = store`);
7. `UPDATE printer_destinations SET is_active=false`; cancel
   `print_jobs` in `('pending','failed')` for the store;
8. meinvoice/einvoice queues: **not touched** — pending jobs drain through
   the existing async dispatcher; the MISA portal owns any post-issuance
   exception handling (CLAUDE.md §4). Documented, not coded;
9. `audit_logs('admin_close_store', …, {reason, access_rows_deactivated,
   destinations_deactivated, print_jobs_cancelled})`;
10. returns a summary jsonb so the UI can show "직원 N명 접근 해제, 프린터
    M대 비활성" 등.

`admin_deactivate_restaurant`는 유지하되(하위호환), Super Admin UI의 버튼은
close_store 플로우로 교체. 재개업은 기존 `admin_update_restaurant`(is_active
true) + `user_store_access` 재활성 + claims refresh — V1은 수동 절차 문서화만
(§5-D2).

## 2. Migration (single file,
`20260709000000_store_closure_v1.sql`)

- `CREATE OR REPLACE user_accessible_stores` — **live prosrc 기반** 재생성 +
  두 분기에 `JOIN public.restaurants r ON r.id = … AND r.is_active` 추가;
- `CREATE admin_close_store` (§1 Layer 2) — SECURITY DEFINER,
  `REVOKE ALL FROM PUBLIC, anon, authenticated` + `GRANT EXECUTE TO
  authenticated, service_role`(내부에서 super_admin 검증; authenticated
  GRANT는 PostgREST 경유 호출용이며 가드가 실제 통제);
- no table DDL.

Rollout: DB-first는 **행동 변경**을 동반함(Layer 1이 비활성 매장 접근을
즉시 차단) — 현재 비활성 매장에 활성 접근 중인 사용자가 있는지 사전 조회
후 적용(있으면 공지). 현 prod 조회로는 활성 매장만 운영 중이므로 실질
무영향 예상 — 적용 직전 재확인 쿼리를 마이그레이션 주석에 포함.

## 3. Client changes

| Surface | Change |
|---|---|
| super_admin_screen | "삭제 (비활성화)" 버튼은 레거시로 유지하고, 별도 "매장 폐업 처리" 플로우 추가: 사유 필수 확인 다이얼로그 → `admin_close_store` → 성공/실패 토스트. 열린 주문 에러는 전용 메시지로 안내 |
| store_service | `closeStore(id, reason)` 추가; `deactivateStore`는 유지(레거시) |
| auth_provider `_resolveAccessibleStores` | `.eq('is_active', true)` 필터 추가 (S2 — 방어적; 주 통제는 Layer 1/claims) |
| l10n | en/ko/vi 신규 문자열 동시 추가 |

## 4. Test matrix (`store_closure_contract_test.sql`, Gate-2 하니스)

| # | Scenario | Expect |
|---|---|---|
| SC0 | 활성 매장 정상 주문 플로우 (회귀) | uas 변경 후에도 Gate 2 6/6 동일 PASS |
| SC1 | 열린 주문 있는 매장 close | `STORE_HAS_OPEN_ORDERS` |
| SC2 | 정상 close | is_active=false; access rows inactive; 대상 유저 claims에서 매장 제거; destinations inactive; pending print_jobs cancelled; audit 요약 |
| SC3 | close 후 해당 매장 waiter가 create_order | `ORDER_CREATE_FORBIDDEN` (Layer 1) |
| SC4 | close 후 해당 매장 staff 로그인 | claims 빈 배열 → AC3 `authErrorNoStoreScope` (로그인 게이트 재사용 검증) |
| SC5 | 타 매장 staff/super_admin | 영향 없음; super_admin은 closed 매장 데이터 조회 가능 |
| SC6 | 이미 closed 매장 재-close | `STORE_ALREADY_CLOSED` |
| SC7 | non-super_admin 호출 | forbidden |
| SC8 | 멀티매장 유저(가맹 2곳 중 1곳 close) | 남은 매장 접근/claims 정상 유지 |

- Flutter: 다이얼로그/토스트 계약 테스트, `dart analyze`.
- 배포 순서: 마이그레이션 → (SC0로 무회귀 증명) → 클라이언트.

## 5. Decisions (defaults proposed)

- D1 강제 폐업(force, 열린 주문 일괄 취소 포함): V1 제외(기본) — 정산
  무결성상 수동 정리 유도. 필요 시 V2에서 `p_force` + 일괄 cancel_order.
- D2 재개업 절차: V1 수동(문서화)(기본) vs `admin_reopen_store` RPC.
- D3 폐업 매장의 staff `users.is_active` 처리: V1 유지(기본 — 계정은
  살아있되 scope 0 → 로그인 거부; 타 매장 재배치 가능) vs 일괄 비활성.
