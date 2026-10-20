# 전체 코드 N+1 검사 — 2026-10-05

**판정: N+1이 남아 있다.** Direct Order 외에 KDS, QR 주문, 재고/발주, MISA, Deliberry, 정산·자동 일마감에서 반복 조회를 확인했다. KDS·QR·발주 권한 확인·MISA는 실제 소스의 함수/클래스를 사용하는 격리 probe로 호출 증가를 재현했다. 다른 항목은 소스에서 호출 경로를 확인했으며, 운영 지연 시간까지 측정한 것은 아니다.

이번 작업은 진단과 증거 보존이다. 애플리케이션·migration을 수정하거나 운영 DB에 접속·배포하지 않았다. 기존 수정·미추적 파일은 보존했다.

## 범위와 판정 기준

- 기준 HEAD: `cc4de81adb8870fd479cb12edd773cda635a01cd` + 현재 작업 파일. HEAD만으로 이번 검사 대상을 재현할 수 없으므로 파일별 SHA-256도 저장했다.
- 2026-10-05 16:40 ICT 스냅샷: 소스/설정 1,532개, `lib` 소스 257개 + ignored 생성 Dart 4개, migration 460개, Edge 진입점 17개. 테스트·운영 스크립트·웹·네이티브 코드도 후보 검색 범위에 포함했다. 외부 Office 저장소와 설치 의존성 내부는 범위 밖이다.
- Flutter 전체 `lib` AST에서 반복문, async callback, `FutureBuilder`, provider family, 행 렌더링과 서비스 호출을 추출하고 실제 호출부를 추적했다. Dart 구문 오류는 없었다. 이는 `flutter analyze` 전체 통과를 의미하지 않는다.
- SQL은 migration 순서, 함수 재정의, rename wrapper, `pg_get_functiondef` 기반 패치를 함께 추적했다. 정적 함수 추출 결과 자체를 운영 DB의 유효 함수 목록으로 간주하지 않았다. 마지막 자동 SQL 추출 후 추가된 `20261005024000_procurement_nonstock_returns.sql`은 별도로 읽었다.
- **네트워크 N+1**: 목록/변경 목록을 받은 뒤 항목마다 별도 API/RPC 조회.
- **DB 내부 반복 조회**: 한 RPC 내부에서 항목마다 SQL 또는 테이블을 읽는 helper 실행. HTTP 요청 수와 구분한다.
- **상관 SQL 후보**: 실행계획의 SubPlan 반복 또는 LATERAL 상관 집계. 모든 nested loop나 인덱스 point lookup을 성능 버그로 단정하지 않는다. 작업량·buffers·시간 확인이 필요하다.
- 개별 주문의 필수 결제·발행·전송·잠금·상태 변경, 페이지 조회, 재시도, JSON 계산은 그 자체로 읽기 N+1이 아니다. 다만 쓰기 함수 내부의 반복 검증 SELECT는 따로 기록했다.

전체 정적 검사와 주요 경로 격리 검증을 완료했다. 모든 운영 데이터 분포·RLS 조합·feature flag·실제 배포 버전을 실행한 전수 동적 검사는 아니다.

## 격리 실측

| 경로 | 입력 1 | 입력 10 | 입력 100 | 무엇을 센 것인가 |
|---|---:|---:|---:|---|
| KDS 이름 보강 | 2 | 20 | 200 | 메뉴/주문 항목 SELECT. 주문당 항목 1개 + 콤보 1개 fixture |
| KDS 콤보 보강 | 1 | 10 | 100 | queue별 콤보 SELECT |
| QR 미서빙 보강 | 3 | 30 | 300 | 항목별 SELECT. 항목당 fulfillment part 1개 fixture |
| 발주 목록 RPC | 7 | 25 | 205 | 같은 사용자의 `users` 역할 조회. 매장 1개 fixture |
| KDS delta 적용 | 1 + 1 | 1 + 10 | 1 + 100 | delta 조회 + ticket 조회. 모두 **같은 queue**의 변경이어도 반복 |

MISA는 같은 사업자 작업 **1 / 10 / 50건 → 설정·토큰 조회 3 / 30 / 150회**였다. 이미 유효한 토큰이 캐시에 있는 조건이다. 발행 API와 상태 쓰기는 이 수에 포함하지 않았다.

SQL 수치는 PostgreSQL 15 `pg_stat_statements`의 중첩 SQL 실행 횟수이며 physical disk read 수가 아니다. 최소 합성 schema에서 실제 helper/RPC 본문을 실행했다. 전체 production schema/RLS는 재현하지 않았다. KDS는 실제 sync 클래스와 fake gateway, 현재 provider와 같은 조회 callback을 사용했다. MISA도 실제 helper + fake DB transport이며 외부 발행은 하지 않았다.

## 우선 수정 대상

### F01 — HIGH: KDS delta가 이벤트마다 ticket RPC를 호출

- [delta 순회](/Users/andreahn/globos_pos_system/lib/features/emergency_fulfillment/kds_realtime_sync.dart:465) → [provider 변경 적용](/Users/andreahn/globos_pos_system/lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart:2092) → [ticket 재조회](/Users/andreahn/globos_pos_system/lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart:2142).
- active mode에서 페이지 내 변경 E개에 `1 + E` 조회가 발생한다. 동일 ticket의 여러 revision도 합치지 않는다. 위 probe에서 동일 queue 이벤트 100개가 ticket 조회 100회를 만들었다.
- shadow mode는 이벤트마다 `observe_kds_shadow_v2`를 호출한다. [이 함수](/Users/andreahn/globos_pos_system/supabase/migrations/20260831010000_kds_realtime_v2.sql:1069)는 전체 station snapshot·timings와 단일 ticket을 읽는다. 활성 queue 수와 이벤트 수가 함께 늘면 더 비싸진다. 운영 rollout mode는 확인하지 않았다.
- 개선: delta 페이지의 queue별 최신 무효화만 합치고, ticket ID 배열을 받는 batch RPC 또는 완성된 delta payload를 사용한다. cursor·ACK·revision gap·bootstrap·세션 변경 의미는 보존한다. 단순 `Future.wait`는 호출 수를 줄이지 않는다.
- 검증: 같은 queue 100개 이벤트, 서로 다른 queue 100개 이벤트, 재연결·삭제·오래된 revision에서 정확한 상태와 일정한 batch 호출 수 확인.

### F02 — HIGH: KDS SQL의 이름·콤보 보강이 아직 행별 조회

- [이름 보강](/Users/andreahn/globos_pos_system/supabase/migrations/20260815180000_paperless_menu_name_and_voice.sql:274) `emergency_localize_paperless_orders`: 항목별 주문/메뉴 SELECT, 콤보 구성별 메뉴 SELECT. 항목 I개 + 콤보 C개면 I+C회.
- [콤보 보강](/Users/andreahn/globos_pos_system/supabase/migrations/20260816190000_kds_combo_component_progress.sql:439) `emergency_add_combo_component_progress`: 주문 queue Q개마다 콤보 SELECT Q회.
- snapshot/today-completed의 rename wrapper chain과 `get_kds_ticket_v2`에 남아 있다. [최신 snapshot wrapper](/Users/andreahn/globos_pos_system/supabase/migrations/20260916190000_kds_start_ready_serve_workflow.sql:1121)도 이전 wrapper를 호출한다.
- `20260919010000_kds_set_based_enrichment.sql`이 바꾼 것은 `emergency_enrich_start_ready_orders`다. 이름·콤보 helper까지 제거한 것은 아니다. Direct Order kitchen v3 수정과도 다른 경로다.
- 개선: 먼저 대상 queue/item ID 집합을 만들고 이름·콤보를 JOIN/GROUP BY로 한 번씩 읽는다. 최상위 helper만 고치지 말고 wrapper 내부까지 검증한다.
- `get_emergency_station_snapshot_base`의 queue별 item 집계·최근 작업 LATERAL도 추가 실행계획 후보다. 이 부분은 위 helper 실측 수와 별개다.

### F03 — HIGH: QR 활성 주문의 미서빙 보강이 항목·part별 조회

- [helper](/Users/andreahn/globos_pos_system/supabase/migrations/20260916190000_kds_start_ready_serve_workflow.sql:1297)와 [현재 qr_get_active_order wrapper](/Users/andreahn/globos_pos_system/supabase/migrations/20260916190000_kds_start_ready_serve_workflow.sql:1385).
- JSON 항목마다 `order_items ... OFFSET index-1 LIMIT 1`, 필요 수량, fulfillment part별 제외 수량을 따로 조회한다. fixture에서는 항목 100개에 300 SELECT였다.
- 반복 OFFSET은 뒤 항목으로 갈수록 더 많은 정렬/건너뛰기 작업을 유발할 가능성도 있다. 이 추가 비용의 운영 실행계획은 미측정이다.
- 개선: payload에 안정적인 item ID를 전달하고 관련 수량을 먼저 집계한다. 호환 계약상 ID를 추가할 수 없다면 동일 정렬의 row number를 한 번만 계산한다. 취소·floor-direct·combo·부분 서빙 정확성을 함께 검증한다.

### F04 — HIGH: 발주 목록이 주문마다 같은 사용자 권한을 다시 읽음

- [목록 RPC](/Users/andreahn/globos_pos_system/supabase/migrations/20260911100000_inventory_workflow_all_stores.sql:885)의 `accessible` CTE가 `can_access_inventory_workflow(po.restaurant_id)`를 행별 호출한다.
- [권한 helper](/Users/andreahn/globos_pos_system/supabase/migrations/20260911100000_inventory_workflow_all_stores.sql:5)는 `inventory_purchase_actor_role()`을 반복 호출하며 접근 가능한 매장도 다시 구한다. 역할 helper는 `users`를 읽는다.
- 실제 RPC에 주문 1/10/100개, admin 사용자·매장 1개를 넣어 역할 조회 **7/25/205회**를 재현했다. 권한 helper는 3/12/102회였다. 출력 LIMIT 이전 후보 집합과 counts 계산에도 영향이 있어 페이지 크기만 줄여서는 해결되지 않는다.
- 개선: 역할과 허용 매장 집합을 요청당 한 번 구해 대상 주문에 JOIN한다. 권한 검사 제거 또는 RLS 우회는 해결책이 아니다.
- 같은 파일의 restrictive RLS 정책에도 관련 helper가 있다. 직접 테이블 접근 시 추가 비용은 실제 RLS 실행계획으로 별도 확인해야 한다.

### F05 — MEDIUM: MISA 작업마다 동일 사업자 설정·토큰을 재조회

- [dispatcher 작업 반복](/Users/andreahn/globos_pos_system/supabase/functions/meinvoice-dispatcher/index.ts:156)에서 `loadSellerConfig` 및 `getMeInvoiceToken`을 작업마다 호출한다.
- `tax_entity`, `meinvoice_tax_entity_config`, `meinvoice_token_cache`를 각각 읽어 같은 사업자 N건에 3N 조회가 된다. batch 상한 50건으로 제한되어도 중복은 남는다.
- 개선: 한 dispatcher 실행 내 `tax_entity_id`별 설정·토큰 캐시/사전 조회. 만료·재발급·인증 실패 시 무효화는 보존한다. 각 인보이스 발행 및 job 상태 쓰기는 여전히 개별 처리한다. **결제 완료가 MISA에 의존하지 않는 비동기 계약을 유지한다.**

### F06 — MEDIUM: Direct Order 고객 알림의 조건부 상세 조회 fanout

- [고객 화면 새로고침](/Users/andreahn/globos_pos_system/lib/features/direct_order/direct_order_storefront_screen.dart:377).
- 목록 1회 + 선택 주문 상세 0~1회 후, 다른 주문이 새 견적/새 증빙 재요청 상태로 바뀔 때 해당 주문마다 `fetchStatus`를 호출한다. 변경 주문 M개면 `1 + 선택상세 + M`이다. 평상시 매 poll마다 전체 주문을 조회하는 구조라고 해석하면 안 된다.
- 개선: 새 summary 계약에 알림 식별자·견적 revision·증빙 review ID를 담거나 변경 ID batch 상세를 사용한다. 엄격한 기존 v2 응답 계약을 조용히 변경하지 않는다.

### F07 — MEDIUM: Direct Order 기존 목록 SQL의 상관 집계

- [고객 목록 v2](/Users/andreahn/globos_pos_system/supabase/migrations/20260910130000_direct_order_customer_payment_and_status.sql:409), [직원 목록 v2](/Users/andreahn/globos_pos_system/supabase/migrations/20260910130000_direct_order_customer_payment_and_status.sql:473). 이후 환불 대상 조건 패치를 포함한 격리 runner로 확인했다.
- 직원 200건 실행계획에서 행별 SubPlan의 `loops=200`이 두 곳, 고객 50건에서 `loops=50`이 한 곳 확인됐다. 품목 합계/최근 메시지 등의 상관 집계다.
- 이것은 **하나의 RPC 안에서 반복되는 SQL 계획**이며 HTTP 200회가 아니다. 작은 page와 적절한 인덱스에서는 비용이 낮을 수 있으므로 운영 지연을 수치로 단정하지 않는다.
- 개선: 대상 page를 먼저 정한 뒤 item/message를 그 ID 집합에 대해 미리 집계한다. 환불 잔액·종료된 주문의 표시 조건을 유지한다.
- 반대로 이미 수정한 kitchen v3는 1/50/100/200건 모두 context helper 0회, actor helper 1회였다. 200건 실행계획에서 집계 1회, correlated SubPlan 0개를 재확인했다.

### F08 — MEDIUM: Deliberry dispatcher의 매장별 재조회

- [매장 목록 읽기](/Users/andreahn/globos_pos_system/supabase/functions/deliberry-dispatcher/index.ts:174) 후 [collectRetryableEvents](/Users/andreahn/globos_pos_system/supabase/functions/deliberry-dispatcher/index.ts:114)가 매장별 RPC를 호출한다.
- 조회한 매장 S개에 목록 1 + 매장별 S 조회. 전체 limit에 도달하면 중단하므로 항상 모든 매장을 읽는 것은 아니다. 소스 확인이며 실제 운영 호출량은 미측정이다.
- 개선: 허용 scope·재시도 조건·정렬을 유지하는 전역 batch claim/read RPC. 이벤트별 외부 전송·성공/실패 ACK는 별개로 유지한다.

### F09 — MEDIUM: 두 정산 경로의 반복 SELECT

- [generate-settlement](/Users/andreahn/globos_pos_system/supabase/functions/generate-settlement/index.ts:72): 매장 목록을 읽은 뒤 매장별 sales와 기존 settlement를 다시 조회한다. 처리 매장 S개 기준 최대 **1+2S** 읽기 경로다.
- [generate_delivery_settlement](/Users/andreahn/globos_pos_system/supabase/functions/generate_delivery_settlement/index.ts:124): sales는 먼저 묶어 읽지만 기존 settlement 존재 여부를 매장마다 조회한다. **1+S** 읽기 경로다.
- 두 함수는 유지해야 하는 별도 업무 경로다. 중복 함수로 판정하지 않는다.
- 개선: 각 함수 안에서 sales 및 기존 settlement를 집계/일괄 조회하고, 중복 정산 방지·동시성·상태 갱신의 원자성을 보존한다. 필수 매장별 쓰기 수와 읽기 수는 따로 측정한다.

### F10 — MEDIUM: 자동 일마감의 매장별 반복 집계

- [run_scheduled_daily_closings](/Users/andreahn/globos_pos_system/supabase/migrations/20260804010000_scheduled_closing_and_promotions.sql:11)는 활성 매장을 순회하며 주문·결제·취소·재고를 여러 상관 집계로 읽는다. 같은 매장의 payments도 합계/수단별/비매출별로 나누어 반복 집계한다.
- 매장 수 S에 따라 집계가 반복된다. 소스상 23:00 ICT cron 계약이지만 운영 cron 등록·실행 시간은 조회하지 않았다.
- 개선: 날짜 범위의 store별 orders/payments/inventory 집계를 먼저 만든 뒤 `INSERT ... SELECT`. `ON CONFLICT` 멱등성과 business date, 비매출 구분을 유지한다. 일반 일마감과 식당 주문 cutoff는 다른 계약이다.

### F11 — MEDIUM: 쓰기 함수 안의 반복 기준정보·권한 조회

일괄 쓰기가 있다는 이유로 전체를 N+1로 판정하지 않았다. 다음은 그 안에서 **실제로 다시 읽는 부분**이다. 호출 횟수는 소스 확인이며 별도 SQL 실측은 하지 않았다.

| 경로 | 반복 조회 | 개선 범위 |
|---|---|---|
| [재고 엑셀 import](/Users/andreahn/globos_pos_system/supabase/migrations/20260821120000_inventory_excel_supplier_creation.sql:4) | 행별 supplier, product code/id 검사. 저장 단계도 supplier/product 및 upsert helper를 다시 호출. 최대 1,000행 | 입력을 relation으로 변환해 기준정보·중복을 일괄 검사. 공급업체 생성의 advisory lock·동시성 보존 |
| [레시피 엑셀 import](/Users/andreahn/globos_pos_system/supabase/migrations/20260822120000_inventory_recipe_base_unit_import.sql:16) | 유효한 각 행에 menu 존재 + ingredient unit SELECT, 즉 검증 단계 2L. 최대 1,000행 | 입력 메뉴·재료 집합 JOIN 후 전체 검증, 그 다음 쓰기. 오류 행 번호·단위 검증·전체 rollback 보존 |
| [수동 발주 생성](/Users/andreahn/globos_pos_system/supabase/migrations/20260911150000_inventory_order_quantity_image_warning.sql:32) 및 같은 파일의 draft 저장 | line별 supplier item/product 검증, 같은 actor role 재조회 | actor role은 한 번 저장; supplier/product 일괄 검증. 가격 권한·수량·트랜잭션 보존 |

`sync_all_store_access`/`sync_brand_store_access`, 매장 초기 구성, 메뉴 import wrapper, 주문 promotion 갱신 및 KDS batch command도 대상을 순회하는 관리·변경 경로다. per-target 권한·잠금·쓰기 자체는 필수일 수 있다. 이 경로들은 상시 목록 조회보다 낮은 우선순위로, 공통 설정·actor 조회를 먼저 계측해야 한다. 모두 N+1이 없다고 판정한 것은 아니다.

## 추가 실행계획 또는 활성 경로 확인이 필요한 항목

| 경로 | 소스 근거와 현재 판정 |
|---|---|
| 발주 catalog | [get_inventory_order_catalog](/Users/andreahn/globos_pos_system/supabase/migrations/20260911150000_inventory_order_quantity_image_warning.sql:513): item JSON 집계 안의 actor role 호출, item별 최근 20건 구매 이력 LATERAL. 실제 고객 데이터로 helper 호출 및 buffers 확인 필요. 목록 RPC F04와 별개 |
| 기존 procurement workspace | [기존 wrapper](/Users/andreahn/globos_pos_system/supabase/migrations/20260913161000_procurement_followup_commands.sql:100)의 legacy order/receipt별 lines 상관 집계와 unpaged 응답. 검사 시점 `InventoryService.fetchProcurementWorkspace`는 기존 RPC를 호출. 아래 새 page RPC 존재만으로 해결 판정하지 않음 |
| 식당 매출 export | [report_rows](/Users/andreahn/globos_pos_system/supabase/migrations/20260904120000_restaurant_sales_report_ready_at_2200.sql:99)의 receipt별 job/tax entity/line LATERAL. 결제수단 snapshot이 없으면 `meinvoice_payment_method_label`이 같은 사업자 config를 반복 조회. snapshot 존재 비율에 따라 다름. helper 정의는 `20260630000000_wetax_shutdown_meinvoice_foundation.sql:230`이며 이름과 달리 현재 MISA 경로 |
| 복수 매장 재고 dashboard | `20260506000000_inventory_purchase_office_contracts.sql:548`의 매장별 `get_inventory_stock_status` 호출. 현재 Flutter 서비스는 단일 store ID를 넘기므로 일반 화면을 다중 매장 N+1로 단정하지 않음. NULL store/all-store RPC 호출 시 대상 |
| 재고 실사 sheet | 이전 실사값의 item별 top-1 LATERAL. 인덱스 이용 시 적절한 계획일 수 있음. 상관 조회 존재만으로 수정 확정하지 않음 |
| 외부 매장 overview view | `20260707011000_external_store_view_security_schema_closure.sql:25`의 staff/월 매출/주문 상관 집계. 현재 Flutter 호출을 찾지 못해 외부 호환 소비자 확인 필요 |
| RLS helper | `is_super_admin`, 역할/접근 매장 helper가 row 조건에 들어가는 정책들. SQL STABLE 표기만으로 요청당 한 번 실행을 보장하지 않음. 실제 role별 `EXPLAIN (ANALYZE, BUFFERS)` 필요 |
| 발주 취소/수정 command | `20261005024000_procurement_nonstock_returns.sql`의 line UPDATE 안에서 receipt 합계 상관 조회. 단일 주문 변경 경로이며 목록과 구분. line 수가 큰 사례의 실행계획 확인 필요 |

## 새 코드 및 오탐 구분

- 검사 중 발주 코드가 병행 변경됐다. `20261005023000_procurement_set_based_evidence.sql`은 **수요·공급업체 지표의 이전 행별 집계를 grouped CTE로 대체**했다. 이전 September 함수 본문만 보고 이 두 함수를 현재 N+1로 기재하지 않았다. snapshots batch도 관계별 선집계 구조다. 신규 코드의 운영 적용은 확인하지 않았다.
- `20261005022000_procurement_paged_reads.sql`은 요청/발주 page와 선택 상세를 분리하고, line/quote/receipt를 선집계한다. `procurement_allowed_actions(p, actor)`는 입력 JSON/row만 계산하며 DB를 읽지 않으므로 per-row 호출 자체는 N+1이 아니다. 검사 당시 widget에 `loadPage` 선택 경로는 추가됐지만 서비스의 기존 workspace 호출은 남아 있었다. 연결 변경은 최종 manifest 시점 이후 다시 확인해야 한다.
- table 관리 목록의 관련 주문은 ID 집합으로 묶어 읽는다. 현재 확인한 목록 경로에서 per-table 추가 SELECT는 없다.
- e-invoice status family는 order ID별 provider지만 현재 cashier 사용처는 마지막 완료 주문 한 건이다. family 선언만으로 N+1 판정하지 않았다.
- QC의 일부 `FutureBuilder`는 로컬 파일 bytes 읽기이고, 다른 상세 future는 선택 상세/popup이다. 화면 행마다 DB 요청하는 것으로 오인하지 않았다.
- 최신 receipt ledger·daily closing 목록·store revenue/report summary는 grouped CTE/고정 개수 집계 경로를 사용한다. SELECT 개수가 많다는 이유만으로 N+1로 세지 않았다.
- 급여·재무·메뉴 등의 page/chunk 조회, outbox 재시도, 로컬 파일 처리, 프린터 작업, 필수 job 전송/ACK는 별도다. 묶음 전송 가능성은 있어도 모두 부모-자식 읽기 N+1은 아니다.
- `order_item_invoice_tax_lines`, VAT allocation, JSON array 가공은 테이블을 읽지 않는 계산이다.
- WeTax dispatcher/poller는 퇴역 경로다. 과거 per-job 조회를 현재 MISA의 문제로 집계하지 않았다. Photo Objet 자동 매출 수집도 퇴역 경로로 제외했다. 명시적 Excel import는 현재 관리 경로로 확인했다.
- 운영 스크립트·테스트 fixture·네이티브 브리지의 반복문은 앱의 상시 화면 조회와 분리했다. 외부 설치 패키지의 내부 구현까지 성능 무결성을 보증하는 검사는 아니다.

## 수정 순서와 완료 기준

1. **KDS F01/F02, QR F03**: 자주 갱신되는 운영·고객 화면이므로 먼저 처리. batch당 호출 수, 동일 queue 중복, item 1/10/100/200개, 모든 station/route의 결과 동등성 확인.
2. **발주 F04 및 catalog**: actor/access scope 계산을 묶고, 역할·다중 매장·권한 없음·가격 숨김 테스트 및 실제 RLS 계획 확인.
3. **Direct Order F06/F07, MISA F05**: 알림 식별자·견적/증빙 상태 계약, 목록 페이지, 사업자 격리·토큰 만료·MISA 장애에서 결제 독립성 검증.
4. **Deliberry·정산·일마감 F08~F10**: store 수 증가에 따른 조회 수와 집계 buffers 확인. 도메인별 멱등성·동시 실행·중복 처리 방지 유지.
5. **일괄 쓰기 F11 및 나머지 후보**: 공유 조회만 줄이고 필수 권한/잠금/원자성은 보존. 1,000행 import 검증과 오류행 rollback 확인.

각 수정의 완료 기준은 “RPC 하나” 또는 “Promise 병렬화”가 아니다. 응답·권한·상태 전이 동등성을 유지하면서 **중복 DB 호출 수와 실제 작업량**이 줄어야 한다. 큰 테이블 전체를 매번 읽는 JOIN도 정답이 아니므로 page/scope로 대상 관계를 제한하고 인덱스·buffers·시간을 함께 본다.

## 검증 결과와 산출물

- PostgreSQL probe: 4경로 × 3크기 = 12개 측정 완료. 임시 Docker 컨테이너 삭제 완료.
- MISA helper probe: 3개 크기 측정 완료, 외부 API 호출 없음.
- KDS sync probe: 3개 테스트 통과. 실행용 임시 repo test 파일 제거, 재현 소스만 증거 폴더에 보존.
- 기존 Direct Order SQL runner: behavior, concurrency, set-based parity/call counts, EXPLAIN 통과. 전체 앱 테스트/빌드는 이번 읽기 감사의 완료 근거로 주장하지 않는다.
- [재현 방법과 원시 증거](/Users/andreahn/globos_pos_system/docs/audits/n_plus_one_20261005/README.md), [SQL 실측](/Users/andreahn/globos_pos_system/docs/audits/n_plus_one_20261005/sql_probe_results.json), [검사 범위·병행 변경 목록](/Users/andreahn/globos_pos_system/docs/audits/n_plus_one_20261005/scope_summary.json).

**소스에서 확인됨 / 격리 환경에서 재현됨 / 운영 migration 적용됨 / 운영 배포됨 / 운영 성능 검증됨은 다른 상태다. 이 보고서는 앞의 두 상태만 증명한다.**


## 후속 사용자 결정 — Deliberry 종료

2026-10-05 사용자가 Deliberry를 사용하지 않으며 닫도록 지시했다. F08과 두 Deliberry 정산 endpoint의 F09는 활성 성능 개선 대상에서 제외한다. 퇴역 코드와 DB guard는 구현·격리 검증했으며, 과거 매출/정산 SELECT 계약을 보존한다. 위 감사 수치는 퇴역 전 소스의 기준선이다. 운영 적용은 별도 상태이며 아직 실행하지 않았다. 세부 결과: [Deliberry 종료 구현](/Users/andreahn/globos_pos_system/docs/deliberry_retirement_implementation_20261005.md).
