# 실행 체크리스트: 500개 매장 안정성

기준: [DESIGN_BRIEF.md](DESIGN_BRIEF.md) · 2026-09-19

`brief-to-tasks` 방식으로 각 항목을 재사용/수정/신규 대상과 검증 가능한 완료 조건으로 나눴다. 전 항목 미실행 상태다. 여러 PR이 필요한 큰 항목은 역할/화면별 동일 계약의 세션 크기 작업으로 분할하며 검증 없는 기반 작업만 별도로 완료 처리하지 않는다. 담당 표기는 역할이며 실제 담당자는 T01에서 지정한다.

## 0. 기준선과 조기 위험 검증

- [ ] **T01 현재 장애와 배포 상태 기준선** — 운영/DB. _재사용: 기존 SQL 통계·측정 문서·배포 스크립트; 신규: 비밀정보 없는 기준선 보고서._ 실제 slow 요청을 request ID로 연결하고 오류 분류, SQL 구간 증가분, CPU/IO/pool/Realtime, 사용자 버전·flag·migration을 기록한다. **완료:** 재현 가능한 데이터와 source/DB/client/운영 4열 상태표, 실제 store/device peak, 담당자 배정. 운영 데이터 변경/통계 reset 금지.
- [ ] **T02 500매장 자원·요금·복구 가능성 사전 심사** — 운영/기술 책임자. _재사용: Supabase 프로젝트·배포 구조; 신규: capacity/DR ADR와 견적._ §3 부하식, 실제 quota, dedicated compute 후보, staging 비용, 복구 RPO/RTO 및 로컬 비상 운영 범위를 확정한다. **완료:** 한도 증설 가능성과 견적 확인, cloud-only 한계/강화 경로 명시; replica를 자동 HA로 간주하지 않음. _의존: T01._
- [ ] **T03 최신 KDS 계약 고정** — DB/QA. _재사용: v2 및 최신 workflow SQL/test; 신규: golden 시나리오/필드 행렬._ snapshot/ticket/delta/ACK/shadow에 start/ready/serve, 트레이/홀/고객 전달, 배달·포장·combo·취소를 대조한다. **완료:** 구/신 경로의 필드·수량·알림 기대값과 차이 목록. 사용자 미추적 migration 상태를 별도 표시. _의존: T01._
- [ ] **T04 내구성·권한 위험 시험 원형** — Flutter/DB/QA. _재사용: offline queue, process_payment, RLS; 신규: 중복/타매장/저장손상 fixture._ 응답 유실 후 재시도, 다중 탭 저장, 파싱 오류, 다른 매장 JWT를 재현한다. **완료:** 손실/중복/누출 실패를 검출하는 테스트가 실제 실패 조건에서 fail함; 수정 전 위험 기록. _의존: T01._

## 1. 즉시 사용자 체감 개선

- [ ] **T05 연결 상태 서비스와 배너 한 경로 완성** — Flutter. _수정: connectivity_service, offline_banner, KO/EN/VI; 재사용: AppStatusBadge/theme._ 성공/timeout/401/403/429/5xx/실제 단절을 구분한다. **완료:** 서버 지연을 인터넷 단절로 표시하지 않고 원인·마지막 성공·회복을 표시; restaurants 주기 ping 제거; 접근성/작은 화면 시험. _의존: T01._
- [ ] **T06 연결 상태 소비자 전수 전환** — Flutter. _수정: cashier/waiter/attendance 등 connectivityProvider 소비 화면._ 화면별 허용/보류/재인증 동작을 구현하고 기존 권한·금융 차단을 유지한다. **완료:** boolean 잔여 소비자 0, 상태별 버튼·대기열·재시도 회귀 PASS. 화면별로 세션 단위 분할. _의존: T05._
- [ ] **T07 KDS refresh 폭주 차단** — Flutter. _수정: emergency_fulfillment_provider의 기존 guard/fallback._ single-flight, 최대 후속 1회, deadline/generation, jitter/budget와 느린 안전 fallback을 적용한다. **완료:** 느린 응답/단절/복귀에서 중첩 실행·늦은 상태 덮기·1초 full retry 폭주 없음; 수량/알림 회귀 PASS. _의존: T03, T05._
- [ ] **T08 오류·중복 실행 추적을 화면까지 연결** — Flutter/API/운영. _재사용: 기존 오류 처리; 신규: 분류된 trace/metric와 운영 대시보드._ 오류 종류·RPC·버전·소요시간·재시도·outbox age를 연결한다. **완료:** 시험 요청 1건을 화면→RPC→로그에서 찾고 PII/토큰 노출 없음; 샘플링/비용 상한 확인. _의존: T01, T05._

## 2. 느린 SQL과 bounded 읽기

- [ ] **T09 workflow enrichment 집합화** — DB. _수정: 최신 유효 enrichment/snapshot SQL; 재사용: 업무 원장._ N+1을 batch join/aggregate로 교체한다. **완료:** T03 golden 차이 0, 10/100/500 활성 티켓 및 대형 주문에서 query count·BUFFERS·지연 비교; index 후보는 근거 제시. _의존: T03._
- [ ] **T10 완료 이력의 서버 페이지+화면 연동** — DB/Flutter. _수정: completed RPC와 history 화면; 신규: 제한 aggregate API 필요 시._ business-day/keyset/조회 시점과 count/timing을 보존한다. **완료:** 오늘 10,000건에도 최초 읽기 상한 준수; 페이지 누락/중복·재열기·취소·마감 회귀 PASS. _의존: T09._
- [ ] **T11 bounded bootstrap+일관된 revision 경계** — DB/Flutter. _수정: get_kds_bootstrap_v2와 초기 로드._ legacy 전체 이력 의존을 제거하고 초기 페이지·활성 전체 완료 상태를 분리한다. **완료:** bootstrap 중 주문/취소가 발생해도 delta 수렴; 500개 활성 주문을 잘라내지 않음; 장애 시 partial을 complete로 표시하지 않음. _의존: T09, T10._
- [ ] **T12 측정된 인덱스와 무정지에 가까운 적용 절차** — DB/release. _재사용: preflight/verify/rollback 관례; 수정: 필요한 인덱스만._ 크기별 lock/statement timeout 및 concurrent 절차를 구분한다. **완료:** staging apply/replay/rollback/reapply, invalid index 정리, 쓰기 비용 비교 PASS; 실제 운영 적용은 T33 이후. _의존: T09~T11._

## 3. v2 실시간 경로 완성

- [ ] **T13 변경 ticket/ACK 최신 workflow 일치** — DB/Flutter. _수정: v2 ticket·command ACK·provider patch; 재사용: 최신 workflow._ 최신 필드와 수량을 모든 경로에서 적용한다. **완료:** 같은 동작의 legacy/v2/재시작 결과와 알림이 일치, 완료/삭제된 ticket이 남지 않음. _의존: T03, T09._
- [ ] **T14 cursor와 영속 change log 복구** — DB/Flutter. _수정: kds_realtime_sync와 delta RPC._ 중복/역순/누락/권한 필터 간격/보존기간 만료/서버 restore epoch를 다룬다. **완료:** 상태+cursor 저장 경계 검증, cursor만 앞선 재시작 복구, 매장·사용자·session 전환 격리 PASS. _의존: T11, T13._
- [ ] **T15 ticket 배치와 event 증폭 예산** — DB/Flutter. _수정: change trigger·ticket loader·병합 guard._ row event 증폭 및 fan-out을 계측하고 bounded batch를 적용한다. **완료:** 1/10/100품목 명령의 A/F/RPC/bytes 기록, hotspot lock 시험 PASS; 업무 알림/순서 유지. _의존: T13, T14._
- [ ] **T16 실제 private channel 권한·재접속 시험** — DB/QA. _재사용: Broadcast/RLS; 수정: 필요 정책·인증 갱신._ 실제 SDK/JWT로 join/권한 회수/다른 매장/다른 floor/customer 접근을 시험한다. **완료:** 누출 0, stale session 차단, 재인증 폭주 방지, 조용한 메시지 유실을 watchdog이 회복. _의존: T14._
- [ ] **T17 제한된 shadow와 안전 전환/복귀** — Flutter/DB/운영. _수정: 기존 rollout/parity; 신규: 의미 차이 리포트._ 같은 revision에서 최신 계약을 비교하고 추가 읽기를 샘플링한다. **완료:** §검증 행렬 0 mismatch, legacy→shadow→active만 허용, v2 장애 때 제한 fallback으로 복귀; source 존재를 활성화로 보고하지 않음. _의존: T07, T11, T13~T16._

## 4. POS 전 영역 요청량과 매장 격리

- [ ] **T18 cashier/waiter/table 변경 ID 갱신** — Flutter/API. _재사용: live_refresh_service와 기존 single-flight; 수정: 해당 provider._ ID/domain별 갱신과 unknown-scope fallback을 구현한다. **완료:** 이벤트 폭주에도 full list 재조회 예산 준수, 결제/테이블 이동·A→B→A scope 경합 PASS. 각 화면은 별도 작업으로 검증. _의존: T08._
- [ ] **T19 고객 디스플레이·QR 트래픽 제한** — Flutter/API. _수정: display/QR/order tracking·메뉴 cache._ 주기 full poll을 제거/제한하고 public catalog와 private order를 분리한다. **완료:** QR 30,000 세션 부하 산정, 확정 가격 서버 재검증, 다른 고객 주문 누출 0, 숨김 탭·복귀·다중 탭 시험. _의존: T08, T16._
- [ ] **T20 report·batch·외부 연동의 우선순위 분리** — DB/API. _재사용: 기존 aggregate/cron/SePay/MISA/settlement; 수정: 필요한 queue/cache/budget._ 높은 보고서 부하가 주문·결제 자원을 소진하지 않도록 한다. **완료:** 마감/급여/보고서/외부 timeout 중 중요 API SLO PASS, MISA 비동기 유지, 두 settlement 영역 보존. _의존: T01, T08._
- [ ] **T21 서버 측 noisy-neighbor 통제** — API/DB. _신규: 비용 기반 admission policy; 수정: 비용 큰 기존 진입점._ store/user/priority별 한도를 강제하고 우회 REST/RPC를 검증한다. **완료:** 폭주 매장만 제한되고 다른 499매장 SLO 유지; JWT/RLS 유지·service_role 노출 없음·결제 미확인 결과 보존. _의존: T02, T08, T18~T20._
- [ ] **T22 데이터 증가·로그 보존 운영** — DB/운영. _재사용: 업무 테이블/change log; 신규: 용량 모델·안전 retention 작업._ 180일 데이터, index/WAL/bloat와 outbox 증가를 측정한다. **완료:** purge/vacuum 중 critical SLO 유지, 오래된 cursor bootstrap 복구, 회계 원장 미삭제. _의존: T02, T14._

## 5. 거래 내구성과 재해 대비

- [ ] **T23 일반 주문 대기열의 내구 저장/이관** — Flutter. _수정: offline_mutation_queue_service; 신규: platform별 transaction 저장 adapter._ 저장 성공 확인, 다중 탭 직렬화, 손상 복구와 기존 데이터 이관을 구현한다. **완료:** crash/restart/full disk/parse 오류/동시 enqueue에서 acknowledged 항목 유실 0; 저장 불능 표시; 기존 queue 차등 대사. _의존: T04, T06._
- [ ] **T24 KDS outbox의 동일 내구 계약** — Flutter/DB. _재사용: EmergencyWebBridge/outbox; 수정: ack/removal/replay._ KDS 명령 ID·수량 인과 순서·scope를 보존한다. **완료:** 완료/삭제 원자성, 기기 재시작·권한 변경·마감 넘김·재전송에서 중복 처리/유실 0. _의존: T04, T13, T23._
- [ ] **T25 주문·결제 명령 멱등성과 결과 대사** — DB/Flutter. _재사용: process_payment/기존 명령 ID; 수정: 미확인 결과 경로._ 서버 commit 뒤 응답 유실 시 동일 ID로 결과를 확인한다. **완료:** 재시도/동시 기기/중복 webhook에서 금전 중복 0, 새 charge 자동 재실행 없음; 원장 합계 일치. _의존: T04, T23, T24._
- [ ] **T26 cloud 복구 실습** — 운영/DB/release. _재사용: 공급자 backup/PITR; 신규: 복원 runbook 및 독립 복원 환경._ DB+Storage+auth/config/client routing을 복원하고 fencing한다. **완료:** 500매장 데이터에서 RPO≤5분/RTO≤30분 계측 또는 실패 보고와 강화 설계; “백업 있음”으로 완료 금지. _의존: T02, T22, T25._
- [ ] **T27 매장 비상 운영 실습과 무중단 범위 확정** — 운영/제품/기술 책임자. _재사용: 기존 종이/출력 흐름; 신규: 이중 회선·UPS·전환/대사 절차._ 로컬 coordinator 필요 여부와 지원 범위를 ADR로 확정한다. **완료:** 24시간 cloud 단절·회선 failover·전원 복구 시 역할별 동작/미지원 전자결제/복구 대사 확인. 자동 다중 단말 영업 요구라면 별도 coordinator 구현·장비 시험 전 이 항목 FAIL. _의존: T02, T23~T26._

## 6. 인증·배포·인수

- [ ] **T28 실제 경로 성능 harness** — QA/성능. _재사용: measure_scalability 및 회귀 fixture; 신규: full-schema/staging open-loop+SDK 측정._ 실제 JWT/RLS, 양방향 명령, QR/Realtime, business-day 혼합 부하를 생성한다. **완료:** production target 거부, 환경/SHA/data seed/부하/원시 결과 재현 가능, 클라이언트 CPU 병목 배제. _의존: T01~T04; 개선 작업과 병행 개발 가능._
- [ ] **T29 500매장·2배 burst·24시간 soak** — QA/운영. _재사용: T28; 신규: 인증 측정 보고서._ 6시간 sustained peak, 30분 burst, 대표 일주기 24시간, 180일 데이터/쏠림을 시험한다. **완료:** VALIDATION_PLAN 전체 SLO·안전성·자원 여유 PASS, 실제 quota 적용/비용 견적 일치. _의존: T12, T17~T25, T28._
- [ ] **T30 장애·복구·구버전 혼합 시험** — QA/운영. _재사용: T28/runbook; 신규: fault matrix._ WS만 차단/HTTP만 지연/DB restart/재접속 폭주/인증 회전/slow consumer/서버 restore/client rollback을 주입한다. **완료:** 데이터 대사 0차이, bounded fallback, 탐지·복구 시간 통과; 불가 항목은 미통과로 표시. _의존: T17, T21, T25~T29._
- [ ] **T31 재발 방지 CI와 지원 버전 정책** — QA/release. _수정: check_repo/기존 테스트/배포 계약; 신규: 새 deterministic regression._ idle poll, read-side write, RLS/금전/대기열/cursor 회귀를 필수화한다. **완료:** 의도적 결함 주입 시 게이트 실패, 구버전/캐시·service-worker 혼합 시험, 미전송 queue 보존하는 업그레이드 정책. _의존: T05~T25._
- [ ] **T32 운영 경보·당직·확장 중단 정책 인수** — 운영. _재사용: T08; 신규: runbook/on-call/월 SLO 보고._ 실패·지연·outbox·quota·결제 미확인 경보를 시험한다. **완료:** 시험 경보→인지→진단→완화→대사 기록, 책임자 지정, 오류 예산 소진 시 기능/확장 동결. _의존: T08, T26, T27, T30._
- [ ] **T33 정확한 SHA release preflight** — release 책임자. _재사용: check_repo/flutter/독립 Judge/deploy_pos_production.sh; 신규: 증거 묶음._ 관련 사용자 변경과 분리한 clean release를 준비한다. **완료:** 정확한 pushed/main SHA의 GitHub 필수 checks PASS, migration preflight/verify/rollback 검증, 운영 적용에 대한 별도 요청 확인. _의존: T29~T32._
- [ ] **T34 매장별 단계 전개** — release/매장 운영. _재사용: rollout flag; 신규: cohort 인수 기록._ 1→5→20→50→100→250→500, 각 관측기간을 지킨다. **완료:** 단계별 성능·업무·금전·권한·quota PASS와 rollback 준비; 실제 없는 매장은 staging 인증으로 명시. _의존: T33._
- [ ] **T35 500매장 최종 인증·정기 재검증 인수** — 기술 책임자/운영/업무 담당. _재사용: 모든 검증 산출물; 신규: 서명된 capacity certificate._ source/DB/client/운영을 각각 승인하고 비용·장비·지원 한계·다음 증설 지점을 확정한다. **완료:** 미해결 CRITICAL/HIGH 0, 500매장 관측 또는 실제 운영 검증 미완료 표시, 부하/복구/권한 재검증 주기 운영 인수. _의존: T34._

## 조건부 확장 작업을 여는 기준

T02/T21/T26에서 단일 프로젝트가 성능·격리·복구 기준을 충족하지 못하면, ticket projection/read replica/warm standby/cell 분리 중 원인에 맞는 최소 대안을 ADR로 정한다. 작업·비용·호환성·데이터 이동·되돌리기 시험을 이 체크리스트에 추가한 뒤 수행한다. Office 앱 수정, 플랫폼 이전, 로컬 coordinator는 이 문서 작성만으로 실행 승인된 것이 아니다.
