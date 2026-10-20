# 중앙 서버 기반 500매장 전달·안정성 개선 계획

작성: 2026-09-20 · 상태: 계획 수립 완료 / 구현·배포·용량 인증 미실시

## 1. 확정 요구사항과 보장 범위

- 미래 500개 매장을 지원한다. 현재 500개 매장이 운영 중이라고 가정하지 않는다.
- 고객 주문→주방, 주방→체커/트레이, 체커/트레이→층, 층→고객 전달을 모두 포함한다.
- 정상 연결에서 전달 목표 1초, 허용 성능 기준 2초다. 같은 기기의 버튼 반응만 빠른 것은 전달 성공이 아니다.
- SQL N+1을 금지한다. 조회뿐 아니라 쓰기, 하위 함수, 행 단위 트리거, 이벤트 생성 및 복구 경로까지 적용한다.
- 로컬 중계 장치, 매장 서버, 신규 매장 장비는 도입하지 않는다. 기존 단말과 중앙 서버 구조를 개선한다.
- 이번 산출물은 계획이다. 기존 사용자 작업을 보존하고, 운영 설정·요금제·DB·코드는 변경하지 않는다.

이 계획은 이전 500매장 계획의 KDS 지연·N+1·복구·용량 통과 기준을 구체화하고 강화한다. 기존 결제, MISA 비동기, Office 연동, 정산 및 마감 계약은 유지한다.

서버 다운 확률을 낮추고 장애의 확산과 복구 시간을 통제한다. 모든 인터넷·클라우드 장애를 포함한 절대 무중단이나 모든 요청의 2초 완료는 보장할 수 없다. 중앙 서비스와 연결이 모두 끊기면 단말 간 전달은 멈춘다. 이때 미전송을 명확히 표시하고 보관·재전송하며, 전달 완료로 표시하지 않는다. 이 한계를 숨기는 대신 장애 상황도 가용성·지연 실패로 계수한다.

## 2. 근거와 미확인 사항

기준 소스: 배포 릴리스 worktree의 `82baead2c90df54f5dfca465147eb1d2fec7d5e3`.

| 관찰 | 상태 | 계획에 반영 |
| --- | --- | --- |
| legacy 전달 안전 갱신이 기존 비연결 1초/연결 5초에서 양쪽 30초±5초로 변경 | 소스 확인 | 실시간 누락 시 평균 약 15초 기다리는 경로 제거 |
| 운영 KDS rollout 설정 0행 | 운영 읽기 확인 | v2 구현과 운영 활성화를 구분; 검증 없이 active 전환 금지 |
| 클라이언트가 구독하는 actions/events 두 테이블의 Realtime publication 등록 누락 | 운영 읽기 확인 | 구독 계약 자동 대조 및 실제 이벤트 수신 시험 |
| 세 전달 batch 함수 모두 품목 루프·수량 루프·단건 처리 함수 호출 존재 | 운영 함수 정의 확인 | 세 함수와 전체 호출·트리거 경로를 집합 처리로 전환 |
| `emergency_enrich_start_ready_orders`는 SQL 집합 처리로 변경됨 | 운영 함수 정의 확인 | 기존 최적화를 재사용하되 전체 N+1 제거 완료로 보지 않음 |
| 전달 함수 누적 평균 약 390~495ms, 최대 약 6.4~7.3초 | 선행 운영 누적 통계 | 평균만으로 서버 정상 판정 금지; 새 관찰 구간 p95/p99 측정 |
| DB `max_connections=60`, 약 480MB, client backend 21개, lock waiter 0 | 2026-09-20 01:21 UTC 단일 표본 | 현재 CPU/IO 병목 또는 500매장 용량의 증거가 아님 |
| 프로젝트 Singapore, PostgreSQL 17, 조직 Pro, ACTIVE_HEALTHY | 관리 API 확인 | 실제 compute·메시지·접속·join 한도는 별도 확인 필요 |
| 기존 부하 스크립트는 축소 스키마, 20초, 최대 100매장, 실 Realtime·쓰기·브라우저 미포함 | 소스 확인 | 500매장 인증 도구로 재사용하지 않고 새 시나리오 추가 |

publication 누락은 확정 결함이지만, 해당 단말의 채널 전체 실패 여부는 아직 WebSocket 기록으로 직접 확인하지 않았다. 주문/대기열의 동일 DB 시각은 같은 트랜잭션의 `now()`일 수 있으므로 실제 처리시간 0ms의 증거로 사용하지 않는다. 원인 조사에서는 단말 요청·구독 상태·화면 갱신을 동일 command ID로 연결한다.

미확인: 실제 매장별 피크, 온라인 단말/채널 수, CPU/RAM/IOPS, pool 대기, WAL/Realtime 지연, 프로젝트별 적용 quota, spend cap, PITR·복구 계약 및 비용. 단계 0 산출물에 반드시 채운다.

## 3. 성공 기준과 측정 방법

| 항목 | 필수 통과 기준 |
| --- | --- |
| 정상/지원 피크의 각 전달 단계 | 클릭→해당 수신 화면 실제 표시 p95 ≤1초, p99 ≤2초 |
| 지연 실패 | 2초 초과·타임아웃·화면 미반영을 전부 기록. 성공 표본만으로 백분위 계산 금지 |
| DB 처리 예산 | 핵심 전달 mutation p95 ≤150ms, p99 ≤400ms를 내부 목표로 사용 |
| SQL 구조 | 입력 1/10/100/1000개 또는 수량 증가로 SQL 실행 횟수가 선형 증가하는 경로 0 |
| 정상 idle | 전체 snapshot/completed 반복 조회 0회. 작은 revision 확인만 허용 |
| 정합성 | 시험 중 확정 주문 유실·수량 중복·중복 결제·타 매장 노출 0건 |
| 가용성 | 핵심 주문·전달 API 월 99.95% 목표. 30일 기준 실패 예산 약 21.6분 |
| 장애 감지 | active 전달 2초 초과 즉시 계측, 지속 장애 1분 내 경보, 담당자 5분 내 인지 |
| 복구 | REST 정상/WS 장애는 별도 2초 전달 시험. DB·전체 서비스 장애는 복구 SLO로 판정 |

2초는 백분위 기반 서비스 목표이며 한 건도 초과하지 않는다는 주장이 아니다. 2초를 넘긴 개별 건도 누락 없이 추적한다. 장애 표본을 제거해 정상처럼 보이게 하지 않는다. 단계별·매장별·단말별 분포를 함께 본다.

클릭 ID, 서버 접수, transaction commit, 이벤트 발행, 수신, 상태 반영, 첫 실제 렌더 프레임을 연결한다. 렌더 뒤 수신 확인을 보내고 업무 ACK와 표시 ACK를 구분한다. 여러 수신자가 필수인 동작은 모든 필수 역할의 반영을 측정한다. 각 역할의 접속 대상/활성 단말 정의를 고정하고 오프라인 단말을 성공으로 분류하지 않는다.

서로 다른 단말의 시계를 단순 차감하지 않는다. 시험 harness의 공통 시간축/왕복 확인, 단말 monotonic clock, 동기화 오차를 사용한다. DB `now()`와 commit 시각도 구분한다. p99를 단계별로 더한 값은 전체 p99가 아니므로 end-to-end를 직접 측정한다.

설계 예산 예: 입력/직렬화 100ms, 요청·인증·네트워크 250ms, DB 400ms, 이벤트 250ms, 필요한 변경 묶음 조회 500ms, 렌더 200ms, 여유 300ms = 2초. 실제 측정으로 재분배하며 합격 기준은 완화하지 않는다.

## 4. SQL N+1 제거: 조회부터 쓰기·트리거까지

우선 변경 대상:

1. `kds_complete_kitchen_batch_v1`
2. `kds_dispatch_tray_floor_batch_v1`
3. `kds_complete_customer_delivery_batch_v1`
4. 이들이 호출하는 progress 함수, combo 부모 수량 집계, ready-lot 할당, event/sequence 생성, 알림 트리거
5. 고객 주문 생성→fulfillment 생성 트리거, snapshot/completed/timing/bootstrap/delta/ticket 조회

처리 방법:

- 입력 JSON을 한 번 관계형 집합으로 파싱한다. 중복 ID·음수 수량·매장·역할·층·workflow 검증을 일괄 수행한다.
- 필요한 행을 정해진 테이블/키 순서로 잠그고, 잠금 획득 후 수량·버전을 재검증한다. 임의 `SKIP LOCKED`로 주문 일부를 누락시키지 않는다.
- `UPDATE ... FROM`, `INSERT ... SELECT`, JOIN, GROUP BY 및 윈도 함수를 사용해 품목과 수량을 일괄 처리한다.
- 수량 100개를 처리하기 위해 단건 함수 100회 호출하지 않는다. 수량·원장 행은 집합 연산으로 만들고 기존 이벤트·감사 계약을 보존한다.
- combo 부모 수량은 영향받은 부모 ID 집합만 그룹 집계해 갱신한다. 전체 매장을 스캔하지 않는다.
- FIFO와 부분 전달은 누적합/순서 기반 배분으로 구현하고, 앞선 주문을 건너뛰거나 새 도착분을 잘못 포함하지 않도록 검증한다.
- sequence는 필요한 범위를 원자적으로 한 번 예약한다. 품목별 매장 sequence 행 갱신 및 잠금 경합을 없앤다.
- 업무 변경, idempotency 결과, 복구용 change log/outbox를 같은 짧은 transaction에 저장한다. transaction 안에서 외부 HTTP·수신 ACK를 기다리지 않는다.
- 행별 trigger가 내부 SELECT/UPDATE를 반복하는 숨은 N+1도 제거한다. 가능한 경로는 statement trigger의 transition table 또는 명시적 일괄 함수를 사용한다. 기존 업무 감사·알림 의미는 보존한다.
- 대형 JSON을 루프마다 이어 붙이지 않고 마지막에 집계한다. `SELECT 단건함수(id) FROM 여러행`으로 루프를 숨기는 변경도 금지한다.
- 동일 idempotency 키에는 최초 결과를 반환하고, 다른 payload 재사용은 거절한다. 중간 오류 시 전부 rollback한다. timeout 뒤 재시도는 동일 키만 사용한다.

검증은 함수 문자열 검색만으로 끝내지 않는다. staging의 `pg_stat_statements.track=all`, 내부 실행 추적, EXPLAIN (ANALYZE, BUFFERS)로 하위 함수·트리거까지 실행 횟수와 시간·WAL·잠금을 측정한다. 고정 업무 분기별 SQL 실행 횟수 상한을 정하고 N/수량에 따라 증가하면 FAIL이다. 처리 행 수와 index 연산량이 증가하는 것은 자연스러운 비용이며 SQL N+1과 구분한다. PostgreSQL 실행계획의 정상 Nested Loop 자체를 금지하지 않는다.

현재 허용 batch 최대치도 시험한다. 최대치를 낮추거나 일부 품목을 잘라내는 방법으로 성능 합격을 만들지 않는다. 최대 요청 계약을 바꿀 필요가 생기면 UI·원자성·호환성까지 별도 설계 변경으로 기록한다.

## 5. 중앙 실시간 전달과 2초 복구

기본 경로: 업무 RPC → 원자적 DB 확정+change log → 매장·station·floor별 private Broadcast → 영향받은 티켓 묶음 반영 → 렌더 수신 확인.

- 먼저 legacy 구독과 publication/RLS/grant를 자동 대조하고 실제 운영 역할로 이벤트 수신을 재현한다. 이 긴급 수정만으로 500매장 준비 완료라고 판단하지 않는다.
- 기존 v2 private Broadcast와 영속 revision을 재사용한다. 구성 조회, 초기화, delta, mutation 응답이 동일 최신 workflow 계약을 사용해야 한다.
- 이벤트 수신마다 단건 ticket RPC를 순차 호출하는 구조를 없앤다. 짧은 20~50ms 병합 창, 중복 ID 제거, batch ticket/delta 조회와 단일 실행 보호를 적용한다. 한창 바쁠 때 debounce가 계속 미뤄지지 않게 최대 지연을 둔다.
- 가능하면 권한으로 제한된 변경 projection을 이벤트/명령 응답에 포함해 즉시 반영한다. 누락·큰 payload는 batch delta로 보충한다. 이름·수량·취소·삭제·FIFO 정렬·다국어·combo 필드 누락을 계약 시험한다.
- 새 주문·초기 연결·재접속·화면 복귀에 subscription와 snapshot 사이 공백이 없어야 한다. consistent revision 경계, epoch, tombstone을 사용한다. 화면 cache와 cursor는 원자적으로 맞추거나 재시작 때 bootstrap한다.
- subscriber의 연결 성공은 전달 성공이 아니다. command/revision별 렌더 ACK를 짧게 묶어 처리하고 미확인 대상만 재전송한다. ACK는 financial/fulfillment transaction을 막지 않는다.
- 중앙 전달 확인 작업은 100~200ms 단위의 bounded batch로 동작하도록 설계·측정한다. 분 단위 cron으로 2초를 맞추려 하지 않는다. 기존 플랫폼에서 지속 실행 조건을 못 맞추면 중앙 관리형 worker를 복수 인스턴스로 운영한다. 이는 매장 장비가 아니다.
- 발행은 재시도 가능하고 소비는 멱등적이어야 한다. 네트워크 exactly-once를 가정하지 않는다. 영속 change log가 진실이며 Broadcast 성공만으로 주문을 삭제하지 않는다.
- 채널 실패·구독 누락·ACK 지연을 명시적으로 감지한다. 단말 상태는 정상/실시간 저하/서버 저하/오프라인을 구분한다. debug 로그에만 남기는 실패는 금지한다.

복구 정책:

| 상태 | 동작 | 성능 판정 |
| --- | --- | --- |
| 정상 | 이벤트 즉시 반영, 30~60초 작은 watermark 검사 | 1초 목표/2초 기준 |
| 단일 이벤트 누락, 연결 살아 있음 | ACK 누락 감지→동일 revision 재전송 또는 누락 delta 유도 | 30초 watchdog을 기다리지 않고 2초 목표에 포함 |
| WS 장애, 업무 HTTP 정상 | 0.5~1초 경량 revision 확인+변경 있을 때만 batch delta; 재연결 병행 | 전체 500매장 동시 장애 부하에서 2초 별도 시험 |
| HTTP도 저하/429/5xx | 요청 admission 제한, 동일 ID의 backoff+jitter, 지속 보관, 미전달 표시 | degraded로 집계; 2초 성공으로 숨기지 않음 |
| 재연결·서버 복구 | 최신 epoch와 누락 revision부터 제한된 묶음 복구; 최신 업무 우선 | 복구 폭주·중복·누락 시험 |

경량 revision 확인도 공짜가 아니다. 예를 들어 KDS 3,000대의 1초 확인은 최대 3,000 HTTP 요청/초를 추가한다. 실제 단말 수와 active 대상에 맞춰 예산에 합산한다. 서버는 동일 store/epoch watermark 조회를 짧게 합칠 수 있으나 인증·권한·지연 한계를 유지한다. 기본 DB 경로가 WS 장애 시험을 통과하지 못하면 중앙 캐시/공유 조회로 DB 접근을 묶는 구현을 먼저 완료한다. 재시도 부하가 감당되지 않는 상태로 출시하거나 전체 snapshot 1초 반복으로 대체하지 않는다.

ACK 재시도·누락 알림 자체가 폭주하지 않게 명령별 재전송 수·byte·연령·대기열 상한, 매장별 공정성을 둔다. 1초 내 완료가 예상되는 최초 전달 경로와 지속 장애 backoff를 분리한다.

완료 이력·타이밍·통계 재조회는 중요 화면 표시와 버튼 완료를 막지 않도록 별도 처리한다. active 티켓은 누락 없는 제한 페이지, 완료 이력은 요청 시 keyset 페이지로 읽는다.

## 6. 500매장 용량 계약과 서버 보호

다음은 측정 전 최소 시험 가정이다. 실제 피크가 크면 상향한다. 매장 수만 500으로 만들고 실제 주문은 몇 개 매장에만 보내는 시험은 인정하지 않는다.

| 부하 | 기본/지속 피크 | 여유·폭주 시험 |
| --- | --- | --- |
| 직원 단말 | 매장당 10대, 총 5,000대 | 10,000대 |
| QR 고객 활성 세션 | 매장당 30명, 총 15,000명 | 30,000명 |
| 실시간 접속 | 직원+고객 추적 합계 7,500 socket 가정 | 15,000 socket |
| 업무 쓰기 | 정상 250건/초, 지속 피크 500건/초 6시간 | 1,000건/초 30분 |
| 데이터 | 150,000주문/일 가정 | 180일 주문 2,700만·품목 1억800만 |
| 매장 쏠림 | 상위 10% 매장이 쓰기의 50% | 1개 매장 과부하 중 나머지 499개 SLO 유지 |
| 실시간 장애 | WS만 전체 단절, HTTP 정상 | 경량 fallback+동시 재가입 30분 |

쓰기 외의 menu/status/read, Auth 갱신, retry, 렌더 ACK, missed-event 확인, background job도 별도 합산한다. 예약업무와 신규 주문을 동시에 시험한다. 원래 지원 피크의 실패를 과부하 거절로 분류해 숨기지 않는다.

인프라 선정은 DB CPU/RAM/IOPS/latency/WAL, pool queue, Realtime message/join/connection, API timeout을 관측한 뒤 정한다. 현재 max_connections 60으로 500매장을 승인하지 않으며 연결 수만 늘리지 않는다. connection pooling과 동시 실행 예산을 함께 조정한다.

메시지 예산은 `명령/초 × 변화 이벤트 증폭 × 실제 수신자 수 + ACK + retry + heartbeat + join`으로 계산한다. 최소 예시에서도 500×2×4=4,000 수신 메시지/초이며 ACK 등은 추가다. 공식 Pro/Team 기본 한도 표만으로 충분하다고 가정할 수 없다. 실제 프로젝트의 quota/spend cap·증설 승인·비용을 확정하고 시험량의 1.5배 여유를 확보한다. [Realtime limits](https://supabase.com/docs/guides/realtime/limits)

보호 조치:

- 정상 피크 CPU·pool·메시지 한도 목표 사용률 65% 이하, 지속 상승하는 대기열/메모리 없음. 메모리는 고정 비율만 보지 않고 reclaim/압박/OOM을 함께 본다.
- 주문·전달·결제를 높은 우선순위로 두고 report/export/import·정산·통계·MISA 작업의 동시성과 처리량을 제한한다. MISA 장애가 결제 완료를 막지 않는다.
- 매장별·계정별 서버 측 rate/concurrency/최대 payload/최대 작업량을 제한한다. 무한 대기 대신 명확한 과부하 응답과 재시도 시점을 준다. 읽기 cache가 권한을 우회하지 않게 한다.
- 전역 및 매장별 retry budget, single-flight, 지수 backoff+jitter, Retry-After를 적용한다. 느릴수록 요청이 증가하는 구조를 금지한다.
- 짧은 transaction, 고정 lock 순서, 업무별 statement/lock timeout을 사용한다. timeout은 미확정 상태일 수 있으므로 원장을 조회한다.
- hot 경로 인덱스를 실제 predicate와 EXPLAIN으로 결정한다. 대형 index는 잠금 최소화 절차로 생성하고 write amplification을 측정한다.
- 활성 주문과 대량 이력 읽기를 분리하고 로그·ACK·outbox의 TTL/보관/정리를 설계한다. 늦은 단말 복구를 위한 보존기간과 만료 후 bootstrap을 연결한다. 저장 공간·WAL·vacuum·bloat를 경보한다.
- 보고서용 read replica는 필요할 때 도입한다. 최신 주문/전달/결제 확인은 primary를 사용한다. read replica는 비동기·읽기 전용이며 Auth/Realtime 가용성을 해결하지 않는다. [Read replicas](https://supabase.com/docs/guides/platform/read-replicas)
- 단일 프로젝트가 시험을 통과하지 못하면 compute/quota·SQL·background 분리 순서로 해결한다. 그래도 한계가 확인될 때만 중앙 cell 분리를 별도 ADR로 설계한다. Office가 의존하는 기존 restaurants 계약을 깨뜨리는 임의 분할은 금지한다.

## 7. 중앙 장애 대응과 데이터 안전

앱·발행 worker는 복수 인스턴스, health check, 자동 재시작, 배포 중 점진 교체를 지원한다. DB의 실제 primary 장애 복구/고가용성 기능은 공급자의 지원 범위와 계약으로 확인한다. read replica를 만들었다는 이유로 자동 쓰기 failover가 된다고 보고하지 않는다.

- DB 확정 뒤 응답이 사라져도 command ID로 결과를 조회한다. 중복 결제·수량 증가를 막는다.
- 단말 대기열은 durable 저장 성공 뒤에만 저장 완료를 표시하고 server ACK 전 삭제하지 않는다. 앱 재시작·다중 탭·권한/매장 변경·저장소 full/corrupt를 처리한다.
- 서버 접수, 수신 단말 표시, 직원의 실제 업무 완료를 구분한다. 오프라인 단말 대신 표시 ACK를 만들지 않는다.
- 한 Realtime 인스턴스/worker 실패는 다른 인스턴스와 HTTP 경로로 복구한다. 공통 DB/API 장애까지 같은 장치가 해결한다고 가정하지 않는다.
- 중앙 전체 장애 때 기존 단말은 마지막 화면과 미전송을 표시한다. 네트워크 단절 동안 다른 단말에 전달되었다고 표시하지 않는다. 온라인 결제 승인을 추측하지 않는다.
- PITR 및 독립 보관 백업, schema/RLS/함수/설정·Auth·Storage 객체 복원 절차를 마련한다. DB 백업에는 Storage 실제 객체가 포함되지 않는다. [Database backups](https://supabase.com/docs/guides/platform/backups)
- 재해 목표는 RPO ≤5분, RTO ≤30분을 시작 기준으로 두고 500매장 데이터로 복원 실측한다. 이는 일반 요청 재시도에서의 확정 거래 유실 0과 다르다. 더 강한 RPO가 필요하면 독립 복제·원장 대사와 추가 비용이 필요하다.
- 복구 전 primary를 하나로 확정하고 쓰기 fencing→복제/복원 검증→연결 전환→원장 대사→재개 순으로 진행한다. 두 primary가 동시에 주문·결제를 처리하지 않도록 한다.
- 재해 한 번이 월 99.95% 오류 예산을 초과하면 실제 SLO 실패다. 별도 복구 목표를 이유로 가용성 통계에서 제외하지 않는다.

비용 산출물: DB compute/IO/storage, Realtime quota/message/egress, 필요 중앙 worker/cache/replica, PITR·독립 백업·복원 훈련, staging 부하시험, 지표 보관. 계획 단계에서는 유료 변경을 실행하지 않는다.

## 8. 실행 순서와 단계별 완료 조건

| 단계 | 담당 역할 | 구체 산출물 | 통과 조건 |
| --- | --- | --- | --- |
| 0. 재현·계측 | Flutter + DB + 운영 | 각 전달 구간 trace, 운영 역할 구독 실패 재현, quota/자원·피크 기준선 | 원인 가설과 증거 분리, 재현 가능한 테스트 |
| 1. 현재 지연 긴급 복구 | Flutter + DB | publication/RLS 정합성, 채널 오류 표시·복구, 변경 묶음 갱신 | 실제 다중 단말 전 단계 2초, 전체 1초 snapshot 없음 |
| 2. SQL 일괄화 | DB | 세 mutation과 주문 생성·조회·하위 함수·트리거 call graph 개선 | N+1 실행 횟수 게이트 및 모든 업무 동일성 PASS |
| 3. 실시간·복구 완성 | Flutter + API/DB | 최신 v2, batch delta, 렌더 ACK·bounded resend, WS 장애 HTTP 경로 | 중복/역순/누락/재시작/권한 회수/정렬 시험 PASS |
| 4. 서버 용량·보호 | 운영 + API/DB | 사양·quota 예산, workload 격리, retry/admission, 대시보드·경보 | 계획된 지원 피크와 장애 fallback 모두 수용 |
| 5. 500매장 인증 | QA/성능 + 운영 | 전체 스키마·실 SDK·RLS·브라우저 시험 결과 | §9 전체 PASS, 원시 증거 보관 |
| 6. 안전 배포 | release + 매장 운영 | exact-main release, additive migration, 작은 cohort, 검증·rollback | 동일 SHA CI 및 실제 운영 검증 PASS |

1단계 긴급 수정은 나머지 인증보다 먼저 작은 범위로 배포할 수 있다. 그 상태는 지연 긴급 수정 완료이며 500매장 인증 완료가 아니다. 단계 2와 3은 계약을 공유해 진행하고, SQL 정확성과 수신 복구 둘 다 통과한 뒤 전체 용량 시험을 한다.

예상 일정은 단계 0 후 확정한다. Flutter 1명·DB/API 1명·성능/QA 1명·운영 담당을 가정할 때 긴급 경로는 수일, 전체 구현·용량/복원 검증은 수주 단위이며 6~10주를 초기 산정 범위로 둔다. 인력·시험환경·인프라 승인에 따라 달라진다. 관측기간이나 실패 게이트를 일정 때문에 생략하지 않는다.

## 9. 필수 시험과 출시 차단 기준

모든 대규모 부하·장애·복원 시험은 운영과 분리된 staging에서 한다. harness는 운영 project/host를 거부하고 합성·익명화 데이터를 사용한다. 결제·MISA 외부 사업자에는 시험 부하를 보내지 않는다.

| 시험 | 방법 및 합격 조건 |
| --- | --- |
| 실제 전달 | 주문→주방→체커→층→고객, 실제 Flutter 브라우저/태블릿 화면과 소리·정렬까지; p95/p99 기준 |
| N+1 | 1/10/100/1000 품목·수량, nested SQL/trigger 실행 횟수 비교; 입력당 추가 SQL 반복 0 |
| 업무 정확성 | 부분 전달, combo, floor_direct, 취소·되돌리기, FIFO, 중복 클릭, 새 주문 동시 유입, 매장·floor·권한 경계 |
| 동시성 | 같은 품목 2단말, 다른 주문/매장 병행, DB commit 후 응답 유실, 잠금 충돌; 초과 수량/중복 0 |
| 실시간 실패 | 구독 실패, publication 누락, 연결 성공 뒤 무음 유실, ACK만 유실, 중복·역순, token 만료; 30초 대기 재현 금지 |
| 규모 증가 | 10→50→100→250→500 매장, 각 30분 이상; 실제 JWT/RLS·쓰기·읽기·Realtime 동시 |
| 지속 peak | 500매장 500명령/초 6시간, 2초 전달 기준과 자원 여유 충족 |
| 2배 burst | 1,000명령/초 30분+15,000 socket; 지원 범위 SLO와 서버 보호·복구 확인 |
| soak | 최소 72시간, 일자 변경 및 21:30/21:45/22:20/23:00 업무 포함; 누수·로그·vacuum·자원 증가 검사 |
| WS 전체 장애 | HTTP 정상 상태에서 모든 WS 중단 30분, 경량 복구 요청까지 합쳐 2초 목표·DB 안정성 확인 |
| 재접속 폭주 | 15,000 socket 재가입, 실제 channel join 수·quota 검증; 95% 주요 화면 60초/전체 120초 내 정합 복구 목표 |
| noisy neighbor | 한 매장 폭주·대형 보고서·배치·외부 연동 지연 중 다른 매장 SLO 유지 |
| 중앙 장애·복원 | worker/Realtime/DB 재시작, connection pool 고갈, disk/WAL 압박, PITR 복원; 원장 대사·RTO/RPO 확인 |
| 배포·rollback | 구/신 앱과 schema 혼재, feature flag·cache·service worker·outbox 호환성, 복귀 뒤 정합성 |

open-loop arrival rate로 입력을 유지해 서버가 느려질수록 시험 부하가 줄어드는 착시를 막는다. 생성기 포화·미완료·거절도 기록한다. 누적 평균 대신 같은 구간의 변화량·histogram·최대 대기·오류를 보관한다. 기존 축소 fixture는 단위 검증에만 쓴다.

중단 조건: 주문 유실·금액/수량 중복·타 매장 노출 1건이면 즉시 FAIL. p99>2초의 연속 관찰 구간, 실패율>0.1%, 지속 대기열 증가, 정상 peak 자원/한도 여유 부족, N+1 발견이면 다음 단계·규모 확대를 차단한다. 짧은 표본 p99는 성공 근거로 쓰지 않고 최소 표본 수/관찰기간을 결과에 명시한다.

## 10. 배포·운영 인수

- 새 release 작업은 최신 원격 main과 정확히 같은 깨끗한 별도 worktree에서 시작한다. 기존 dirty·untracked 사용자 작업을 복사하거나 삭제하지 않는다.
- additive migration, preflight/verify/rollback, schema cache와 앱 호환성 시험을 준비한다. 큰 index 변경은 별도 안전 절차를 사용한다.
- `scripts/deploy_pos_production.sh`를 사용하고 정확한 pushed SHA의 GitHub 필수 check 통과를 확인한다. 로컬 테스트만으로 release PASS라 하지 않는다.
- 개발/SAMPLE→실매장 1곳→현재 운영 매장 순으로 적용한다. pilot은 peak/마감 포함 최소 48시간 확인한다. 실제 존재하지 않는 500매장 배포를 계획하지 않는다.
- 미래 확장 50/100/250/500 단계마다 인증 부하와 실제 지표를 재대조한다. 현재 확인된 작은 매장의 성공을 500매장 검증으로 대체하지 않는다.
- 전달 rollout은 legacy→제한 shadow→active. shadow는 추가 조회 비용을 제한한다. 동일 revision에서 수량·순서·권한·최신 batch 계약을 비교한다.
- rollback은 이미 기록한 주문·이벤트를 지우지 않고 호환 앱/기능 flag로 수행한다. 전체 단말 1초 full polling으로 복귀하는 rollback은 금지한다. 저하 모드 사용 시 SLO 실패와 복구 대기를 명시한다.
- 대시보드: 단계/매장/버전별 클릭→렌더 지연, ACK gap, revision lag, 재시도·outbox 최고 연령, DB 내부 SQL 횟수·latency·CPU/IO/pool/lock, message/join quota, active rollout 상태.
- 관측 ID는 trace 로그에, 낮은 cardinality의 집계만 metric label에 둔다. 토큰·고객 개인정보·결제 비밀은 기록하지 않는다. 경보마다 담당자·원인 확인·완화·복구 절차를 연결한다.
- 인증 보고서는 소스 구현 / DB 적용 / 앱 배포 / 운영 검증 / 500매장 용량 검증을 별도 상태로 표기한다. 계획·코드·migration 존재만으로 완료 처리하지 않는다.

## 11. 구현 시 추적할 위치

- Flutter: `lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart`, `kds_realtime_sync.dart`, 주문/QR/Kitchen provider, 연결 표시·offline queue·웹 저장소.
- DB: 세 batch RPC의 새 migration, 기존 `20260831010000_kds_realtime_v2.sql`의 유효 함수/트리거 대체, 기존 집합 enrichment 재사용, 주문 생성·일괄 ticket/delta RPC 및 필요한 인덱스.
- 검증: `test/kds_realtime_sync_test.dart` 등 기존 회귀를 확장하고 별도 전체 스키마·실 SDK 부하 harness를 추가한다. 단순 소스 문자열 검사와 HTTP 평균값만으로 승인하지 않는다.
- 운영: 생산 배포 스크립트와 SHA 기반 CI, 기존 업무별 preflight/verify/rollback 패턴 재사용. Office의 restaurants 결합점·비동기 MISA·두 정산 경로·Photo 수집 중단 계약 보존.

완료는 2초 전달, N+1 없음, 500매장 피크·실시간 장애 부하, 원장 정합성, 복원 훈련, 단계 배포가 모두 증거로 확인된 상태다. 한 조건이라도 빠지면 검증된 마지막 규모까지만 지원 가능하다고 기록한다.
