# KDS 실시간 개선 계획 기능 보존 재검증

- 검증일: 2026-08-31
- 대상: `DESIGN_BRIEF.md`, `TASKS.md`, 현재 KDS 구현과 관련 회귀 테스트
- 상태: 소스 구현 및 로컬 검증 완료, 운영 migration·배포·canary 전

## 결론

구현된 변경 대상은 KDS의 동기화 transport와 읽기 증폭뿐이다. 기존 업무 기능 또는 화면 동작은 변경하지 않았고, 모든 매장의 기본 rollout mode는 `legacy`다. 따라서 migration과 앱을 배포하더라도 운영자가 매장별로 `shadow` 검증을 통과시켜 `active`로 전환하기 전에는 기존 Postgres Changes 구독과 1초 폴링이 그대로 권위 경로다.

현재 코드를 다시 대조한 결과 초기 초안에는 다음 두 가지 모호성이 있었다.

1. 완료 내역과 타이밍을 단순히 지연 로딩하면 최근 완료 selector count, 오늘 완료 목록, station/batch timer 표시 시점이 바뀔 수 있었다.
2. 새 event stream을 KDS 버튼 명령 중심으로만 해석하면 신규·추가 주문, 운영 모드, leftover 요청처럼 KDS 외부에서 발생하는 변경을 놓칠 수 있었다.

다음과 같이 수정했다.

- 타이머 경계, 완료 count, fulfillment mode는 기존 표시 시점을 유지한다.
- 목록 크기만 제한하며 완료 탭을 열었을 때 기존과 동일하게 즉시 사용할 수 있어야 한다.
- 기존 8개 Postgres Changes 구독이 감지하던 모든 source mutation을 전수 매핑하기 전에는 구독을 제거하지 않는다.
- legacy/v2의 DB 결과, 오류, side effect, 화면 입력 상태, 알림 입력 상태가 허용 오차 0일 때만 전환한다.
- 기존 업무 RPC는 유지하고 additive v2 wrapper를 우선 사용한다.
- 새 user-visible UI, 문구 또는 작업 흐름은 이번 범위에서 추가하지 않는다.

## 현재 기능 대조 결과

### 명령 경로

현재 provider의 다음 진입점을 보존 대상으로 확인했다.

- `recordProgress`
  - `emergency_record_progress`
  - `emergency_record_combo_component_progress`
  - `emergency_record_floor_direct_progress`
- `completeOrder`
  - `emergency_complete_route_order_stage`
- `revertOrder`
  - `emergency_revert_route_order_action`
- `advanceLeftoverPackaging`
  - `emergency_advance_leftover_packaging`
- `_flushOutbox`
  - FIFO 처리
  - 영구적인 서버 거절은 제거
  - 일시 장애는 첫 실패 지점부터 재시도

새 계획은 위 RPC의 validation, 수량 계산, 권한, 오류 코드, event ledger, idempotency, downstream trigger side effect를 변경하지 않는다. v2는 이 기존 동작을 호출하고 같은 트랜잭션에서 revision/change log와 ACK를 추가하는 방식이 우선이다.

### 상태 갱신 원인

현재 다중 테이블 구독과 전체 snapshot이 포착하는 다음 원인을 모두 보존 대상으로 확인했다.

- 운영 세션 및 fulfillment mode 변경
- 신규 주문과 추가 주문
- 기본 fulfillment item 진행·취소
- 콤보 구성품 진행·취소
- floor-direct item 생성·진행·취소
- 주문 단위 완료와 되돌리기
- fulfillment event에 따른 handoff와 timing
- leftover packaging 요청 및 단계 진행
- direct delivery KDS 진행에 따른 고객 주문 상태 side effect

이 목록과 기존 8개 구독 테이블의 원인 매핑이 100%가 되기 전에는 1초 폴링이나 기존 구독을 제거할 수 없다.

### 화면과 알림

다음 동작은 변경 금지 대상으로 확인했다.

- phone 4개, tablet 8개 카드와 pagination
- 카드/상세 화면, 자동 상세 닫힘, 홈 이동
- 메뉴 상태 색상과 이전 단계 handoff 표시
- kitchen/tray/floor 액션 가능 조건
- 콤보 구성품 독립 표시·정렬·완료
- floor-direct 음료 노출/비노출과 floor 분리 표시
- delivery 라벨과 floor 제외
- initial/supplemental batch 및 station timer 경계
- 최근/오늘 완료 열람과 revert
- 한국어/베트남어/영어 선택
- 신규·추가·handoff·floor-direct·leftover 음성 및 flash
- foreground push fallback
- POS print/paperless와 기존 session draining
- cashier 미제공 경고와 결제 비차단 계약

## 실행한 구현 검증

관련 기능 회귀 명령:

```bash
flutter test \
  test/emergency_digital_fulfillment_contract_test.dart \
  test/kds_card_menu_sync_contract_test.dart \
  test/emergency_fulfillment_responsive_test.dart \
  test/floor_direct_beverage_contract_test.dart \
  test/direct_delivery_kds_routing_contract_test.dart \
  test/takeout_leftover_packaging_contract_test.dart \
  test/live_refresh_all_domains_contract_test.dart \
  test/live_sync_scope_contract_test.dart \
  test/provider_poll_guard_test.dart
```

결과:

- 관련 KDS/주문/알림 회귀 테스트: 116 passed, 실패 0
- 신규 realtime sync 및 SQL contract 테스트: 14 passed, 실패 0
- 전체 `flutter test`: 1,238 passed, 환경 의존 테스트 2 skipped, 실패 0
- `flutter analyze`: issue 0
- `bash scripts/check_repo.sh`: exit 0
  - Flutter/Deno/Node 테스트, security scan, production gate contract, web release build, whitespace contract 통과
- 신규 migration을 관련 선행 migration과 함께 disposable PostgreSQL DB에 적용: 성공
  - 비-legacy rollout 0건
  - private Broadcast authorization 함수와 deferred broadcast trigger 생성 확인
  - shadow 관측·health RPC 생성 확인
- production DB migration, 앱 배포, feature flag 변경: 수행하지 않음

## 구현 결과 대조

- `legacy`: 기존 8개 Postgres Changes 구독과 1초 snapshot 폴링을 그대로 사용한다.
- `shadow`: 기존 경로만 화면 상태를 결정하고, v2 ticket 결과는 legacy와 비교해 parity health만 기록한다.
- `active`: private Broadcast는 깨우기 신호로만 사용하고, 매장별 durable revision/change log를 따라잡은 뒤 변경된 ticket만 다시 읽는다.
- v2 명령 RPC는 기존 업무 RPC에 위임하므로 validation, 오류, 원장 기록, direct-delivery side effect의 권위 구현을 복제하지 않는다.
- config/bootstrap/realtime 오류, revision gap, retention 만료, session·station·floor identity 변경은 bootstrap 또는 legacy fallback으로 복구한다.
- `legacy -> active` 직접 전환은 DB에서 거부하며, station/floor별 현재 shadow cycle 10회 이상·mismatch 0건이어야 active 전환이 가능하다.
- active에서 legacy로 rollback하면 모든 단말에 bootstrap-required control event를 전송한다.

## 구현 시 강제 중단 조건

다음 중 하나라도 발생하면 v2 활성화 또는 기존 폴링/구독 제거를 중단한다.

- legacy와 v2의 수량, 상태, 정렬, 액션 가능 여부 차이 1건 이상
- RPC 오류 코드 또는 direct-delivery 등 side effect 차이 1건 이상
- 신규·추가·handoff·floor-direct·leftover 알림 누락/중복 1건 이상
- 최근/오늘 완료, timer, mode 표시 시점 회귀
- outbox 유실, 순서 변경 또는 중복 수량 반영 1건 이상
- 교차 매장·station·floor 정보 노출 1건 이상
- 기존 화면, 문구, 버튼, pagination의 승인되지 않은 변경
- 기존 관련 회귀 테스트 실패

## 운영 전 남은 검증

다음은 소스 구현 여부가 아니라 실제 운영 환경에서만 확정할 수 있는 release gate다.

- production Supabase의 Realtime/DB connection·message quota와 비용 여유
- 1,000 연결·100 command/s, 연결 끊김·재접속 폭주 부하 테스트
- 실제 운영 데이터로 station/floor별 shadow parity 10회 이상·mismatch 0건
- 1개 내부 매장 canary에서 지연, 오류율, DB CPU/IO, 알림 누락·중복 확인
- 단계적 5% → 25% → 100% rollout과 rollback drill
- exact pushed SHA를 사용하는 production deployment gate

따라서 현재 결론은 "기존 기능 보존을 전제로 한 소스 구현과 로컬 검증 완료"다. 100개 매장 운영 인증은 위 부하·quota·canary gate를 통과한 뒤에만 선언한다.
