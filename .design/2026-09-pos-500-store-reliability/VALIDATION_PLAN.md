# 검증·확장 승인 계획

기준: [DESIGN_BRIEF.md](DESIGN_BRIEF.md), [TASKS.md](TASKS.md) · 2026-09-19

현재 결과: **NOT RUN**. 이 문서는 시험 설계이며 PASS 보고서가 아니다.

## 1. 증거와 환경 원칙

- 각 결과에 commit SHA, dirty diff 여부, migration 목록/hash, client build, test seed, DB/API/Realtime 사양·실제 quota, 지역, JWT role/scope, 실행 시간, workload, 원시 histogram·오류·금액 대사를 붙인다.
- source implemented / DB applied / client deployed / operationally verified 네 칸을 분리한다. 과거 문서 PASS, 로컬 SQL PASS, 앱 화면 캡처만으로 운영 성능을 승인하지 않는다.
- 운영에서 허용되는 진단은 낮은 비용의 읽기 전용 상태 확인과 정상 트래픽 관측이다. 부하·장애·복원·RLS 악성 시나리오는 익명화/합성 데이터의 격리된 staging에서만 한다.
- harness는 production project/host를 명시적으로 거부한다. destructive fixture는 harness가 생성한 격리 자원만 정리한다. 요금·테스트 데이터 양과 중단 조건을 사전에 확인한다.
- JWT/RLS와 실제 Supabase SDK 연결을 유지한다. 서비스 키로 우회한 단순 SQL 성능은 참고치다. 외부 은행·MISA에는 부하를 보내지 않고 sandbox/동작 계약 stub으로 장애를 재현한다.
- `pg_stat_statements`는 reset 없이 동일 관찰 구간의 증가분을 비교한다. role/queryid 및 함수 래퍼 변경을 추적하고 nested 통계를 중복 합산하지 않는다. 평균·누적 SQL 시간·DB CPU·HTTP p95를 구분한다.

## 2. 데이터와 부하 생성

기준 데이터는 최신 전체 migration/RLS/trigger/function과 실제 구조를 사용한다. 축소 fixture는 단위 테스트에만 사용한다.

| 축 | 필수 범위 |
| --- | --- |
| 매장/권한 | 500개 매장, 모든 사용 역할, 다매장 관리자, 권한 철회 사용자, 다른 floor/station, 고객 제한 토큰 |
| 데이터 나이 | 당일/30일/180일; 180일에 주문 2,700만·품목 1억800만 기준; skew와 취소/수정 포함 |
| 활성 큐 | 일반 10/50/100, 혼잡 500 ticket/매장; 1/10/100품목, combo·floor_direct·배달·포장·leftover |
| 완료 이력 | 당일 10,000건 대형 매장, 다일 이력, cutoff/현지 날짜 경계 |
| 연결 | 직원 5,000+추적 2,500 기본, 2배인 15,000 socket; 실제 기기당 channel 수 측정 |
| HTTP 고객 | QR 15,000/30,000 세션; 메뉴 열기·변경·주문·추적의 실제 think time; 메뉴 cache miss도 포함 |
| 배경 | 보고서/급여/export, promotion 경계, settlement, 결제 webhook, MISA timeout/복구, 마감 |

임의의 잘못된 수량 업데이트를 많이 보내는 대신 실제 주문→결제→조리→준비→인계→전달 sequence를 생성한다. accepted/rejected/unknown을 구분하며 정상 업무 거절을 기술 성공으로 숨기거나 오류로 섞지 않는다.

쓰기 arrival-rate는 open-loop로 제어하고 session 사용자 행위는 think-time 모델을 병행한다. 느려질 때 발생 부하 자체가 줄어드는 closed-loop 착시를 방지한다. 생성기 포화, coordinated omission, timeout/drop을 계수하고 성공 표본만의 percentile을 단독으로 보고하지 않는다. 모든 timeout/거절/미완료 수와 end-to-end 대기시간을 별도 포함한다.

DB/API 부하는 실서버 경로, Realtime은 실제 socket/가입 인증 경로를 사용한다. 브라우저/Flutter 실제 화면 렌더링은 역할별 대표 기기 집단에서 계측하고 전체 socket 시험과 결합한다. headless API만으로 화면 SLO를 통과 처리하지 않는다.

## 3. 단계별 성능 시험

1. **기준선 A/B:** 기존/개선 버전 동일 데이터·compute·network, cold/warm cache 각 3회. 지연/RPS/bytes/query count/BUFFERS/쓰기 증폭 비교. 같은 DB에 두 버전을 동시에 섞어 불공정 비교하지 않는다.
2. **정확성 선행:** 1/10/50매장 실제 업무 시나리오를 대사한다. 금전·권한·주문 누락이 있으면 scale 시험으로 넘어가지 않는다.
3. **증가 시험:** 100→250→500매장, 각 최소 30분 안정 구간. 직원·고객·배경 작업을 함께 증가시킨다. 마지막 통과 단계와 최초 자원 한계 지점을 기록한다.
4. **지속 peak:** 500매장, 500업무명령/초 6시간. 정상 peak 자원은 목표 65% 이하, quota/디스크 안전 여유 유지. write/read/message/retry·pool queue를 전부 계수한다.
5. **burst:** 1,000명령/초+직원 10,000+추적 5,000 socket+QR 30,000 세션 30분. peak 초과에서는 설계된 bounded admission 여부도 확인한다. 정상 지원 범위의 실패를 “의도된 과부하”로 재분류하지 않는다.
6. **24시간 soak:** 150,000주문/일 기준 일주기와 예약된 혼잡 구간, 21:30/21:45/22:20/23:00 경계를 포함한다. memory/channel/timer/DB connection/outbox/로그 증가, TTL/vacuum을 측정한다.
7. **편중 시험:** 상위 10% 매장에 50% 쓰기, 추가로 한 매장 폭주. 다른 매장의 p95/p99·실패율과 권한 안전성은 정상 SLO 유지.
8. **개점/reconnect 폭주:** 모든 단말 로그인/토큰 갱신/구독/초기 페이지 동시 시작 및 공급자 WS 단절 뒤 복귀. join-rate 한도와 backoff가 실제로 동작하는지 측정한다.

peak/burst/soak는 별도 결과다. 6시간 peak의 약 1,080만 명령과 30분 burst의 약 180만 명령이 발생시킬 로그/비용을 사전 산정한다. 데이터 정리 역시 운영 데이터가 아닌 시험 fixture에만 한다.

§4 SLO를 역할·매장 크기·전체 분포로 각각 판정한다. 장치당 타이머/요청 중첩이 없고 정상 idle full snapshot/completed 조회 0을 별도 확인한다. 500매장인데 실제 동작 매장은 몇 개뿐인 시험을 금지한다.

## 4. 장애·정합성 시험 행렬

| 주입 상황 | 필수 관찰과 합격 조건 |
| --- | --- |
| 일반 인터넷 정상, REST 3/5/10초 지연 | serverDegraded 표시; internet-offline 오판 0; 늦은 응답이 최신 scope를 덮지 않음 |
| 401/403/429/5xx, token 만료·회수 | 원인 분리, bounded refresh/backoff; 권한 우회·무한 로그인/재시도 없음 |
| 실제 인터넷 단절 5분/1시간/24시간 | 마지막 동기화·대기·미확인 표시; 저장된 명령 보존; cloud 미지원 기능을 성공처럼 표시하지 않음 |
| WebSocket만 단절 / subscribe 성공 뒤 알림 유실 | HTTP 정상 업무 유지; watchdog/delta 회복; 1초 full polling 재발 없음 |
| DB commit 뒤 응답 유실 | 동일 command ID 결과 확인; 주문·결제·KDS 수량 중복 0 |
| DB transaction 중 실패 / restart | 원자성 유지; commit 안 된 동작을 성공 표시하지 않음; 연결풀 재생성 폭주 통제 |
| delta 중복·역순·빈 페이지·누락 | cursor 단조성/scan 경계, idempotent apply, 복구 후 authoritative 상태와 일치 |
| bootstrap 페이지 사이 주문/삭제 | 완전한 활성 큐로 수렴; partial 목록 완료 표시 없음; 정렬/알림 유지 |
| scope에서 보이지 않는 revision | 정상 cursor 전진; 잘못된 gap 감지/재bootstrap 루프 없음 |
| log 보존기간 만료 / restore 후 epoch 변화 | 안전한 rebootstrap; 기존 cursor 재사용으로 주문이 사라지지 않음 |
| 사용자/매장 A→B→A·floor 재배치·logout | 오래된 응답/채널/캐시/대기열이 새 scope에 반영되지 않음 |
| app crash/재시작·탭 2개 동시 enqueue | 저장 성공 표시된 레코드 유실 0; ACK 전 삭제 금지; 중복 실행은 서버에서 방지 |
| 저장소 full/corrupt/읽기 실패 | 사용자에게 저장 실패·복구 필요 표시; 빈 대기열로 위장하지 않음 |
| 기기 데이터 삭제·장비 파손 | 보장 한계와 복제/운영 복구 정책 검증; 로컬 복제 없는 RPO=0 주장 금지 |
| 고객 타 주문·타 매장/타 floor 구독 | 데이터·메시지·ticket 접근 0, ID 추측/토큰 재사용/권한 철회 검증 |
| 대형 report/export·MISA/SePay 장애 | critical 주문/결제 SLO 유지; background backlog와 복구 대사 |
| 15,000 socket 동시 재접속 | join/message 한도 준수, 95% 중요 화면 ≤60초/전체 ≤120초, bootstrap 예산 유지 |
| legacy/shadow/active와 앱 구버전 혼재 | 최신 업무 수량 동일, payload 호환성·안전 fallback; rollback 때 조회 폭주 없음 |
| backup 복원·primary 전환 | 쓰기 fencing, RPO/RTO 측정, 결제/주문 대사, Auth/Storage/client 연결까지 확인 |

“유실 0” 검증은 생성 명령 원장, 서버 응답, DB 확정 원장, 고객/직원 화면, 결제 시뮬레이터를 command/order/payment ID로 대사한다. count만 비교하지 않고 금액·수량·상태·사업일을 비교한다. 결과 미확인 명령을 삭제해서 합계를 맞추지 않는다.

## 5. 기존 테스트 재사용과 신규 회귀

기존 `test/kds_realtime_sync_test.dart`, `test/kds_realtime_v2_contract_test.dart`, `test/provider_poll_guard_test.dart`, `test/display_polling_test.dart`, `test/scalability_live_consumer_regression_test.dart`, 최신 KDS workflow/전달 테스트를 재사용한다. 계약 테스트가 문자열 존재만 확인하는 경우 실제 RPC·SDK 동작 검증을 보완한다.

신규 최소 regression:

- 상태 분류·hysteresis·provider 소비자별 허용 작업·현지화 UI.
- singleton/in-flight/generation/timeout 후 잔여 요청, background resume, 다중 탭.
- enrichment 차등 golden, N+1 query count, completed keyset/aggregate, 활성 큐 누락 방지.
- 최신 KDS ticket/ACK/bootstrap/shadow 일치 및 실제 private Broadcast 권한.
- durable outbox migration/crash/corruption와 idempotent command/payment reconciliation.
- read-only RPC의 업무 DML/live event 미발생, 서버 admission 우회 방지.
- 마감/타임존/cutoff/holiday 및 기존 금융 보고서 불변식.

관련 변경을 완성한 후 `bash scripts/check_repo.sh`, `flutter analyze`, `flutter test`, 변경 Dart format, 필요한 SQL/SDK integration 시험을 수행한다. 본 문서 작성 중에는 구현을 바꾸지 않았으므로 애플리케이션 시험을 실행하거나 통과했다고 보고하지 않는다.

## 6. 배포 단계와 중단 조건

운영 전제: 새 코드/SQL에 대한 별도 실행 요청, clean release checkout, 정확한 SHA 필수 GitHub checks, 검증된 migration preflight/verify/rollback, 복구 준비. `scripts/deploy_pos_production.sh`를 우회하지 않는다.

| cohort | 최소 관측 | 다음 단계 조건 |
| --- | --- | --- |
| 1매장 shadow→active | 48시간, peak와 마감 포함 | 최신 계약 mismatch 0, 담당자 업무 확인, 제한 rollback 실제 연습 |
| 5→20→50매장 | 각 24시간 이상 | 다른 매장 영향 없음, SLO/금전/권한/대기열/버전·quota PASS |
| 100매장 | 72시간 | 일주기·report·peak·복구 관측 PASS |
| 250매장 | 7일 | 누적 데이터·로그·비용 추세, 오류 예산 및 업무 인수 |
| 500매장 | 7일 | capacity certificate와 실제 운영 결과 일치 |

현재 매장 수가 cohort보다 적으면 해당 행은 NOT RUN이다. staging 인증과 실제 운영 검증을 별개로 표시한다. 각 단계에 신규 매장을 추가할 때도 인증 부하 범위를 확인한다.

즉시 중단: 타 매장 정보 노출, 확정 주문 유실, 중복 결제/금액 불일치, 잘못된 수량/업무 상태. 확장 중단/완화 검토: 5분 중요 API 실패율 >0.5%, p99 10분 초과, 정상 네트워크 outbox >2분, quota/자원 >80% 5분, unknown payment 증가. 임계값 미만이어도 업무 안전성 문제가 있으면 중단한다.

복귀 순서: cohort 확대 중단 → report/비필수 batch 감속 → 영향 cohort 제한 mode/검증 client → 신규 오류 차단 → backlog와 결제 결과 대사 → 원인 수정·동일 시험 재수행. 데이터를 삭제하거나 기존 1초 legacy polling을 전역 활성화하지 않는다. 지급/결제 결과가 불명확하면 자동 재결제하지 않는다.

## 7. 인수·정기 재검증

최종 보고서는 CRITICAL/HIGH/MEDIUM/LOW/CONFIRMED와 우선 수정 목록을 사용한다. CRITICAL/HIGH 미해결, 안전성 FAIL, capacity/DR 미측정, 실제 quota 미확인이 있으면 승인 불가다.

인수 산출물: baseline, 계약 parity, migration 3종 검증, 실제 SLO histogram, 500매장/2배 burst/soak 결과, noisy-neighbor/RLS·금전 대사, quota/비용 증거, backup 복구 기록, 매장 비상 운영 절차, 정확한 release SHA, cohort 기록, 담당자 연락/rollback 권한.

운영 계획: 일별 SLO/queue/용량 추세 확인, 주별 slow-query·증폭·cost 검토, 월별 staging 성능 회귀·독립 복원 검증, 분기별 매장 회선/정전/클라우드 단절 훈련. 새로운 주요 업무/스키마/Realtime 경로/compute 변경 또는 매장·단말·주문량 20% 증가 시 capacity 재검증한다. 이것은 운영 인수 항목이며 이 문서가 자동화나 알림을 실제 생성한 것은 아니다.

최종 인증서에는 **지원 상한은 500매장이라는 숫자만이 아니라 단말·QR 세션·명령/초·payload·보존기간·네트워크·장애 모드의 조합**임을 기록한다. 한계 밖에서는 안전하게 저하하고 증설/재인증한다.
