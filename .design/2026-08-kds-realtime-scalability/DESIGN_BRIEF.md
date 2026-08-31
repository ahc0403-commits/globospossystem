# KDS 실시간 동기화 및 100개 매장 확장 설계

- 작성일: 2026-08-31
- 상태: 구현 전 승인용 설계
- 대상: 주방/트레이/플로어 KDS 및 긴급 주문 처리 화면
- 목표 규모: 100개 매장, 매장당 상시 단말 10대, 총 1,000개 연결

## 1. 결정 요약

현재의 `1초마다 전체 스냅샷 재조회`를 정상 동작 경로에서 제거한다. 이를 단순히 폴링 주기를 늘리는 작업으로 처리하지 않고, 다음 구조로 전환한다.

1. 사용자의 조리 진행 명령은 서버가 확정한 변경 내용을 ACK로 즉시 반환한다.
2. 같은 DB 트랜잭션에서 매장별 연속 revision과 논리적 변경 이벤트 1건을 기록한다.
3. 변경 이벤트를 매장·스테이션별 비공개 Supabase Broadcast 채널로 전달한다.
4. 수신 단말은 전체 화면을 다시 읽지 않고 해당 주문/아이템만 패치한다.
5. 연결이 끊겼다가 복구되면 마지막 revision 이후의 변경만 읽는다.
6. 최초 진입, 권한/세션 변경, 변경 로그 공백에만 제한된 전체 bootstrap을 수행한다.

즉, Broadcast는 빠른 전달 수단이고 DB 변경 로그는 유실 없는 복구 수단이다. 둘 중 하나에만 의존하지 않는다.

### 변경 범위 선언

이번 작업이 바꾸는 것은 **KDS 상태를 가져오고 전달하고 복구하는 동기화 경로와 그 성능**뿐이다. 주문·조리·전달·포장·결제의 업무 규칙, 화면 기능, 알림 의미는 변경하지 않는다.

허용되는 변경:

- 전체 스냅샷 반복 조회를 ACK/Broadcast/delta로 대체하는 내부 데이터 전송 방식
- 기존 결과와 동일한 값을 반환하는 additive v2 RPC
- 새 revision/change log 테이블과 해당 테이블만을 위한 RLS
- provider 내부 동기화 상태, reducer, reconnect 처리
- 동기화 성능·정합성 관측 지표와 회귀/부하 테스트

허용되지 않는 변경:

- 기존 운영 테이블·컬럼·상태값의 삭제, 이름 변경 또는 의미 변경
- 기존 업무 RPC의 입력, validation, 수량 계산, 권한, 오류 코드, side effect 의미 변경
- kitchen → tray → floor 수량 체인과 완료/취소/되돌리기 규칙 변경
- 콤보, floor-direct, takeout, leftover packaging, direct delivery routing 변경
- fulfillment mode, 기존 세션 draining, POS print 경로 변경
- 결제 가능 조건, cashier 미제공 경고, 영수증/프린터 동작 변경
- 화면 레이아웃, 액션 노출, 페이지 크기, 색상, 문구, 다국어 동작 변경
- 음성 문구, 알림 대상·횟수·순서, flash, foreground push fallback 변경
- 기존 IndexedDB outbox 포맷·순서·idempotency 의미의 비호환 변경

위 금지 항목이 필요해지는 경우 이 개선 작업에 포함하지 않고 별도 설계와 승인을 받아야 한다.

## 2. 현재 문제와 근거

### 확인된 현상

- KDS provider가 여러 테이블의 Realtime 변경을 구독하면서도 매초 `load()`를 실행한다.
- `load()` 한 번에 메인 스냅샷뿐 아니라 오늘 완료, 타이밍, 매장 모드 RPC까지 함께 호출한다.
- 조리 완료 명령도 RPC 성공 뒤 전체 `load()`가 끝날 때까지 UI busy 상태를 유지한다.
- Realtime 행 이벤트 하나가 들어와도 전체 재조회가 중복으로 발생할 수 있다.
- 현재 스냅샷 RPC는 여러 migration wrapper가 중첩되어 있고, 활성 세션 전체를 JSON으로 조립한다.

### 운영 데이터에서 확인된 병목

- 주문/아이템 총량은 아직 작아 단순한 "DB 데이터가 많이 쌓여서" 생긴 장애로 보기 어렵다.
- 운영 통계에서 스냅샷 RPC는 매우 많은 횟수로 호출되었고 평균·최대 지연이 진행 명령 RPC보다 훨씬 컸다.
- 짧은 실시간 표본에서도 스냅샷 호출 자체가 DB 실행 시간을 지속적으로 소비했다.
- 따라서 주원인은 데이터 보존량보다 `상시 전체 재조회 × 단말 수`가 만드는 읽기 증폭과 명령 후 동기식 재조회다.

### 100개 매장에서의 현재 구조

매장당 KDS 단말 10대가 모두 1초 폴링하면 초당 약 1,000회의 전체 스냅샷 요청이 발생한다. 각 요청이 여러 RPC와 JSON 조립을 포함하므로 데이터량이 지금과 같아도 선형 이상으로 DB 연결, CPU, 네트워크가 소모된다. 현재 구조로는 100개 매장 운영을 승인하지 않는다.

## 3. 범위와 불변 조건

### 반드시 유지할 동작

- 기존 수량 진행 체인과 상태 전이 규칙
- 부분 조리, 콤보 구성품, 플로어 직송 음료, 주문 단위 완료
- 중복 클릭/재전송에 대한 idempotency
- IndexedDB outbox와 오프라인 명령 재전송
- 로그인한 사용자의 매장·스테이션·층 권한
- 현재 선택 탭, 페이지, 음성/알림, 프린터 관련 동작
- 주문 원장과 감사용 이벤트 보존

### 기능 보존 매트릭스

| 기존 기능 | 현재 계약 | 새 동기화 경로의 의무 | 승인 증거 |
|---|---|---|---|
| 기본 메뉴 진행 | stage별 수량을 독립 보존하고 ordered quantity를 넘지 않음 | 기존 progress RPC를 additive v2 wrapper가 그대로 호출하고 결과만 envelope로 전달 | 기존 수량 체인·SQL 동시성 테스트 + legacy/v2 결과 비교 |
| 메뉴 단위 취소 | station별 정확한 역방향 delta 적용 | validation과 오류 코드를 바꾸지 않고 동일 ACK/이벤트로 수렴 | kitchen/tray/floor 취소 widget test |
| 주문 단위 완료/되돌리기 | 원자적·idempotent이며 downstream progress가 있으면 잘못된 revert 거절 | 기존 route-aware action RPC와 side effect를 보존 | action/revert SQL contract + 최근 완료 UI 테스트 |
| 콤보 구성품 | 구성품별 독립 수량·정렬·표시 | base item과 합치지 않고 component identity를 envelope에 유지 | combo contract 전체 + snapshot parity |
| floor-direct 음료 | kitchen/tray에서 숨김, floor에서 직접 완료·취소 | route snapshot과 floor 권한을 그대로 보존 | floor-direct SQL/widget contract |
| 배달 주문 | floor로 보내지 않고 tray에서 종료, 고객 상태 동기화 | 기존 DB trigger side effect 실행 순서와 결과를 보존 | direct-delivery KDS routing contract |
| takeout·잔여 음식 포장 | immutable takeout line과 5단계 reverse handoff | packaging request 상태 변경도 revision stream에 포함 | takeout/leftover contract + 단계별 E2E |
| 신규·추가 주문 | 새 주문, 추가 주문, handoff를 구분해 알림 | 전체 상태 diff와 동등한 before/after 의미를 reducer가 제공 | 신규/추가/handoff/floor-direct 음성·flash 테스트 |
| 음성·push | 베트남어 음성, coalescing, foreground push fallback | 알림 판단 함수·문구·횟수는 바꾸지 않고 입력 상태만 동일하게 갱신 | 기존 web fallback/voice contract + event sequence test |
| 카드·상세·타이머 | 4/8 슬롯, 선택/페이지 유지, batch/station clock 경계 보존 | timing boundary를 bootstrap/ticket/delta에 포함하고 경과 시간은 기존 방식으로 계산 | responsive/card/timer contract |
| 최근/오늘 완료 | 현재 세션 밖 오늘 완료도 열람·취소/되돌리기 가능 | selector count는 항상 최신 유지, 목록은 탭 진입 전에 즉시 확보 | recent/today completed widget test |
| fulfillment mode | paperless와 POS print, 기존 session draining 의미 유지 | bootstrap/control event로 즉시 반영하며 TTL 때문에 동작을 늦추지 않음 | mode/session/print regression |
| outbox | 순서 보존, 영구 거절 제거, 일시 장애 재시도 | 기존 record와 UUID를 그대로 사용하고 ACK/delta만 추가 | offline 20명령·재시작·중복 재전송 test |
| cashier/결제 | 미제공 경고는 정보성이고 결제를 막지 않음 | KDS 변경이 payment API나 summary 의미를 건드리지 않음 | cashier/payment contract |
| 권한·격리 | 매장·station·floor 할당 범위만 접근 | 기존 권한은 유지하고 새 private topic/change log에 같은 범위를 추가 | 교차 매장·station·floor negative test |

각 행은 Release A 이전에 현재 테스트가 통과해야 하고, Release B shadow에서 legacy와 v2 결과가 허용 오차 0으로 일치해야 한다. 하나라도 불일치하면 해당 매장의 v2 활성화와 폴링 제거를 중단한다.

### 이번 범위에서 제외

- 매장 내 로컬 엣지 서버를 통한 완전한 WAN 독립 운영
- 결제 생명주기 또는 주문 접수 정책 변경
- KDS UI 전면 재설계
- 다중 리전 active-active 구성
- 근거 없는 원장 파티셔닝 또는 중복 projection 테이블 선도입

완전한 인터넷 단절에서도 여러 단말이 서로 실시간 동기화되어야 한다면 매장 로컬 허브가 별도 프로젝트로 필요하다. 이번 설계는 cloud-first 구조와 기존 단말별 outbox를 전제로 한다.

## 4. 목표 아키텍처

```text
사용자 명령
  -> progress RPC
      -> 기존 KDS 원장 갱신
      -> 매장 revision +1
      -> kds_change_log 1건 기록
      -> 동일 KdsChangeEnvelope ACK
  -> 호출 단말 즉시 패치

kds_change_log INSERT
  -> 대상별 private Broadcast
  -> 다른 단말이 같은 envelope 적용

재접속 단말
  -> last_revision 이후 delta 조회
  -> 순서대로 적용
  -> 현재 high watermark 도달
```

### 4.1 기존 원장을 우선 read model로 사용

`emergency_order_queue`, `emergency_fulfillment_items`와 콤보/플로어 직송 관련 테이블은 이미 KDS용 조회 원장 역할을 한다. 먼저 이 원장들을 set-based 쿼리로 읽는 제한형 v2 RPC를 만든다.

별도의 `kds_active_orders` 같은 중복 projection 테이블은 v2 쿼리가 성능 게이트를 통과하지 못할 때만 도입한다. 이 결정으로 초기에는 이중 쓰기와 정합성 위험을 줄인다.

### 4.2 매장별 revision과 변경 로그

추가 테이블의 최소 계약은 다음과 같다.

#### `kds_store_revisions`

- `restaurant_id` primary key
- `current_revision bigint not null`
- `updated_at timestamptz not null`

#### `kds_change_log`

- `restaurant_id`
- `revision bigint`
- `session_id`
- `event_id uuid`
- `event_type`
- `target_station`
- `target_floor_label nullable`
- `queue_id`, `order_id`, `order_item_id` 등 대상 식별자
- `payload jsonb`: 화면 패치에 필요한 최소 확정 데이터
- `created_at`

필수 제약과 인덱스:

- unique `(restaurant_id, revision)`
- unique `event_id`
- `(restaurant_id, target_station, revision)`
- `(restaurant_id, target_floor_label, revision)`
- 매장 권한 및 스테이션/층 권한을 검사하는 RLS

한 매장 안에서는 progress RPC가 revision 행을 잠그고 증가시킨다. 예상 명령량에서는 이 짧은 직렬화가 병목보다 순서 보장의 이점이 크다. 실제 부하 시험에서 매장 단위 lock 대기가 목표를 넘을 때만 revision shard를 검토한다.

### 4.3 하나의 업무 명령은 하나의 논리 이벤트

DB 행이 여러 개 수정되더라도 클라이언트에 전달하는 이벤트는 업무 명령 기준 1건이다. 운영 테이블 각각에 Realtime trigger를 붙이지 않는다. 같은 명령에서 반환하는 ACK와 Broadcast payload는 동일한 `KdsChangeEnvelope`를 사용한다.

```json
{
  "schema_version": 1,
  "restaurant_id": "...",
  "session_id": "...",
  "revision": 1234,
  "event_id": "uuid",
  "event_type": "item_progressed",
  "target": {"station": "kitchen", "floor_label": null},
  "entities": {"queue_id": "...", "order_item_id": "..."},
  "patch": {"kitchen_done_quantity": 2, "status": "ready"},
  "occurred_at": "..."
}
```

클라이언트는 `event_id`로 중복을 제거하고 revision 순서로 적용한다. 이미 적용된 revision은 무시하고, revision이 건너뛰면 delta catch-up을 실행한다.

KDS 화면을 바꾸는 원인은 KDS 버튼 명령만이 아니다. 신규 주문, 추가 주문, 주문 취소/복구, 운영 세션·fulfillment mode 변경, leftover packaging 요청과 진행, direct delivery 상태 변경도 모두 source mutation inventory에 포함한다. 현재 8개 운영 테이블 구독이 감지하던 모든 원인을 새 stream이 대체한다는 증거가 생기기 전에는 기존 구독을 제거하지 않는다.

### 4.4 비공개 Broadcast 토픽

- `kds:{restaurant_id}:kitchen`
- `kds:{restaurant_id}:tray`
- `kds:{restaurant_id}:floor:{floor_label}`
- `kds:{restaurant_id}:control`

채널은 private로 만들고, 구독 권한은 JWT의 사용자와 DB의 매장/스테이션/층 배정을 함께 검사한다. payload에 고객 개인정보나 불필요한 주문 전체 데이터를 싣지 않는다.

Supabase는 데이터베이스 변경 구독에서 확장성과 보안을 위해 Broadcast 방식을 권장한다. Postgres Changes는 구독자별 권한 검사와 단일 처리 흐름의 비용이 있으므로 KDS의 다중 테이블 fan-out 경로에서는 제거한다.

참고:

- https://supabase.com/docs/guides/realtime/subscribing-to-database-changes
- https://supabase.com/docs/guides/realtime/benchmarks
- https://supabase.com/docs/guides/realtime/broadcast

### 4.5 제한형 v2 조회 API

- `get_kds_bootstrap_v2(station, floor_label, active_limit, recent_limit)`
  - 현재 활성 주문의 제한된 첫 페이지, 현재 revision, 서버 시각을 반환한다.
- `get_kds_ticket_v2(queue_id)`
  - 신규/변경 주문 한 건만 다시 동기화한다.
- `get_kds_changes_v2(after_revision, station, floor_label, limit)`
  - 재접속 또는 revision 공백 복구용 순서 보장 delta를 반환한다.
- `get_kds_recent_completed_v2(cursor, limit)`
  - 오늘 완료 목록은 cursor로 제한하되, 기존 selector count와 탭 진입 시점의 즉시 표시를 보존한다.
- `get_kds_high_watermark_v2()`
  - payload 없이 현재 매장 revision만 확인하는 저비용 watchdog이다.

bootstrap과 delta에는 서버가 강제하는 최대 limit를 둔다. 응답 크기, 쿼리 실행 시간, 반환 행 수를 관측 가능하게 만든다.

### 4.6 클라이언트 동기화 상태

클라이언트는 boolean `isLoading` 하나가 아니라 다음 상태를 구분한다.

- `bootstrapping`: 최초 제한 스냅샷 로딩
- `subscribed`: Broadcast 연결 및 revision 일치
- `catchingUp`: 누락된 revision 적용 중
- `offlineQueued`: 네트워크 단절, 로컬 outbox 적재
- `degraded`: Broadcast 불안정, revision watchdog/delta 경로 사용
- `rejected`: 서버가 명령을 거절하여 optimistic patch 롤백

명령 버튼은 네트워크 전체 재조회가 아니라 해당 명령 ACK까지만 기다린다. ACK가 성공하면 서버 확정 patch를 적용하고 busy를 해제한다. Broadcast로 같은 event가 다시 와도 중복 적용하지 않는다. 이 내부 상태를 이유로 새 화면, 문구, 버튼 또는 작업 흐름을 추가하지 않는다. 기존 오류/오프라인 표면에서 구분할 수 없는 상태가 실제 운영상 필요하면 별도 UI 변경 승인을 받는다.

### 4.7 전체 스냅샷 허용 조건

정상 연결 중의 주기적 전체 스냅샷 호출 수는 0이어야 한다. 전체 bootstrap은 다음 경우에만 허용한다.

- 최초 화면 진입
- 로그인 사용자, 매장, 운영 세션, 스테이션 또는 층 변경
- 클라이언트 cursor가 서버 변경 로그 보존 범위보다 오래됨
- delta 검증 실패 또는 스키마 버전 불일치
- 운영자가 명시적으로 실행한 복구 동작

Broadcast 연결이 끊겼다고 즉시 전체 스냅샷 폴링으로 돌아가지 않는다. 우선 지수 backoff 재연결, high watermark 확인, delta catch-up 순으로 복구한다.

## 5. 성능·정합성 목표

### 사용자 체감 SLO

- 클릭 후 로컬 optimistic 반응: 100ms 이내
- progress RPC ACK: p95 500ms 이하, p99 1초 이하
- 다른 KDS 단말 반영: p95 1초 이하
- 변경 100건 이하 재접속 catch-up: p95 2초 이하
- 활성 티켓 50건 bootstrap: p95 1초 이하, 압축 전 payload 100KB 이하
- 정상 연결 중 단말당 전체 snapshot polling: 0회/분

### 정합성 SLO

- 승인된 명령 유실 0
- 한 `event_id`의 중복 수량 반영 0
- 매장 간 이벤트 노출 0
- 스테이션/층 권한 외 이벤트 노출 0
- outbox 재전송과 온라인 명령이 같은 idempotency 계약 사용

## 6. 100개 매장 용량 모델과 승인 게이트

기본 부하 모델:

- 100개 매장 × 10개 상시 단말 = 1,000 WebSocket 연결
- 피크 시 매장당 초당 1개 KDS 명령 = 초당 100개 논리 이벤트
- 이벤트당 평균 수신 단말 2개 = 초당 약 200개 전달 메시지
- 장애 복구 시험: 1,000개 단말 동시 재접속 및 delta catch-up

현재 Supabase 공개 한도상 일반 Pro의 동시 연결 500개는 이 모델에 부족하다. Pro no-spend-cap 또는 Team의 10,000개 연결/초당 2,500개 메시지 수준 이상, 혹은 계약형 한도를 배포 전 확인해야 한다. 메시지 한도는 publish 수가 아니라 구독자별 전달 수를 기준으로 산정한다.

- https://supabase.com/docs/guides/realtime/limits
- https://supabase.com/docs/guides/realtime/settings

100개 매장 준비 완료 판정은 코드 배포만으로 하지 않는다. 다음을 모두 통과해야 한다.

1. 실제 프로젝트 Realtime quota가 목표 연결·메시지의 최소 20% 여유를 확보한다.
2. 1,000 연결, 100 명령/초, 평균 fan-out 2 부하 시험에서 SLO를 만족한다.
3. 1,000 연결 재접속 폭주에서 DB connection/CPU와 delta API가 안정적이다.
4. 매장·스테이션·층 교차 권한 침범 테스트가 모두 거절된다.
5. change log 보존/정리 중에도 cursor 복구가 안전하다.

## 7. 단계별 전환 전략

### Release A — 즉시 지연 완화

- 기존 업무 RPC의 의미를 바꾸지 않는 additive v2 wrapper가 반환한 확정값을 실제 화면 patch에 사용한다.
- 성공 뒤 `await load()`를 제거해 버튼 busy 시간을 ACK까지만 제한한다.
- 완료 selector count, 타이머 경계, fulfillment mode는 기존 표시 시점과 의미를 유지한다. 큰 목록만 필요한 시점에 제한 조회한다.
- 동시에 발생한 refresh 요청을 coalesce한다.
- 기존 동기화는 유지하되 관측 지표를 먼저 추가한다.

이 단계는 체감 지연과 중복 읽기를 줄이지만 100개 매장 완료 상태는 아니다.

### Release B — 내구성 있는 이벤트 동기화

- revision/change log와 v2 API를 additive migration으로 추가한다.
- 모든 KDS 명령 진입점이 동일 envelope를 생성하도록 통합한다.
- 신규·추가 주문, 취소/복구, 세션·모드, 포장 요청 등 KDS 외부에서 발생하는 source mutation도 빠짐없이 stream에 연결한다.
- private Broadcast와 클라이언트 delta sync engine을 도입한다.
- 기존 경로와 새 경로를 dual-publish/shadow-compare하여 결과 차이를 측정한다.

### Release C — 매장별 canary와 1초 폴링 제거

- feature flag로 내부/저위험 매장부터 새 경로를 활성화한다.
- shadow 결과, 명령 지연, revision gap, outbox 재처리를 검증한다.
- 통과한 매장에서만 무조건 1초 폴링과 다중 테이블 Postgres Changes 구독을 제거한다.
- 1개 → 소규모 cohort → 50% → 100% 순서로 확대한다.

### Release D — 100개 매장 확장 승인

- 목표 규모 부하/재접속/느린 네트워크 시험을 수행한다.
- Supabase quota와 비용 경보를 확정한다.
- 장애 대응 runbook, 보존 정책, dashboard를 운영 인수한다.

## 8. 관측 지표와 알림

필수 metric:

- 명령 ACK p50/p95/p99 및 오류율
- Broadcast publish-to-apply 지연
- 현재 revision과 단말 applied revision 차이
- revision gap/catch-up/full bootstrap 발생 횟수
- 단말당 snapshot 호출 횟수
- bootstrap/delta 응답 크기와 DB 실행 시간
- outbox 길이, 가장 오래된 항목 나이, 재시도 횟수
- Realtime 연결 수, 전달 메시지 수, quota 사용률
- 매장별 command rate와 fan-out

알림 기준은 최소한 ACK p95 초과, revision lag 지속, outbox 적체, full bootstrap 급증, quota 70/85/95% 구간을 포함한다.

## 9. 변경 로그 보존과 정리

- Broadcast replay는 영구 원장이 아니므로 복구의 기준은 `kds_change_log`다.
- 1차 제안은 7일 보존이며, 실제 최대 오프라인 시간과 용량 측정 후 확정한다.
- 정리 작업은 활성 클라이언트 cursor보다 오래된 데이터만 제거하고, 오래된 cursor는 bootstrap으로 명시적으로 전환한다.
- 기존 감사/업무 이벤트 원장은 이 정책으로 삭제하지 않는다.
- change log 크기가 측정 임계치를 넘을 때만 날짜 파티셔닝을 추가한다.

## 10. 롤백 전략

- DB 변경은 additive migration으로 배포하고 기존 RPC/테이블을 즉시 제거하지 않는다.
- 매장별 feature flag로 v2 수신과 폴링 제거를 독립적으로 되돌릴 수 있게 한다.
- 전환 기간에는 legacy와 v2 이벤트를 dual-publish하되 UI에는 한 경로만 적용한다.
- v2 장애 시 기존 읽기 경로를 제한된 비상 모드로 복구하되 무조건 1초 폴링은 사용하지 않는다.
- outbox와 명령 idempotency key는 양 경로에서 동일하게 유지한다.
- 롤백 후에도 생성된 revision/change log는 감사와 원인 분석을 위해 보존한다.

## 11. 기존 문서와의 관계

이 설계는 `.design/2026-08-kds-card-menu-sync/DESIGN_BRIEF.md`에 적힌 `Realtime + 1초 fallback polling` 요구 중 1초 polling 부분을 대체한다. 메뉴명/카드 정보 동기화와 기존 기능 요구는 계속 유효하다.

구현 순서와 완료 조건은 같은 폴더의 `TASKS.md`를 기준으로 한다.
