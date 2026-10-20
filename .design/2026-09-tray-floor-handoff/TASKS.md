# Build Tasks: 트레이 층별전환 및 층 고객전달

Generated from: 2026-09-18 사용자 요구 2건과 현재 KDS 구현
Date: 2026-09-18
Status: 로컬 구현·Flutter 전체 회귀·웹 릴리스 빌드 완료 — Docker 의존 SQL 전체 게이트, 운영 DB 적용, 앱 배포, 현장 smoke는 아직 수행하지 않음

## 확정 동작

- 트레이의 메인 주문 보드는 기존 4/8슬롯 구조를 유지한다. 가로 2분할 대상은 트레이 상단의 **`층별전환` 전용 화면**이며, 왼쪽은 `1F`, 오른쪽은 `2F`로 고정하고 세로 적층하지 않는다.
- 주방에서 메뉴 수량을 `조리 완료` 처리하면 서버가 발급한 기존 `oldest_tray_ready_sequence`를 기준으로 트레이 메인 보드의 맨 앞으로 이동한다.
- 주방 완료 후 아직 트레이가 층으로 보내지 않은 수량이 하나라도 있는 동안 주문 **카드 전체**와 해당 메뉴가 0.5초 간격으로 점멸한다.
- 트레이 상단에 최신 요청의 문구대로 `층별전환` 버튼을 추가한다. 전체 화면 목록은 1F/2F를 좌우 두 열로 표시하고, 각 열에는 주방 완료 후 아직 층으로 보내지 않은 메뉴명과 수량만 표시한다.
- 층별전환 목록은 선택용 `+/-` 없이 `메뉴명 × 대기 수량`, 총 메뉴 수량, 해당 층 확인 버튼만 제공한다. `1F 전달 확인`은 1F만, `2F 전달 확인`은 2F만 원자적으로 전송한다.
- 서버 ACK 후 해당 준비 수량의 점멸을 종료한다. 같은 주문에 아직 주방 미완료 음식이 남으면 접수 시각 FIFO 위치로 복귀하고, 트레이 단계가 전부 끝났으면 기존처럼 활성 보드에서 빠져 최근 완료로 이동한다.
- 버튼을 연 뒤 새로운 주방 완료분이 도착했거나 수량이 취소·원복되면 기존 화면에 없던 수량을 몰래 함께 보내지 않는다. 서버가 stale로 거절하고 최신 목록을 다시 연다.
- 각 층 화면 상단에는 `고객전달` 버튼을 추가한다. 버튼을 누르면 **현재 로그인 층에 트레이가 전달했지만 아직 고객에게 전달하지 않은 음식만** 8개 주문 박스로 표시한다.
- 고객전달 박스는 테이블 번호와 메뉴명, 메뉴별 전달 가능 수량, `- / 선택수량/가능수량 / +`만 표시한다. 선택 초기값은 0이며, 하단 `고객전달완료`는 현재 페이지에서 선택한 수량만 고객 전달 상태로 원자적으로 변경한다.
- 고객전달 성공 후 전량 전달된 메뉴는 박스에서 제거하고, 남은 메뉴가 없는 주문 박스는 사라진다. 일부만 전달했거나 트레이에서 새 음식이 도착하면 남은 수량으로 박스를 유지한다.

## 기존 구성요소 판정

- **그대로 재사용**: `emergency_tray_ready_lots`, `emergency_floor_ready_lots`, 매장별 ready sequence, `kds_record_station_progress_v3`, `kds_serve_ready_order_v3`의 층 권한/ready-lot 소비 의미, 수량 불변식, KDS Realtime ticket/change log, IndexedDB outbox, `_readyPulseTimer`, `_EmergencyOrderCard`, `_BoardPager`, KO/VI/EN copy 구조, 기존 floor 색상 토큰.
- **수정 필요**: `compareEmergencyOrdersForStation`을 사용하는 트레이 우선 정렬, `_buildActive`, `_EmergencyHeader`, 카드 점멸 범위, `EmergencyFulfillmentNotifier`의 tray/floor batch payload·outbox·ACK 처리.
- **새로 생성**: 트레이 층별전환 summary/allocation 모델, `TrayFloorTransitionSheet`, 층 고객전달 selection/allocation 모델, `CustomerDeliveryScreen`, 트레이·층 멱등 batch RPC와 감사 action table, SQL preflight/verify/rollback 및 runtime test.
- **변경 금지**: 결제/주문 완료 상태, MISA, 정상 프린터 모드, floor-direct 음료의 직접 제공 경로, 배달 기사 인계 의미, 기존 주방 checker batch와 개별 완료/원복 API.

## Foundation

- [ ] **실패 재현 테스트를 먼저 고정**: 트레이 층별전환 목록이 1F/2F로 나뉘지 않는 상태, 주방 완료 후 카드 전체가 아닌 메뉴만 점멸하는 상태, 층 화면에 8박스 고객전달 선택 UI와 다중 주문 batch API가 없는 상태를 각각 실패 테스트로 만든다. _Modifies: `test/emergency_fulfillment_responsive_test.dart`, `test/kds_start_ready_workflow_test.dart`; reuses existing fixture notifier and v2 order builders._

- [ ] **트레이 전달 가능 수량 helper 추가**: 음식 처리 line별 `kitchen_done_quantity - tray_dispatched_quantity`를 authoritative 대기 수량으로 계산하고, `workflow_version >= 2`, 비배달, 비취소, `needs_review == false`, `floor_direct == false`만 층별 전달 후보로 반환한다. 콤보 부모와 component를 중복 집계하지 않는다. _Modifies: `EmergencyFulfillmentItem`/`EmergencyFulfillmentOrder`; reuses `_operationalItems`, `sourceKind`, route snapshot and existing quantity clamps._

- [ ] **층별 summary와 실제 allocation을 분리**: 화면에는 같은 메뉴를 이름별로 합쳐 `김밥 × 10`처럼 보여주되, 전송 payload는 FIFO로 정렬된 실제 `queue_id + item_id + source_kind + quantity` 목록을 유지한다. 총 수량은 display group 합계와 allocation 합계가 항상 같아야 한다. _Creates: `TrayFloorHandoffMenuGroup`, `TrayFloorHandoffAllocation`, `buildTrayFloorHandoffSummary`; modifies provider only._

- [ ] **고객전달 가능 수량과 8박스 모델 추가**: 현재 floor assignment와 같은 `floor_label`의 홀 주문에서 `tray_dispatched_quantity - floor_served_quantity > 0`인 음식 line만 `CustomerDeliveryBox`로 만든다. 같은 주문의 메뉴를 한 박스에 묶고 테이블 번호, queue/order ID, 메뉴별 가능한 수량, `oldestReadySequence`를 보존한다. _Creates: customer delivery presentation/selection models; reuses `_operationalItems`, source kind, localized names and floor-ready lot semantics._

## Core UI — 트레이 층별전환

- [ ] **트레이 메인 보드와 ready 우선순위 보존**: 메인 보드는 기존 Phone 4슬롯/Tablet 8슬롯을 유지한다. 주방 완료 주문은 `oldestTrayReadySequence`로 전체 트레이 보드 맨앞에 오고, 전송 후 ready sequence가 없어지면 `createdAt → queueNo → queueId` FIFO로 복귀한다. _Modifies: comparator를 우회하는 갱신 경로가 있을 때만 provider reconciliation; reuses existing `_EmergencyOrderBoard`._

- [ ] **카드 전체 ready 점멸 적용**: 트레이 주문에 `oldestTrayReadySequence != null`이고 전달 가능 수량이 남아 있으면 `_EmergencyOrderCard`의 배경·테두리·Semantics 상태 전체를 `_readyPulseOn`에 연결한다. 기존 메뉴 단위 파란색/점멸은 유지해 색상 외에도 `주방 완료·층 전달 대기` 문구와 아이콘을 제공한다. _Modifies: `_EmergencyOrderCard`; reuses the single screen-level timer, so no per-card Timer is created._

- [ ] **트레이 헤더에 `층별전환` 진입점 추가**: 주방 `checker 전달`과 동일한 배치·터치 크기의 버튼을 tray assignment에서만 노출하고, 대기 수량 0이면 disabled 또는 `0` badge로 표시한다. 주문 상세, 최근 완료, station mismatch, printer mode에서는 잘못 실행되지 않게 한다. _Modifies: `_EmergencyHeader` and `_EmergencyCopy`; reuses current header responsive layout and Material icons._

- [ ] **층별전환 전체 화면을 가로 2분할**: 새 `TrayFloorTransitionSheet`를 `Row` 안의 동일 폭 1F/2F 두 열로 고정하고 세로 적층 fallback을 만들지 않는다. 각 열에는 `대기 총 N개`, 메뉴명, 수량만 표시하며 주문 금액·결제·고객 정보·미완료 메뉴·floor-direct 음료는 표시하지 않는다. 목록이 길면 각 열이 독립 스크롤하며, 하단에는 층별 확인 버튼과 취소만 둔다. _Creates: `lib/features/emergency_fulfillment/tray_floor_transition_sheet.dart`; reuses `PosColors`, surface/border tokens and fullscreen dialog pattern._

- [ ] **배달·포장과 예외 floor를 층별전환에서 제외하되 숨기지 않기**: `sales_channel == delivery` 주문은 기존 트레이 메인 보드와 기사 인계 동작을 그대로 유지하지만 1F/2F 전환 목록에는 넣지 않는다. 예상하지 못한 floor label은 자동 전송하지 않고 화면 상단에 `층 확인 필요` 경고와 수량을 표시한다. _Modifies transition filtering only; reuses current delivery action and review state._

## Core UI — 층 고객전달

- [ ] **층 헤더에 `고객전달` 버튼 추가**: 활성 floor assignment에서만 버튼을 표시하고 현재 층의 tray-delivered 미전달 음식 수량 badge를 붙인다. printer mode, assignment mismatch, 최근 완료, 주문 상세 처리 중에는 실행을 막는다. _Modifies: `_EmergencyHeader`, `_EmergencyCopy`, floor screen entry path; reuses header responsive layout._

- [ ] **고객전달 화면에 고정 8박스 보드 구현**: 페이지마다 정확히 8개의 주문 박스를 유지하고, 가로 화면은 4열×2행, 세로 화면은 2열×4행으로 배치한다. 빈 자리는 빈 슬롯으로 유지하고 9번째 주문부터 다음 페이지에 배치한다. 각 박스에는 큰 테이블 번호와 트레이 전달 음식의 메뉴명만 표시한다. _Creates: `lib/features/emergency_fulfillment/customer_delivery_screen.dart`, private `_CustomerDeliveryBoard`/`_CustomerDeliveryBox`; reuses `_BoardPager`, fixed-slot sizing and POS tokens._

- [ ] **메뉴별 `-/+` 선택 조작 추가**: 각 메뉴 행은 기본 `0/전달가능수량`에서 시작하고 `+`는 최대 가능 수량까지, `-`는 0까지 조정한다. 버튼은 48dp 이상이며 선택값은 `itemId + sourceKind`로 보존한다. 이미 고객 전달된 수량, 트레이 미전달 수량, 다른 층 수량은 선택 상한에 포함하지 않는다. _Modifies only new customer screen; reuses localized menu names and tabular number styling._

- [ ] **하단 고정 `고객전달완료` 바 구성**: 현재 페이지에서 선택한 총 수량을 표시하고 0개일 때 비활성화한다. 확인 중에는 모든 `-/+`, 페이지 이동, 닫기를 잠그며, 숨은 다른 페이지 선택은 허용하지 않는다. 성공 후 selection을 지우고 최신 8박스 페이지를 다시 계산한다. _Creates bottom action bar; reuses current busy/progress/error presentation._

- [ ] **고객전달 성공 후 박스 전이 구현**: 선택 수량만 `floor_served`로 반영하고 전량 전달된 메뉴 행은 제거한다. 박스에 남은 음식이 없으면 박스를 제거하고, 일부 수량 또는 이후 트레이 도착분이 있으면 남은 수량으로 유지한다. 준비 순번이 남은 박스는 `oldestReadySequence` 우선, 그 외 tie-break는 접수 FIFO를 사용한다. _Modifies provider-to-screen reconciliation; reuses current floor completion/recent logic._

## Server Transaction & Integrity

- [ ] **층 단위 멱등 batch RPC 추가**: 새 additive migration에 `emergency_tray_floor_batch_actions`와 `kds_dispatch_tray_floor_batch_v1(request_id, floor_label, allocations)`를 추가한다. 활성 tray assignment, 같은 restaurant/session, 정확한 floor, 홀 workflow v2, positive quantities를 검증하고 모든 allocation을 한 트랜잭션으로 `tray_dispatched` 처리한다. _Creates: new timestamped migration; reuses `kds_record_station_progress_v3` and existing ready-lot consumption._

- [ ] **화면 snapshot과 서버 현재 목록의 완전 일치 검증**: 행 잠금 후 해당 층의 현재 tray-ready line 집합과 전달 수량이 payload와 정확히 같은지 확인한다. 누락·추가·수량 변경·중복 line·다른 층 line이 하나라도 있으면 전체를 `KDS_TRAY_FLOOR_BATCH_STALE`로 rollback한다. _Modifies only the new RPC; prevents newly completed food from being silently included._

- [ ] **동시성·멱등성·감사 보장**: `request_id + normalized allocation hash + floor`를 저장해 같은 요청 재전송은 같은 ACK를 반환하고 다른 payload 재사용은 거절한다. queue/item/ready lot을 고정 순서로 잠그고, constituent event IDs와 changed quantity를 batch action response에 남긴다. _Creates batch audit contract; preserves append-only fulfillment events and downstream-safe existing revert rules._

- [ ] **Realtime과 floor 알림 연결 유지**: 각 `tray_dispatched` event가 tray와 해당 floor ticket을 갱신하고 기존 `emergency_floor_ready_lots` 및 floor push를 생성하게 한다. batch 성공 때문에 결제 완료, order status 완료, 테이블 해제, MISA 호출은 절대 발생시키지 않는다. _Reuses existing trigger/target and push infrastructure; modifies only if runtime SQL proves a missing target._

- [ ] **고객전달 다중 주문 batch RPC 추가**: 같은 migration 또는 분리된 다음 additive migration에 `emergency_customer_delivery_batch_actions`와 `kds_complete_customer_delivery_batch_v1(request_id, allocations)`를 추가한다. 서버가 로그인 사용자의 활성 floor assignment를 권한 기준으로 사용하고, payload의 각 line이 같은 restaurant·session·floor에 속하며 `0 < quantity ≤ tray_dispatched - floor_served`인지 잠금 후 검증한다. _Creates a floor-scoped batch RPC; reuses `kds_record_station_progress_v3(..., 'floor_served', ...)` and floor-ready lot FIFO consumption._

- [ ] **선택분만 원자적으로 고객전달 처리**: 고객전달 batch는 현재 페이지에서 명시적으로 선택된 allocation만 한 트랜잭션으로 처리한다. 화면을 연 뒤 새 음식이 도착해도 자동 포함하지 않으며, 새 음식의 존재만으로 기존 선택을 거절하지 않는다. 다만 선택 수량이 취소·다른 단말 제공으로 줄었으면 전체 batch를 `KDS_CUSTOMER_DELIVERY_BATCH_STALE`로 rollback한다. _Modifies only the new RPC; keeps unselected and newly arrived quantities pending._

- [ ] **고객전달 멱등성·감사·원복 연결**: normalized allocation hash와 request ID를 저장하고 같은 요청은 같은 결과를 반환한다. constituent event/action ID를 주문별로 남겨 기존 downstream-safe floor 원복 규칙이 계속 작동하게 하며, 다른 payload로 같은 ID를 재사용하면 충돌 오류를 반환한다. _Creates batch audit response; preserves append-only events._

- [ ] **수량·결제 경계 고정**: batch 처리 후에도 모든 음식에 `0 ≤ floor_served ≤ tray_dispatched ≤ tray_received ≤ kitchen_done ≤ required`가 유지되어야 한다. 고객전달은 payments 생성, `orders.status='completed'` 강제 변경, 테이블 해제, MISA 호출을 하지 않고 기존 파생 상태와 캐셔 미제공 계산만 갱신한다. _Reuses existing constraints and reconciliation; no financial mutation._

## Provider, Offline & State Reconciliation

- [ ] **Provider batch command 추가**: `completeTrayFloorBatch(floorLabel, snapshot)`이 요청 UUID와 exact allocations를 전송하고 중복 탭을 잠근다. 성공 후 ticket/full snapshot을 갱신해 ready sequence, 수량, 정렬을 서버 ACK 기준으로 바꾼다. _Modifies: `EmergencyFulfillmentNotifier`; reuses `_sendOutboxPayload`, UUID and existing load path._

- [ ] **고객전달 selection batch command 추가**: `completeCustomerDeliveryBatch(allocations)`이 현재 floor의 선택분을 request UUID와 함께 전송하고, 성공한 queue ticket들을 갱신한다. client는 selection 합계와 server `changed_quantity`가 다르면 성공으로 닫지 않고 전체 snapshot을 재조회한다. _Modifies: `EmergencyFulfillmentNotifier`; reuses outbox dispatcher, ticket refresh and error mapping._

- [ ] **오프라인 outbox 안전성 유지**: 네트워크 오류면 `tray_floor_batch` 또는 `customer_delivery_batch` payload를 IndexedDB에 저장하되 카드 수량·점멸·정렬을 성공처럼 미리 바꾸지 않는다. 관련 주문 박스를 `동기화 대기`로 잠그고 재전송 ACK 뒤에만 제거·점멸 종료·FIFO 복귀를 적용한다. stale/권한 오류는 자동 성공 처리하지 않고 최신 목록을 다시 보여준다. _Modifies: outbox dispatcher and error copy; reuses pending queue IDs and reconnect flush._

- [ ] **모든 갱신 경로의 정렬 일치**: full snapshot, v2 ticket refresh, realtime row patch, batch ACK, outbox replay가 모두 같은 `compareEmergencyOrdersForStation`을 사용하게 확인한다. 각 floor list에서는 ready sequence 우선, ready가 사라지면 `createdAt → queueNo → queueId` FIFO로 복귀한다. _Modifies reconciliation only where a path bypasses the comparator._

## Regression Tests

- [ ] **순수 모델 테스트**: 1F/2F 전환 필터, partial kitchen completion, same-name aggregation, FIFO allocation, combo component 중복 제거, direct drink·delivery·needs-review 제외, tray ready 우선 및 전송 후 FIFO 복귀를 검증한다. 고객전달 모델은 현재 floor만 포함하고 `tray_dispatched - floor_served` 수량과 8박스 정렬이 정확한지 별도로 검증한다. _Modifies: `test/kds_start_ready_workflow_test.dart`; reuses current order/item fixture helpers._

- [ ] **층별전환 가로 2분할 Widget 테스트**: 1F/2F 열의 y 좌표가 같고 x 좌표가 순서대로이며 어떤 viewport에서도 세로로 쌓이지 않는지 확인한다. 각 열의 수량·독립 스크롤·층별 확인 버튼, 긴 KO/VI/EN 문구, 100%/130%/200% text scale에서 overflow가 없는지 검증한다. _Modifies: `test/emergency_fulfillment_responsive_test.dart`; creates golden updates only if existing visual suite requires them._

- [ ] **우선 이동·카드 점멸·복귀 행동 테스트**: 오래된 A/B 주문 뒤에 있던 C가 주방 완료되면 해당 floor 첫 카드로 이동하고 카드 전체 색이 500ms마다 변하는지 검증한다. 확인 ACK 후 준비분 0이면 점멸이 멈추며, 미완료 메뉴가 남은 C는 A/B/C의 원 접수 FIFO 위치로 돌아가는지 고정한다. _Modifies focused widget/provider tests; tests state changes rather than source strings._

- [ ] **층별전환 화면/command 테스트**: sheet에는 kitchen-done 대기 메뉴의 이름·수량만 나오고 `+/-`가 없으며, 1F 확인이 2F allocation을 포함하지 않는지 검증한다. 처리 중 재탭, 성공 닫기/refresh, stale 유지/오류, offline queued 상태를 포함한다. _Creates focused sheet tests or extends responsive test depending file size._

- [ ] **고객전달 8박스 Widget 테스트**: 정확히 8개 슬롯, 테이블 번호, tray-delivered 메뉴명, 9번째 주문 페이지 이동, 메뉴별 `-/+`, `0/N` 상한·하한, 현재 페이지 selection 합계, 0개 버튼 비활성, 처리 중 전체 잠금을 검증한다. _Creates focused `test/customer_delivery_screen_test.dart` or extends the emergency responsive suite._

- [ ] **고객전달 상태 전이 테스트**: 3개 중 2개 선택 시 `floor_served +2`만 반영되고 박스에 1개가 남는지, 전량 선택 시 메뉴/박스가 제거되는지, 새 tray 전달분은 자동 선택되지 않는지, 다른 층·floor-direct·미도착 음식이 표시되지 않는지 검증한다. _Modifies provider/widget tests; tests actual selection allocations instead of source strings._

- [ ] **실제 Postgres SQL 테스트**: 정상 1F/2F tray batch와 floor 고객전달 selection batch, 다른 층·매장·station 접근 거절, exact-set/selected-quantity stale, 같은 request 재전송, request hash conflict, 두 tray 또는 두 floor 단말 동시 확인, 취소/원복 경쟁, tray/floor ready lot 소비, 수량 불변식을 실행 SQL로 검증한다. _Creates: `supabase/tests/kds_tray_floor_batch_test.sql`, `supabase/tests/kds_customer_delivery_batch_test.sql` plus preflight/verify/rollback scripts._

- [ ] **기존 기능 회귀 매트릭스 실행**: 주방 checker 3열, 개별 tray 전달/원복, floor 개별·전체 제공, 배달 기사 인계, floor-direct 음료, 추가 주문, 캐셔 미전달 취소, 최근 완료, realtime fallback, outbox replay, 정상 프린터 모드를 모두 유지한다. _Reuses existing Flutter and SQL suites; no feature deletion._

## Release Gates & Operational Verification

- [ ] **정적·로컬 검증**: 변경 Dart format, focused tests, `flutter analyze`, 전체 `flutter test`, SQL preflight/runtime/verify, Web build, `bash scripts/check_repo.sh`, `git diff --check`를 통과한다. 독립 검토는 `CRITICAL / HIGH / MEDIUM / LOW / CONFIRMED`와 Priority Fix List를 남기고 CRITICAL/HIGH 0건이어야 한다. _Reuses project verification scripts._

- [ ] **안전한 migration/배포 순서**: 새 migration은 transaction 안에서 self-verify하고 기존 적용 migration을 수정하지 않는다. exact pushed HEAD의 필수 GitHub Actions가 모두 성공한 뒤에만 `scripts/deploy_pos_production.sh`로 DB와 앱을 배포한다. 소스 구현, migration 적용, 앱 배포, 운영 검증 상태를 따로 보고한다. _Reuses production gates; no manual bypass._

- [ ] **현장 운영 smoke**: 실제 주방 1대, tray 1대, 1F/2F 단말에서 각각 주문을 넣고 `주방 완료 → 트레이 맨앞+카드 점멸 → 층별전환 1F/2F 분리 → 해당 층만 전송 → 점멸 종료/FIFO 복귀 → 해당 층 고객전달 8박스 수신 → -/+ 수량 선택 → 고객전달완료 → 잔량/박스 제거`를 확인한다. 동시에 들어온 주방 완료·트레이 전달, 부분 고객전달, 두 floor 단말 경쟁, 오프라인 복구, 배달 주문 비간섭도 확인한다. _Operational verification; test orders must follow the approved non-sales/test-order procedure._

## 권장 구현 순서

1. 실패 테스트와 tray-ready summary/allocation helper
2. 트레이 카드 전체 점멸과 `층별전환` 1F/2F 가로 split 화면
3. tray 층별전환 provider command와 atomic batch RPC
4. 층 고객전달 8박스·수량 선택 UI와 selection 모델
5. 고객전달 atomic batch RPC, Realtime/outbox 및 SQL 동시성 테스트
6. responsive·기존 배달/floor-direct/원복 전체 회귀
7. exact SHA CI, migration, 공식 production deployment, 실기기 smoke

## 완료 판정

- 트레이 `층별전환` 화면에서 1F와 2F 목록이 좌우로 명확히 분리되고 어떤 화면 크기에서도 세로로 쌓이지 않는다.
- 주방 완료 ACK 후 주문이 tray ready sequence 순으로 메인 보드 맨앞에 오며 카드 전체가 지속 점멸한다.
- 층별전환 목록은 주방에서 넘어온 미전달 음식의 이름과 수량만 정확히 보여준다.
- 한 층 확인은 그 층의 화면 snapshot만 원자적으로 전송하고, 다른 층·신규 완료분·음료·배달을 포함하지 않는다.
- 서버 ACK 후 점멸이 끝나고 남은 활성 주문은 원 접수 FIFO로 복귀하며, 모든 갱신 경로와 재접속 후에도 같은 순서를 유지한다.
- 각 floor의 `고객전달` 화면은 현재 층에 tray-dispatched된 미전달 음식만 테이블별 8박스로 보여주고, 메뉴별 `-/+` 선택 범위를 초과하지 않는다.
- `고객전달완료`는 현재 페이지에서 선택한 수량만 한 트랜잭션으로 `floor_served` 처리하며 부분 잔량은 남기고 전량 완료 박스는 제거한다.
- 새 tray 도착분은 자동 선택·완료되지 않고, 동시 단말·취소로 선택 가능 수량이 달라지면 잘못된 초과 제공 없이 stale 처리된다.
- 기존 주방 checker, 개별 동작/원복, floor 제공, 배달, floor-direct, 결제·프린트·감사 계약이 모두 유지된다.
