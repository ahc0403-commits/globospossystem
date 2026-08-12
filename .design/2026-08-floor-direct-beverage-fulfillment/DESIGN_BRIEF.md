# 설계 브리프: 페이퍼리스 음료 층 직접 제공 경로

Date: 2026-08-12
Source: 사용자 요청 및 현재 GLOBOS POS 페이퍼리스 구현 조사
Status: 핵심 기능 로컬 구현 및 검증 완료 — 운영 미배포

## 구현 상태 (2026-08-12)

- 음식 처리 원장을 변경하지 않고 음료 전용 원장을 추가해 기존 주방→트레이→층 경로를 보존했다.
- 주방·트레이 음료는 조회 전용, 배정 층 음료는 개별/주문 전체 완료·원복이 가능하다.
- 일반 음료와 콤보 음료를 주문 시점 route snapshot으로 분리한다.
- 고객 QR에는 최종 제공 수량, 캐셔에는 논리 품목별 제공 상태를 표시한다.
- 관리자 메뉴별 route 설정, 매장별 신규 주문 활성화 플래그, 보고서 내 운영 분석 대시보드를 구현했다.
- 5열 메뉴 그리드와 고객 환경 보호 안내 문구를 유지했다.
- POS DB 안에서 이벤트를 계산하는 매장 범위 분석 RPC를 구현했다. Office KPI 연동과 장기 집계 테이블/cron은 별도 승인 과제로 남긴다.
- 운영 DB 적용과 웹 배포는 수행하지 않았다.

## 1. 목표

페이퍼리스 주문에서 음료를 주문 전체 구성에는 계속 노출하되, 처리 권한과 시간 측정 경로를 음식과 분리한다.

- 음식: `주문 접수 → 주방 완료 → 트레이 수령/발송 → 층 제공 완료`
- 음료: `주문 접수 → 해당 층에서 직접 제공 완료`
- 주방과 트레이에는 음료가 보이지만 품목 클릭과 주문 단위 완료 대상에서는 제외한다.
- 해당 층에서만 음료 품목을 개별 클릭하거나 층 주문 전체 완료로 처리할 수 있다.
- 고객 주문 화면과 캐셔 화면에는 최종 제공 수량과 품목별 상태가 동일하게 반영된다.
- 기존 음식의 개별 완료, 주문 전체 완료, 원복, 오프라인 outbox, 5열 그리드, 고객/캐셔 진행 표시, 포스 프린트 모드를 훼손하지 않는다.

## 2. 현재 구현에서 확인한 기준선

### 그대로 보존할 계약

1. `emergency_fulfillment_items`의 음식 수량 체인:

   ```text
   0 <= floor_served
     <= tray_dispatched
     <= tray_received
     <= kitchen_done
     <= ordered
   ```

2. 품목 클릭은 `emergency_record_progress`에서 계정의 매장·스테이션·층을 재검증하고 한 번에 1개만 처리한다.
3. 하단 `완료(다음 단계)`는 `emergency_complete_order_stage`에서 현재 스테이션의 처리 가능한 수량만 원자적으로 완료한다.
4. `취소(원복)`는 append-only action/event를 남기고, 다음 단계가 이미 처리한 수량은 원복을 거절한다.
5. Flutter 클라이언트는 낙관적 반영 후 서버 스냅샷을 다시 읽고, 통신 실패 시 멱등성 ID와 함께 IndexedDB outbox에 보관한다.
6. 주문 상세는 5개 이상일 때 태블릿 5열, 중간 화면 3/2열, 휴대폰 1열을 사용한다.
7. 고객 QR 주문 화면은 페이퍼리스 주문에 `전달/남음` 수량을 표시한다.
8. 캐셔는 결제를 차단하지 않고 주문 전체 미제공 수량과 메뉴별 제공 수량을 표시한다.
9. 포스 프린트 주문은 현행 프린터 경로를 그대로 사용하고, 주문/품목의 `fulfillment_mode_snapshot`으로 페이퍼리스 여부를 고정한다.
10. 적용된 과거 migration은 수정하지 않고 새 additive migration으로만 확장한다.

### 현재 구조에서 바로 음료 분기를 넣으면 깨지는 지점

- 화면의 `hasActionableQuantity`는 모든 품목이 동일한 단계 체인을 탄다고 가정한다.
- 층 품목은 현재 `tray_dispatched_quantity`까지만 클릭할 수 있으므로 직접 제공 음료는 항상 `0 / 0`이 된다.
- DB 제약은 `floor_served <= tray_dispatched`를 강제하므로 트레이를 건너뛴 음료를 저장할 수 없다.
- 주문 전체 완료 RPC가 모든 품목을 현재 스테이션 단계로 이동하므로 음료도 주방·트레이 완료 처리된다.
- 주방·트레이 보드는 로컬 처리 가능 수량이 없는 주문을 숨기므로 음료 전용 주문이 표시되지 않는다.
- 캐셔의 품목 진행 Map은 `order_item_id`당 단일 행을 가정한다.
- 선택한 콤보 음료는 별도 `order_items` 행이 아니라 부모 주문 품목의 `combo_components` JSON에 저장된다.

## 3. 핵심 설계 결정

### 3.1 카테고리명으로 런타임 판별하지 않는다

`음료`, `Drink`, `Đồ uống` 같은 표시명 비교는 다국어·이름 변경·Excel 갱신에 취약하다. 메뉴에 명시적인 처리 경로를 저장한다.

```text
kitchen_tray_floor  음식 기본 경로
floor_direct        해당 층 직접 제공 경로
```

- `menu_items.fulfillment_route`에 현재 설정을 저장한다.
- `order_items.fulfillment_route_snapshot`에 주문 품목 생성 시점을 고정한다.
- 메뉴 설정을 나중에 바꿔도 이미 생성된 주문의 경로는 바뀌지 않는다.
- 기존 주문과 기존 `emergency_fulfillment_items`는 모두 `kitchen_tray_floor`로 유지해 배포 중 동작이 바뀌지 않게 한다.
- 현재 안정적인 `menu_categories.system_key = 'drink'` 항목은 메뉴 초기 분류에만 사용한다. 런타임은 이름이나 현재 카테고리를 다시 조회하지 않는다.
- `alcohol` 카테고리는 영업 확인 없이 자동 음료 전환하지 않는다. 필요하면 메뉴별 설정으로 `floor_direct`를 지정한다.

### 3.2 기능 활성화 플래그를 별도로 둔다

`restaurant_settings.floor_direct_beverages_enabled boolean default false`를 추가한다.

- false: 새 주문도 기존 음식 체인으로 캡처한다.
- true: 새로 생성되는 주문 품목부터 메뉴의 `fulfillment_route`를 캡처한다.
- 활성화 전 생성된 주문은 끝까지 기존 경로로 처리한다.
- 문제 발생 시 플래그를 false로 바꾸면 신규 직접 제공 유입만 즉시 중단되고, 이미 캡처된 주문은 새 클라이언트에서 정상 마감한다.

이 플래그는 페이퍼리스/포스 프린트 운영 모드와 독립적이다. 직접 제공 경로는 페이퍼리스 KDS에서만 사용하며 포스 프린트 티켓 생성 규칙은 바꾸지 않는다.

### 3.3 주문 품목과 작업 단위를 분리한다

결제·영수증의 `order_items`는 그대로 유지하고, KDS의 `emergency_fulfillment_items`를 논리적 작업 단위로 확장한다.

추가 필드 권장안:

- `line_key text not null default 'base'`
- `source_kind text`: `order_item`, `combo_component`
- `component_menu_item_id uuid null`
- `fulfillment_route_snapshot text not null default 'kitchen_tray_floor'`
- `name_ko_snapshot`, `name_vi_snapshot`, `name_en_snapshot`

고유성은 기존 `(session_id, order_item_id)`에서 다음으로 확장한다.

```text
(session_id, order_item_id, line_key)
```

작업 단위 생성 규칙:

- 일반 음식: `line_key=base`, 음식 경로 1개
- 일반 음료: `line_key=base`, 층 직접 경로 1개
- 콤보 음식 부분: 기존과 동일한 부모 콤보 작업 1개
- 콤보에 포함/선택된 음료: `line_key=combo:<menu_item_id>`로 음료 종류별 작업 추가
- 동일 음료를 여러 개 선택하면 한 행에 수량을 합산한다.
- 콤보의 음식 부분은 현재와 같이 하나의 콤보 행으로 유지해 기존 주방·트레이 UX를 보존한다.
- 콤보가 직접 제공 구성만 가진 예외는 주방용 빈 base 행을 만들지 않는다.

`combo_components` 스냅샷에는 앞으로 각 구성의 메뉴 ID, 다국어 이름, 수량, `is_total_quantity`, `fulfillment_route_snapshot`을 함께 저장한다. 현재 JSON 소비자는 새 필드를 무시할 수 있으므로 하위 호환된다.

### 3.4 경로별 DB 수량 제약

기존 제약을 삭제하지 않고 같은 이름의 route-aware 제약으로 교체한다.

```text
route = kitchen_tray_floor:
  0 <= floor_served <= tray_dispatched <= tray_received <= kitchen_done <= ordered

route = floor_direct:
  kitchen_done = 0
  tray_received = 0
  tray_dispatched = 0
  0 <= floor_served <= ordered
```

클라이언트가 잘못된 버튼을 노출하더라도 서버가 주방·트레이의 음료 수량 변경을 반드시 거절한다.

## 4. 상태 전이와 권한

| 품목 경로 | 주방 | 트레이 | 해당 층 | 다른 층 |
|---|---|---|---|---|
| 음식 | 표시·클릭 가능 | 표시·클릭 가능 | 트레이 발송분만 클릭 가능 | 주문 자체 미노출 |
| 층 직접 제공 | 표시·클릭 불가 | 표시·클릭 불가 | 주문 즉시 클릭 가능 | 주문 자체 미노출 |

### 품목 개별 클릭

- 음식은 기존 단계와 RPC를 그대로 사용한다.
- 직접 제공 음료는 `floor_served`만 허용하고 limit는 `ordered_quantity`다.
- 주방·트레이가 직접 제공 음료에 `emergency_record_progress`를 호출하면 `PAPERLESS_ROUTE_STAGE_FORBIDDEN`으로 거절한다.
- 층 계정도 자신의 `floor_label` 주문만 처리할 수 있다.
- 중복 event ID는 현재와 같이 한 번만 반영한다.

### 주문 전체 완료

- 주방: 음식 경로 품목의 남은 `kitchen_done`만 완료하고 직접 제공 음료는 건드리지 않는다.
- 트레이: 음식 경로 품목의 남은 `tray_received/tray_dispatched`만 완료하고 직접 제공 음료는 건드리지 않는다.
- 층: 도착한 음식과 직접 제공 음료의 남은 `floor_served`를 함께 완료한다.
- 음료만 있는 주문의 주방·트레이 전체 완료 버튼은 비활성화한다.
- 서버는 처리 대상 delta가 0이면 기존 `ALREADY_COMPLETE` 계열 오류를 유지하되, 경로 때문에 처리 불필요한 경우를 구분 가능한 코드로 반환한다.

### 원복

- 음식 action의 원복 규칙은 변경하지 않는다.
- 직접 제공 음료의 층 완료 action은 동일한 append-only 보상 이벤트로 원복한다.
- 음료는 하위 단계가 없으므로 층 제공 수량만 0 아래로 내려가지 않게 검증한다.
- 한 주문의 층 전체 완료에서 음식과 음료를 함께 처리했다면 한 action ID 아래 품목별 event를 기록하고 함께 원복한다.

### 주문 취소와 수량 변경

- 취소된 주문 품목의 base와 콤보 component 작업을 모두 `is_cancelled=true`로 동기화한다.
- 주문 수량 증가/감소 시 base 및 배수형 콤보 수량을 다시 계산한다.
- 처리 수량보다 주문 수량이 작아지면 기존 `needs_review` 계약을 모든 작업 단위에 적용한다.
- 이미 처리한 수량은 자동 삭제하지 않는다.

## 5. 스테이션 UI

### 주방·트레이 상세

직접 제공 음료 카드는 기존 5열/3열/2열/1열 레이아웃 안에 그대로 배치한다.

- 음료 아이콘과 `층에서 직접 제공` 배지를 표시한다.
- 카드 색상은 완료/경고색이 아닌 정보성 중립색을 사용한다.
- `제공 수량 / 주문 수량`은 조회용으로 계속 표시한다.
- 카드의 `onTap`은 null이고 semantics도 비활성 상태를 명확히 읽는다.
- 눌러도 낙관적 상태 변경, RPC, outbox 기록이 발생하지 않는다.
- 음식 카드는 현재 클릭·진행·원복 동작을 그대로 유지한다.

### 주방·트레이 보드

현재는 로컬 actionable 수량이 없으면 주문이 숨겨지므로 별도 표시 판정을 추가한다.

- 로컬 음식 처리 필요: 기존 `처리 대기`
- 로컬 음식은 완료됐지만 직접 제공 음료가 남음: `층 직접 제공 진행 중`
- 음료 전용 주문: 주문 카드는 보이되 `층 처리 주문 · 로컬 작업 없음`
- 모든 최종 제공 완료: 활성 보드에서 제거
- 음료 전용 주문은 주방·트레이가 완료한 action이 없으므로 최근 완료 목록에 억지로 넣지 않는다.

### 층 상세

- 음식은 기존처럼 트레이 발송 수량까지만 클릭할 수 있다.
- 직접 제공 음료는 주문 생성 직후 `0 / 주문 수량`으로 클릭 가능하다.
- 음식과 음료는 아이콘·배지로 구분하되 한 주문의 5열 그리드 안에서 함께 확인한다.
- 하단 전체 완료는 현재 층에서 처리 가능한 음식과 음료 delta를 한 트랜잭션으로 완료한다.

### 알람

- 직접 제공 음료가 생성되면 해당 층에 즉시 알람과 push를 보낸다.
- 주방·트레이는 직접 제공 음료만 있는 주문 때문에 작업 알람을 울리지 않는다. Realtime/폴링으로 주문은 표시한다.
- 혼합 주문은 음식 생성으로 주방 알람, 음료 생성으로 해당 층 알람을 각각 한 번씩 보낸다.
- `event_id` 중복 제거와 기존 Web Push/outbox 계약을 유지한다.

## 6. 고객 주문 화면과 캐셔

### 고객 주문 화면

결제용 주문 행은 바꾸지 않고 `fulfillment_parts`를 선택적으로 추가한다.

```json
{
  "order_item_id": "...",
  "name": "Combo A",
  "quantity": 1,
  "served_quantity": 1,
  "fulfillment_parts": [
    {"name": "Combo A", "route": "kitchen_tray_floor", "served": 1, "ordered": 1},
    {"name": "Cola", "route": "floor_direct", "served": 0, "ordered": 1}
  ]
}
```

- 일반 메뉴는 기존 `전달/남음` 표시를 유지한다.
- 콤보는 결제 메뉴명 아래에 음식 부분과 선택 음료의 제공 수량을 표시한다.
- 고객은 주방·트레이 내부 상태를 보지 않고 최종 제공 수량만 확인한다.
- 기존 클라이언트가 `fulfillment_parts`를 몰라도 기존 필드로 렌더링할 수 있게 한다.

### 캐셔

- 기존 `미제공 N` 경고는 유지한다.
- 품목별 상세는 논리적 작업 단위별 상태를 표시한다.
- 직접 제공 음료에는 `층 직접 제공` 라벨을 붙인다.
- 콤보 음료도 부모 콤보 아래에 별도 상태로 표시한다.
- 합계는 모든 비취소 작업 단위의 `ordered - floor_served`를 합산한다.
- 결제는 현재와 같이 경고만 하며 차단하지 않는다.
- 직접 테이블 SELECT에서 `order_item_id` Map으로 덮어쓰는 방식을 서버 RPC 기반 상세 조회로 교체해 콤보 다중 작업을 안전하게 처리한다.

## 7. 분석 데이터 계약

직접 제공 음료에는 가짜 주방·트레이 완료 이벤트를 만들지 않는다.

- 작업 생성 시각 또는 새 `floor_direct_ready` event를 시작점으로 사용한다.
- 음료 완료는 기존 `floor_served` event에 route 정보를 함께 남긴다.
- 음식 분석은 기존 네 단계만 사용한다.
- 음료 분석은 `주문/작업 생성 → 층 제공 완료`만 사용한다.
- 병목 계산에서 음료의 주방·트레이는 0분이 아니라 `N/A`로 제외한다.
- 기존 주문은 `legacy kitchen_tray_floor`로 해석한다.

초기 릴리스는 정확한 event 축적까지만 포함한다. 대시보드와 병목 리포트는 운영 경로가 안정된 뒤 Release C로 만든다.

### 분석 처리 위치

분석 계산은 Flutter 화면이나 외부 스프레드시트에서 하지 않고 POS Supabase Postgres에서 수행한다.

```text
paperless progress RPC
  -> emergency_fulfillment_events (원천 append-only event)
  -> v_fulfillment_line_cycle_times (논리 품목별 정규화 시간)
  -> fulfillment_metrics_hourly / fulfillment_metrics_daily (집계)
  -> get_store_fulfillment_dashboard RPC -> POS 관리자 > 보고서 > 페이퍼리스 운영
  -> v_office_pos_fulfillment_metrics   -> Office > KPI > 주문 처리
```

- `emergency_fulfillment_events`를 감사 가능한 원천 사실로 유지한다. 기존 테이블을 이름 변경하거나 현재 조리 동작의 write path를 교체하지 않는다.
- event에는 route, logical line identity, 메뉴/층 snapshot, action ID를 저장한다. 이름 변경이나 메뉴 이동이 과거 통계를 바꾸지 않게 한다.
- Flutter는 원천 event 전체를 내려받아 계산하지 않는다. 날짜 범위가 길어져도 DB가 집계한 제한된 row만 읽는다.
- 현재 emergency/event 테이블에는 자동 삭제를 추가하지 않는다. 향후 보관 정책을 만들더라도 일·시간 집계를 먼저 확정 저장한 후 원천 event를 별도 승인 절차로 보관 처리한다.

### 시간과 병목 정의

`v_fulfillment_line_cycle_times`는 논리 품목 line 한 개를 한 행으로 정규화한다. 단순 `max(created_at)`이 아니라 delta와 원복을 누적해 최종적으로 해당 수량에 도달한 유효 시각을 사용한다.

| 지표 | 시작 | 종료 | 적용 경로 |
|---|---|---|---|
| 주방 조리 | `order_received` | `kitchen_done` | 음식 |
| 트레이 수령 대기 | `kitchen_done` | `tray_received` | 음식 |
| 트레이 준비·발송 | `tray_received` | `tray_dispatched` | 음식 |
| 층 서빙 | `tray_dispatched` | `floor_served` | 음식 |
| 층 직접 음료 제공 | `floor_direct_ready` 또는 line 생성 | `floor_served` | 직접 제공 음료 |
| 전체 리드타임 | `order_received` | 모든 logical line의 `floor_served` | 주문 전체 |

- 주문 병목은 그 주문에 실제 적용된 단계 중 소요 시간이 가장 긴 단계다.
- 직접 제공 음료의 주방·트레이 시간은 0초가 아닌 `N/A`로 저장하고 denominator에서 제외한다.
- 평균만 표시하지 않고 P50, P90, SLA 초과율, 표본 수를 함께 계산한다.
- 미완료 주문은 완료 시간 통계에 넣지 않고 `현재 대기 시간`과 `미완료 수량`으로 별도 표시한다.
- 취소, 수량 감소, 원복은 event 원장을 따라 재계산하며 중복 action은 한 번만 집계한다.
- 모든 날짜 경계는 기존 운영 계약인 `Asia/Ho_Chi_Minh`, 00:00 business date를 사용한다.

### 집계 방식과 갱신 주기

- 원천 event와 정규화 view는 상세 조사 및 검증용이다.
- `fulfillment_metrics_hourly`는 매장·영업일·시간대·route·stage·층·메뉴 단위의 P50/P90, 완료 수량, SLA 초과 수량, 원복 수량을 저장한다.
- `fulfillment_metrics_daily`는 Office 장기 추세와 매장 비교에 사용한다.
- 기존 `pg_cron` 패턴을 재사용해 최근 영업일 구간을 5분마다 idempotent upsert한다. 늦은 완료와 원복을 반영하도록 현재 영업일만 append하지 않고 최근 구간을 재계산한다.
- 집계 실패 시 화면을 비우지 않고 마지막 정상 결과, `마지막 갱신`, `지연됨` 상태를 표시한다.
- raw count, line timing count, rollup count를 대조하는 데이터 품질 검사에서 불일치가 있으면 대시보드에 `부분 데이터`로 표시한다.

### 표시 위치 1 — 매장용 POS

기존 `관리자 > 보고서` 안에 `매출`과 분리된 `페이퍼리스 운영` 하위 화면을 추가한다. 기존 매출 `reportProvider`가 원천 테이블을 client-side 집계하는 경로에는 event 분석을 섞지 않고, 전용 read-only RPC/provider를 사용한다.

- 대상: 현재 로그인한 매장 관리자와 허용된 super admin.
- 기본 범위: 오늘. 빠른 선택은 오늘, 7일, 30일이며 날짜·층·route·메뉴·시간대 필터를 제공한다.
- 첫 화면: 전체 리드타임 P50/P90, SLA 준수율, 현재 미완료, 가장 큰 병목을 즉시 보여준다.
- 주 증거: 시간대별 단계 P50/P90 추이와 병목 비중을 작은 다중 막대/선 그래프로 표시한다.
- 상세: 느린 메뉴, 느린 층, 지연 주문을 표로 제공하고 주문을 선택하면 단계별 타임라인을 read-only로 연다.
- 필수 수치는 hover 없이 노출하며 모바일에서는 요약 -> 단계 차트 -> 순위 표 순서로 배치한다.
- 기존 주방·트레이·층 화면은 실시간 처리 화면으로 유지한다. 과거 분석 차트 때문에 작업 화면의 Realtime, 폴링, 알람에 부하를 추가하지 않는다.

### 표시 위치 2 — 본사용 Office

다매장 비교와 장기 추세는 기존 `https://office.globos.vn/kpi`의 `주문 처리` 영역에서 보여준다. POS에는 Office용 versioned read-only 집계 view를 추가하고, Office 서버만 이를 읽는다.

- 대상: 본사 권한 사용자. 매장별 원천 event나 직원 개인정보를 브라우저에 직접 노출하지 않는다.
- 주요 화면: 매장별 P50/P90, SLA 초과율, 병목 단계 비중, 층 직접 음료 제공 시간, 전주·전월 대비.
- 매장 비교는 표본 수와 데이터 갱신 시각을 항상 함께 표시한다.
- Office 장애나 지연은 POS 주문 처리와 결제에 영향을 주지 않는다.
- 초기 Release C는 POS 매장 대시보드를 먼저 배포하고, 계산 결과 대조 후 같은 집계 계약으로 Office를 연결한다.

### 접근 권한

- 매장 RPC는 `user_accessible_stores(auth.uid())` 범위를 강제하고 고객·주방·트레이·층 계정에는 제공하지 않는다.
- Office cross-store view는 기존 Office 서버의 server-side 연결에서만 사용하고 service-role 자격 증명을 Flutter/Web client에 포함하지 않는다.
- actor 정보는 감사 조사용 상세 권한에서만 조회하며 기본 대시보드와 매장 순위에는 노출하지 않는다.
- 고객 QR 및 캐셔 상태 RPC는 분석 view와 분리해 대시보드 변경이 주문 조회나 결제에 영향을 주지 않게 한다.

## 8. 관리자와 Excel

### 메뉴 관리

메뉴 추가/수정창에 `페이퍼리스 처리 경로` 선택을 추가한다.

- `주방 → 트레이 → 층` 기본값
- `층에서 직접 제공` 선택값
- 음료 시스템 카테고리에서는 새 메뉴 기본값을 직접 제공으로 제안한다.
- 사용자가 명시적으로 바꿀 수 있으며 감사 로그에 old/new route를 남긴다.
- 음식 구성도 포함된 콤보 자체를 직접 제공으로 설정하는 것은 서버에서 거절하고, 콤보 안 음료 component만 직접 제공한다.

### Excel

- 내보내기 마지막 열에 안정적인 코드값 `fulfillment_route`를 추가한다.
- 기존 열 순서와 기존 workbook 입력은 유지한다.
- 열이 없는 구형 파일은 카테고리 기본값으로 보완한다.
- 알 수 없는 값은 전체 transaction을 거절하고 행 번호를 알려준다.
- round-trip 후 route가 유실되지 않는 테스트를 추가한다.

## 9. 호환 배포 순서

### Release A — DB expand, 기능 OFF

- 새 컬럼·route-aware 제약·호환 RPC를 배포한다.
- 모든 default는 기존 음식 경로다.
- 직접 제공 플래그는 모든 매장에서 false다.
- 기존 Flutter 앱이 그대로 동작하는지 검증한다.
- 기존 활성 페이퍼리스 주문을 재분류하지 않는다.

### Release B — 새 Flutter 클라이언트

- provider/model이 route 누락 시 음식 경로로 fallback한다.
- 주방·트레이 비활성 음료 카드, 층 직접 클릭, 캐셔·고객 component 표시를 배포한다.
- 기능 플래그는 계속 false라 운영 동작은 아직 바뀌지 않는다.
- 모든 스테이션 브라우저가 새 exact SHA를 로드했는지 확인한다.

### Store configuration

- `system_key='drink'` 메뉴를 직접 제공 후보로 제시한다.
- 매장 담당자가 실제 음료/예외 메뉴를 확인한다.
- 콤보 선택 음료와 고정 음료 구성의 route snapshot을 확인한다.
- 주류는 별도 확인 후 설정한다.

### Pilot enable

- 진행 중 페이퍼리스 주문이 없는 시점에 Binh Thanh 한 매장만 플래그를 켠다.
- 혼합 주문, 음료 전용 주문, 콤보 음료를 실제 1F/2F 계정으로 검증한다.
- 문제가 없으면 매장별로 순차 활성화한다.

### Release C — 분석 대시보드

- 파일럿 event를 수작업 타임라인과 대조해 시간 계산이 맞는지 먼저 shadow 검증한다.
- 집계 테이블·refresh job·매장 dashboard RPC를 주문 처리 write path와 분리해 배포한다.
- POS 한 매장의 `페이퍼리스 운영` 화면을 먼저 열고 수치·부하·권한을 확인한다.
- 같은 versioned 집계 계약으로 Office `주문 처리` KPI를 연결한다.
- 분석 job이나 Office가 실패해도 paperless action, 결제, 고객 주문 조회는 계속 동작해야 한다.

### Rollback

- 즉시 플래그 false: 신규 주문은 기존 체인으로 돌아간다.
- 이미 직접 제공으로 캡처된 주문은 새 서버/클라이언트로 마감한다.
- 직접 제공 미완료 주문이 0이 되기 전에는 route-aware DB 함수나 새 Flutter 코드를 롤백하지 않는다.
- destructive schema rollback은 하지 않는다.

## 10. 필수 테스트 매트릭스

| 시나리오 | 주방 | 트레이 | 층 | 고객/캐셔 |
|---|---|---|---|---|
| 음식만 | 기존과 동일 | 기존과 동일 | 발송분 처리 | 기존과 동일 |
| 음료만 | 표시·클릭 불가 | 표시·클릭 불가 | 즉시 클릭 가능 | 음료 진행 표시 |
| 음식+음료 | 음식만 클릭 | 음식만 클릭 | 두 종류 클릭 | 메뉴별 상태 표시 |
| 콤보+선택 음료 | 콤보 음식 클릭 | 콤보 음식 클릭 | 선택 음료 즉시 처리 | 콤보 하위 상태 표시 |
| 수량 2 이상 | 음료 변경 없음 | 음료 변경 없음 | 한 개씩 증가 | 1/2, 2/2 반영 |
| 주문 전체 완료 | 음식만 변경 | 음식만 변경 | 음식+음료 변경 | 합계 일치 |
| 원복 | 음식 기존 규칙 | 음식 기존 규칙 | 음료 원복 가능 | 즉시 감소 |
| 오프라인 | 음료 클릭 생성 안 됨 | 음료 클릭 생성 안 됨 | outbox 후 재전송 | 중복 없음 |
| 잘못된 층/매장 | 접근 거절 | 접근 거절 | 접근 거절 | 데이터 미노출 |
| 모드/route 변경 중 기존 주문 | snapshot 유지 | snapshot 유지 | snapshot 유지 | 상태 불변 |

추가 회귀 게이트:

- 현재 5열 2행 테스트와 모든 기존 paperless golden 유지
- 기존 음식 item-level/whole-order/revert 테스트 유지
- 포스 프린트 mode의 print job payload·claim 결과 불변
- 결제 원자성·미제공 경고 비차단 계약 불변
- KO/VI/EN, 390×844, 1024×768, 1440×900, 100%/200% 글자 크기
- 전체 `bash scripts/check_repo.sh`, `flutter test`, release web build
- 운영 배포는 exact pushed main SHA의 `Photo Objet contract` 성공 후 `scripts/deploy_pos_production.sh`만 사용

## 11. 완료 판정

1. 음료 전용 주문도 주방·트레이에 보이고 어떤 조작도 발생하지 않는다.
2. 같은 음료는 해당 층에서만 수량 단위로 처리된다.
3. 음식 경로의 모든 기존 동작과 수량 제약이 그대로 통과한다.
4. 주문 전체 완료가 주방·트레이에서 음료를 건드리지 않고, 층에서는 음식과 음료를 정확히 완료한다.
5. 콤보 음식과 선택 음료가 서로 다른 경로로 처리되고 고객·캐셔에 둘 다 표시된다.
6. 고객·캐셔·세 스테이션의 수량이 Realtime/폴링 후 동일하다.
7. route 변경이 기존 주문을 중간에 재라우팅하지 않는다.
8. 포스 프린트 주문과 결제는 이번 변경 전과 동일하다.
9. 플래그 OFF 상태에서 현재 운영 동작과 golden이 동일하다.
10. 파일럿에서 오류 없이 마감한 뒤에만 다른 매장에 활성화한다.
11. POS 매장 대시보드와 Office 집계가 같은 fixture에서 동일한 P50/P90·병목 결과를 반환한다.
12. 분석 refresh 실패·지연·Office 장애가 주문 처리와 결제에 영향을 주지 않는다.
