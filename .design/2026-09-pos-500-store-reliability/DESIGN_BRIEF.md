# 500개 매장 POS 안정성·성능 개선 계획

작성일: 2026-09-19 · 상태: **계획만 수립, 구현·운영 변경·용량 인증 미실시**

검토 기준: HEAD `cc4de81adb8870fd479cb12edd773cda635a01cd`와 현재 작업 트리. 기존 사용자 수정 및 미추적 파일은 보존한다. 실행 체크리스트는 [TASKS.md](TASKS.md), 시험·배포 승인 기준은 [VALIDATION_PLAN.md](VALIDATION_PLAN.md)를 따른다.

## 1. 결론과 범위

우선순위는 **오프라인 오판 제거 → 과도한 전체 조회와 SQL 비용 제거 → 누락 복구 가능한 실시간 동기화 → POS 전 영역 부하 통제 → 500개 매장 실부하·장애 시험 → 단계 배포**다. 서버 증설과 timeout 연장만으로 완료하지 않는다.

“다시는 발생하지 않음”을 절대적인 무장애 보장으로 표현하지 않는다. 대신 같은 결함이 다시 배포되지 않게 자동 검증하고, 오류를 정확히 표시하며, 장애 때 주문·결제의 중복/유실을 막고, 복구 시간과 확장 한도를 측정한다. 인터넷·전력·클라우드 전체 장애까지 무중단 영업을 요구하면 매장 내 대체 운영 체계가 별도로 필요하다.

이 계획은 기존 Flutter/Supabase 구조를 우선 개선한다. 검증 전에 전체 재작성, 무조건적인 샤딩, 신규 플랫폼 이전을 선택하지 않는다. 다만 단일 프로젝트의 장애가 모든 매장에 영향을 줄 수 있다는 한계는 숨기지 않는다. §8의 복구·매장 비상 운영 게이트를 통과하지 못하면 500개 매장 확대를 승인하지 않는다.

적용 범위: 직원 POS, 주문/결제, KDS/트레이/홀/고객 전달, 고객 디스플레이, QR 주문, 실시간 연결, 인증, 오프라인 대기열, 보고서·배치·외부 연동, 관측·복구·배포. 새 결제 수단이나 업무 정책 변경은 포함하지 않는다.

## 2. 확인된 사실과 아직 증명하지 못한 것

| 구분 | 관찰/소스 증거 | 계획에 반영할 의미 |
| --- | --- | --- |
| 확인 | `connectivity_service.dart`가 `restaurants` REST 조회 실패를 모두 `false`로 처리한다. 웹 5초, native는 외부 3초 race가 먼저 종료하고 내부 요청 timeout은 4초다. 10초마다 반복한다. | 서버 지연·인증 오류도 인터넷 단절로 표시될 수 있다. native를 단순히 “4~5초”로 설명하면 부정확하다. |
| 확인 | KDS legacy/shadow는 연결 정상 시 5초, 비연결 시 1초 간격을 사용한다. 한 갱신에 config/snapshot/completed/timing/mode 조회가 발생한다. 단일 실행 보호와 실패 backoff는 이미 있다. | 기존 보호를 재사용하되, 실시간 연결 장애가 전체 조회 증가로 이어지는 경로를 없앤다. |
| 확인 | v2 소스는 private Broadcast 알림 → 영속 delta → 변경 ticket 조회 방식이다. bootstrap은 여전히 legacy snapshot/completed/timing 함수를 호출한다. | v2 flag만 켜도 모든 비싼 조회가 사라지는 것은 아니다. bootstrap과 재접속도 개선해야 한다. |
| 확인 | `emergency_enrich_start_ready_orders`에 주문별·품목별 SQL 및 JSON 누적 루프가 있다. | 집합 기반 조회 후보. 해당 함수 하나가 전체 지연의 원인이라는 인과관계는 별도 측정한다. |
| 당시 운영 관찰 | 2026-09-19 진단 시 active 매장 8개, KDS rollout 설정 0행. active session 2개, station assignment 7개. | 7개는 온라인 단말 수가 아니다. v2가 소스에 있다는 것과 운영 활성화는 다르다. 실행 시 재확인한다. |
| 당시 운영 관찰 | 약 7일 누적 authenticated SQL 실행시간 중 snapshot/completed 두 함수군 합계가 약 93.4%. completed 평균 약 1.07~1.24초, snapshot 약 0.34~0.57초, 일부 약 8초. | 최우선 최적화 대상. 이 비율은 CPU 점유율도, HTTP p95도 아니다. 변경 전후 동일 시간 구간의 증가분으로 재측정한다. |
| 당시 운영 관찰 | 짧은 HTTP 점검에서 timeout과 이후 성공이 함께 관찰됨. 관리 API DB 조회도 연결 timeout이 관찰됨. 잠금/교착은 샘플에서 없었음. | 실제 지연은 있으나 CPU/IO/연결풀/네트워크/서비스 장애 중 근본 자원 원인은 아직 확정하지 않는다. |
| 확인 | 기존 100매장 시험은 축소 스키마·짧은 읽기 시험이며 p95 약 4.6~4.8초 기록이 있다. | 전체 업무, 실제 JWT/RLS/Realtime, 결제 쓰기, 장시간 운영을 검증한 500매장 인증이 아니다. |
| 확인 | 일반 offline mutation queue는 SharedPreferences JSON read-modify-write이고 파싱 오류 시 빈 목록을 반환한다. | 동시 변경·손상·저장 실패·브라우저 데이터 삭제에 대한 내구성을 새로 증명해야 한다. 기존 대기열이 완전한 오프라인 POS라는 주장은 금지한다. |

운영 관찰값은 이 대화의 선행 읽기 전용 진단 기록이며 현재 상태나 성능 인증서가 아니다. 원본 측정 산출물이 없는 수치는 T01에서 재수집해 기준선으로 고정한다. 운영 통계 reset, 무거운 운영 EXPLAIN ANALYZE, 운영 부하시험은 하지 않는다.

주요 소스: `lib/core/services/connectivity_service.dart`, `lib/widgets/offline_banner.dart`, `lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart`, `lib/features/emergency_fulfillment/kds_realtime_sync.dart`, `lib/core/services/offline_mutation_queue_service.dart`, `supabase/migrations/20260831010000_kds_realtime_v2.sql`, `supabase/migrations/20260916190000_kds_start_ready_serve_workflow.sql`.

기존 `.design/2026-08-kds-realtime-scalability/`와 `docs/scalability-remaining-execution.md`의 구현을 재사용하되 과거 PASS를 이번 버전의 PASS로 이월하지 않는다. 9월 18일 트레이→홀→고객 전달 변경 등 사용자 작업은 최신 계약 검증에 포함하되 임의 수정/배포하지 않는다.

## 3. 500개 매장 용량 계약

매장 수만으로 용량을 정하지 않는다. 아래 수치는 **측정 전 설계 가정/최소 시험 범위**다. T01에서 실제 피크가 더 크면 상향한다. 낮추려면 근거와 명시적인 범위 변경이 필요하다.

| 항목 | 500매장 기준 | 인증 스트레스/피크 |
| --- | --- | --- |
| 직원 단말 | 매장당 10대 = 5,000대; 역할별 실제 사용 비율 적용 | 10,000대 접속 |
| 고객 QR 활성 세션 | 매장당 30명 = 15,000명 | 30,000명; 직원 부하와 동시에 |
| 고객 주문추적 실시간 연결 | 위 QR 세션 중 매장당 5명 = 2,500개 | 5,000개; 나머지 QR은 메뉴 열람 등 HTTP 부하 |
| 총 실시간 socket | 직원+추적 = 7,500개 | 15,000개; 한 기기의 여러 탭/클라이언트도 실제로 계수 |
| 업무 쓰기 명령 | 혼잡 시간 평균 250건/초 | 지속 500건/초 6시간, 순간 1,000건/초 30분 |
| 이력 | 300주문/매장/일 × 500 = 150,000주문/일 | 180일: 주문 2,700만, 품목 4개/주문이면 1억800만 |
| 쏠림 | 균등 부하와 별개 | 상위 10% 매장이 쓰기 50%, 1개 매장 폭주 동시 주입 |

쓰기 명령 혼합의 시작점: 주문/추가/취소 25%, 결제/결과확인 15%, 조리/준비/인계/전달 50%, 기타 운영 10%. 오류 재시도, 인증 갱신, 메뉴·테이블 읽기, report, webhook, cron은 이 명령 수와 별도로 합산한다. 실제 업무 시퀀스가 먼저이며 비율 때문에 불가능한 상태를 만들지 않는다.

예시 요청 예산:

- KDS형 화면 3,000개가 5초마다 5회 RPC하면 초당 약 3,000회, 1초 간격이면 약 15,000회다. 이는 실제 현재 RPS가 아니라 제거할 구조적 상한 예시다.
- 개선 후 정상 idle 상태의 full snapshot/completed 반복 조회는 0회. 30초 jitter watchdog 3,000개는 평균 약 100회/초의 작은 조회다. 더 긴 주기는 조용한 이벤트 누락 감지 SLO와 함께 결정한다.
- 변경이 많은 상황에서는 delta와 ticket 조회도 큰 부하다. 티켓 ID 배치, 같은 ID 병합, 한 번 실행+한 번 후속 실행, byte/row 상한을 서버와 클라이언트 양쪽에서 적용한다.
- 일반 QR 메뉴는 버전 기반 CDN/캐시를 사용하고, 권한·가격·재고는 주문 확정 시 서버에서 재검증한다. 주문별 개인정보/접근 토큰은 공유 캐시에 넣지 않는다. 고객 추적을 15,000명 전체의 1~2초 polling으로 대체하지 않는다.

Realtime 예산은 `명령/초 × 명령당 이벤트 증폭 A × 수신자 fan-out F`에 발신·control·presence·재접속 메시지를 더해 산정한다. 원본 row trigger가 여러 번 발생하므로 A=1을 가정하지 않는다. 예비 예산 A=2, F=4, burst F=10이면 보수적 발신 포함 burst는 `1,000×2×(10+1)=22,000 messages/s`다. 제어 여유 2,000을 포함한 24,000의 1.5배인 **36,000 messages/s**, 15,000 socket의 1.5배인 **22,500 connections**를 초기 상한 협의값으로 둔다. 실제 A/F와 공급자 계수로 확정하며 무조건 구매하는 수치는 아니다. 정상 피크 자원 사용률은 65% 이하를 목표로 한다.

현재 공식 문서의 Pro(no spend cap)/Team 기본 Realtime 한도는 10,000 connections, 2,500 messages/s이며 초과하면 연결이 끊길 수 있다. 따라서 “유료 요금제니까 충분”으로 승인하지 않는다. 실제 프로젝트 한도·join 속도·지원 증설 승인과 비용을 확인한다. [Supabase Realtime limits](https://supabase.com/docs/guides/realtime/limits)

## 4. 사용자 체감·안전성 합격 기준

아래는 목표이며 현재 달성했다는 뜻이 아니다. 정상 서비스 기준은 실제 베트남 매장 네트워크의 역할별 end-to-end 측정이며 외부 결제망 승인 대기시간은 별도 표시한다.

| 항목 | 승인 목표 |
| --- | --- |
| 주문 서버 확정 | p95 ≤ 1초, p99 ≤ 2초 |
| POS 내부 결제 트랜잭션 확정 | p95 ≤ 2초, p99 ≤ 4초; 외부 승인과 분리 |
| KDS 동작 ACK | p95 ≤ 800ms, p99 ≤ 2초 |
| 다른 단말 변경 반영 | DB commit→화면 p95 ≤ 1초, p99 ≤ 3초 |
| KDS bootstrap | 최초 50티켓 페이지 p95 ≤ 1초/100KB 목표; 활성 100티켓 전체 동기화 p95 ≤ 2초 |
| 조용한 이벤트 유실 감지 | watchdog 포함 45초 이내; 감지 후 100개 delta 적용 p95 ≤ 3초 |
| 재접속 폭주 복구 | 15,000 socket 복구, 중요 화면 동기화 95% ≤ 60초, 전체 ≤ 120초; 부하시험으로 확인 |
| 기술 실패율 | 정상·지속 피크에서 0.1% 미만; 의도된 업무 거절과 별도 집계 |
| 안전성 | 시험 중 확정 주문 유실, 중복 결제, 타 매장 데이터 노출 0건; 1건이면 즉시 FAIL |
| 연결 표시 | 서버 지연/401/403/429/5xx 시험을 “인터넷 끊김”으로 오표시 0건 |
| 월 가용성 목표 | 중요 주문/결제 API 99.95%; 30일 오류 예산 약 21.6분. 외부 장애도 사용자 체감 집계에서 숨기지 않음 |

큰 주문·500개 활성 티켓은 별도 payload/시간 한도를 정하고 시험한다. 빠르게 보이게 하려고 활성 주문을 잘라내거나 부분 결과를 전체 목록처럼 표시하지 않는다. 서비스 불능 burst에서는 대기/재시도를 명확히 표시하고 bounded admission을 적용하며 결제 결과를 추측하지 않는다.

## 5. P0: 잘못된 오프라인 판정과 중복 실행 제거

1. boolean을 `unknown / online / networkUnavailable / serverDegraded / authRequired / realtimeDegraded`로 교체한다. 네트워크 신호는 힌트다. 실제 HTTP 401/403/429/5xx는 인터넷 연결 부재의 증거가 아니다. 권한 거절은 작업 오류로, 401은 필요 시 1회 갱신 후 재인증으로 처리한다.
2. 일반 업무 요청 성공/실패를 재사용한다. `restaurants`를 10초마다 읽는 연결 검사를 제거한다. 필요할 때만 개인정보 없는 가벼운 health 확인을 쓰며 그것도 전체 서비스 건강의 증명으로 삼지 않는다.
3. 단발 timeout은 “서버 응답 지연”으로 표시한다. 상태 전환 debounce/hysteresis, 성공 시 회복, 백그라운드·절전·복귀 처리와 KO/EN/VI 문구를 함께 구현한다. 이전 성공 시각과 미전송 건수를 표시한다.
4. 화면 정책을 분리한다: 읽기 캐시는 stale 표시, 안전한 주문만 대기열, 금전 작업은 서버 확정/확인 상태. 상태 enum 변경으로 권한 검사나 결제 검증을 우회하지 않는다. `connectivityProvider`의 모든 소비자를 전수 전환한다.
5. 요청별 deadline·세대 번호·단일 실행을 둔다. Dart timeout만으로 서버 작업이 취소됐다고 가정하지 않는다. 늦은 응답이 새 상태를 덮지 못하게 하고 쓰기는 같은 command ID로 결과 조회/재시도한다.
6. 전역·매장·단말 retry budget, 지수 backoff+jitter, 429 Retry-After, circuit breaker를 적용한다. 오류일수록 full polling을 빠르게 하지 않는다. 구버전 단말/다중 탭의 폭주도 관측한다.

## 6. P1: SQL·동기화 구조 개선

### 6.1 비싼 조회를 작은 집합 조회로 바꾸기

- 운영에서 낮은 비용의 지표를 수집하고, 익명화 복제 데이터의 staging에서 실제 JWT/RLS로 EXPLAIN (ANALYZE, BUFFERS)를 수행한다. 함수 wrapper 전체와 내부 세부 쿼리를 구분한다.
- 주문/품목/ready lot를 한 번에 모아 join/aggregate한다. JSON의 정렬·null·수량·취소·combo·floor_direct·배달·포장·잔여수량·다국어·업무일 의미를 차등 테스트한다.
- completed는 DB 단계에서 business-day 조건과 keyset 페이지를 적용한다. 오늘 전체 이력을 매번 만드는 구조를 없애고, 화면 카운트·타이밍은 별도 작은 aggregate로 유지한다. 재열기/취소/정정 동작도 반영한다.
- 인덱스는 실제 predicate, 선택도, 정렬과 계획으로 결정한다. 기존 인덱스 중복, write amplification, migration lock을 확인한다. 큰 테이블은 별도 concurrent-build 절차와 실패 후 invalid index 정리를 설계한다.
- read RPC는 업무 상태나 live event를 생성하지 않는다. 권한 필터를 늦게 적용해 전체 매장을 읽지 않는다. `SECURITY DEFINER`의 scope 검증·고정 search_path·실행 권한을 검증한다.
- 집합 조회로 목표를 못 맞춘 경우에만 ticket projection을 도입한다. 도입 시 command와 projection의 원자성, 재구축, 원본 대조와 지연 지표가 필수다.

### 6.2 기존 v2의 안전한 완성

- 기존 private Broadcast를 알림으로, DB change log를 복구 원장으로 유지한다. 알림 수신만으로 업무 상태 확정을 추측하지 않는다. Broadcast는 확장에 권장되는 방식이지만 영속 복구/권한 설계는 애플리케이션 책임이다. [Supabase database changes](https://supabase.com/docs/guides/realtime/subscribing-to-database-changes)
- bootstrap, ticket, delta, mutation ACK, shadow compare가 최신 workflow와 같은 필드를 반환하도록 계약을 고정한다. 특히 start/ready/serve 및 트레이→홀→고객 전달 batch를 포함한다.
- DB 변경과 change log는 같은 트랜잭션에 기록한다. 매장별 revision 직렬화는 매장 간 공용 잠금으로 번지지 않아야 한다. 동일 매장의 대형 주문 contention도 측정한다.
- 중복·역순·누락·삭제·세션 교체·권한 회수·매장 변경을 처리한다. cursor는 현재 데이터 캐시와 일치하는 범위까지만 전진한다. 저장 cursor만 앞서 있고 화면 캐시는 사라진 재시작을 복구한다.
- bootstrap 중 변경이 생겨도 snapshot의 경계 revision 이후 delta로 정확하게 수렴해야 한다. 권한상 보이지 않는 revision 간격은 정상 진행으로 처리하고 진짜 보존기간 만료와 구분한다.
- delta 페이지 및 ticket 다건 API에 rows/bytes/work 상한을 둔다. 많은 변경을 한 ticket 단위로 병합하되 서로 다른 주문의 진행 순서와 업무 알림은 보존한다.
- 정상 idle에 legacy full poll 0회. 30초 전후 jitter watchdog은 scope/config/revision만 확인한다. watchdog도 overlap을 막고 화면 dispose·매장 전환 시 정리한다.
- v2 실패 시 즉시 전 매장을 1초 legacy polling으로 보내는 fallback 금지. degraded delta recovery와 점진적 bootstrap을 우선한다. 불가피한 legacy fallback은 §10의 제한 모드만 사용한다.
- legacy→shadow→active를 거친다. 동일 revision에서 의미상 정규화한 결과로 비교하며 timing 값 차이와 업무 필드 차이를 분리한다. 몇 개 샘플이 같다는 이유로 활성화하지 않는다.

### 6.3 POS 전체로 부하 통제 확대

- cashier/waiter/table/customer display/QR/order tracking의 타이머·구독·refresh 호출을 목록화한다. 기존 `live_refresh_service.dart`와 provider single-flight를 재사용한다.
- 주문 변경은 영향받는 ID만, 설정 변경은 해당 캐시만 무효화한다. 이벤트 한 건이 전체 report/menu/catalog를 다시 읽게 하지 않는다. unknown scope일 때만 제한된 정합성 재조회한다.
- 메뉴/이미지는 버전 기반 캐시 및 적절한 크기로 제공한다. store/user/scope/session별 캐시를 분리하고 logout/권한 변경 때 폐기한다.
- SePay/QR/외부 결제 조회, MISA, settlement, report, export, payroll, cron의 동시 실행 예산을 정한다. MISA 비동기 원칙과 두 settlement 함수의 별도 업무 영역을 유지한다.
- 21:30 cutoff, 21:45 grace end, 22:20 finalization, 23:00 cash close 및 일자 변경을 대규모 동시 부하 시험에 포함한다. 일정의 업무 의미를 임의로 바꾸지 않는다.

## 7. P2: 서버 용량·매장 격리·데이터 증가

### 용량 선정

DB 크기 477MB나 max_connections=60이라는 당시 관측으로 compute 크기나 CPU 포화를 단정하지 않는다. 실제 CPU/메모리/IOPS/지연/연결풀 대기/WAL/Realtime lag를 측정한다. shared CPU가 아닌 dedicated compute 후보를 staging에서 비교하고, 지속 피크 여유와 월 비용을 함께 선택한다. 정확한 사양·가격은 구매 시 확인한다. [Supabase compute and disk](https://supabase.com/docs/guides/platform/compute-and-disk)

연결 예산은 `업무 API + Auth + Realtime DB 작업 + Edge/배치 + 운영 예약 < 안전한 DB pool 한도`로 잡는다. WebSocket 7,500개를 DB connection 7,500개로 계산하지 않는다. pool 대기시간과 최대 동시 실행을 측정하며 max_connections만 올리지 않는다. 긴 트랜잭션/idle transaction/statement/lock timeout은 업무 종류별로 시험 후 정한다.

보고서는 사전 집계/캐시를 우선한다. 그래도 영향을 주면 읽기 전용 replica에 지연 허용 report만 보낸다. 결제 직후 확인과 실시간 재고·주방은 primary에 둔다. replica는 비동기이며 GET/읽기 전용 제약이 있고 Auth/Realtime 분산이나 자동 writable failover를 대신하지 않는다. [Supabase read replicas](https://supabase.com/docs/guides/platform/read-replicas)

### 한 매장의 문제를 다른 매장으로 확산시키지 않기

- 요청의 store ID를 믿지 않고 JWT의 실제 accessible-store/role/assignment로 검증한다. 고객은 해당 주문만 볼 수 있는 제한 토큰/권한을 사용하고 직원 범위로 확장하지 않는다.
- 서버 측 비용 큰 API에 매장별·사용자별 rate/concurrency/row/time 한도를 둔다. 1개 매장 폭주에도 다른 499개 매장 중요 API가 SLO를 지키는지 시험한다.
- 클라이언트 제한만으로 보호가 된다고 주장하지 않는다. gateway를 선택하면 기존 직접 REST/RPC 경로가 우회 경로가 되지 않는지 검증해야 한다. service_role을 클라이언트에 노출하거나 RLS를 해제하지 않는다.
- critical 주문/결제, 운영 동기화, report/export의 우선순위와 예산을 분리한다. 과부하 때 보고서부터 지연시킨다. “유실 없이 무조건 수락”하는 무한 대기열 대신 명시적 수락/거절/확인 필요 상태를 사용한다.
- 거대한 전역 잠금/순번/동기식 전매장 집계는 금지한다. 매장별 키와 제한 batch로 처리하되 업무상 동일 주문의 원자성은 보존한다.

### 데이터 수명

예시로 주문당 12개 change event면 180만 event/일, 7일 보존 시 1,260만 event다. event당 1KB라면 payload만 약 12.6GB이며 index/WAL/bloat/백업은 별도다. 실제 이벤트 증폭과 bytes를 측정해 보존기간·partition·vacuum·디스크 예산을 정한다.

delta 복구 보존기간의 시작 목표는 7일. 그보다 오래 끊긴 단말은 안전한 bootstrap으로 복구한다. 오래된 로그 삭제를 위해 결제/회계/감사 원장을 함께 삭제하지 않는다. 금융·개인정보 보존정책은 담당자 검토를 거쳐 별도 확정한다. TTL 작업 자체가 peak 잠금/IO 부하를 만들지 않게 작은 batch/partition 운영을 시험한다.

## 8. P3: 오프라인 내구성·복구·재해 대비

### 거래 안전성

- 주문과 KDS command는 저장 성공이 확인된 후에만 “대기열 저장됨”으로 표시한다. 내구 저장소의 transaction/동시 탭 locking, checksum/schema version, scope, retry metadata를 갖춘다. SharedPreferences 기존 레코드는 검증 가능한 무손실 이관을 한다.
- 서버는 command ID+store+업무 주체에 대한 중복 방지와 동일 결과 재응답을 제공한다. exactly-once 네트워크 전달을 가정하지 않고 at-least-once 재전송에 안전하게 만든다.
- 주문별 인과 순서, 버전 충돌, 가격/재고/권한 변경, 영업일 경계를 처리한다. 재로그인했다고 다른 사용자의 미전송 주문을 자동 실행하지 않는다.
- 결제 timeout은 실패 확정이 아니라 결과 미확인이다. 같은 payment intent/command ID로 원장을 조회하며 새로운 결제를 자동 재실행하지 않는다. `process_payment`의 원자성과 MISA 비동기 계약을 유지한다.
- 저장소 손상은 빈 대기열처럼 숨기지 않는다. 복구/내보내기/운영 알림을 제공한다. clear-cache/강제 로그아웃/앱 교체 전에 미전송 데이터를 보호한다. 물리적 단말 파손까지 보장하려면 다른 장치에 durable 복제가 필요하다.

### 매장 인터넷이 실제로 끊길 때

각 매장은 다른 통신사 보조 회선(4G/5G), 자동 전환, 핵심 장비 UPS, 대체 단말·출력/수기 절차를 갖춘다. 개인정보가 들어 있는 장애 기록은 승인된 경로로만 보관한다. 보조 회선 실제 전환과 인터넷 없이 운영하는 훈련을 한다.

1차 소프트웨어 보장 범위는 캐시 열람·허용된 주문/작업의 안전한 보관·복구 후 재전송이다. 클라우드 연결 없는 여러 단말 간 KDS 전파, 온라인 결제 승인은 보장하지 않는다. 화면에 “저장됨”과 “주방 접수됨”을 명확히 구분한다.

**클라우드 장애 중에도 전 매장 자동 주문→주방 운영을 계속해야 한다면** 로컬 매장 coordinator를 필수 확장 경로로 채택한다. 로컬 journal/프린트·LAN 전달, 한 명의 쓰기 권한자(lease/fencing), UPS·예비 장비, 클라우드 재연결 시 주문/수량/금전 정산, 소프트웨어 서명 업데이트가 필요하다. 은행·카드사 승인 없이 전자결제를 성공 처리하지 않는다. 이 범위는 신규 제품/장비 결정이므로 별도 설계·예산 승인과 실매장 24시간 단절 시험 후에만 “오프라인 다중 단말 영업 지원”으로 표시한다. 이를 선택하지 않으면 수기 비상 운영이라는 한계를 500매장 인수 기준에 기록한다.

### 클라우드 장애와 데이터 복원

- PITR와 별도 보관 백업을 준비하고 정기 복원한다. DB 백업에 Storage 실제 객체가 포함된다고 가정하지 않는다. 설정·권한·함수·Storage·인증·DNS/클라이언트 연결까지 복구 목록에 넣는다. [Supabase backups](https://supabase.com/docs/guides/platform/backups)
- 목표: 단일 서비스 장애 탐지 ≤ 2분, 운영자 인지 ≤ 5분. 재해 데이터 RPO ≤ 5분, core API RTO ≤ 30분을 500매장 데이터 크기에서 실제 복원해 증명한다. 공급자 기능/계약으로 못 맞추면 warm standby 등 추가 구조와 비용을 승인하기 전 확대하지 않는다.
- 일반 요청 재전송/프로세스 재시작에는 확정 거래 유실 0건을 요구한다. 재해 RPO 5분은 최대 그 구간의 복원 공백 가능성을 뜻한다. 결제업체 내역/단말 durable journal과 대사해 복구한다. 독립 복제와 검증 없이 재해까지 RPO=0이라고 홍보하지 않는다.
- 가용성 99.95%와 30분 재해 복구는 다른 기준이다. 재해 한 번으로 월 오류 예산을 초과할 수 있으며 이 경우 SLO 미달로 보고 신규 확장을 중단한다.
- 복구 대상 전환은 쓰기 fencing→복제 지연/원장 확인→단일 primary 확정→연결 전환→정합성 검사→재개 순이다. split-brain/양쪽 동시 결제 금지. replica를 생성했다는 이유만으로 DR 완료 처리하지 않는다.

단일 DB/프로젝트 장애 범위를 반드시 여러 매장 그룹으로 제한해야 한다면 별도 ADR로 cell 분리를 설계한다. 매장→cell routing, 인증, 데이터 이동·cutover·대사, 글로벌 report의 비동기 집계, cell별 독립 배포를 검증한다. `restaurants`의 물리명/필수 컬럼과 Office의 기존 POS 프로젝트 직접 읽기를 보존해야 하며 Office 변경은 별도 명시적 요청 없이는 하지 않는다. 이 호환성을 해결하지 않은 샤딩은 승인하지 않는다.

## 9. 관측과 재발 방지

한 요청에 request/command ID, 익명화 store/device, app/build SHA, RPC, 결과 분류, DNS/connect/server/전체 지연, retry 수를 남긴다. 토큰·결제정보·주문 개인정보를 로그에 기록하지 않는다. 고카디널리티 ID는 metric label 대신 추적 로그에 둔다.

필수 대시보드: 역할·매장별 p50/p95/p99/실패율, DB query 시간 증가분/CPU/IO/풀 대기/lock, Realtime join 실패·message rate·fan-out·lag, revision gap, full poll RPS, outbox oldest age/실패/용량, payment unknown/중복 차단, background job backlog, 버전·rollout 분포. 표본 평균만으로 느린 매장을 숨기지 않는다.

즉시 중단 경보: 타 매장 노출·중복 결제·확정 주문 누락·금액 불일치. 성능 경보 시작 기준: 중요 API 5분 실패율 >0.5%, p99 목표 초과 10분, 정상 네트워크 outbox oldest >2분, resource/Realtime quota >80% 5분. 이 기준은 pilot 기준선으로 보정하되 안전성은 완화하지 않는다. 오프라인 장치의 대기와 정상 네트워크의 처리 정체를 분리한다.

같은 원인 재발 방지 CI: idle full polling 금지, timeout/401 오프라인 오표시 금지, read RPC의 업무 DML 금지, bounded history/active 누락 방지, N+1 query count 회귀, single-flight/generation, cursor/ACK 멱등성, RLS 누출, 결제 결과 미확인 복구. 시간 기반 성능 인증은 잡음 많은 unit CI와 분리된 고정 환경에서 수행한다.

## 10. 도입 순서·롤백·예산

| 단계 | 담당 역할 | 산출물/통과 후 다음 단계 |
| --- | --- | --- |
| 0. 기준선·상태 일치 | 기술 책임자+DB/운영 | 현재 source/migration/deployment/운영 활성 상태, 실제 부하·한도·SLO 대시보드 |
| 1. 긴급 안정화 | Flutter+DB | 연결 상태 분리, 제한 retry/fallback, 비싼 조회 집합화; 기존 업무 동일성 증명 |
| 2. v2 완성 | Flutter+DB+QA | 최신 workflow parity, bounded bootstrap/delta, cursor/중복/누락 회귀 시험 |
| 3. 전 영역·내구성 | API/DB+Flutter+운영 | report/QR/인증/배치 격리, 내구 대기열·결제 대사·복구 |
| 4. 용량 인증 | 성능/QA+운영 | 500매장 전체 부하, 2배 burst, soak, noisy-neighbor, 복구 및 한도 계약 |
| 5. 단계 배포 | release 책임자+매장 운영 | 1→5→20→50→100→250→500 순서의 승인 기록 |

1개 pilot은 peak/마감 포함 최소 48시간, 5~50개 단계는 각각 최소 24시간, 100개는 72시간, 250개는 7일, 500개는 7일 관측한다. 실제 매장 수가 적으면 다음 규모는 staging으로만 인증하고 운영에서 확인됐다고 표시하지 않는다. shadow 추가 읽기 자체도 비용이므로 작은 cohort만 샘플링하고 예산을 제한한다.

rollback은 매장별 flag/직전 검증 client 및 호환 read RPC로 수행한다. additive migration을 우선하며 이미 확정된 주문·원장·change log를 삭제하지 않는다. **검증된 느린 fallback**만 허용: single-flight+후속 1회, jitter, 최소 10~30초 재조회/실패 backoff, history on-demand, 서버 전역 예산. 이는 비상 저하 모드이며 1초 반영 SLO를 만족한다고 표시하지 않는다. v2/legacy 혼합 상태를 실제로 시험한다.

운영 배포는 `scripts/deploy_pos_production.sh`와 정확한 pushed/main SHA의 GitHub 필수 check를 통과해야 한다. DB 변경마다 preflight/verify/rollback/migration history 증거를 남긴다. dirty 사용자 작업과 섞인 release는 금지한다. 독립 Judge/local PASS만으로 운영 release PASS라 하지 않는다.

일정은 두 경로로 관리한다: 긴급 안정화는 우선 실행 가능한 작은 PR 단위, 500매장 인증은 안전성·복구·관측기간을 생략하지 않는 별도 경로다. 초기 인력 가정은 Flutter 1, DB/API 1, QA/성능 1, 운영/release 담당이며 단계 0 후 작업별 견적을 확정한다. 참고 범위는 cloud 경로 구현·검증 6~10주와 cohort 관측기간; 로컬 coordinator/cell이 필요하면 별도 추가 일정이다. 일정 때문에 미통과 게이트를 삭제하지 않는다.

예산 항목: DB dedicated compute/IO·디스크, Realtime 실제 quota/메시지/egress, PITR/별도 백업/복원 연습, 필요 시 replica/standby, staging 부하시험, 관측 보관, 매장 보조회선/UPS/기기. T02에서 공급자 견적과 실제 월 사용량 모델을 제출하고 유료 변경은 승인 후 수행한다.

## 11. 완료 정의

“500매장 준비 완료”는 코드 작성이 아니라 다음 모두를 뜻한다.

1. 최신 업무 계약과 금융·권한 안전성 전부 PASS.
2. 500매장 실제 경로의 용량·장애·데이터 증가 시험 PASS, 증거/환경/SHA 보관.
3. 적용 quota/인프라/복구·비상 운영이 계약과 일치하고 담당자가 인수함.
4. 동일 SHA로 source 구현, DB 적용, client 배포, 운영 검증을 각각 기록함.
5. 단계별 관측을 통과하고 모니터링·rollback·on-call이 작동함.

시험이나 비용/권한/복구 조건이 하나라도 충족되지 않으면 인증 가능한 매장 수를 마지막 통과 단계로 제한한다. 실패를 감추기 위해 timeout을 늘리거나 활성 주문/실패 표본을 삭제하지 않는다.
