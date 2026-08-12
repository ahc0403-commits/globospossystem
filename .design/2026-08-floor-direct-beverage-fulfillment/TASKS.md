# Build Tasks: 페이퍼리스 음료 층 직접 제공 경로

Generated from: `.design/2026-08-floor-direct-beverage-fulfillment/DESIGN_BRIEF.md`
Date: 2026-08-12

## 현재 구현 범위

2026-08-12 기준으로 층 직접 제공 DB 원장/RPC, 일반·콤보 음료 분기, 주방·트레이 읽기 전용 표시, 층 개별·전체 완료/원복, 고객·캐셔 상세 상태, 관리자 route/매장 플래그, POS 운영 분석 대시보드까지 로컬 구현·검증했다. 기존 음식 처리와 포스 프린트 기능은 그대로 유지한다.

아래 목록은 구현 완료 항목뿐 아니라 Excel 확장, Office KPI, 운영 파일럿과 점진 배포까지 포함한 전체 릴리스 계획이므로 체크되지 않은 후속 항목은 이번 로컬 구현 완료 판정과 별개다. 운영 배포는 아직 실행하지 않았다.

## 기준선과 안전장치

- [ ] **현재 운영 기준선 고정**: 배포 SHA `157dd31a`에서 음식 전용 개별 완료, 주문 전체 완료/원복, outbox, 5열 그리드, 고객 QR 진행, 캐셔 품목 상태, 포스 프린트 회귀 테스트 결과와 golden checksum을 기록한다. _Reuses: `test/emergency_fulfillment_responsive_test.dart`, `test/pos_paperless_visual_test.dart`, `test/emergency_digital_fulfillment_contract_test.dart`, QR/cashier contract tests._
- [ ] **운영 데이터 read-only preflight**: 적용된 migration history, 활성 페이퍼리스 세션/미완료 수량, `drink` 시스템 카테고리, 콤보 구성, 1F/2F 스테이션 배정, 메뉴별 분류 후보를 조회해 구현 전 보고한다. 데이터는 변경하지 않는다. _Reuses: existing production migration gates and store-scoped schema._
- [ ] **회귀 불변식 테스트 선작성**: 플래그 OFF와 route 필드 누락 시 기존 음식 체인·UI·RPC·print job이 동일하다는 테스트를 먼저 추가한다. _Modifies: existing contract/widget tests; creates no runtime component._

## DB Foundation — Release A, 기능 OFF

- [ ] **명시적 메뉴 처리 경로 추가**: `menu_items.fulfillment_route`, `order_items.fulfillment_route_snapshot`, 매장별 enable flag를 additive migration으로 추가하고 모든 기존 행/default를 `kitchen_tray_floor`로 둔다. 기존 주문은 재분류하지 않는다. _Modifies: menu/order schema; reuses `fulfillment_mode_snapshot` pattern._
- [ ] **메뉴 경로 관리 RPC 추가**: 기존 create/update RPC signature는 유지하고 route-aware v2 또는 전용 setter를 추가해 권한·매장·콤보 제약·감사 로그를 원자적으로 처리한다. _Creates: additive admin RPC; reuses `require_admin_actor_for_restaurant` and `audit_logs`._
- [ ] **주문 시점 경로 스냅샷 고정**: 새 주문 품목만 enable flag와 메뉴 route를 읽고 snapshot하며, 이후 메뉴 이동/이름 변경/route 변경이 주문에 영향을 주지 않게 한다. _Modifies: order-item BEFORE INSERT capture; reuses advisory-lock mode snapshot pattern._
- [ ] **콤보 component snapshot 확장**: 기존 `combo_components` JSON에 다국어 이름과 component route를 추가하되 기존 필드는 그대로 유지한다. 선택 음료 총수량과 고정 component 배수 규칙을 보존한다. _Modifies: `snapshot_order_item_combo_components`; reuses current QR combo payload._
- [ ] **KDS 작업 단위 일반화**: `emergency_fulfillment_items`에 line identity, source kind, component menu ID, route와 이름 snapshot을 추가하고 기존 행을 `base` 음식 행으로 유지한다. 고유성을 `(session_id, order_item_id, line_key)`로 확장한다. _Modifies: existing ledger additively; no table rename._
- [ ] **route-aware 수량 제약 적용**: 음식은 기존 연쇄 제약을 그대로 유지하고 직접 제공은 upstream 수량 0과 `floor_served <= ordered`만 허용한다. 잘못된 route/stage 조합은 서버에서 거절한다. _Modifies: existing quantity constraint and progress RPC._
- [ ] **동기화 trigger에서 논리 작업 생성**: 일반 메뉴는 base 한 행, 콤보는 기존 음식 base와 직접 제공 component 행을 생성/갱신하고 취소·수량 감소·needs_review를 모든 행에 동기화한다. _Modifies: `emergency_sync_order_item`; reuses existing queue/session creation._
- [ ] **호환 조회 RPC 제공**: 기존 station snapshot과 order summary signature를 유지하면서 route/line 정보를 추가하고, 캐셔가 다중 line을 안전하게 읽는 상세 RPC를 새로 제공한다. _Modifies: `get_emergency_station_snapshot`, `get_emergency_order_summaries`; creates detailed progress RPC._
- [ ] **직접 제공 event와 push 추가**: direct line 생성 시 해당 층에만 즉시 알림을 보내고 event에 route를 기록한다. 기존 kitchen→tray→floor push와 event ID 중복 제거는 유지한다. _Modifies: event stage constraint/sync trigger; reuses push dispatcher._
- [ ] **세션 마감 계산 확장**: 직접 제공 component까지 모두 `floor_served=ordered`여야 draining session이 닫히게 하고, 음식 전용 기존 결과가 동일한지 검증한다. _Modifies: close/drain and unresolved summary functions._
- [ ] **Release A 호환 검증**: feature flag false에서 기존 앱과 새 DB 조합으로 전체 paperless/print/payment 테스트를 통과시키고 운영에는 동작 변화가 없음을 확인한다. _Reuses: production gate and existing binaries/clients._

## Flutter 모델과 상호작용 — Release B

- [ ] **route-aware 도메인 모델 추가**: `EmergencyFulfillmentItem`에 route/source/line/name snapshot을 파싱하고 필드 누락 시 음식 경로로 fallback한다. station별 progress target과 actionability를 단일 helper로 정의한다. _Modifies: `emergency_fulfillment_provider.dart`; reuses current JSON model._
- [ ] **주문 가시성과 완료 판정 분리**: `hasActionableQuantity`와 `shouldRemainVisible`을 분리해 음료 전용·층 처리 중 주문도 주방/트레이 활성 보드에 표시하되 최근 완료 판정은 기존 action 원장을 유지한다. _Modifies: order model and board filters._
- [ ] **낙관적 품목 처리 경로 보호**: 주방/트레이 direct item은 `_applyOptimistic`, RPC, outbox에 절대 들어가지 않고 층 direct item만 `floor_served`를 ordered limit까지 반영한다. _Modifies: notifier progress helpers; reuses idempotent outbox._
- [ ] **낙관적 주문 전체 완료 경로 보호**: 주방/트레이는 음식 line만, 층은 도착 음식과 direct line을 완료하도록 서버 결과와 동일하게 계산한다. _Modifies: `_applyOptimisticOrderCompletion`; reuses current action IDs._
- [ ] **비활성 음료 카드 UI**: 주방/트레이에서 음료 아이콘, `층에서 직접 제공`, 조회용 제공 수량을 표시하고 onTap·button semantics를 비활성화한다. 음식 카드 스타일과 5열 레이아웃은 유지한다. _Modifies: `_EmergencyMenuRow`; reuses current responsive grid and tokens._
- [ ] **층 직접 제공 UI**: 층 화면에서 direct 음료를 주문 즉시 활성화하고 음식은 기존 tray-dispatched limit를 유지한다. 개별 클릭과 하단 전체 완료를 둘 다 검증한다. _Modifies: existing detail interaction; creates no new screen._
- [ ] **읽기 전용 주문 카드 상태**: 음료 전용 주문과 음식 완료 후 층 처리 중 주문에 중립 상태 문구를 추가해 `완료`로 오인하지 않게 한다. _Modifies: `_EmergencyOrderCard` and localized copy._
- [ ] **알람 판정 분리**: kitchen/tray local actionable set과 floor direct ready set을 구분해 음료 때문에 잘못된 스테이션 알람이 울리지 않게 한다. _Modifies: screen alarm detection; reuses Web Audio/FCM services._

## 고객·캐셔 상태

- [ ] **고객 active-order payload 확장**: 기존 top-level 필드를 유지하면서 선택적 `fulfillment_parts`를 반환하고, 일반 메뉴는 기존 수량 결과가 동일하게 한다. _Modifies: `qr_get_active_order`; reuses token-scoped security._
- [ ] **고객 주문 화면 component 진행 표시**: 일반 메뉴는 현재 badge를 유지하고 콤보는 음식/선택 음료의 최종 제공 수량만 하위 행으로 보여준다. 내부 주방·트레이 단계는 노출하지 않는다. _Modifies: QR active-order models and screen._
- [ ] **캐셔 상세 progress 모델 도입**: raw table Map 덮어쓰기를 상세 RPC로 교체하고 주문 품목별 logical line 상태를 저장한다. RPC 실패 시 결제를 유지하는 현재 fail-open 표시 정책을 보존한다. _Modifies: `CashierOrder`, `PaymentNotifier`; reuses payment readiness flow._
- [ ] **캐셔 품목별 상태 표시**: 콤보 음료를 포함해 무엇이 제공/미제공인지 표시하고 direct line에 `층 직접 제공` badge를 붙인다. 결제 버튼은 차단하지 않는다. _Modifies: `_CashierOrderItemsPanel`; reuses warning panel and status badge._

## 관리자·Excel

- [ ] **메뉴 처리 경로 편집 UI**: 메뉴 추가/수정창에 두 경로 selector를 추가하고 음료 카테고리 기본값, 콤보 validation, 저장 오류를 KO/VI/EN으로 제공한다. _Modifies: menu dialog/provider/service; reuses existing Toast fields and RPC permission flow._
- [ ] **메뉴 목록 route 가시화**: 운영자가 잘못 분류한 메뉴를 찾도록 메뉴 카드에 작고 명확한 route badge를 표시한다. _Modifies: existing menu item list; reuses status badge/tokens._
- [ ] **Excel import/export route round-trip**: 선택적 마지막 열로 stable route code를 추가하고 구형 workbook을 계속 허용한다. 잘못된 값은 행 단위 오류로 전체 transaction을 거절한다. _Modifies: existing menu Excel parser/export/RPC; reuses current round-trip contracts._

## DB 및 보안 검증

- [ ] **음식 경로 불변 SQL 테스트**: 기존 수량 체인, 단계 권한, order action, downstream revert 거절이 동일함을 검증한다. _Modifies: emergency SQL/contract fixtures._
- [ ] **direct 경로 SQL 테스트**: kitchen/tray stage 거절, assigned floor 성공, wrong floor/store 거절, duplicate event/action dedupe, 음수/초과 방지를 검증한다. _New test cases in existing contract suite._
- [ ] **혼합 주문 전체 완료 테스트**: 주방/트레이 action이 direct line을 변경하지 않고 floor action이 두 경로를 정확히 완료/원복하는지 검증한다. _New DB integration fixture._
- [ ] **콤보 line 테스트**: 선택 음료 종류별 aggregation, fixed quantity multiplier, cancellation, quantity decrease, name/route snapshot 불변성을 검증한다. _New DB and Dart contract cases; reuses combo fixtures._
- [ ] **RLS와 조회 격리 테스트**: cashier/station/customer RPC에서 다른 매장·다른 층·취소 품목이 노출되지 않는지 검증한다. _Modifies: security contract tests._
- [ ] **프린트·결제 회귀 테스트**: pos_print ticket payload/claim, paperless hold, payment atomicity, warning non-blocking, digital receipt가 route 필드 때문에 바뀌지 않는지 검증한다. _Reuses: print/payment/receipt contract suites._

## 반응형·시각 회귀

- [ ] **음식 전용 golden 불변**: route 누락/default 음식 fixture의 기존 paperless golden이 변경되지 않게 한다. _Reuses: `test/pos_paperless_visual_test.dart`._
- [ ] **음료·혼합 주문 widget matrix**: food-only, drink-only, mixed, combo drink, quantity 2+, individual action, whole action, revert를 kitchen/tray/floor에서 검증한다. _Modifies: `test/emergency_fulfillment_responsive_test.dart`._
- [ ] **5열 그리드 회귀**: 10개 혼합 메뉴가 1024×768에서 5×2로 유지되고 direct 카드가 비활성화돼도 음식 카드 클릭 좌표·key가 유지되는지 검증한다. _Reuses: current 5-column test._
- [ ] **접근성·다국어·확대 검증**: KO/VI/EN, 390×844, 1024×768, 1440×900, 100%/200% 글자에서 overflow와 잘린 상태 문구가 없고 disabled semantics가 정확한지 확인한다. _Modifies: responsive operational tests._
- [ ] **실제 브라우저 다중 계정 E2E**: kitchen, tray, 1F/2F, cashier, customer route를 동시에 열고 mixed/drink-only/combo 주문의 Realtime/폴링 일치를 확인한다. _Reuses: Flutter Web deployment and fixed station accounts._

## 점진 배포

- [ ] **Release A 배포**: clean exact-main, required GitHub check, production migration preflight/rollback readiness를 통과한 DB expand를 기능 OFF로 배포한다. _Reuses: `scripts/deploy_pos_production.sh`; no feature enable._
- [ ] **Release B 배포**: 새 Flutter 클라이언트와 Edge compatibility를 배포하고 모든 스테이션이 새 SHA를 로드했는지 확인한다. 플래그는 OFF로 유지한다. _Modifies: production web client; reuses exact-SHA release gate._
- [ ] **매장 메뉴 분류 검수**: drink 후보와 콤보 component를 운영자에게 보여주고 실제 층 직접 제공 메뉴만 승인해 설정한다. _Uses: new admin route UI/report._
- [ ] **Binh Thanh 파일럿 활성화**: 미완료 paperless 주문 0, 1F/2F 계정 정상, 알람 테스트 성공 후 한 매장만 flag를 켠다. _Depends on: Release A/B and classification review._
- [ ] **파일럿 관측과 롤백 훈련**: direct 미완료 수량, forbidden-stage 오류, outbox 적체, station snapshot 오류, cashier/customer 불일치를 감시하고 flag-off 복구를 검증한다. _Creates: operational checklist/queries; no destructive rollback._
- [ ] **순차 확대**: 파일럿의 실제 mixed/drink/combo 주문이 정상 마감되고 요구 지표가 안정된 뒤 매장별로 활성화한다. _Depends on: pilot acceptance._

## 분석 대시보드 — Release C

- [ ] **Release C 분석 기준선 고정**: 파일럿 event에서 음식·direct 음료·혼합·콤보·원복 표본을 선정하고 수작업 타임라인과 기대 P50/P90/병목 결과를 fixture로 고정한다. _Depends on: stable Release B event collection; creates analytics golden fixtures._
- [ ] **route-aware 논리 line 시간 view**: event delta를 누적해 최종 유효 단계 도달 시각을 계산하고, 음식은 주방/트레이/층, direct 음료는 생성→층 제공만 반환한다. N/A 단계를 0으로 기록하지 않는다. _Creates: `v_fulfillment_line_cycle_times`; reuses append-only fulfillment events and logical line snapshots._
- [ ] **시간·일 집계 테이블과 refresh 함수**: 매장·영업일·시간·route·stage·층·메뉴별 P50/P90, 표본 수, SLA 초과, 원복을 idempotent upsert한다. 최근 영업일 재계산으로 늦은 event를 반영한다. _Creates: `fulfillment_metrics_hourly`, `fulfillment_metrics_daily`, refresh RPC/cron; reuses existing pg_cron pattern and 00:00 cutoff._
- [ ] **집계 대조와 stale 상태**: raw event, normalized line, rollup 수량을 대조하고 불일치·job 실패·갱신 지연을 `partial/stale`로 반환한다. 마지막 정상 결과는 유지한다. _Creates: read-only analytics health contract._
- [ ] **매장 전용 dashboard RPC**: 날짜·층·route·메뉴·시간대 filter를 받되 로그인 사용자의 accessible store 범위를 강제하고 제한된 집계·지연 주문만 반환한다. _Creates: `get_store_fulfillment_dashboard`; no raw event download to Flutter._
- [ ] **POS 페이퍼리스 운영 대시보드**: `관리자 > 보고서`에 별도 하위 화면을 만들고 P50/P90, SLA, 현재 미완료, 병목, 시간대 추이, 메뉴/층 순위와 read-only 주문 타임라인을 표시한다. 기존 매출 provider와 실시간 station 화면은 분리한다. _Modifies: reports navigation/UI; creates dedicated provider; reuses current date range and responsive report shell._
- [ ] **POS 대시보드 반응형·접근성 검증**: 필수 값은 hover 없이 표시하고 KO/VI/EN, 모바일 portrait, 태블릿, desktop, 200% 확대, partial/stale/offline 상태와 CSV export를 검증한다. _Creates: provider/widget/visual/E2E analytics tests._
- [ ] **Office 집계 계약 추가**: PII와 actor를 제외한 versioned read-only store/day/hour 집계 view를 POS DB에 제공하고 Office 서버만 읽게 한다. 기존 `restaurants`/Office 매출 계약은 변경하지 않는다. _Creates: `v_office_pos_fulfillment_metrics_v1`; reuses established Office read-only view pattern._
- [ ] **Office 주문 처리 KPI 화면**: `office.globos.vn/kpi`에 매장 비교, 전주·전월 추세, 병목 비중, direct 음료 시간을 표시하고 표본 수·last updated·partial 상태를 함께 제공한다. POS 대시보드 수치와 fixture를 대조한 뒤 연결한다. _Modifies: Office app in a separately approved repository task; depends on stable POS aggregate contract._
- [ ] **Release C 점진 배포**: 집계 job과 RPC를 먼저 배포해 수치를 shadow 검증하고, POS 단일 매장 화면을 연 뒤 Office를 연결한다. 분석 장애가 주문·결제·paperless action에 영향을 주지 않는지 부하 및 fail-open 검증을 통과한다. _Separate release; reuses exact-main GitHub and production deployment gates._

## 최종 리뷰

- [ ] **설계 대조 리뷰**: 모든 완료 조건, 기존 기능 불변식, 콤보 예외, feature flag, rollback 조건을 구현 결과와 대조한다.
- [ ] **운영 승인**: required GitHub Actions가 exact main SHA에서 성공하고 파일럿 체크리스트가 완료된 경우에만 기능을 ON으로 판정한다.
