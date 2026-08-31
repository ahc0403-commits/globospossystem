# KDS 실시간 동기화 및 100개 매장 확장 작업 계획

기준 문서: `DESIGN_BRIEF.md`

각 작업은 독립적으로 검증 가능한 수직 단위다. 체크는 코드 작성이 아니라 명시된 완료 조건과 테스트를 모두 통과했을 때만 한다.

## 현재 구현 상태 — 2026-08-31

- 소스 구현 완료: additive DB schema/RPC, private Broadcast, 매장별 durable revision/delta, Dart sync engine, legacy/shadow/active provider 경로, 자동 legacy fallback, shadow parity activation gate
- 로컬 검증 완료: 전체 Flutter 테스트·analyze, Deno/Node/security/deploy contract, web release build, disposable PostgreSQL migration apply
- 운영 반영 안 함: production migration, 앱 배포, rollout mode 변경
- Release C blocker 유지: production quota 확인, 1,000 연결·100 command/s 부하, shadow parity, canary, 단계적 rollout
- 아래 체크리스트는 구현 코드 존재가 아니라 각 운영 수치와 승인까지 충족했을 때만 체크한다.

## 진행 원칙

- 기존 미추적 사용자 파일을 변경하거나 정리하지 않는다.
- DB migration은 additive 방식으로 작성하며 운영 원장 삭제/변경은 별도 승인 없이는 하지 않는다.
- production 배포는 `CLAUDE.md`의 production gate와 `scripts/deploy_pos_production.sh`만 사용한다.
- 새 동기화 경로는 매장별 feature flag로 켜고 끌 수 있어야 한다.
- 1초 폴링 제거는 Release C의 canary 승인 전에는 수행하지 않는다.
- 중복 projection은 v2 조회 쿼리가 성능 목표를 통과하지 못한 증거가 있을 때만 추가한다.
- 이 작업의 변경 허용 범위는 동기화 transport, additive v2 API, 새 revision/change log, provider 내부 sync engine, 관측·테스트뿐이다.
- 기존 업무 테이블·상태값·RPC 의미, 화면 기능·문구·레이아웃, 음성·push, printer/payment, routing, outbox 의미는 변경하지 않는다.
- 허용 범위 밖 변경이 필요하면 구현을 중단하고 별도 설계·승인을 받는다.

## Milestone 0 — 계약과 기준선 고정

### T01. 운영 병목 회귀 테스트와 기준선 기록

- [ ] `DESIGN_BRIEF.md`의 기능 보존 매트릭스 각 행을 현재 자동 테스트 또는 새 characterization test에 연결한다.
- [ ] base/combo/floor-direct progress, order complete/revert, leftover packaging의 현재 RPC 입력·출력·오류·side effect를 fixture로 고정한다.
- [ ] 신규/추가 주문, handoff, floor-direct, leftover 음성·flash의 before/after event sequence를 고정한다.
- [ ] 현재 provider에서 한 번의 progress 명령이 만드는 RPC, 전체 snapshot, auxiliary RPC 호출 수를 테스트로 고정한다.
- [ ] 활성 티켓 10/50/100건 기준 기존 snapshot의 p50/p95, payload 크기, DB 실행 계획을 기록한다.
- [ ] 명령 ACK, 버튼 busy 시간, 다른 단말 반영 시간의 현행 기준선을 기록한다.
- [ ] `test/emergency_digital_fulfillment_contract_test.dart`의 `<= 1초 폴링` 주장을 목표 상태 계약으로 교체할 위치를 표시한다.

재사용:

- `test/emergency_digital_fulfillment_contract_test.dart`
- `test/provider_poll_guard_test.dart`
- 기존 Supabase RPC와 pg_stat_statements 진단 절차

완료 조건:

- 동일 시드로 전환 전후를 비교할 수 있는 자동 테스트/SQL과 수치 보고서가 저장된다.
- 현행 정상 동작을 깨는 테스트와 현행 병목을 의도적으로 드러내는 테스트가 구분된다.
- 기능 보존 매트릭스에 미검증 행이 0개다.

### T02. Supabase 요금제·한도·클라이언트 호환성 승인

- [ ] 실제 production 프로젝트의 Realtime 동시 연결, 전달 메시지, channel, payload 한도를 확인한다.
- [ ] 1,000 연결과 200 delivered msg/s에 20% 이상 여유가 있는지 확인한다.
- [ ] 현재 lockfile의 `supabase_flutter`, `supabase`, `realtime_client` 버전에서 private Broadcast, auth 갱신, reconnect 동작을 작은 spike로 검증한다.
- [ ] 업그레이드가 필요하면 별도 dependency 변경과 회귀 테스트 범위를 확정한다.

재사용:

- `pubspec.yaml`
- `pubspec.lock`
- 현재 Supabase 초기화/auth 코드

완료 조건:

- 플랫폼 한도와 비용 책임자가 문서화되고, 불충분하면 요금제/계약 변경이 Release C의 명시적 blocker로 등록된다.
- 실제 클라이언트 버전으로 private 채널 연결/재연결 proof가 통과한다.

### T03. `KdsChangeEnvelope`와 상태 머신 계약 확정

- [ ] schema version, event type, entity ID, authoritative patch, revision, event ID 필드를 Dart/SQL 양쪽에서 정의한다.
- [ ] ACK와 Broadcast가 동일 envelope를 사용하도록 계약 테스트를 작성한다.
- [ ] 중복 revision, 같은 event 재수신, revision gap, 오래된 schema version 처리 규칙을 작성한다.
- [ ] `bootstrapping/subscribed/catchingUp/offlineQueued/degraded/rejected` 전이를 표와 테스트 케이스로 확정한다.

수정/생성 후보:

- `lib/features/emergency_fulfillment/` 아래 sync model 파일
- `test/` 아래 KDS sync contract test
- 신규 migration의 JSON 반환 계약

완료 조건:

- 모든 mutation 종류가 envelope 예시와 기대 patch를 가진다.
- 클라이언트와 SQL contract test가 동일 fixture를 검증한다.

## Milestone 1 — Release A: 체감 지연과 읽기 증폭 완화

### T04. progress RPC ACK를 이용한 즉시 확정 패치

- [ ] 기존 progress/action RPC를 수정하거나 대체하지 않고 호출하는 additive v2 command wrapper를 우선 사용한다.
- [ ] v2 wrapper가 legacy와 동일한 validation, 권한, 오류 코드, 수량, event ledger, direct-delivery side effect를 보존하는 parity test를 작성한다.
- [ ] `_sendProgress()`가 v2 wrapper의 RPC JSON 결과를 typed result로 반환한다.
- [ ] `recordProgress()`가 성공 후 전체 `load()`를 기다리지 않고 ACK의 확정 수량/상태를 적용한다.
- [ ] base item, 콤보 구성품, floor-direct, 주문 단위 완료/되돌리기, leftover packaging 진입점을 모두 같은 ACK 원칙으로 처리한다.
- [ ] optimistic 상태와 서버 ACK가 다를 때 서버 값을 우선하며, 거절 시 안전하게 롤백한다.
- [ ] idempotency key와 기존 outbox 포맷의 호환성을 보존한다.

수정 후보:

- `lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart`
- `lib/features/emergency_fulfillment/emergency_fulfillment_screen.dart`
- progress RPC migration

완료 조건:

- 성공한 명령 뒤 전체 `load()` 호출이 0회다.
- 버튼 busy 상태가 ACK 직후 해제된다.
- 모든 진행 경로의 수량 체인 및 중복 클릭 테스트가 통과한다.
- legacy와 v2의 DB 최종 상태, 반환 오류, side effect가 허용 오차 0으로 일치한다.

### T05. auxiliary RPC 지연 로딩과 refresh coalescing

- [ ] 오늘 완료 목록은 제한 조회하되 selector count가 항상 최신이고 탭 진입 시 기존과 동일하게 즉시 열리도록 한다.
- [ ] station/batch timing boundary는 bootstrap/ticket/delta에 포함하고 기존 카드·상세 clock 계산을 그대로 유지한다.
- [ ] 매장 fulfillment mode는 bootstrap과 control event로 즉시 관리하며 TTL 때문에 paperless/print 전환이나 draining 표시가 늦어지지 않게 한다.
- [ ] 짧은 시간에 여러 invalidation이 와도 동시 full `load()`가 하나를 넘지 않도록 coalesce한다.
- [ ] stale request가 최신 화면 상태를 덮지 못하도록 request generation/cancellation을 적용한다.

재사용:

- `lib/core/services/live_refresh_service.dart`의 debounce/연결 상태 개념
- 현재 Riverpod provider 구조

완료 조건:

- 메인 KDS 진입에서 기존에 보이던 selector count, 타이머, mode가 누락되거나 늦게 바뀌지 않는다.
- 동일 순간 20개 invalidation 테스트에서 동시 snapshot 호출이 1개 이하이고 최종 상태가 최신이다.
- recent/today completed와 timer 관련 기존 contract/widget test가 변경 없이 통과한다.

### T06. 내부 동기화 상태와 기존 오류 UX 보존

- [ ] `bootstrapping/subscribed/catchingUp/offlineQueued/degraded/rejected`는 우선 provider 내부 상태로 구현한다.
- [ ] 기존 화면의 로딩, 오류, outbox 적재 메시지와 버튼 노출 의미를 변경하지 않는다.
- [ ] 명령 ACK 지연이 화면 전체를 막지 않도록 명령 단위 진행 표시로 제한한다.
- [ ] outbox 적재 성공과 서버 거절을 사용자에게 다른 메시지로 보여준다.
- [ ] 기존 탭/선택/반응형/음성 동작을 보존한다.
- [ ] 새 user-visible UI가 필요하면 이 task에 넣지 않고 별도 승인 대상으로 분리한다.

재사용:

- 현재 KDS screen과 공통 UI token/primitive
- 기존 outbox 및 오류 메시지 처리

완료 조건:

- 느린 네트워크, 완전 오프라인, 서버 validation 실패 widget test가 서로 다른 기대 UI를 검증한다.
- 기존 screenshot/위젯 계약에서 의도하지 않은 화면 차이가 0이고 기존 기능 회귀 테스트가 통과한다.

## Milestone 2 — Release B: 내구성 있는 서버 변경 스트림

### T07. 매장 revision 및 change log additive migration

- [ ] `kds_store_revisions`와 `kds_change_log`를 추가한다.
- [ ] unique 제약, 대상별 cursor 인덱스, FK/시간 필드를 추가한다.
- [ ] revision 증가와 change log INSERT를 기존 업무 변경과 같은 트랜잭션에 묶는 helper를 만든다.
- [ ] 매장·스테이션·층 범위의 SELECT 권한과 service-side 쓰기 권한을 RLS로 제한한다.
- [ ] 7일 보존 후보의 용량 추정과 안전한 cleanup job을 작성하되 자동 활성화는 운영 승인 뒤 수행한다.

생성 후보:

- `supabase/migrations/*_kds_realtime_change_log.sql`
- SQL contract/security tests

완료 조건:

- 동시에 실행한 같은 매장 명령이 중복 없는 연속 revision을 가진다.
- 업무 mutation이 rollback되면 revision/change log도 함께 rollback된다.
- 다른 매장 및 권한 밖 층의 change log를 읽을 수 없다.

### T08. 모든 KDS mutation의 논리 이벤트 단일 발행

- [ ] base progress, 콤보, floor-direct, 주문 완료/되돌리기, leftover packaging 등 KDS 명령 entrypoint 목록을 만든다.
- [ ] 신규 주문, 추가 주문, 주문 취소/복구, session/mode 전환, leftover 요청, direct-delivery 상태 등 KDS 화면을 바꾸는 source mutation 목록을 만든다.
- [ ] 현재 8개 Postgres Changes 구독 테이블의 INSERT/UPDATE/DELETE 원인을 각각 새 logical event에 매핑한다.
- [ ] 각 entrypoint가 성공할 때 change log 1건과 동일 envelope ACK를 생성한다.
- [ ] 한 명령에서 여러 행이 바뀌어도 클라이언트 이벤트가 행 수만큼 늘어나지 않게 한다.
- [ ] 기존 UUID idempotency로 재호출하면 새 revision/event를 만들지 않고 최초 결과를 반환한다.

재사용:

- 기존 `emergency_record_progress` 계열 RPC
- 현재 emergency event ledger와 outbox idempotency

완료 조건:

- KDS 화면을 바꾸는 command/source mutation 감사표와 기존 8개 구독 원인에서 누락이 0개다.
- 각 명령의 최초 호출/동시 중복/재시도 SQL 테스트가 상태와 event 수를 검증한다.

### T09. private Broadcast 발행과 채널 권한

- [ ] change log의 논리 이벤트 1건을 대상 private topic에 전달한다.
- [ ] kitchen/tray/floor/control topic의 명명과 fan-out 규칙을 구현한다.
- [ ] 인증 토큰 갱신과 재구독 시 중복 적용을 방지한다.
- [ ] payload에 최소 patch만 포함하고 개인정보/전체 주문 payload를 금지하는 contract test를 둔다.

완료 조건:

- 허용된 계정은 자신이 배정된 topic만 구독한다.
- 매장/층을 바꾼 위조 topic 구독은 서버에서 거절된다.
- 한 업무 명령의 delivered message 수가 설계한 수신자 수와 일치한다.

### T10. 제한형 bootstrap 및 single-ticket v2 RPC

- [ ] 중첩 wrapper 대신 set-based SQL로 `get_kds_bootstrap_v2`를 구현한다.
- [ ] 서버 강제 limit, cursor, 현재 revision, 서버 시각을 포함한다.
- [ ] 신규 주문/복잡한 patch 복구용 `get_kds_ticket_v2(queue_id)`를 구현한다.
- [ ] 기존 localization, 콤보 진행, takeout, batch timing, sales channel 필드를 결과 계약에 보존한다.
- [ ] fulfillment mode, active/draining session, leftover task, today-completed count와 기존 정렬 기준도 결과 계약에 보존한다.
- [ ] EXPLAIN ANALYZE와 10/50/100 활성 티켓 fixture로 쿼리를 검증한다.

재사용:

- 기존 emergency queue/item 및 확장 원장
- 기존 snapshot wrapper가 보장하던 필드 contract test

완료 조건:

- 활성 50 티켓에서 bootstrap p95 1초, payload 100KB 이하를 만족한다.
- 기존 화면에 필요한 필드 parity test가 통과한다.
- 같은 DB fixture에서 legacy/v2의 표시·액션 가능 여부·정렬·알림 입력 상태가 허용 오차 0으로 일치한다.
- 목표를 못 맞추면 원인을 기록한 뒤에만 별도 projection 작업을 새 task로 추가한다.

### T11. delta, high-watermark, recent-completed v2 RPC

- [ ] `get_kds_changes_v2`가 권한 범위 안의 이벤트를 revision 오름차순으로 제한 반환한다.
- [ ] 오래된 cursor, limit 초과, session 변경을 구분하는 응답 코드를 제공한다.
- [ ] payload 없는 `get_kds_high_watermark_v2`를 구현한다.
- [ ] 완료 내역은 cursor pagination 기반 `get_kds_recent_completed_v2`로 분리한다.
- [ ] 최근 완료 selector count와 탭 진입 시 첫 page 준비 시점이 기존 UX와 동등하도록 계약한다.

완료 조건:

- revision 공백 1건/100건/보존 범위 초과 테스트가 각각 delta/다중 page/bootstrap-required로 귀결된다.
- 완료 탭을 열지 않은 세션에서는 recent-completed RPC 호출이 0회다.
- 단, selector count와 완료/revert 가능 여부가 누락되지 않고 기존 today-completed test가 통과한다.

## Milestone 3 — Release B: 클라이언트 sync engine

### T12. Broadcast 구독, cursor 저장, 중복 제거

- [ ] 대상 private Broadcast를 구독하는 sync engine을 기존 8개 운영 테이블 Postgres Changes와 나란히 shadow mode로 추가한다.
- [ ] 현재 매장/세션/스테이션/층별 last applied revision을 안전하게 저장한다.
- [ ] ACK와 Broadcast로 같은 event가 두 번 도착해도 한 번만 적용한다.
- [ ] 구독 시작 전에 bootstrap revision을 잡고, subscribe 뒤 high watermark/delta로 race window를 닫는다.

수정/생성 후보:

- `lib/features/emergency_fulfillment/` 아래 sync engine/repository
- 기존 provider의 `_subscribe()`와 realtime handler

완료 조건:

- ACK 우선/Broadcast 우선/동시 도착 순서 테스트에서 최종 상태가 동일하다.
- 화면 재진입과 auth refresh 뒤 subscription leak가 없다.
- T08의 모든 source mutation이 shadow stream에 도착하기 전에는 기존 8개 구독을 제거하지 않는다.

### T13. envelope 기반 부분 상태 적용

- [ ] item progress, order state, 신규 ticket, 삭제/취소, 콤보/플로어 패치를 reducer로 적용한다.
- [ ] patch만으로 안전하지 않은 이벤트는 `get_kds_ticket_v2` 한 건만 조회한다.
- [ ] 전체 list를 교체하지 않아 선택 탭, 페이지, scroll/포커스가 유지되게 한다.
- [ ] revision별 불변식 검증 실패 시 gap recovery로 넘긴다.
- [ ] reducer가 만드는 before/after state가 기존 신규·추가·handoff·floor-direct·leftover 알림 판단 함수에 동일한 입력을 제공한다.

완료 조건:

- 100개 연속 이벤트를 적용해도 전체 bootstrap이 호출되지 않는다.
- 다른 주문의 UI 상태와 현재 사용자 선택이 유지된다.
- mutation 종류별 reducer unit test가 기존 수량 체인과 일치한다.
- 알림 문구·대상·coalescing·횟수와 flash가 legacy event sequence와 일치한다.

### T14. 재접속 catch-up과 gap 복구

- [ ] 지수 backoff로 Broadcast를 재연결한다.
- [ ] 재연결 뒤 last revision부터 delta를 page 단위로 모두 적용하고 high watermark 도달을 확인한다.
- [ ] revision gap, session 변경, 로그 보존 범위 초과를 서로 다르게 처리한다.
- [ ] 전체 bootstrap은 설계 문서의 허용 조건에서만 호출한다.
- [ ] 연결 상태가 불확실할 때 저비용 high-watermark watchdog을 jitter와 함께 사용한다.

완료 조건:

- 1/10/100개 누락 이벤트가 중복 없이 복구된다.
- 1,000개 모의 단말이 동시에 reconnect해도 고정 간격 폭주 대신 jitter/backoff가 관측된다.
- 정상 연결 상태에서 주기적 full snapshot 호출은 0이다.

### T15. outbox와 revision stream 통합

- [ ] IndexedDB object store, record key/payload, UUID, FIFO flush와 영구 거절 삭제 규칙은 비호환 변경하지 않는다.
- [ ] 기존 outbox를 생성 순서대로 flush하고 각 ACK envelope를 즉시 reducer에 적용한다.
- [ ] 재전송 응답이 이미 처리된 event라면 동일 결과로 수렴한다.
- [ ] 온라인 Broadcast와 offline outbox ACK의 순서가 교차해도 revision gap 로직으로 복구한다.
- [ ] 잘못된/영구 거절 명령은 무한 재시도하지 않고 별도 사용자 조치 상태로 둔다.

완료 조건:

- 오프라인에서 20개 명령 적재 후 복구 테스트가 서버 원장과 모든 단말 상태를 일치시킨다.
- 앱 재시작/브라우저 새로고침 중에도 승인된 명령이 유실되지 않는다.

### T16. legacy/v2 shadow comparison과 매장별 feature flag

- [ ] `legacy_polling`, `v2_shadow`, `v2_active`를 매장 단위로 제어한다.
- [ ] shadow에서는 v2 상태를 UI에 적용하지 않고 legacy 결과와 의미상 비교한다.
- [ ] 차이를 order/item/event type별 metric으로 수집하되 민감정보는 기록하지 않는다.
- [ ] v2 장애 시 새 배포 없이 매장 단위로 legacy 제한 모드로 전환한다.

완료 조건:

- 동일 fixture와 실제 canary에서 상태/수량 parity가 허용 오차 0으로 일정 기간 유지된다.
- flag 변경이 다른 매장에 영향을 주지 않는다.

## Milestone 4 — Release C: 폴링 제거와 관측성

### T17. 무조건 1초 폴링 및 다중 테이블 구독 제거

- [ ] v2 canary 승인 매장에서 `_startPolling()`의 무조건 1초 전체 `load()`를 중단한다.
- [ ] KDS용 8개 테이블 Postgres Changes 구독을 제거한다.
- [ ] degraded mode는 high watermark + delta를 사용하며 full snapshot 고정 폴링으로 돌아가지 않는다.
- [ ] 기존 `<= 1초` 테스트를 `정상 경로 full polling 0`, `gap 시 delta`, `bootstrap 허용 조건` 계약으로 교체한다.

완료 조건:

- 30분 정상 운영 테스트에서 단말당 전체 snapshot 호출이 0이다.
- 주문 생성부터 조리/트레이/플로어 완료까지 타 단말 p95 반영이 1초 이하다.
- legacy flag를 켜면 롤백 경로가 정상 동작한다.
- 기능 보존 매트릭스와 source mutation coverage가 100%가 아니면 이 task를 시작하지 않는다.

### T18. 운영 dashboard와 경보

- [ ] ACK latency, publish-to-apply, revision lag, gap, bootstrap, outbox, Realtime quota를 매장별/전체로 수집한다.
- [ ] 70/85/95% quota 경보와 ACK/revision/outbox SLO 경보를 추가한다.
- [ ] event ID, restaurant ID, revision으로 한 명령을 추적하되 고객 개인정보는 제외한다.
- [ ] 지표 수집 실패가 주문 명령 트랜잭션을 실패시키지 않게 한다.

완료 조건:

- 의도적으로 Broadcast를 끊거나 RPC를 지연시킨 game-day에서 예상 경보와 runbook 링크가 발생한다.
- 운영자가 특정 매장의 마지막 revision과 뒤처진 단말 여부를 확인할 수 있다.

## Milestone 5 — 검증, canary, 100개 매장 승인

### T19. DB 원자성·보안·idempotency 검증

- [ ] mutation + revision + change log 원자성을 동시성 테스트한다.
- [ ] 중복 UUID, 순서 역전, 권한 없는 매장/스테이션/층 접근을 테스트한다.
- [ ] cleanup과 동시 delta read가 누락/중복을 만들지 않는지 검증한다.
- [ ] migration up과 feature rollback의 데이터 안전성을 검증한다.

완료 조건:

- SQL contract/security suite가 production과 동일한 Postgres/Supabase 정책에서 통과한다.

### T20. Flutter provider·widget·브라우저 회귀 검증

- [ ] sync state transition, reducer, reconnect, subscription dispose를 unit/provider test로 검증한다.
- [ ] 기존 responsive, KDS card/menu, floor direct, outbox 테스트를 모두 실행한다.
- [ ] direct delivery routing, takeout/leftover, voice/push, fulfillment mode/print, cashier/payment contract를 모두 실행한다.
- [ ] 두 계정·복수 탭으로 실제 Broadcast와 명령 ACK를 E2E 검증한다.
- [ ] 느린 3G, packet loss, offline/online 전환 시나리오를 자동화한다.

완료 조건:

- 전체 관련 테스트가 통과하고 subscription/timer leak 및 무한 busy 상태가 없다.
- 기존 화면·문구·액션·알림·업무 결과에 승인되지 않은 차이가 0이다.

### T21. 100개 매장 부하 및 재접속 시험

- [ ] 100 매장 × 10 연결을 서로 다른 JWT/권한으로 생성한다.
- [ ] 매장당 1 command/s, 평균 fan-out 2를 30분 이상 유지한다.
- [ ] 1,000 연결 동시 reconnect, delta 100건 catch-up, 일부 slow consumer를 주입한다.
- [ ] DB CPU/connection/lock, Realtime quota, ACK와 apply latency, 오류율을 기록한다.

완료 조건:

- ACK p95 500ms/p99 1초, 타 단말 반영 p95 1초, 100 delta catch-up p95 2초를 충족한다.
- 승인된 명령 유실·중복 적용·교차 매장 노출이 0이다.
- 플랫폼 quota에 최소 20% 여유가 남는다.

### T22. 단계적 production canary 및 롤백 리허설

- [ ] 내부/저위험 1개 매장에서 `v2_shadow`를 운영한다.
- [ ] parity와 SLO 통과 후 같은 매장을 `v2_active`로 전환한다.
- [ ] 소규모 cohort → 50% → 100% 사이에 최소 관측 창과 중단 조건을 둔다.
- [ ] 각 단계에서 flag rollback, Broadcast 중단, delta 장애, quota 임박 리허설을 수행한다.

중단 조건:

- 승인 명령 유실 또는 중복 수량 1건 이상
- 교차 매장/권한 데이터 노출 1건 이상
- ACK/반영 SLO 지속 위반
- revision gap 또는 full bootstrap 비율 급증
- Realtime/DB quota 안전 여유 미달

완료 조건:

- 각 단계의 지표, 승인자, 배포 SHA, 롤백 결과가 기록되고 다음 단계 승인 전 자동 확대가 없다.

### T23. 운영 runbook과 보존 정책 인수

- [ ] `revision lag`, Broadcast 장애, outbox 적체, quota 초과, 오래된 cursor 대응 절차를 작성한다.
- [ ] change log 보존 기간과 cleanup schedule을 실제 용량 측정으로 확정한다.
- [ ] 매장 지원팀이 강제 재동기화와 feature rollback을 수행하는 절차를 검증한다.
- [ ] 기존 감사 이벤트와 change log의 보존 목적 차이를 명시한다.

완료 조건:

- 운영 담당자가 개발자 도움 없이 모의 장애를 진단하고 안전한 복구 절차를 완료한다.

### T24. 저장소·릴리스 게이트 통과

- [ ] `CLAUDE.md`가 요구하는 formatter, analyzer, unit/widget/integration test를 실행한다.
- [ ] production DB migration과 앱 배포를 지정 스크립트로만 수행한다.
- [ ] 배포 대상 Git SHA와 GitHub Actions 성공 SHA가 정확히 일치하는지 확인한다.
- [ ] 관련 없는 사용자 변경과 미추적 파일이 포함되지 않았는지 최종 확인한다.

완료 조건:

- production gate가 동일 SHA로 PASS하고, canary 승인 기록 및 복구 절차가 연결되어 있다.

## 완료 정의

다음 조건을 모두 만족해야 "100개 매장 준비 완료"라고 판단한다.

- 정상 경로에 1초 전체 snapshot polling과 다중 테이블 Postgres Changes 구독이 없다.
- ACK/Broadcast/delta가 같은 envelope와 revision 계약으로 수렴한다.
- 1,000 연결·100 command/s 부하와 동시 재접속 시험이 SLO를 통과한다.
- Supabase 실제 quota와 비용 경보가 목표 규모를 수용한다.
- 매장·스테이션·층 권한, idempotency, outbox, 기존 KDS 기능 회귀가 모두 통과한다.
- 기능 보존 매트릭스 전 항목과 모든 source mutation이 legacy/v2 허용 오차 0으로 일치한다.
- canary 확대와 롤백 리허설이 완료되고 production gate가 동일 SHA로 PASS한다.
