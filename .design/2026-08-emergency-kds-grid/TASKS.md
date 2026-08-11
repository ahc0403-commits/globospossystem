# Build Tasks: 비상 대응 KDS 고정 분할 보드

Generated from: `.design/2026-08-emergency-kds-grid/DESIGN_BRIEF.md`
Date: 2026-08-11

## Foundation

- [ ] **현재 동작과 수량 체인 회귀 기준 고정**: 기존 키친·트레이·층별 Phone/Tablet 테스트와 `emergency_record_progress` SQL 계약을 먼저 실행해 기준선을 기록하고, 비상 모드 OFF의 프린트·결제 동작이 비교 가능한 상태로 만든다. _Reuses as-is: existing emergency widget/contract tests and `scripts/check_repo.sh`; no production mutation._
- [ ] **카드 보드 상태 모델 확장**: 주문을 현재 스테이션에서 작업 가능한 카드, 동기화 대기 카드, 최근 완료 카드로 계산하고 페이지·선택 주문 상태를 Snapshot 갱신 후에도 안정적으로 보존한다. _Modifies: `EmergencyFulfillmentOrder`, `EmergencyFulfillmentState`, `EmergencyFulfillmentNotifier`; reuses existing Snapshot and Realtime._

## Core UI

- [ ] **고정 4/8슬롯 주문 보드 구현**: 기존 `_EmergencyOrderQueue`를 페이지형 Grid로 교체해 Phone 4슬롯, Tablet 이상 8슬롯과 방향별 2×2/4×1/2×4/4×2 배치를 제공하고, 대기번호·경과시간·테이블·층·메뉴 수·상태 및 페이지 컨트롤을 한 카드 안에 완성한다. _Modifies: `EmergencyFulfillmentScreen`; creates reusable private board/card/pager widgets; reuses header, tokens, alarm and offline banner._
- [ ] **주문 전체 상세 화면 구현**: 주문 카드를 누르면 전체 메뉴와 수량/단계 상태를 보여주는 route-local 상세로 전환하고, 스크롤 가능한 메뉴 영역과 하단 고정 `취소(원복)`/`완료(다음 단계)` 버튼을 제공한다. _Modifies: current `_EmergencyOrderDetails` and `_EmergencyItemCard`; removes item-level controls from the operator flow; reuses localized item names._
- [ ] **스테이션별 카드 상태 표현 완성**: 키친·트레이·층별 화면이 같은 보드/상세 구조를 쓰되 작업 가능, 부분 도착, 동기화 대기, 정정 필요, 최근 완료, 원복 불가 상태를 색상과 문구로 구분한다. _Modifies shared emergency presentation; reuses `PosColors`, `OfflineBanner`, existing alert state._

## Interactions & Data Integrity

- [ ] **주문 단위 완료 RPC 추가**: 현재 스테이션의 처리 가능한 모든 품목 delta를 행 잠금 후 한 트랜잭션으로 반영하고, 공통 action ID와 품목별 append-only 이벤트를 기록한다. 트레이 기본안은 수령·발송을 같은 action에서 함께 처리한다. _Creates additive migration/RPC; reuses emergency tables, RLS checks, quantity-chain constraint and push enqueue._
- [ ] **안전한 취소(원복) RPC 추가**: 직전 완료 action만 보상 이벤트로 되돌리고, 트레이/층 등 다음 단계가 이미 소비한 수량은 DB에서 거절하며 사용자에게 구체적 사유를 반환한다. _Creates additive revert RPC and action grouping; preserves immutable audit history._
- [ ] **Provider와 outbox를 주문 action 단위로 전환**: 완료/원복의 중복 탭을 잠그고 UUID 멱등성 키, 낙관적 표시, IndexedDB 저장, 순서 재전송, 서버 거절 시 복구를 구현한다. 기존 품목 단위 API는 호환성을 위해 보존하되 새 화면에서는 호출하지 않는다. _Modifies: `EmergencyFulfillmentNotifier` and emergency web bridge payload handling; reuses polling/Realtime._
- [ ] **완료 후 다음 작업 이동과 원복 진입 제공**: 완료 성공 시 보드의 다음 오래된 카드로 이동하고 최근 완료 영역에서 방금 action을 원복할 수 있게 한다. 새 주문/추가 주문 도착 시 현재 페이지나 열려 있는 상세를 강제로 바꾸지 않는다. _Modifies screen navigation state; depends on order action RPCs._

## Responsive & Accessibility

- [ ] **방향 전환·긴 데이터 마감**: 390×844, 430×932, 844×390, 768×1024, 1024×768에서 슬롯 수와 배치를 검증하고 긴 KO/VI/EN 메뉴명, 8개 이상 품목, 100%/130%/200% 글자 크기에서도 상세 버튼과 메뉴가 잘리지 않게 한다. _Modifies board/detail sizing only as findings require; no information removal._
- [ ] **현장 조작 접근성 적용**: 모든 카드와 버튼을 최소 48dp 터치 영역으로 만들고, 선택/처리 중/완료/원복 불가 상태에 Semantics 레이블, 포커스 순서, 색상 외 상태 표현을 제공한다. _Modifies new board/detail components; reuses app theme._

## Verification & Release Safety

- [ ] **Widget 회귀 테스트 확장**: 4/8슬롯, 5번째/9번째 페이지 이동, 카드→상세→뒤로가기, 전체 메뉴 표시, 완료/원복 payload, 처리 중 중복 탭 방지, 신규 Snapshot 중 선택 보존을 테스트한다. _Modifies: `test/emergency_fulfillment_responsive_test.dart`; creates focused board interaction tests if the file becomes too large._
- [ ] **SQL 동시성·감사 테스트 추가**: 주문 전체 완료, 추가 주문 delta, 같은 action 재전송, 두 장치 동시 완료, 허용 원복, downstream 진행 후 원복 거절, 다른 매장/층 접근 거절, 이벤트 action grouping을 실제 Postgres에서 검증한다. _Creates preflight/verify/rollback SQL fixtures; no production apply._
- [ ] **다중 계정 E2E 갱신**: Super Admin 활성화 → 키친 주문 완료 → 트레이 주문 완료 → 배정 층 주문 완료 → 캐셔 미제공 해제와 역방향 원복 거절을 실제 역할 계정 흐름으로 검증한다. _Modifies multi-account emergency slice; preserves current role route isolation._
- [ ] **저장소 및 릴리스 게이트 실행**: 변경 Dart 포맷, `flutter analyze`, 관련 테스트, 전체 `flutter test`, SQL 검증, Flutter Web build, `bash scripts/check_repo.sh`, `git diff --check`를 통과한다. 운영 DB 적용과 배포는 별도 승인 후 `scripts/deploy_pos_production.sh`만 사용하고, exact pushed head SHA의 필수 GitHub Actions 성공을 확인한다. _Reuses project production gates; no direct deployment._

## Review

- [ ] **트레이 단일 완료 의미 승인**: 현장 담당자가 `완료` 한 번으로 `주방 수령 + 층 발송`을 함께 기록하는 기본안을 승인한다. 별도 시점 기록이 필수라면 UI는 유지하고 상세 내부 상태만 `수령 대기 → 발송 대기` 두 번의 완료로 조정한다.
- [ ] **실기기 운영 검토**: 키친 태블릿, 트레이 휴대폰, 각 층 휴대폰에서 카드 식별 속도, 페이지 이동, 메뉴 확인, 장갑/한 손 조작, 실수 원복 문구를 실제 주문 데이터로 승인한다.
- [ ] **독립 회귀 검토**: Critical/High/Medium/Low/Confirmed 분류로 DB 권한·수량 체인·오프라인 재전송·기존 프린트 흐름을 검토하고 Critical/High 0건일 때만 배포 승인을 요청한다.
