# 전체 N+1 개선 실행 계획

작성: 2026-10-05 · 상태: **계획 수립 완료 / Deliberry 퇴역 운영 적용·검증 완료 / 나머지 N+1 구현 후속**

근거: [전체 감사 보고서](/Users/andreahn/globos_pos_system/docs/n_plus_one_full_code_audit_20261005.md), [실측·재현 자료](/Users/andreahn/globos_pos_system/docs/audits/n_plus_one_20261005/README.md).

**사용자 결정 반영:** 2026-10-05 Deliberry를 사용하지 않으므로 닫기로 확정했다. F08과 Deliberry 정산 F09는 성능 개선 대상에서 제외하고 퇴역 검증으로 대체한다. 주문 수신·전송·재처리·정산 생성은 HTTP 410/DB 쓰기 차단으로 종료하며, 기존 원장은 읽기 전용으로 보존한다. 나머지 N+1 개선 범위는 유지한다.

## 1. 목표와 범위

목표는 주문·주방·고객 화면과 배경 업무에서 **같은 정보를 항목/매장마다 다시 읽는 구조를 제거**하고, 데이터 증가 시 호출 수·조회 범위·응답 크기를 제한하는 것이다. 금액·수량·권한·순서·멱등성·기존 사용자 동작은 유지한다.

감사 F01~F11 전체와 추가 후보 C01~C10을 포함한다. 이미 개선된 코드는 재작성하지 않고 기존 구현을 재사용·검증한다. 외부 Office 저장소 변경, 새 메시지 플랫폼·전역 캐시 도입, 결제 구조 재작성은 이 계획의 기본 구현 범위에 넣지 않는다. Office 소비자 호환 확인은 필요하다.

구현 방식은 기존 서비스와 RPC 개선이 기본이다. payload 계약을 보존할 수 있는 SQL은 같은 public signature의 새 migration으로 교체하고, batch나 새 필드가 필요한 경로에만 versioned RPC/API를 추가한다. `Future.wait`/`Promise.all`로 N개 요청을 동시에 보내는 것을 해결로 인정하지 않는다.

**판정 단위는 HTTP 요청, DB 중첩 SQL, 처리 행/bytes, 쓰기·잠금 비용을 각각 구분한다.** 처리 항목이 많아지면 처리 행과 필수 쓰기는 늘 수 있다. 정상적인 indexed nested loop나 필요한 개별 결제·발행까지 일률적으로 없애는 계획이 아니다.

## 2. 착수 기준과 최신 변경 반영

기준 HEAD는 `cc4de81adb8870fd479cb12edd773cda635a01cd`이며 미커밋/미추적 작업을 포함한다. 구현 시작 시 소스 hash와 실제 함수 정의를 다시 고정한다. 과거 감사 manifest는 덮어쓰지 않고 새 baseline을 별도 저장한다.

| 경로 | 계획 작성 시 확인 | 조치 |
|---|---|---|
| KDS delta/provider, MISA | 감사 manifest와 동일 | F01/F02/F05 개선 대상 |
| Deliberry·두 정산 Edge | 사용자 종료 결정으로 HTTP 410 handler로 교체 | F08/F09 최적화 대신 W07 퇴역 검증 |
| Direct Order kitchen v3 | 감사에서 set-based call count/계획 통과 | 재사용. 다른 목록 수정 시 회귀 gate로 유지 |
| `emergency_enrich_start_ready_orders` | 기존 set-based migration 존재 | 재사용. 이름·콤보 wrapper까지 해결한 것으로 오인하지 않음 |
| Procurement 수요·업체 지표·snapshot batch | `20261005033000_procurement_set_based_evidence.sql` 존재 | 기존 선집계 구현의 결과·범위·계획 검증 |
| Procurement page API와 화면 | `InventoryService.fetchProcurementPage` 및 `inventory_order_workflow_screen.dart`의 `loadPage` 연결 확인 | **감사 시점의 미연결 상태는 해소됨.** 새 연결을 다시 만들지 않고 실제 호출·페이지 계약 검증 |
| 기존 `fetchProcurementWorkspace` | 호환 함수/경로가 남음 | 남은 소비자를 조사하고 legacy SQL 최적화 또는 사용 범위를 기록. 즉시 삭제하지 않음 |

기존 [KDS 중앙 안정성 계획](/Users/andreahn/globos_pos_system/.design/2026-09-kds-central-reliability-plan/PLAN.md), [500매장 검증 계획](/Users/andreahn/globos_pos_system/.design/2026-09-pos-500-store-reliability/VALIDATION_PLAN.md), [발주 개선 계획 §12.4/T14](/Users/andreahn/globos_pos_system/docs/plans/pos_procurement_process_improvement_20261005.md)과 연결한다. 이 문서는 그중 반복 조회 제거를 구체적인 변경 단위로 나눈다. 별도 중앙 ACK worker나 전체 500매장 인증이 이번 단위 수정의 완료 조건에 섞이지 않게 하되, N+1 수정만으로 500매장 운영 인증을 주장하지 않는다.

## 3. 보존할 계약

1. `process_payment`의 단일 주문 원자 결제, 결제/환불 금액, UUIDv7 인보이스 식별자, MISA 비동기 처리 유지.
2. 두 기존 정산 Edge endpoint는 HTTP 410으로 닫고 과거 Deliberry 매출·정산 원장/읽기 계약을 보존한다. 이력 삭제·기간/금액 변경은 하지 않는다.
3. 매장·사용자·station·floor·고객 session 권한 유지. 캐시나 입력 ID 배열이 권한 검사를 대신하지 않는다.
4. Direct Order 인원수, 신규 접수 중단 시 기존 주문 접근, 배달 업체와 무관한 유효 링크, 고객 동의 포장 전환, 환불 잔액/미처리 주문 표시 유지.
5. KDS 부분 조리·준비·인계·전달·취소·combo·floor-direct·배달/포장·업무일 경계 유지.
6. 발주 가격 비공개, 승인 revision, 입고/반품 재고 원장, 단위 환산, 금액 반올림, retry key·전체 rollback 유지.
7. `restaurants` 물리 테이블과 Office 연결 필드 유지. 기존 public RPC grant/search_path/응답 모양을 보존하거나 새 버전으로 전환.
8. WeTax와 Photo Objet 자동 수집은 퇴역 상태 유지. 일반 일마감 23:00과 식당 cutoff/finalization은 별도 계약 유지.

## 4. 작업 순서

우선순위 P0는 먼저 구현할 업무상 우선순위이며 운영 장애가 이미 발생했다는 의미가 아니다.

| 단계 | 작업 | 감사 연결 | 담당 영역 | 선행 조건 | 완료 산출물 |
|---|---|---|---|---|---|
| 0 | W00 기준선·계약·측정 확정 | 전체 | DB/App/QA | 없음 | 재현 fixture, hash, 전후 측정 방식 |
| 1, P0 | W01 KDS SQL 일괄 보강 | F02, C10 | DB/QA | W00 | 이름·콤보·snapshot 경로 동등성 및 상수 횟수 조회 |
| 1, P0 | W02 KDS delta batch | F01 | App/DB/QA | W01 | queue batch RPC, 페이지 단위 적용/복구 |
| 1, P0 | W03 QR 일괄 보강 | F03 | DB/QA | W00 | OFFSET 반복 제거, 항목·part 정합성 |
| 2, P0 | W04 발주 권한·catalog·page | F04, C01/C02/C07 | DB/App/QA | W00 | 권한 한 번 계산, 현재 page 연결 검증 |
| 3, P1 | W05 Direct Order 목록·알림 | F06/F07 | App/Edge/DB | W00 | 목록 선집계, versioned 알림 summary |
| 3, P1 | W06 MISA 실행 내 캐시 | F05 | Edge/QA | W00 | 사업자별 설정/유효 토큰 재사용 |
| 운영 적용·검증 완료 | W07 Deliberry 퇴역 | F08/F09 | Edge/DB/App/QA | 사용자 사용 중지 결정 | HTTP 410, UI 진입 중지, DB 쓰기/cron 차단 검증 |
| 4, P1 | W08 자동 일마감 집계 | F10 | DB/QA | W00 | 범위 집계, 중복/동시성 검증 |
| 5, P1 | W09 import·명령 내부 조회 | F11, C08/C09 | DB/QA | W04, KDS 부분은 W01 | 일괄 검증, trigger까지 반복 비용 검증 |
| 5, P2 | W10 기타 후보 종결 | C03/C04/C05/C06 | DB/QA | W00 | 수정 또는 유지 근거와 재평가 기준 |
| 6 | W11 통합·릴리스·관측 | 전체 | App/DB/운영 | 해당 배포 묶음 완료 | 정확한 SHA gate, canary, rollback 증거 |

W03/W04/W06은 코드 의존성이 낮아 독립 변경 묶음으로 개발할 수 있다. 배포도 한 번에 전부 바꾸지 않고 검증이 끝난 묶음별로 한다. W00 뒤 권장 첫 묶음은 W01+W02, 다음은 W03/W04다. 각 묶음은 기능 코드와 의미 있는 회귀·성능 검증을 함께 포함한다.

## 5. 수치로 확인할 목표

다음은 **구현 후 수용 기준**이며 아직 달성한 결과가 아니다. 일정한 SQL 호출 수가 실행 시간 O(1)을 뜻하지 않는다.

| 경로 | 감사 기준선 | 목표 |
|---|---|---|
| KDS delta E개, 고유 queue U개 | delta 1 + ticket E | 기본 페이지 100개: delta 1 + batch ticket 최대 1. 일반식 `1 + ceil(U/100)`, U=0이면 ticket 0 |
| KDS shadow | 이벤트마다 전체 snapshot/timings/ticket | 페이지당 snapshot 1·timings 1·batch ticket 1 이하. 비교 표본은 중복 제거된 queue별로 기록 |
| KDS 이름 helper | 항목+콤보 100+100에서 200 SELECT | 입력 집합을 읽는 집계 SELECT 1회, 행별 테이블 helper 0 |
| KDS 콤보 helper | queue 100개에 100 SELECT | 대상 queue 집합 집계 SELECT 1회 |
| QR helper | 항목 100개/각 part 1개에 300 SELECT | 단일 set-based SELECT, 반복 OFFSET 및 항목별 테이블 helper 0 |
| 발주 목록 | 주문 100개에 역할 테이블 205회 | 최상위 actor role 계산 1회·허용 매장 집합 계산 1회. 그 내부 조회 총량도 주문 수와 무관한 고정 상한으로 검증 |
| Direct Order poll | 목록 1 + 선택 상세 0~1 + 변경 주문 M | 목록 summary 1 + 선택 상세 0~1. 알림 때문에 추가 상세 0 |
| Direct Order 목록 SQL | staff 200/customer 50회 상관 집계 | page ID로 관계별 선집계. 대상 item/message 집계의 correlated SubPlan 0 |
| MISA 같은 사업자 50 job | 설정/토큰 150 SELECT | 유효 토큰 경로 설정 2 + 토큰 1 = 3 SELECT. 사업자 T개면 최대 3T, 토큰 갱신·쓰기 별도 |
| Deliberry | store 목록 1 + 방문 매장 S | 퇴역: business query·vendor 전송 0, endpoint HTTP 410 |
| Deliberry 정산 | 최대 1+2S / 1+S read | 퇴역: 신규 생성 0, 두 endpoint HTTP 410, 이력 SELECT 유지 |
| 자동 일마감 | 매장마다 여러 집계 | 매장 집합을 대상으로 관계별 한 번 집계, `INSERT ... SELECT`; 반복 store SELECT 0 |
| recipe import | 유효 L행 검증에 2L SELECT | menu/ingredient 검증을 집합 조회. 입력 1~1,000행에서 검증 SQL 횟수 고정 |

MISA dry-run은 사업자당 설정 2회 이하, 토큰/외부 발행 0회가 목표다. 사업자가 job마다 다른 경우 3T가 3N일 수 있으며, 이를 중복 캐시 개선 실패로 오해하지 않는다.

KDS의 `1 + ceil(U/100)`은 같은 assignment/session에서 정상 ticket 무효화를 처리하는 페이지의 예산이다. control barrier로 bootstrap이 필요한 경우, 초기 연결, 설정/watermark 확인, 오류 재시도는 별도 항목으로 계수하고 전체 요청 합계에도 포함한다. 복구 요청을 숨겨 목표를 맞추지 않는다.

시간/용량 목표는 W00에서 같은 환경 A/B 기준선을 고정한다. 주요 조회 p95·DB buffers·payload가 개선되어야 하며, 다른 업무의 유의미한 회귀가 있으면 배포하지 않는다. 잠정 회귀 검토 기준은 같은 workload 3회 측정에서 p95 또는 buffers 10% 초과 악화이며, 원시 분포와 오차도 함께 판단한다. 근거 없이 특정 millisecond의 개선을 보장하지 않는다. KDS 전달의 기존 p95 1초/p99 2초 목표는 별도 end-to-end 시험으로 유지한다.

## 6. 작업별 구현 설계

### W00 — 기준선과 성능 회귀 장치

- 감사 probe를 재사용해 입력 크기·역할·scope·branch별 기대 호출 수를 고정한다. 실제 Flutter provider/Edge handler/SQL wrapper까지 통합 fixture를 확장한다. helper 단독 PASS를 전체 화면 PASS로 쓰지 않는다.
- `pg_stat_statements` 중첩 호출과 `pg_stat_user_functions`를 연결하고, 내부 주요 SELECT는 `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`를 저장한다. 부모·자식 누적 시간을 중복 합산하지 않는다.
- 기존 probe의 PostgreSQL 15 최소 schema는 단위 재현용으로 유지한다. 통합 시험은 CI와 맞는 Supabase PostgreSQL 이미지, 현재 migration/RLS/trigger/grant를 사용한다. 운영 버전은 운영 적용 단계에서 별도로 확인한다.
- 각 RPC의 응답 key/타입/null/정렬/권한 거절/최대 입력을 contract fixture로 고정한다. 기존 버그로 판명된 의미 차이는 별도 변경으로 표시한다.
- 신규 측정 결과에는 commit+dirty hash, DB/runtime, seed, 입력/출력 행, HTTP/RPC 수, 내부 SQL 수, bytes, buffers, p50/p95/p99, 오류·timeout·lock을 기록한다.
- 장기 실행/부하·장애 시험은 격리 환경에서 한다. 운영 통계는 reset 없이 관찰 구간 증가분만 수집한다. 이번 계획 작성에서는 운영 접근을 하지 않는다.

### W01 — KDS 이름·콤보·snapshot의 DB 조회

대상: `emergency_localize_paperless_orders`, `emergency_add_combo_component_progress`, 이들을 호출하는 snapshot/today-completed/ticket wrapper chain.

1. 입력 JSON을 `WITH ORDINALITY`로 한 번 펼쳐 queue/item/component ID 집합과 원래 순서를 보관한다.
2. 주문 항목·floor-direct·메뉴 이름·콤보를 각각 대상 ID 집합으로 제한해 조회한다. 같은 메뉴가 여러 항목에 있으면 기준정보는 한 번 읽는다.
3. 서로 다른 1:N 관계를 각각 GROUP BY한 뒤 JOIN한다. 원장과 콤보를 직접 곱해서 수량·행이 늘지 않게 한다.
4. name fallback, 기존 JSON key, 빈 배열/null, 이름 없는 메뉴, 취소된 component, 순서를 그대로 보존해 마지막에 JSON을 집계한다.
5. 최신 `emergency_enrich_start_ready_orders` 구현을 재사용한다. `_pre_*` 함수 rename chain에서 구형 조회가 다시 실행되지 않는지 전 경로 call count를 확인한다.
6. snapshot base의 item/recent-action 조회(C10)는 page/scope 제한과 실제 계획을 보고 같은 묶음에서 처리한다. 전체 매장을 미리 집계하는 변경은 금지한다.

검증: 모든 station, base/combo/floor-direct, 배달/포장, empty/cancelled, 1/10/100/200 ticket. 기존/new JSON의 업무 필드와 정렬 동일, 이름·콤보 SQL 횟수 고정. RPC 한 겹 아래뿐 아니라 bootstrap/ticket/today-completed/shadow까지 확인한다.

### W02 — KDS 네트워크 batch와 revision 정합성

대상: [sync](/Users/andreahn/globos_pos_system/lib/features/emergency_fulfillment/kds_realtime_sync.dart), [provider](/Users/andreahn/globos_pos_system/lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart), 새 SQL batch API.

**제안 계약:** `get_kds_tickets_batch_v1(p_queue_ids uuid[])`. 이름은 신규 제안이며 착수 시 동일 이름 부재를 확인한다. 최대 고유 ID 100개, 서버가 사용자·활성 assignment·session·매장·floor를 검증한다. 식별자 배열은 권한 근거가 아니다. 응답은 `revision` 및 요청 ID별 `ticket` 또는 `null` 결과를 포함해 삭제/비가시성도 처리한다. 조회와 revision은 같은 statement snapshot 경계로 읽는다.

- batch SQL에서 `get_kds_ticket_v2(id)`를 N번 부르지 않는다. W01의 scope 제한 집계로 ticket 집합을 한 번 만든다. 단건 v2는 구버전 호환용으로 유지한다.
- delta 한 페이지를 먼저 검증한 뒤 일반 ticket 무효화는 queue별로 합친다. `bootstrap_required`, session/assignment 변경, leftover 등 서로 다른 이벤트 의미는 순서와 barrier를 보존한다. 알 수 없는 이벤트를 그냥 버리지 않는다.
- 기본 100-event 페이지는 ticket batch 1개로 처리한다. 범위를 넘는 페이지는 제한된 chunk 수를 계수한다. 20~50ms live-event 병합은 기존 single-flight와 결합하되 지속 이벤트로 처리가 계속 밀리지 않게 최대 대기 시간을 둔다.
- 응답 준비 후 한 번에 state를 적용하고 성공한 delta의 `scanned_through_revision`까지만 cursor를 저장한다. ticket 응답의 더 높은 revision을 delta cursor에 그대로 복사하지 않는다.
- 부분 실패/timeout이면 cursor를 전진시키지 않고 멱등 재적용한다. 오래된 응답, 화면 폐기, 사용자/매장 전환은 generation 검증으로 차단한다. state를 영속화하지 않는 재시작에서는 cursor만 믿고 복구 완료 처리하지 않는다.
- shadow도 batch 비교로 바꾼다. 비교 양쪽은 같은 snapshot/revision 경계에서 읽고, 동시 변경으로 비교 기준이 달라지면 불확정으로 기록해 재측정한다. event 수와 unique ticket 비교 수를 별도 계수해 관측 분모가 바뀐 것을 숨기지 않는다. 이전 shadow SQL의 오류를 삼키고 cursor만 진행하는 동작은 새 비교 실패 지표로 드러낸다.
- 새 서버를 먼저 설치한 뒤 앱을 전환한다. 일시적 장애에서 자동으로 N개 단건 호출로 폭발하는 fallback은 두지 않는다. 호환성 불일치 시 기존 제한된 bootstrap/rollout 경로와 명시적 오류를 사용한다.

검증: 같은 queue 100 revision, 서로 다른 queue 100개, 빈/가려진 delta, 삭제, 역순·중복·gap, 동시 신규 revision, session/floor 전환, crash/reconnect, 일부 chunk 실패. KDS 명령 ACK·업무 수량과 표시 상태가 최종 authoritative snapshot에 수렴해야 한다.

### W03 — QR 활성 주문의 일괄 수량 보강

- 기존 `qr_get_active_order` 외부 응답을 우선 유지한다. 이번 성능 변경에서는 item ID 신규 필드를 요구하지 않는다.
- 서버에서 현재 정렬과 동일한 `row_number(created_at,id)`를 한 번 계산해 JSON ordinality와 연결한다. 항목마다 OFFSET을 실행하지 않는다. 이미 payload에 신뢰 가능한 item ID가 있는 경로만 ID JOIN을 쓴다.
- base/floor-direct의 최신 유효 row 및 line_key별 excused 값을 대상 order item 집합에서 한 번 산출한다. base 우선→direct→JSON quantity fallback 의미를 보존한다.
- fulfillment_parts도 펼쳐서 JOIN·수량 계산 후 원래 part/item 순서로 복원한다. 최신 row 선택의 기존 tie 의미를 고정하고 임의 변경을 숨기지 않는다.
- 외부 token·활성 주문 판정, 취소·service item 제외, takeout 계약은 유지한다.

검증: 0/1/10/100/현재 최대 항목, 동일 메뉴 중복, base 없는 항목, 복수 part, 부분 취소·제외, 잘못된 token, 주문이 닫히는 경쟁 조건. 고정 수 SELECT 및 기존 수량/키/정렬 동등성.

### W04 — 발주 권한·catalog·현재 page 통합

- `get_inventory_workflow_orders`에서 actor role을 한 번, 접근 가능한 store ID 집합을 한 번 materialize한다. 현재 service_role/super_admin/일반 역할의 scope와 `p_store_id`, mine/status/counts 의미를 보존한다.
- 주문 page, counts, stores 반환 모두 같은 허용 store 집합을 JOIN한다. `can_access_inventory_workflow(po.restaurant_id)`를 주문마다 호출하는 구문을 없앤다. role helper 호출을 다른 per-row 함수 속으로 옮기는 방식은 금지한다.
- `get_inventory_order_catalog`의 actor role도 한 번 계산한다. 구매 이력은 대상 supplier/product와 기간으로 제한해 주문별 합계 후 pair별 최근 20건과 median을 계산한다. 소량 catalog에서 기존 indexed LATERAL이 더 좋은 경우도 A/B 기록 후 결정한다.
- 연결된 `fetchProcurementPage/loadPage`는 그대로 사용한다. 페이지 20/50, catalog 200, 선택 PR/PO 상세, quote/receipt lines를 포함한 실제 화면 호출 수를 검증한다. 일부 자료가 상한을 넘으면 다음 페이지 또는 명시적 제한 상태가 있어야 하며 조용히 누락하면 안 된다.
- 구 workspace 호출자는 사용처를 다시 확인한다. 사용 중이면 wrapper의 order/receipt lines를 집합 집계로 바꾸고 계약을 유지한다. 남은 호출자가 없더라도 Office/구버전 소비자를 확인하기 전 삭제하지 않는다.
- 수요/업체/snapshot batch는 이미 있는 `20261005023000` 구현을 검사한다. 전체 원장을 불필요하게 집계하거나 비용이 큰 정렬을 만들면 scope/index만 보완한다.
- RLS C07은 직접 테이블 조회와 SECURITY DEFINER RPC를 각각 실제 JWT role로 검증한다. row와 무관한 actor 정보만 요청당 계산 가능하며, row별 store 접근 판단을 단순 상수화하지 않는다.

검증: admin/store_admin/brand_admin/super_admin/orderer/accounting/service_role, 권한 없음·철회·다른 매장, 가격 비공개, counts/페이지 동일, 전체 이력 100/1,000/10,000건에서 고정 페이지 호출 수·bytes. 기존 발주 개선 T14와 결과를 공유한다.

### W05 — Direct Order 목록 SQL과 알림 summary

**SQL 먼저:** public orders v2/staff list v2의 현재 필터·환불 eligibility·정렬로 대상 page ID를 확정한 후 item count, 최신 quote, proof review, message aggregate, fulfillment/refund 정보를 각 관계에서 선집계해 붙인다. 오래된 미완료/미환불 주문을 page 결정 전에 잘못 제외하지 않는다. v2 응답 키는 유지한다.

**제안 신규 계약:** Edge `orders_v3` 및 DB `direct_order_public_orders_v3`로 알림용 summary를 제공한다. 필요한 필드는 현재 `_notifyForStatus` 소비에서 정하고 최소한 request ID, 알림 kind, 해당 quote ID/version 또는 proof review ID, 표시용 상태를 포함한다. 각 알림의 중복 제거 key를 안정적으로 계산한다. 직원 전용/다른 고객 필드와 불필요한 전체 메시지는 담지 않는다.

- 새 v3도 v2/단건 status를 주문별 호출하지 않는다. 같은 page 선집계 결과에서 만든다.
- 고객 poll은 summary 1회, 현재 열린 주문 상세 0~1회로 유지한다. 다른 주문 알림을 띄우기 위해 `fetchStatus`를 추가하지 않는다. 알림 클릭 시 상세를 여는 정상 사용자 조회는 별개다.
- 구 v2를 유지하고 DB → Edge action allowlist/rate limit/validation → Flutter model/service/screen 순으로 배포한다. capability 부재 fallback은 한 세션에 제한해 같은 오류 요청을 매 poll 반복하지 않는다.
- 알림 dedupe 상태는 session/store 경계로 분리한다. 새 견적, 동일 상태의 새 review, 재연결·중복 응답에서 누락/중복 여부를 비교한다. 현재 동작을 바꾸는 경우 변경 사유를 별도 기록한다.

검증: 0/1/50 고객 주문, 1/50/100/200 직원 주문, 동시 변경 알림 50개, 부분 환불, 포장 전환, 폐점 후 기존 주문, 고객 토큰 격리, 이전 v2 클라이언트. kitchen v3의 helper 0회 회귀도 유지한다.

### W06 — MISA 사업자별 설정·토큰 재사용

- dispatcher 실행의 지역 변수 Map으로만 캐시한다. 여러 실행/사업자 사이의 장기 전역 캐시는 도입하지 않는다.
- `loadSellerConfig` 성공 결과를 tax entity별 한 번 읽는다. 유효 token은 expiry와 refresh skew를 보존한 record로 받아 실행 내 재사용한다. helper의 기존 string 반환 소비자는 호환 adapter를 유지할 수 있다.
- 작업 사이 시간이 흘러 갱신 경계를 넘으면 해당 token만 재검증/갱신한다. 실패 Promise를 영구 캐시하지 않는다. 같은 실패를 job 수만큼 즉시 재요청하지 않도록 실행 내 실패 상태와 bounded retry를 명시한다.
- dry-run에서는 token·vendor API를 호출하지 않는다. payload 검사, job별 오류/attempt/event 기록, UUIDv7 ref_id와 비동기 dispatch를 유지한다.
- 토큰 오류나 응답 유실 시 자동 발행을 새로 반복하는 정책은 추가하지 않는다. 현재 재시도/원장 확인 계약을 유지하고 필요한 auth cache만 무효화한다.

검증: 같은 사업자 50건에서 3 SELECT, 여러 사업자에서 3T 상한, 만료 직전/중간 만료, 설정 누락, MISA timeout, dry-run, job별 실패 격리. fake transport helper 시험을 실제 handler 의존성 주입 시험까지 확장한다.

### W07 — Deliberry 퇴역 (코드·격리 검증 완료, 운영 적용 대기)

사용자 요청으로 기존 batch 최적화 계획을 철회한다. 신규 batch API나 개선된 dispatcher를 만들지 않는다.

- 관리자 메뉴와 구 화면 진입, provider 직접 호출을 닫았다.
- `deliberry-webhook`, `deliberry-dispatcher`, `generate-settlement`, `generate_delivery_settlement`는 DB/외부 API/credential 조회 없이 HTTP 410을 반환한다.
- `20261005050000_deliberry_retirement.sql`은 신규 수신·변경·재처리·정산 생성 RPC 권한과 table write를 차단하고 관련 cron을 해제한다. 이력 원장과 기존 SELECT/Office read 계약을 보존한다.
- 배포 스크립트에 네 endpoint 교체와 HTTP 410 확인을 포함했다. 실제 운영 교체/DB migration 적용은 아직 실행하지 않았다.
- 재활성화에는 새 사용자 결정과 migration이 필요하다. 원장 삭제나 기존 pending event 강제 전송으로 종료 처리하지 않는다.

검증: 실제 과거 migration 기반 SQL fixture에서 원장 동등성, 관리자/service_role/replication 역할의 쓰기 차단, cron 선택 해제, 다른 POS 경로 보존을 확인했다. Flutter 3개 언어와 direct provider 호출, Edge 6개 응답 시험을 통과했다. 세부 증거는 `docs/deliberry_retirement_implementation_20261005.md` 참조.

### W08 — 자동 일마감

Deliberry 정산 F09는 W07에서 퇴역하므로 추가 최적화를 하지 않는다.

대상 날짜/미마감 store 집합 → orders/payments/cancelled-items/inventory를 각각 store별 집계 → 한 `INSERT ... SELECT`. payments의 여러 합계는 `FILTER`로 한 집계에서 계산한다. 관계별 선집계로 금액 중복을 막는다. 기존 `ON CONFLICT`, 날짜 경계, inactive store, 비매출, inventory snapshot 의미를 유지한다. 과거 Deliberry 원장을 조회하는 보고서 계약은 보존한다.

검증: 1/10/100/500 store, 매출 없음·복수 결제·취소·비매출, 이미 마감, 두 동시 실행·중간 실패·재실행. store/기간별 원본 결제·마감 합계 대사 100% 일치. 단순 count 비교로 완료 처리하지 않는다.

### W09 — 일괄 입력·변경 명령과 trigger 내부 조회

- ingredient/recipe import 입력을 ordinal/source_row를 포함한 typed relation으로 한 번 파싱한다. 중복 code, menu/product/supplier scope, 단위·수량·가격·역할 검증을 집합 JOIN으로 처리한다.
- 모든 입력을 검증한 뒤 쓰는 기존 원자성을 유지한다. 오류가 여러 개면 원래 행 순서/검사 우선순위와 일치하는 첫 오류를 반환한다. 전체 rollback, NaN/Infinity 거절, 최대 1,000행 계약 유지.
- 상품/업체의 존재 여부를 미리 읽었더라도 잠금 전후 변경 가능성을 고려한다. 공급업체 생성 advisory lock과 unique constraint를 유지하고 lock은 정렬된 키 순서로 잡는다. 캐시된 가격/재고만 믿고 확정하지 않는다.
- 수동 발주/draft는 actor role 한 번 계산, supplier/product 집합 검증 후 기존 line 쓰기·총액 계산을 수행한다. 필요하면 공통 내부 bulk helper를 만들되 SQL SECURITY 경계를 넓히지 않는다.
- C08 발주 취소/수정의 receipt accepted 합계는 대상 PO line별로 한 번 집계한 뒤 UPDATE JOIN한다. 동시 입고 확정·반품·취소에서 잠금 후 잔량을 재검증한다.
- C09 KDS batch command·combo sync trigger·promotion/store-access/menu import wrapper는 기존 중앙 안정성 계획의 batch/trigger 항목과 연결한다. 일반 루프를 모두 없애지 않고, 1/10/100/최대 입력에서 중첩 공통 SELECT·원장 재집계·sequence 갱신의 증가를 먼저 측정한다. 반복이 확정되면 영향 ID 집합 집계 및 set-based DML로 변경한다.
- KDS 쓰기 변경은 W01/W02와 별도 release 묶음으로 다룬다. 고정 lock 순서, FIFO 배분, event/revision 연속성, idempotency 결과, 업무 변경+outbox 원자성을 보존한다. trigger를 끄거나 단건 `process_payment`를 다른 결제 anchor로 대체하지 않는다.

검증: 정상/중복/권한/잘못된 단위·숫자, source_row 오류, 동시 import, 최대 입력, 부분 실패 rollback. 실제 trigger까지 포함한 호출·buffers·WAL·lock 비교. 필요한 개별 쓰기와 제거한 공통 조회를 결과표에서 분리한다.

### W10 — 추가 후보 전부 종결

“미측정”을 “문제 없음”으로 처리하지 않는다. 아래 항목별로 **수정 완료** 또는 **유지 근거+대표 계획+재평가 조건**을 남긴다. 미사용 후보는 소비자 조사 근거와 보존 정책을 적는다.

| ID | 후보 | 담당 작업·확인 방법 | 조건에 따른 개선 |
|---|---|---|---|
| C01 | 발주 catalog | W04, actor call count + 최근 이력 계획 | actor 단일 계산, pair별 선집계/윈도 |
| C02 | 구/신 procurement workspace | W04, 실제 route trace·구버전/Office 계약 | 새 page 검증, legacy 소비 경로 보완 |
| C03 | 매출 export | W10, snapshot 유무별 receipt 1/100/10,000 | 기간/page별 line/job 선집계, 사업자 config 한 번 JOIN. 역사적 세금·snapshot 우선 의미 유지 |
| C04 | 다매장 inventory dashboard | W10, 단일 store와 NULL/all-store 분리 측정 | 지원되는 all-store 경로를 store별 집계. 단일 store에 억지 batch 도입 금지 |
| C05 | 재고 실사 top-1 | W10, 실제 인덱스·history skew·buffers A/B | indexed LATERAL 유지 또는 대상 item별 최신 row 선계산. 더 싼 계획 채택 |
| C06 | 외부 overview view | W10, 소비자·store 수·월 집계 계획 | 현재 view 계약을 보존한 사전 집계. 소비자 미확인 상태에서 삭제 금지 |
| C07 | row 조건의 RLS helper | W04, 실제 JWT/권한 철회/row 범위 시험 | 요청 공통 actor만 한 번 계산, store별 scope JOIN 유지 |
| C08 | 발주 취소/수정 receipt 합계 | W09, 다수 line·동시 입고 | 잠금·재검증된 line별 집계 UPDATE |
| C09 | KDS/관리 명령·trigger 반복 | W09, 하위 호출/lock/WAL 추적 | 입증된 반복 공통 읽기·집계만 일괄화. 필수 업무 DML 유지 |
| C10 | KDS snapshot base 상관 조회 | W01, 현재 wrapper 전 경로 계획 | 대상 queue별 item/recent-action 묶음, 적절한 top-1 index는 유지 가능 |

## 7. 테스트와 재발 방지

### 데이터 축

| 축 | 필수 사례 |
|---|---|
| 크기 | 조회 0/1/10/100/200, import 1/10/100/1,000, store 1/10/100/500 |
| 총 이력 | 고정 page에서 100/1,000/10,000건, 당일/30일/180일; 새로 조회하는 범위와 무관한 이력 증가 |
| 입력 중복 | 동일 queue/menu/supplier/tax entity 반복, 모두 다른 ID, 권한 없는 ID 혼합 |
| 권한 | 실제 직원 역할·service_role·고객 token, 타매장/floor·권한 철회·session 교체 |
| 시간 | 날짜/cutoff, token expiry, 두 페이지 사이 변경·삭제, 두 concurrent command |
| 오류 | DB/HTTP timeout, 일부 chunk 실패, 응답 유실, MISA 실패, 재시도·중복 이벤트 |

### 자동 검증 구성

1. 기존 KDS/QR/Direct Order/발주 SQL fixture를 우선 확장한다. 제안 신규 파일은 `scripts/test_n_plus_one_regressions.sh`와 `test/fixtures/n_plus_one/`이며 구현 때 생성한다. 현재 존재하는 runner라고 보고하지 않는다.
2. SQL source 문자열 검사는 보조로만 사용한다. 실제 RPC 결과 parity, 중첩 table read 횟수, query plan 및 client request 수를 assert한다. 실패를 감지하는지 의도적으로 기존 N+1 경로에도 실행한다.
3. KDS 실제 provider/gateway, Direct Order 실제 service/screen, Edge 실제 handler의 호출 횟수를 검증한다. 테스트 callback을 개선 구현처럼 만들어 통과시키는 것으로 끝내지 않는다.
4. 빠른 기능/호출 수 회귀는 `scripts/check_repo.sh`에 통합한다. 기존 CI 20분 예산을 측정해 필요하면 격리 성능 job을 분리하고 해당 변경에 필요한 gate로 연결한다. 측정을 빼서 green을 만들지 않는다.
5. merge 전 기존 repository checks·관련 SQL/Edge tests·Dart 분석·Flutter tests·web release build를 수행한다. 문서 작성만 한 이번 단계에서는 이 시험을 새로 실행했다고 주장하지 않는다.
6. 리뷰 체크: 루프/row renderer 안 원격 조회, batch RPC 안 단건 RPC 호출, 데이터 읽는 per-row helper, 1:N join 중복, page 전 전체 집계, cross-scope 캐시, row cap 누락, 무제한 fallback을 확인한다.

## 8. migration·배포·롤백

### 준비

- 기존 미추적 파일은 보존한다. 구현마다 적용 순서가 유일한 새 migration을 만들고 이전 파일을 조용히 수정하지 않는다. Procurement migration은 현재 `20261005030000` 이후로 분리됐다. release 준비에서 실제 적용 이력과 소유 작업을 확인한다. 이번 Deliberry 작업은 다른 작업의 파일명을 바꾸지 않는다.
- 각 성능 개선 SQL 묶음에 preflight/verify/rollback을 준비한다. 적용 전 signature·grant·search_path·현재 정의 hash와 인덱스 중복을 확인한다. rollback은 **이번 변경 직전 정의**를 복원하며 예전 migration 전체를 다시 실행하지 않는다. Deliberry 퇴역은 자동 재활성화 rollback을 제공하지 않으며, 새 사용자 결정과 migration이 있어야 다시 열 수 있다.
- 대형 인덱스는 EXPLAIN 근거가 있을 때만 추가한다. `CREATE INDEX CONCURRENTLY`는 transaction migration과 실행 조건이 다르므로 현재 배포 gate의 지원 경로를 먼저 갖춘다. 무조건 concurrent를 migration 본문에 넣지 않는다.

### 순서

1. 묶음별 로컬/격리 DB 기능·성능·권한·동시성 검증.
2. clean release checkout과 정확한 pushed SHA의 필수 **POS release contract** GitHub Actions 성공 확인. 로컬 PASS는 이 gate의 대체가 아니다.
3. 기존 client와 호환되는 DB helper/새 RPC 먼저, 필요한 Edge action 다음, Flutter 다음 순서로 적용.
4. 운영 배포는 `scripts/deploy_pos_production.sh` 경로를 사용한다. Deliberry 퇴역 endpoint 네 개의 배포와 HTTP 410 확인은 추가됐다. 현재 스크립트에 MISA dispatcher 배포는 포함되지 않으므로 **W06 전에 대상 allowlist·인증 검사·테스트·버전 확인을 gate에 추가**한다. 수동 Edge deploy로 우회하지 않는다.
5. KDS는 기존 rollout scope로 1매장부터 전환한다. 전체 500매장 확대는 기존 capacity 계획을 따른다. SQL helper 교체는 공유 함수라 전체 소비자에 즉시 영향이 있으므로, client flag만으로 DB canary가 된다고 주장하지 않는다. DB별 canary가 꼭 필요하면 versioned 함수/서버 routing을 먼저 준비한다.
6. 최소 한 번의 실제 peak·업무일 경계·관련 batch 실행을 관측한다. KDS/다중매장 확대 관측 기간은 기존 rollout 계획을 충족한다. MISA·정산 시험은 운영 invoice/지급을 인위적으로 생성하지 않고 정상 업무 결과로 확인한다.

### 중단·복구

즉시 중단: 타매장/다른 고객 정보 노출, 금액·수량 불일치, 주문 누락, 잘못된 삭제/상태 덮기, 중복 확정/발행, cursor 전진 후 데이터 유실. 성능은 고정 workload 기준 p95·buffers 악화, 오류/timeout/lock·backlog 증가도 중단 판단에 포함한다.

- client/batch 문제가 있으면 해당 rollout 확대를 중단하고 검증된 client/mode로 되돌린다. 구버전 복귀가 N+1을 다시 만들 수 있으므로 cohort와 요청 예산을 제한하고 전역 1초 snapshot polling으로 복귀하지 않는다.
- DB 회귀는 준비된 직전 함수 정의 복원 또는 forward fix로 대응한다. 새 client가 쓰는 RPC를 먼저 DROP하지 않는다.
- MISA는 필요한 dispatcher만 감속/중지하고 pending 작업을 보존한다. 재시도는 동일 job 식별자로 한다. 결제 완료는 계속 독립적으로 동작해야 한다. Deliberry는 퇴역 상태를 유지하며 기존 event를 재전송하지 않는다.
- 일마감 rollback은 이미 확정된 업무 데이터를 지우지 않는다. 읽기/코드 복원 후 확정 원장을 대사하고 중복 없이 재개한다. 과거 Deliberry 정산 원장은 읽기 전용으로 유지한다.

## 9. 실행 체크리스트와 최종 완료 판정

- [ ] W00: 감사 기준선/최신 정의/수치 계약 확정
- [ ] W01: KDS 이름·콤보·wrapper SQL 개선, C10 판정
- [ ] W02: KDS batch API·provider·shadow·cursor 회귀 통과
- [ ] W03: QR 항목/part 일괄 보강 및 동등성 통과
- [ ] W04: 발주 권한·catalog·page/RLS 검증 완료
- [ ] W05: Direct Order 선집계·알림 summary·v2 호환 완료
- [ ] W06: MISA 실행 내 캐시·만료/실패·dry-run 시험 완료
- [x] W07 코드·격리: Deliberry 퇴역 UI/Edge/DB guard 및 회귀 완료
- [ ] W07 운영: migration·네 endpoint·앱 적용 및 HTTP 410 확인
- [ ] W08: 자동 일마감 전후 대사/동시성 완료 (Deliberry 정산은 퇴역)
- [ ] W09: import/command/trigger의 검증된 반복 조회 제거
- [ ] W10: C01~C10 각각 수정 또는 유지 근거로 종결
- [ ] W11: CI·migration gate·단계 배포·운영 관측·rollback 증거 확보

최종 보고서에는 각 F/C 항목별로 **소스 구현 / 격리 검증 / DB 적용 / Edge·앱 배포 / 운영 검증**을 별도 기재한다. 필수 항목을 “나중에 측정” 상태로 두고 전체 완료라고 보고하지 않는다.

최종 완료 조건은 F01~F11의 개선 기준 통과, 모든 후보의 근거 있는 판정, 기존 업무 계약 회귀 통과, 관련 release gate 및 운영 관측 완료다. 남겨야 하는 indexed top-1·필수 개별 작업은 이유와 측정치를 남긴다. **“모든 SQL에 loop가 없다”가 아니라 “불필요한 N+1이 제거됐고 처리 범위와 비용을 측정으로 설명할 수 있다”를 완료 기준으로 삼는다.**

초기 산출물은 계획 문서였다. 이후 Deliberry 사용 중지 요청을 반영해 관련 기능 코드·DB migration·배포 gate를 변경하고 격리 검증했다. 운영 DB/서비스에는 아직 적용하지 않았다.


## 2026-10-05 후속 운영 반영

W07 Deliberry 종료와 기존 Direct Order 주방 set-based 개선을 운영에 반영하고 확인했다. 전체 N+1 계획의 나머지 구현 상태는 그대로다. [정확한 main 릴리스·운영 검증 보고서](../operations/direct_order_deliberry_sample_release_20261005_70498547.md) 참조.
