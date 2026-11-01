# POS 전체 개선 잔여 완료 실행계획

- 기준일: 2026-11-01, 베트남 UTC+7
- 확인한 POS main/운영 SHA: `6de6702e6cc62497623070f6f9cae70c5cc7a502`
- 확인한 Office main SHA: `8b24d58836b6014d62c498c3f17c106b7da398e8`
- 상태: **잔여 구현 진행 중. 개별 구현/영향 검증과 전체 계획·운영 완료는 구분한다. 아래 실행 기록 참조.**
- 범위: 기존 통합 계획 U01–U12의 잔여 전부, POS 33개 기능, POS–Office 연결 경계. Office 자체의 모든 업무를 새로 감사하는 범위는 아니다.

## 현재 실행 상태 — 구현과 통합 완료 구분

POS 원격 main은 `ad6595a0`, 작업 브랜치는 PR #655이며 아직 draft다. Office 원격
main `d5d1797e`는 연결 작업 `45d6b8c8`의 조상이다. 사용자 원래 checkout은 변경하지
않는다. 운영 배포·2시간 사전 혼합 부하·1배/3배 각 12시간은 아직 시작하지 않았다.

| 묶음 | 확보한 부분 | 남은 완료 조건 |
|---|---|---|
| G0 | 양쪽 계정 private 보관/범위 점검, 현재 schema, 실제 Auth/REST/양쪽 Edge·Storage·Realtime와 공통 HTTP/WS 주소 준비 | 실단말/하드웨어 배정, 전체 runtime·혼합 부하 manifest 확정 |
| G1 | native 복원/최종 객체 대조, 업그레이드 금융 보존·결제/주문 receipt 검사 | 전체 브라우저 결합과 모든 신규/업그레이드 업무 |
| G2 | 양쪽 SQL/Edge/UI, 실제 신규 법인·첫/추가 매장·Auth worker·직원/사진 근태, 두 정책의 소프트웨어 주문 전달 연결 | 실제 개시 승인·두 앱 브라우저·구매/입고·Office 업무 전체 흐름 |
| G3 | root scope, KDS progress/single-payment journal, 인증 명령과 일부 주문/QC/설정/리포트/근태·증빙 전환 | 나머지 legacy 도메인, 계산대 분할·합산·비매출 복구와 나머지 서버 계약 |
| G4 | 메뉴 잔량 부분 갱신, 리포트 병합, 증빙 metadata batch, 계산대 조회 취소/예산 | 계산대 summary/detail·페이지, 전체 worker 예산, 규모별 계획/실측 |
| G5 | native JSON worker 누적 수정, 일부 화면/타이머 수명, 근태·증빙 사진 상한 | 큰 화면 분리, 파일/큐/이미지/worker 메모리 및 전체 자원 상한 |
| G6 | 개별 실제 SQL/API·위젯 검사 | T01–T16 연결, 혼합/실패 주입, 2시간 사전 부하 |
| G7 | 공식 gate·증거 규칙 보존 | 동결 후보 1배/3배 각 12시간, 최종 main 전체 recipe 1회, 공식 배포, 두 마감 관찰 |

## 1. 완료의 정의

이번 작업은 아래 여덟 작업 묶음을 끝내고, 새 법인·첫 매장부터 정상 영업·마감까지 실제 연결을 검증하는 것을 목표로 한다. Office 연결, 전역 상태, 부하 시험 세 항목만 끝내고 전체 완료로 표시하지 않는다.

**전체 완료 조건은 다음을 모두 만족하는 것이다.**

1. 잔여 항목마다 구현 대상·업무 소유자·실행 검사·증거가 연결되어 있다.
2. 매장 0개인 법인의 POS–Office 연결과 첫 매장·추가 매장 개설이 작동한다.
3. 33개 기능의 저장 결과·접근 범위·갱신·취소·복구 계약이 목록에서 빠지지 않는다.
4. 신규 설치와 운영 스키마 업그레이드 양쪽에서 최종 함수·트리거·권한·업무 불변식을 검증한다.
5. 혼합 부하·응답 유실·재연결·시간 경계·12시간 사용 시험에서 정확성과 성능 기준을 만족한다.
6. 실제 최소 사양 단말과 필요한 하드웨어 어댑터의 시험을 끝낸다. 클라우드 브라우저 성공으로 대체하지 않는다.
7. 두 프로젝트의 공식 절차로 적용하고 운영 주소·SHA·DB 이력·영향 기능을 확인한다.
8. 배포 후 마감 시간대 2회를 관측해 점진적 지연과 자원 누적 여부를 확인한다.

상태는 `미착수 / 구현중 / 구현완료 / 검증완료 / 운영확인완료 / 차단`으로 나눈다. 구현·개별 검사·배포 READY를 전체 완료로 올리지 않는다. 필수 시험이 미실행이면 해당 항목은 미완료다. 기존 운영 로그인 스모크 면제는 `NOT_RUN_OWNER_WAIVER`로 별도 표시하며 로그인 검증 PASS로 바꾸지 않는다.

## 2. 이미 반영한 부분과 재작업하지 않을 부분

| 운영 반영된 내용 | 이번 작업에서 할 일 |
|---|---|
| 결제 확정과 목록 재조회 분리, 늦은 조회 응답 보호 | 회귀를 보존하고 공통 결과 규약으로 연결한다. 같은 수정부터 다시 시작하지 않는다. |
| KDS 대기열 상한·물리 HTTP deadline·disposal 취소 | 다른 요청 경로의 예산과 연결하고 장시간 누적을 측정한다. |
| 주문별 statement 할인 재계산, 매장/트랜잭션당 잔량 이벤트 1회 | 변경 메뉴 부분 갱신과 전체 업무·혼합 부하 검증을 추가한다. |
| 매장 없는 최고관리자 경로, POS 법인 등록 UI | Office 최초 소유 관계와 첫 매장 개설을 완결한다. |
| QC 응답 세대/매장 보호 | 전역 scope 규약으로 확장한다. |
| `main.dart` 역참조 103개 제거 | 재도입을 차단하고 큰 화면의 업무 책임을 분리한다. |
| 공식 배포의 잘못된 로컬 공개 환경변수 요구 수정 | 사전 의존성 점검·장시간 시험 증거 연결을 보완한다. |

직전 앱 전체 검증은 `7a3b71fe`에서 완료됐고, 배포 절차만 변경한 `6de6702e`는 입력 동일성 검증과 배포 도구 검사를 거쳐 적용됐다. 이 과거 증거는 기준선·회귀 참고 자료다. 새 앱/SQL 구현의 검증을 대신하는 면제로 사용하지 않는다.

기존 야간 감사 결과는 유효한 기준이다. 10월 31일 21:59 DB 리프레시는 사용자의 직접 조치로 분리한다. 이후 정상 지표를 코드 개선의 실측 성과로 사용하지 않는다.

## 3. 실행 순서·작업량·책임

작업량은 **구현 담당 1명이 순차 진행하는 추정치**이며 개발과 영향 검사를 포함한다. 별도 인력이나 병렬 에이전트를 전제로 하지 않는다. 총 **약 16–25 작업일**, 별도로 12시간 시험 2회와 운영 마감 2회 관찰 시간을 확보한다. 환경·스키마·실단말 준비 상태를 G0에서 확인한 뒤 날짜를 확정한다. 이 값은 납기 보장이 아니다.

| 순서 | 작업 | 기존 계획 | 주 책임 | 예상 작업량 | 다음 단계로 넘어갈 조건 |
|---|---|---|---|---|---|
| G0 | 잔여 목록·운영 기준선·시험 환경 확정 | U01·U11·U12 | 구현 담당, 단말 배정은 매장 운영 담당 | 0.5–1일 | 33개 기능 목록, 필요한 입력과 확보 경로, 부하 기준선 고정 |
| G1 | 최종 DB 계약·신규/업그레이드 fixture | U02·U05 | DB/구현 담당 | 2–3일 | 실제 유효 정의 대조와 두 설치 경로의 자동 검사 성공 |
| G2 | POS–Office 최초 법인·매장 연결 | U07 | POS·Office 연결 구현 담당 | 2–4일 | 매장 0개에서 법인 연결, 첫/추가 매장, 실패 재개·권한 검사 성공 |
| G3 | 결과·scope·복구 규약 전체 적용 | U03·U08 | 기능별 구현 담당 | 4–6일 | 33개 영역마다 전환/보존 사유와 실패 복구 검사 등록 |
| G4 | 부분 조회·이벤트·캐시·백그라운드 예산 | U04·U05·U06 | 데이터/작업 처리 구현 담당 | 2–3일 | 규모별 호출/행/bytes/동시성 측정과 거래 보호 성공 |
| G5 | 큰 화면·장시간 UI/메모리 비용 정리 | U09·U10 | Flutter 구현 담당 | 2–3일 | 업무 책임 분리, 타이머/구독 회수, 파일 처리 상한 검증 |
| G6 | 전체 생애주기 E2E·혼합 부하·실패 주입 | U11 | 검증 구현 담당 | 2–3일 | 아래 T01–T16 및 2시간 사전 부하 시험 성공 |
| G7 | 12시간 시험·공식 배포·마감 관측 | U01·U10·U11·U12 | 구현/운영 담당 | 1–2일 능동 작업 + 시험/관측 경과 시간 | 실제 단말과 두 마감 시간대까지 최종 완료표 충족 |

한 사람이 여러 책임을 맡을 수 있다. 매장 운영 담당의 역할은 실제 단말 확보·시험 화면 실행·물리 출력 확인이며 코드나 비밀번호를 채팅으로 전달하는 일이 아니다.

개발 영향 검사는 G1–G5에서 같이 작성한다. G6에서 모든 단위 검사를 처음부터 재작성하지 않는다. 과거 장애 당시의 복구 불가능한 시점 지표를 계속 요구하며 나머지 구현을 멈추지 않는다. 과거 최초 촉발 자원의 미확정은 사실로 남기고, 확인된 결함의 재현·해결과 이후 관측으로 재발 방지 근거를 완성한다.

## 4. G0 — 시작 시 막힘을 제거한다

### 확보할 산출물

- `feature_contract_inventory`: 33개 영역별 화면/route, 읽기·쓰기 진입점, RPC/뷰/트리거, 역할, scope, 결과 형태, 복구 방법, 검사 ID, 담당, 상태.
- POS·Office 각각의 source SHA, migration 이력, 최종 DB 계약 manifest, 공식 배포 대상·접속 방식·증거 재사용 조건.
- 실제 POS·주방·층 단말의 모델/OS/브라우저/메모리 확인 가능한 값, 네트워크 조건, 프린터·카메라·지문 어댑터 목록.
- 실제 피크 요청 구성과 단말 수, 주문/항목/이력/Excel 크기 분포. 기존 감사의 HTTP 요청 수를 주문 건수로 환산하지 않는다.

### 준비가 필요한 경우의 처리

| 입력 | 우선 확보 방법 | 없을 때의 처리 |
|---|---|---|
| 운영 최종 스키마 | 기존 인증된 배포 환경/관리형 export에서 **schema-only**를 받는다. POS와 Office를 각각 확보한다. | 구현 담당이 최초 준비 단계에서 정확한 접근·export 의존성을 보고한다. 임의 토큰 추출·다른 VM 이전·부분 fixture를 최종 스키마로 선언하지 않는다. 다른 독립 구현은 계속한다. |
| Office 연결 환경 | 기존 `pos-bridge` 설정과 공식 Office 배포 연결을 확인한다. | 기존 연결의 실제 부족 권한/설정만 특정한다. POS·Office 공통 비밀번호나 새 로그인 매핑으로 해결하지 않는다. |
| 최소 사양 단말 | 매장 기기 목록과 제한된 진단 화면으로 확인한다. | 매장 운영 담당이 시험용 단말·접속 시간을 배정한다. 모델/메모리가 확인되지 않으면 추정 최소 사양으로 보고하지 않는다. |
| 업체·출력 시험 수단 | 기존 sandbox/격리 어댑터 및 실제 출력 장치를 사용한다. | 클라우드 대체 검증과 물리 장치 검증을 분리하고 후자는 차단 사유·실행 담당을 남긴다. |

전체 프로젝트를 “마지막에 실기기가 없어서 미완료”로 남기지 않도록 이 네 항목을 G0에서 확정한다. 별도 유료 인프라나 권한 확대가 필요하면 실제 대상과 비용/영향이 특정된 시점에만 판단한다.

운영 진단은 기존 로그·관리 지표를 우선 사용한다. 새 관측은 제한된 샘플·집계·배치 전송으로 구현한다. 개인정보·주문 본문·비밀번호·토큰은 수집하지 않으며, 관측 자체가 항목별 DB 호출이나 매 화면 갱신 전체 집계를 만들지 않게 한다.

## 5. G1 — DB의 실제 최종 조합을 검증 가능하게 만든다

### 변경 대상

- POS `scripts/check_repo.sh`, `scripts/test_store_operating_upgrade.sh`, SQL fixture/검증 inventory.
- POS·Office의 대상 RPC/뷰/트리거/RLS/GRANT/인덱스·확장 버전 manifest.
- 새 설치 기준 schema와 운영 기준 schema → 신규 forward migration 적용 경로.

### 구현

1. 함수 이름만이 아니라 signature·반환형·정의 해시·별칭 호출, 연결 트리거와 실행 순서, RLS/GRANT, 관련 인덱스를 묶어 기록한다. 적용 이력과 실제 runtime 정의의 차이를 식별한다.
2. 과거 623개 migration을 일괄 수정하거나 적용 이력을 덮어쓰지 않는다. 변경 범위부터 명시적인 최종 정의와 forward migration으로 정리한다.
3. POS와 Office를 독립된 격리 DB/Auth로 복원한다. 운영 데이터·실계정·사진·비밀 설정을 복사하지 않는다. 테스트용 사용자/직원/법인은 생성기로 만든다.
4. 신규 설치는 검증된 canonical baseline과 이후 migration으로 구성한다. 업그레이드는 현재 운영 schema-only에서 시작한다. 파일이 존재한다는 이유로 두 경로를 같은 검증으로 간주하지 않는다.
5. 실제 인보이스/private schema·트리거·권한을 포함한다. 외부 발행·알림·cron은 격리된 시험 어댑터로 연결한다.
6. 현재 schema 검사가 환경변수 제공 시에만 실행되는 공백을 없앤다. 이 통합 릴리스에서는 누락을 `NOT_RUN`/차단으로 표시하는 명시적인 검사 항목으로 등록한다.

**완료 기준:** 신규/업그레이드 DB 모두에서 결제·할인·재고·근태·개설·리포트·권한 불변식이 일치한다. 실행 계획은 실제 시험 데이터 규모에서 수집한다. schema-only 입력이 없으면 G1 최종 검증은 미완료이며 부분 fixture 성공으로 바꾸지 않는다.

## 6. G2 — POS에서 Office 최초 법인 연결을 끝낸다

### 확인한 공백

Office `ops.connect_verified_pos_stores`는 같은 POS `tax_entity_id`에 이미 연결된 `ops.stores`가 있어야 Office 소유 법인을 찾는다. 현재 `store_mapping_sync`는 최대 200개 목록에서 정확히 200개가 반환돼도 전체 동기화를 거부한다. 이 경로에 최초 법인 생성을 억지로 넣으면 매장 0개 문제와 규모 제한이 남는다.

Office 법인 정본은 `accounting.legal_entities`, 브랜드 관계는 `ops.legal_entity_brands`, 매장은 `ops.stores`다. POS 법인/매장 ID와 Office 법인/매장 ID 및 양쪽 Auth ID는 서로 다르다.

### 사용자 흐름

1. POS 최고관리자가 기존 법인 등록 화면에서 **Office 연결**을 시작한다. 매장이 없어도 가능하다.
2. 법인 소유·POS actor 권한을 서버에서 검증하고, 재시도에도 유지되는 연결 `operation_id`와 일회성 연결 요청을 만든다.
3. 기존 Office 로그인 흐름으로 이동한다. Office 권한을 확인한 관리자가 **기존 Office 법인 연결 또는 새 법인 등록**과 소유 범위를 확인한다. 두 앱의 Auth를 합치지 않는다.
4. Office `pos-bridge`가 POS 서버에서 최신 법인·요청 정보를 다시 읽고, Office 법인/브랜드 관계/업무 식별자 매핑을 한 Office 트랜잭션으로 확정한다.
5. 기존 서버 간 POS 연결을 이용하는 제한된 확인 RPC로 POS 연결 상태를 확정한다. POS에는 `연결 대기 / Office 확인 필요 / 연결 완료 / 재확인 필요`를 표시한다.
6. 첫 매장 등록 시 검증된 법인 매핑을 사용해 Office 매장을 연결한다. 기존 법인의 추가 매장도 같은 경로를 사용한다.

기존 store eligibility view만으로는 매장 0개 법인을 확인할 수 없으므로, 그 경우를 위한 **범위 제한된 법인/연결 요청 조회 계약**을 추가한다. 이름·세금번호·같은 UUID만으로 소유 법인을 추정하지 않는다. 새 Office 법인 등록도 해당 actor의 실제 Office 권한 범위 안에서 수행한다.

### 구현 계약

- 연결 요청에는 양쪽 프로젝트, POS 법인, Office 법인, 양쪽 확인 actor, 요청 ID, payload hash, 계약 버전, 유효기간과 상태를 기록한다. 서버 비밀은 클라이언트에 전달하지 않는다.
- POS 법인에 활성 Office 대상은 하나로 제한하고 매장은 그 관계를 사용한다. 브랜드의 기존 다대다 법인 관계와 여러 매장이 한 법인을 쓰는 구조를 유지한다.
- 법인 이전·연결 교체는 별도 이력과 효력 시점으로 처리한다. 과거 매출·발행 문서의 귀속을 새 법인으로 덮어쓰지 않는다.
- 두 DB 사이의 원자적 트랜잭션을 주장하지 않는다. 각 DB의 원자성 + 지속 가능한 연결 작업 상태 + 동일 요청 결과 조회로 복구한다.
- Office 확정 후 POS 확인 응답이 유실되면 Office의 동일 operation 결과를 조회해 확인 단계부터 재개한다. 새 법인·브랜드·매장을 다시 생성하지 않는다.
- 인증된 매장/법인 범위의 선택 ID manifest를 사용한다. 한 요청은 최대 200개 매장, 다수 요청이 필요하면 안정된 키셋/배치로 진행한다. 항목별 RPC를 병렬화하지 않는다. 목록 한 페이지가 200개라는 이유로 실패시키지 않는다.
- 기존 store onboarding/readiness, `store_external_links`, `procurement_store_onboarding`와 확인 증거를 연결한다. 별도 중복 개설 시스템을 만들지 않는다.
- Office를 사용하지 않는 capability는 `미사용`, 필수 연결이 없는 구매/승인 단계는 `필수 미설정`으로 표시한다. Office 장애 때문에 이미 확정된 POS 결제가 실패로 바뀌지 않게 한다.
- 신규 operator 문구는 양쪽 앱의 기존 ko/en/vi 체계를 사용한다.

### 완료 기준

- 매장 0개인 새 POS 법인 → 기존/새 Office 법인 → 첫 매장 → 추가 매장을 seed 없이 연결한다.
- 동일 요청 20회 재전송·동시 승인·중간 응답 유실·재시작에도 활성 매핑과 생성 문서/매장이 중복되지 않는다.
- 법인 A 요청을 법인 B actor가 읽거나 연결·교체하지 못한다. 만료/변조/사용 완료 연결 요청은 거부한다.
- 직영/외부 소유 등 현재 지원 정책을 검증하고, 지원되지 않는 조합은 명시적으로 거부한다.
- 준비 완료된 신규 매장에서 판매·구매 승인/입고·근태·Office 조회까지 이어진다.

## 7. G3 — 전역 상태는 공통 계약으로, 업무 규칙은 기능별로 유지한다

### 7.1 명령 결과

공통 표현은 `confirmed / queued / unknown / rejected`로 정한다.

| 결과 | 의미 | 화면/복구 규칙 |
|---|---|---|
| confirmed | 서버가 업무 결과를 확정 | 즉시 확정 상태 반영. 이후 조회 실패가 쓰기 실패로 돌아가지 않는다. |
| queued | 내구성 있는 대기열에 저장 | 전송 대기 표시. 저장되지 않은 메모리 값만으로 queued를 반환하지 않는다. |
| unknown | 요청이 처리됐을 가능성이 있으나 결과 미확인 | 동일 operation 결과를 먼저 조회. 중복 쓰기를 자동 재시도하지 않는다. |
| rejected | 업무/권한/입력 조건으로 명시적으로 거절 | 실패 이유와 수정 가능한 입력을 표시. 자동 재시도하지 않는다. |

조회 상태는 이 명령 결과와 분리해 `fresh / stale / loading / failed`로 표현한다. 빈 결과·실제 0·권한 오류·갱신 실패를 같은 값으로 숨기지 않는다.

기존 구매 journal, KDS outbox, 근태 결과 재확인을 공통 adapter로 연결한다. 모든 도메인의 내부 상태 머신을 하나로 합치지 않는다. 결제·인쇄·발행처럼 다른 부작용을 같은 재시도 정책으로 묶지 않는다.

각 명령에는 operation ID, 적용 범위, 대상/버전, 결과 ID, 복구 조회 방법을 정의한다. 서버가 operation ID를 보존하지 않는 경로는 서버 계약까지 추가한다. 화면에서 enum만 바꾸고 응답 유실 문제를 해결했다고 하지 않는다.

### 7.2 scope·캐시·비동기 응답

공통 scope에는 실제 사용자/권한 revision·법인·활성 매장·단말 역할·관련 조회 조건을 포함한다. 현재 `LiveSyncScope`, `CoalescedRefresh`, KDS 요청 lifetime을 확장/재사용한다.

- 매장/법인/사용자/권한 변경 시 generation을 갱신하고 이전 범위의 늦은 조회 응답을 폐기한다.
- 진행 중 쓰기는 원래 scope의 작업 결과로 기록한다. 현재 화면으로 끌어오거나 취소된 것으로 추정하지 않는다.
- 로그아웃/권한 회수/화면 종료 때 해당 scope의 구독·타이머·읽기 요청을 정리한다. 공유 Auth transport는 종료하지 않는다.
- 캐시 키, TTL, 변경 ID 무효화, 조회 중 요청 공유를 기능별로 선언한다.
- 같은 조회는 실행 중 1개 + 병합 후속 1개를 기본으로 한다. 다른 거래 명령을 하나의 전역 대기열로 묶지 않는다.

### 7.3 적용 순서와 누락 방지

1. 금융·재고·주방·근태 등 부작용이 있는 명령.
2. 메뉴/정책/개설/QC/계정·권한 설정.
3. 목록·리포트·고객 표시·읽기 전용 화면과 파일 생성.

33개 영역마다 `적용 완료 / 기존 계약 보존·adapter 완료 / 읽기 전용·명령 규약 비대상 / 퇴역` 중 하나를 검사 근거와 함께 기록한다. 관련 코드가 없다는 이유 없는 `비대상`은 허용하지 않는다. 신규 변경이 inventory에 연결되지 않으면 변경 검사가 실패하게 한다.

**완료 기준:** A→B 전환·로그아웃·권한 변경·응답 역전·commit 후 응답 유실·중복 클릭을 검사하고, 잘못된 범위 반영과 중복 부작용이 0이다. unknown을 성공/실패로 추정하지 않으며 복구 화면을 통해 기존 결과를 확인할 수 있다.

## 8. G4 — 조회·이벤트·작업 예산을 명시한다

### 8.1 남은 데이터 접근 수정

- 할인 잔량 변경과 메뉴 구성 변경을 구분한다. 변경 메뉴 ID를 모아 제한된 일괄 조회로 잔량을 갱신하고, 구버전 클라이언트용 기존 이벤트 계약은 유지한다.
- 결제 목록은 요약/현재 페이지와 선택 주문 상세를 분리한다. 오래된 미결제 주문도 검색·페이지로 모두 접근할 수 있고 정확한 총액이 보존되어야 한다.
- KDS 현재 큐/완료 이력, 리포트 summary/detail, 카탈로그/레시피/Excel을 각각 필요한 범위로 조회한다.
- 일대다 JOIN 곱셈, RLS 비용, LIMIT 앞 전체 집계, 큰 OFFSET, 반복 COUNT와 과도한 전송을 실행 계획·행 수·bytes로 확인한다.
- 결제 중 임시 DDL, 출력 보류/준비, 반복 할인·가격/전체 건수 집계도 유효 함수 내부까지 확인하고 측정한 비용부터 줄인다.
- 정상 응답으로 연결 상태를 갱신하고 중복 health 호출·정상 상태의 설정 폴링을 줄인다. 전달·복구의 최신성 요구는 유지한다.

### 8.2 백그라운드 작업

MISA·SePay 후속 처리·출력·알림·계정 생성·유효한 cron의 실제 활성 목록을 만든다. 퇴역 Deliberry·Photo 자동 수집·자동 매출 확정은 재활성화하지 않는다.

각 작업에 배치 크기, 동시 실행 수, 전체 deadline, 재시도 횟수/backoff/jitter, lease/ack, idempotency, queue age, 정지/재개 조건을 선언한다. 여러 worker 인스턴스의 **합산 동시성**도 제어한다. 필요 시 기존 DB claim에 전체 상한을 추가하며 항목마다 예산 조회 RPC를 호출하지 않는다.

거래 처리와 작업 실행의 연결/CPU 예산을 분리한다. 부하가 높을 때 선택적 작업을 지연할 수 있으나 결제·주방 전달을 조용히 버리거나 인쇄/발행을 무한 보류하지 않는다. 외부 결과가 불명인 인쇄·발행은 실제 결과 조회/확인 전 재전송하지 않는다.

초기 시험값은 선택적 worker 동시성 합계 4, 종류별 2 이하, 배치 50 이하, 작업 lane deadline 30초를 출발점으로 삼는다. 외부 provider 한도·기존 안전한 값이 더 작으면 그 값을 유지한다. G0 기준선과 혼합 시험으로 확정하며, 이 숫자를 현재 운영 설정/달성값으로 주장하지 않는다.

30초 deadline은 시험용 조회/제어 lane의 출발값이다. 금융·발행·물리 출력의 외부 부작용에 일률적으로 적용하지 않는다. 해당 작업의 기존 provider 계약·결과 조회·lease 회수 규칙에 맞춰 별도로 정한다.

**완료 기준:** 1/20/200개 항목, 10/100/1,000개 주문, 100/10,000/100,000개 이력에서 호출 수·스캔 행·응답 크기·동시성·락/연결 대기를 기록한다. 제한된 페이지 수 외의 항목별 원격 호출이 없고, 거래와 선택적 작업의 합산 예산·대기열 크기가 유지된다.

## 9. G5 — 큰 화면과 오래 열린 단말을 정리한다

- 구매 workspace, 계산대, 관리자 화면을 표시 widget·조회 controller·업무 명령·계산/파일 처리로 분리한다. 업무별 서비스와 기존 공개 계약은 유지한다.
- `main.dart` 역참조 재도입과 새 순환 의존을 자동 검사한다. 파일 줄 수 감소만을 완료로 삼지 않는다.
- KDS 1초 시계/0.5초 점멸이 화면 전체 재계산·조회·정렬로 이어지지 않게 표시 영역만 갱신한다.
- 화면 전환/재연결/숨김·복귀 반복에서 살아 있는 timer·subscription·request·worker를 계측한다.
- 큰 Excel/PDF/카탈로그 작업은 최대 입력 크기·peak memory를 정하고 배치/worker/스트리밍으로 처리한다. 취소·worker 종료·실제 다운로드와 파일 내용/합계를 검사한다.
- 프린터·사진·지문은 지원 플랫폼과 물리 어댑터의 확인 항목을 구분한다. 정적 파일 생성 성공을 실제 출력 성공으로 바꾸지 않는다.

**완료 기준:** 주요 기능 테스트가 전체 앱 초기화에 의존하지 않고 실행되며, 100회 화면 전환·100회 재연결 뒤 정리 가능한 자원이 선언된 기준치로 돌아온다. 화면 구조 변경 전후 업무 결과·권한·다운로드 내용이 같다.

## 10. G6 — 전체 기능을 연결하는 검증 목록

### 10.1 33개 영역과 적용 묶음

| 영역 묶음 | 반드시 inventory에 등록할 기능 |
|---|---|
| 개설·권한·설정 | `auth`, `onboarding`, `super_admin`, `store_setup`, `settings` |
| 주문·결제·고객 | `waiter`, `table`, `order`, `qr_order`, `direct_order`, `cashier`, `payment`, `customer_display` |
| 주방·전달·출력 | `kitchen`, `emergency_fulfillment`, `store_workflow`, `print_station`, `digital_receipt` |
| 구매·재고·품질 | `inventory`, `inventory_purchase`, `procurement`, `store_procurement`, `qc` |
| 인력·관리·Photo | `attendance`, `admin`의 직원/급여/근태 등 하위 업무, `photo_inventory`, `photo_ops`, `photo_sales_import` |
| 원장·세무·분석 | `receipt_ledger`, `red_invoice_intake`, `report`, `restaurant_sales_export` |
| 퇴역 계약 | `delivery`: 신규 업무가 아닌 차단 응답·과거 이력 보존 검사 |

공통 Auth/terminal session, router/permissions, SQL/RLS, Edge/cron, worker, 플랫폼 어댑터와 Office 경계도 연결한다. 관리자 하위 업무를 화면 하나로 세어 누락시키지 않는다.

### 10.2 격리 fixture

- 법인 A·B는 서로 다른 POS/Office Auth/업무 식별자를 사용한다. 매장 0개부터 시작하며 ID는 생성한다.
- A 첫 매장은 주방→지정 층, B 첫 매장은 주방→트레이→층 정책을 사용한다. 실제 전가복/분식 프로필과 신규 ID 양쪽을 검사한다.
- A 추가 매장, Photo 업태 매장, 샘플, 삭제/폐쇄 이력이 있는 매장을 포함한다.
- POS와 Office 역할/직원은 별도 생성한다. 테스트 권한을 service_role 한 개로 대체하지 않는다.
- 신규/업그레이드 두 DB 구성에서 같은 필수 시나리오를 실행한다.

| ID | 연결 시나리오 | 통과 조건 |
|---|---|---|
| T01 | 매장 0개 법인 A/B → Office 법인 → 첫 매장 | seed 없이 개설, 상대 법인 접근 거부 |
| T02 | 추가 매장·업태·소유 유형 | 기존 법인 연결 재사용, capability/readiness 일치 |
| T03 | 계정·직원·역할·단말 → 영업 준비 | 직원/로그인 분리, 실제 권한, 중단 재개 |
| T04 | 홀/QR/직접 주문 → 메뉴 선택/추가/취소 | 옵션·가격·수량·재고·세금 snapshot 일치 |
| T05 | 할인 마지막 수량 경쟁 → 취소 → 정상가/후불 | 초과 배정·할인 소실 0, 잔량 정확 |
| T06 | 주방 시작/부분 완료 → 각 전달 정책 → 서빙 | 누락·중복·다른 층 오전달 0 |
| T07 | 단일/합산/분할 결제 → 환불/비매출 | 금액/원장 일치, 중복 효과 0 |
| T08 | 구매 신청 → 점장 → 구매 최종 승인 → PO → 검수/입고 | 정책 3와 과거 정책 이력, 수량/재고·문서 보존 |
| T09 | 신규 직원 근태·사진·급여·QC | 중복 입력/응답 유실 복구, 권한·시간 경계 정확 |
| T10 | 마감 → 세무·매출/메뉴/병목 분석 → Excel/PDF | 원장/집계 일치, 실제 브라우저 파일·내용 확인 |
| T11 | 사용자/법인/매장 전환·권한 회수·로그아웃 | 늦은 응답 폐기, 타 범위 표시/쓰기 0 |
| T12 | commit 후 응답 유실·탭 종료·서버 재시작 | operation 결과 재확인, 중복 결제/입고/연결 0 |
| T13 | 샘플/삭제/폐쇄·법인 이전 | 샘플 제외, 실제 과거 매출/발행 문서 귀속 보존 |
| T14 | Photo 수동 import·재고·근태/급여 | 실제 worker asset/파일 확인, 자동 수집 비활성 유지 |
| T15 | 이전 웹+새 DB / 새 웹+새 DB / Office 전후 버전 | 기존 단말 호환, 지원 불가 계약은 명시적 안내 |
| T16 | 전체 업무 + 출력/발행/알림/리포트 혼합 | 정확성 불변식과 합산 요청/DB/작업 예산 유지 |

실패 주입은 저장 직전·commit 직후 응답 유실, RTT 증가, 30초 단절, 토큰 만료, 역순 응답, 중복 이벤트, 외부 업체 중단, 자정/영업일 경계, 할인 시작/종료 경계를 포함한다. 시험은 운영과 분리한다. 실제 매장에 가짜 결제·근태·매출을 생성하지 않는다.

## 11. G7 — 장시간 시험과 운영 완료 판정

### 11.1 시험 순서

1. 30분 환경/정확성 점검과 2시간 혼합 사전 시험으로 실행기·fixture·자원 누적 결함을 먼저 찾는다.
2. 후보 코드·DB 계약·설정·부하 구성을 고정한다.
3. **실제 최소 사양 단말을 포함한 1배 부하 12시간**, **3배 데이터/동시성 12시간**을 각각 수행한다. 결과를 합쳐 24시간 한 개 PASS로 뭉개지 않는다.
4. 같은 기계에서 두 부하를 경쟁시키며 비교하지 않는다. 순차 시험을 기본으로 하고, 독립 자원과 동일한 상한이 확보될 때만 동시 실행한다.
5. 통과한 후보에서 배포 입력을 고정하고 각 저장소의 최종-main 검증과 공식 배포를 진행한다.
6. 배포 후 매장 마감 시간대 2회를 기존 관측과 제한된 진단으로 확인한다. 실제 피크가 없으면 `마감 피크 관측 미완료`로 남긴다.

클라우드 PostgreSQL/PostgREST 부하, 실제 브라우저 E2E, 실제 저사양 단말·물리 어댑터의 결과를 별도로 보관한다. 브라우저 에뮬레이션을 실제 저사양 기기로 표시하지 않는다.

### 11.2 부하 구성

G0의 관측과 실제 단말 수를 기준으로 1배 manifest를 확정한다. 출발 예시는 매장 2곳·매장당 8개 역할 lane·QR 동시 사용자 20명이며, 3배에서는 해당 동시성과 데이터량을 명시적으로 늘린다. 현재 운영 단말 수를 이 예시 숫자로 가정하지 않는다.

G6의 단기 규모 시험에서는 데이터만 3배, 동시성만 3배인 경우를 각각 측정해 원인별 증가율을 구분한다. 장시간 3배 시험은 두 조건을 합친 피크 상황의 안정성 검사로 사용한다.

각 단말의 동시 읽기·대기열·재시도 상한을 실제 앱과 같게 유지한다. 업무 이벤트는 실제 선후 관계를 따르며, 주문 없이 결제하거나 같은 operation을 새 거래처럼 반복해 부하를 채우지 않는다. 주문/결제/주방을 중심으로 구매·근태·QC·설정·리포트/Excel과 백그라운드 작업을 혼합한다. 요청 수뿐 아니라 업무 건수·종류와 그 후속 호출을 함께 기록한다.

### 11.3 수치 기준 — 제안값이며 현재 달성값이 아니다

| 항목 | 완료 목표 |
|---|---|
| 금융·수량·권한 | 중복 결제/입고, 할인 초과 배정, 전달 수량 누락, 타 법인 접근 0 |
| 정상 주요 읽기 | 서버 API P95 ≤500ms. 네트워크와 화면 표시 시간은 별도 기록 |
| 결제 | 서버 확정 P95 ≤1초, 확정 표시가 목록 재조회 완료를 기다리지 않음 |
| 주방 전달 | 정상 지정 층 반영 P95 ≤2초, 누락 변경 복구 5초 수준의 기존 요구 유지 |
| 장시간 악화 | 마지막 2시간 P95가 첫 안정 1시간 대비 20% 넘게 악화하지 않음. 절대 목표도 함께 충족 |
| heap | 안정/GC 후 기준 heap의 12시간 증가 ≤10%, 마지막 구간에 지속 누적 추세 없음. 최대 파일 peak memory 별도 기록 |
| 타이머·구독·요청 | 반복 전환/재연결 뒤 60초 내 선언한 정상 기준치로 회수, 증가 누적 0 |
| 대기열·재시도 | 경로별 상한과 합산 예산 이내, 복구 후 backlog가 측정 가능한 시간 안에 해소됨 |
| DB·작업 | 연결/락/CPU/IO/queue age를 같은 시간축으로 기록. 일시 오류가 무한 재시도·작업 폭주로 증폭되지 않음 |
| 새 연결 | 복구 후 같은 operation으로 양쪽 상태가 수렴, 중복 법인/매장/활성 매핑 0 |

정상 부하와 의도적 오류 주입 구간의 오류율/지연을 섞지 않는다. 장치의 물리 인쇄 결과 불명은 실제 확인 전 성공으로 만들지 않는다. 목표 변경이 필요하면 시험 전에 근거와 새 기준을 기록하며, 실패한 뒤 기준을 조용히 완화하지 않는다.

### 11.4 검증 증거 유효기간과 중복 방지

현재 POS 전체 검증은 6시간, Office는 원본 완료 기준 24시간 규칙을 유지한다. **12시간 시험 전에 POS 전체 recipe를 실행한 뒤 그 결과가 배포 때도 유효하다고 가정하지 않는다.**

- 장시간 시험은 별도 실행기/증거 계약을 먼저 구현한다. 제안은 원본 종료 시각부터 48시간 유효한 독립 soak 증거이며, 이는 현재 구현된 기능이 아니다.
- soak 증거는 app/SQL/계약/lockfile/도구 이미지/부하·단말·자원 설정/측정·종료·정리 로그 해시를 묶는다. relevant 입력 변경·손상·미완료·만료는 거부하고 승계로 원본 유효기간을 연장하지 않는다.
- 최종 배포 gate가 soak 입력과 최종 릴리스 입력의 동일성을 실제 검증하도록 구현한다. Git SHA가 다르다는 이유만으로 재시험하거나, 같다는 이유만으로 DB/환경 차이를 무시하지 않는다.
- 순서는 `영향 검사 → 코드 고정 → 장시간 시험 → 최종-main 전체 검증/검증된 승계 → 운영 빌드/배포`다.
- POS는 해당 릴리스의 공식 전체 검사를 한 번 실행하고 DB/웹 단계에서 재사용한다. Office는 기존 동일-tree 승계 규칙을 따른다. 두 규칙을 임의로 통일하지 않는다.
- 같은 원장/로그/앱 입력의 검사를 이유 없이 다시 돌리지 않는다. 실패 후에는 원격 이력과 완료 증거를 먼저 확인하고 지원되는 경로로 미완료 단계만 재개한다.

## 12. 배포 단위와 호환 순서

새로운 완료 작업은 제품 코드가 바뀌므로 직전 배포의 전체 검사 면제를 자동 승계하지 않는다. 두 저장소를 각각 검증하고, 연결 흐름 한 개를 두 개의 독립 완료 주장으로 쪼개지 않는다.

1. 양쪽 코드/DB/계약과 검사 목록을 준비하고 격리된 두 DB에서 먼저 완주한다.
2. POS의 추가형 연결 계약·상태와 새 POS 웹을 공식 통합 release-plan으로 적용한다. Office 새 capability가 준비되지 않았을 때 연결 기능은 `준비 중`으로 표시하고 미지원 호출을 보내지 않는다. 기존 영업은 유지한다.
3. Office DB·`pos-bridge`·관리자 확인 화면을 공식 Office wrapper로 적용한다. POS의 새 계약이 이미 존재하므로 첫 법인 연결이 가능해진다.
4. 서버에서 검증된 Office 연결 capability/결과를 확인한 POS 화면이 연결 단계를 활성화한다. 이를 위해 POS 웹을 다시 배포하지 않는다. 두 프로젝트 웹은 이 연결 릴리스에서 **각각 한 번** 배포한다.
5. 전체 연결을 확인한 뒤 신규 법인/매장 준비 완료를 판정한다. POS 쪽만 배포됐다는 이유로 Office 연결 완료를 표시하지 않는다.

POS는 `scripts/deploy_pos_production.sh`, Office는 `scripts/run_office.sh`의 기존 공식 배포 절차와 대상·권한·이력·Auth·Edge·웹 검증을 유지한다. 위 capability/증거 연결은 새로 구현·검사할 내용이지 현재 존재하는 옵션처럼 실행하지 않는다.

롤백은 검증된 이전 웹/호환 capability로 되돌리는 방식으로 준비한다. 추가형 DB 변경과 확정된 연결/금융/문서 이력은 보존한다. DB 역변경이 필요하면 별도 검토한 forward migration으로 수행하며 이미 처리된 쓰기·원장을 삭제하지 않는다. 두 DB 중간 실패는 operation 결과 조회 후 확인 단계부터 재개한다.

## 13. 최종 완료표와 보고물

최종 보고는 아래 항목을 한 파일에서 추적한다. 하나라도 필수 항목이 미완료이면 “전체 계획 완료”를 선언하지 않는다.

| 완료표 | 필요한 증거 |
|---|---|
| G0–G7 | 구현 PR/SHA, 담당, 검사 ID, PASS/FAIL/미실행/면제/차단 구분 |
| 33개 기능 | 명령/조회/scope/복구/업무 검증 연결, 비대상 사유 |
| 신규·기존 업무 | T01–T16의 UI/API/SQL·두 DB 결과와 금액/수량/권한 불변식 |
| 장시간·실단말 | 1배/3배 각각의 12시간 원본 측정, 장치 정보, 파일/물리 어댑터 결과 |
| DB | 양쪽 최종 계약 해시, migration/실제 정의/권한/trigger·index 대조 |
| 배포 | 양쪽 최종 SHA·배포 URL/ID·자산 해시·운영 주소·공식 종료 코드 |
| 운영 성능 | 배포 후 마감 2회 시계열, 지연/오류/연결·락·queue/단말 자원 |
| 한계·면제 | 기존 로그인 스모크 면제, 복구 불가능한 과거 시점 지표, 기타 필수 미실행의 실제 상태 |
| 경과 시간 | 개발/시험/외부 대기/실패 복구/재사용을 구분하고 walltime을 중복 합산하지 않음 |

코드만 완료된 항목을 운영 확인 완료로 올리지 않는다. 운영 로그인 스모크 면제는 계속 명시적으로 남으며 이 계획으로 로그인 정상 판정을 만들지 않는다. 그 외 필수 범위를 새로 생략하지 않는다.

## 14. 근거와 현재 실행 상태

- POS [기존 통합 계획](https://github.com/ahc0403-commits/globospossystem/blob/6de6702e6cc62497623070f6f9cae70c5cc7a502/docs/pos/resilience/INTEGRATED_IMPROVEMENT_PLAN_KO.md), [구현/잔여 ledger](https://github.com/ahc0403-commits/globospossystem/blob/6de6702e6cc62497623070f6f9cae70c5cc7a502/docs/pos/resilience/IMPLEMENTATION_STATUS_20261031.md).
- POS [기존 Office 준비/확인 계약](https://github.com/ahc0403-commits/globospossystem/blob/6de6702e6cc62497623070f6f9cae70c5cc7a502/supabase/migrations/20261022170000_store_operational_acceptance.sql).
- POS [scope](https://github.com/ahc0403-commits/globospossystem/blob/6de6702e6cc62497623070f6f9cae70c5cc7a502/lib/core/utils/live_sync_scope.dart), [갱신 조정](https://github.com/ahc0403-commits/globospossystem/blob/6de6702e6cc62497623070f6f9cae70c5cc7a502/lib/core/utils/coalesced_refresh.dart), [근태 복구](https://github.com/ahc0403-commits/globospossystem/blob/6de6702e6cc62497623070f6f9cae70c5cc7a502/lib/features/attendance/attendance_kiosk_provider.dart).
- Office [기존 매장 앵커 기반 매핑](https://github.com/ahc0403-commits/restaurant_office_app/blob/8b24d58836b6014d62c498c3f17c106b7da398e8/supabase/migrations/20261019105000_verified_pos_store_mapping.sql), [`pos-bridge` sync](https://github.com/ahc0403-commits/restaurant_office_app/blob/8b24d58836b6014d62c498c3f17c106b7da398e8/supabase/functions/pos-bridge/index.ts#L2862), [Office 법인/매장 관계](https://github.com/ahc0403-commits/restaurant_office_app/blob/8b24d58836b6014d62c498c3f17c106b7da398e8/supabase/migrations_legacy/503_legal_entity_operating_scope_foundation.sql).
- 기존 [전체 schema 업그레이드 시험](https://github.com/ahc0403-commits/globospossystem/blob/6de6702e6cc62497623070f6f9cae70c5cc7a502/scripts/test_store_operating_upgrade.sh), [제한된 KDS 부하 실행기](https://github.com/ahc0403-commits/globospossystem/blob/6de6702e6cc62497623070f6f9cae70c5cc7a502/scripts/tests/jeongabok_kds_sync_load.py)는 재사용하되 전체 혼합/실단말 장시간 시험 완료로 간주하지 않는다.

이 계획 수립에서는 운영/제품 코드를 변경하거나 DB/배포를 실행하지 않았다. 기존 사용자 작업 경로와 checkout을 보존했다. 새 표준 타입·연결 요청·soak 실행기·증거 검증·capability 전환은 모두 앞으로 구현할 산출물이다.

## 15. 실행 기록 — 2026-11-01 진행 중

- 거버넌스 PR #653과 G0/G1 시험 도구 PR #654는 main에 반영됐다.
- 실제 샘플 POS 8개 + Office 1개 계정을 확인하고 Git 밖 0600 설정에 저장했다.
  원본 로그인/자기 프로필 시험은 9개 인증 통과이며 sp_order/sp_pr1의
  초기 설정도 기존 정상 비밀번호 변경 경로로 완료해 9개 역할 모두 준비됐다.
- POS 5,819 / Office 9,359 metadata object의 실제 계약 해시를 확보했다.
  현재 schema-only DDL에 의한 fresh/upgrade 복원 증거는 확보 대기다.
- G3: 공통 결과/scope/조회 lifetime을 추가하고 주문 상세에 동시 읽기 1개+후속 1개,
  전환/종료/로그아웃 후 늦은 응답 차단을 연결했다. QC 주간/기간/후속조치/이슈 조회도
  매장·조회 조건 전환과 disposal을 보호한다. 전체 도메인 결과 adapter 전환은 남아 있다.
- G4: 할인 잔량 statement 변경 집합을 매장별 1개 transaction event에 묶고 최대
  100개 메뉴 ID를 전달한다. 기존 INSERT signal을 유지하며 새 reader는 UPDATE도
  병합한다. 메뉴는 해당 ID의 수량 컬럼만 읽고 전체 catalog/카테고리는 재조회하지 않는다.
  ID 없는 구 이벤트/복구 신호는 기존 전체 조회로 복구한다.
- 개발 영향 검사: 결과/읽기 계약·QC·메뉴 병합 19개와 실제 HTTP 주문 전환 3개 통과.
  기존 할인 SQL 검사에 새 migration/event 검사를 포함해 PostgreSQL 17에서 통과했다.
  마지막 수량 동시 주문·취소 복구·후불 할인·기존 50% 정책·원래 결제 함수 보존을 포함한다.
  이는 작업 중 입력에 대한 결과이며 최종-main 전체 검증 PASS가 아니다.
- Office 별도 작업 공간: 정확히 200개라는 이유로 실패하던 연결 목록을 선택 manifest
  최대 200개/키셋 page로 바꿨다. 8개 영향 검사와 bridge 타입 검사 통과.
  최초 법인 연결의 지속 작업·양쪽 확인 UI를 구현했다. 독립 PostgreSQL DB/Auth
  fixture에서 20개 검사, Office bridge/배치/준비 상태 21개, 확인 화면 POS 3개/Office 3개 통과.
  새/기존 법인 명시적 선택, 20회 동시/반복 확정, 응답 유실/만료 후 재개, 첫 매장,
  별도 브랜드 ID의 구매 연결 및 정지 계정 제외를 포함한다. 이는 부분 fixture이며
  현재 전체 schema 복원·실제 두 앱 브라우저·신규 매장 전체 업무 검증은 남아 있다.
- 실제 매장 최소 사양 단말 배정, 최신 POS/Office schema-only 덤프 경로를 요청했다.
  사용자 샘플 계정 제공만으로 물리 단말·인쇄·12시간 부하를 PASS로 만들지 않는다.
- G5/G6/G7 전체 완료 및 1배/3배 각각 12시간 시험, 운영 배포·마감 2회 관찰은 미완료다.
  제품 코드가 아직 고정되지 않아 장시간 시험을 최종 후보 증거로 시작하지 않았다.

### G5 화면 반복 갱신 — 개발 증거

2026-11-01 KDS의 시계/점멸을 화면 setState에서 카드/선택 상세의
ValueListenableBuilder로 옮겼다. 상위 화면·board의 주문 분류/정렬/페이지 구성은
시간 tick만으로 재실행하지 않는다. 카드의 메뉴 projection도 tick builder 밖에 둔다.
기존 주방/트레이/층 시계, 점멸, 부분 전달·서빙·guest floor 검사를 포함한
영향 검사 99개가 통과했다. 새 3초 측정에서는 상위 화면/board/card widget의
build 호출 0회와 시간 표시 진행을 함께 확인했다. 100회 화면 진입/종료도 통과했다.
이는 Flutter debug fixture의 측정이며 실제 장시간 heap·reconnect·물리 단말 성능,
구매/계산대/관리자 화면 분리는 아직 미완료다. 원본 개발 로그는
`/workspace/scratch/pos-resilience-completion-dev/kds-render-tests.log`에 보존했다.

### G2 순차 배포와 권한 회수 — 개발 증거

POS는 Office 서버가 보고한 version 1 준비 상태가 있어야 새 연결을 생성한다.
Office의 기존 인증된 구매 연결 cron(현재 실제 매분 실행)이 Office DB 계약을 확인한 뒤
POS에 준비 상태를 보고한다. 매장 수와 무관하게 2회 호출, 전체 3초 abort 예산이다.
보고 실패는 기존 구매 연결 작업을 중단하지 않는다. POS 보고 유효기간은 15분이며
새 연결의 시작에만 적용한다. 기존 operation의 조회/확정 결과 복구는 보존한다.
POS 관리자 권한이 Office commit 이후 회수되면 POS 확정은 재확인 상태로 남긴다.

독립 DB/Auth fixture 20개와 Edge 준비 상태 3개, POS 확인 화면 3개 영향 검사가
통과했다. 공식 전체 recipe, 운영 capability 전환과 두 앱 브라우저 시험은 미실행이다.

### 다음 실행의 실제 선행 조건

당시 미확보였던 최신 schema-only 입력은 아래 G1 추가 작업에서 관리형 HTTPS
카탈로그 추출·의미상 복원 대조·native pg_dump 재복원으로 확보했다. DB TCP 연결이나
임의 토큰 추출을 사용하지 않았다. 실제 샘플 단말/접속 시간은 아직 미확보다.
HTTPS 관리 연결과 검증 계정 인증도 확보했으므로 인증 부재로 기록하지 않는다.
현재 스키마 확보는 전 업무·실단말·장시간 검증의 완료와 구분한다.

G3의 금융·재고·주방·근태 등 전 도메인 명령/unknown 복구, G4의 결제 목록/상세와
전체 worker 합산 예산, G5의 나머지 큰 화면/파일 상한, G6의 T01–T16/2시간 혼합,
G7의 frozen 후보·실제 1배/3배 각 12시간·공식 배포/마감 관측은 아직 완료하지 않았다.
장시간 작업은 백그라운드에도 시작하지 않았으며 현재 12시간 PASS 증거는 없다.
이 상태에서 최종-main 전체 recipe를 먼저 반복하거나 운영 DB/웹을 부분 반영하지 않는다.

### G0 Office 전체 검증 계정 — 2026-11-01 추가 요청

Office Auth 23개와 프로필 23개를 일괄 대조했다. 고아 Auth/프로필은 각각 0개다.
현재 유효한 native grant 273개를 계정별 사전 집계해 역할/접근 범위와 함께
Git 밖 `/workspace/.private/office-validation-accounts.json`에 저장했다.
동일한 사용자 제공 비밀번호 참조와 검증용 계정 선택자는 같은 디렉터리의
`office-validation.env`에 보관한다. 디렉터리 0700, 파일 0600이며 본문/토큰/비밀번호를
일반 문서나 로그에 넣지 않는다. 현재 20개는 credential 준비 조건을 만족하고
3개는 비활성이라 실제 시험 계정 선택에서 제외한다. 전체 계정의 비밀번호를
인증한 결과로 간주하지 않으며, 운영 계정 비밀번호/권한/활성 상태는 변경하지 않는다.

새 `scripts/resilience/office_accounts.py`는 전체 목록 해시/대상/중복/완전성을 확인하고
Office 최초 법인 관리자와 샘플 매장 구매/품질/재무에 필요한 최소 계정을 선택한다.
이름으로 권한을 추정하거나 샘플 역할에 다른 매장/그룹 관리자를 대입하지 않는다.
로그인은 계정당 1회, 동시성 1, 자동 재시도 0이며 생성한 세션만 local logout 한다.
검증 중 정체성/역할/scope가 바뀌거나 응답·정리가 불명이면 실패/UNKNOWN으로 남긴다.
기존 sample 도구를 포함한 계정 검증 도구 영향 검사 28개가 통과했다.
실제 연결 업무/신규 후보 E2E/전체 장시간 시험 PASS로 승격하지 않는다.

추가로 실제 최소 계정 2개의 로그인/본인 프로필/현재 native grant를 확인했다.
법인 관리자 및 샘플 매장 구매·품질·재무 4개 역할 lane을 충족하며, 생성한 세션은
각각 local logout으로 정리했다. 기존 운영 bridge의 config_status 읽기도 성공했다.
이는 `PASS_SELECTED_IDENTITIES`이며 23개 전체 비밀번호 인증이나 신규 후보 법인
연결 E2E 성공이 아니다. private readiness 결과는 같은 비공개 디렉터리에 보관한다.

### G3/G4/G5 주방 항목 전달 복구 — 개발 증거

항목별 진행 요청을 HTTP 전에 원래 event UUID/actor/store/session/station/floor와
함께 저장한다. 저장되지 않았다고 확인된 경우 전송하지 않고, 저장/전송 결과가
불명인 경우 `unknown`으로 보존한다. 확정된 전달은 후속 새로고침/정리 실패로
실패 처리하지 않는다. 자동 복구는 prepared 요청을 보내지 않고 결과부터 조회하며,
명시적 새로고침 복구는 원래 ID와 payload를 재사용한다. 로그아웃/담당 변경 뒤
이전 요청을 새 범위로 재전송하거나 응답을 새 화면에 반영하지 않는다.

전가복의 실제 kitchen batch 요청 UUID는 완료 event UUID와 다르므로, 신규 읽기
RPC `get_kds_progress_receipts_v1`이 두 원장을 요청 100개씩 집합 조회한다.
private batch 테이블의 직접 SELECT 권한을 확대하지 않고 현재 활성 actor/store를
서버에서 확인한다. 추가형 migration은
`20261101045728_kds_progress_receipt_reconciliation.sql`이며 운영에는 미적용이다.
기존 수량 계산·층/체커 routing·결제·할인 allocator는 수정하지 않는다.

구버전 탭이 새 미확정 요청을 자동 재전송하지 않도록 새 진행 journal을 별도
IndexedDB/native 키로 분리했다. 원래 intent 순서를 보존하고 새 journal은 1000건
상한을 둔다. 전송은 round당 최대 20건/15초, 결과 조회도 전체 15초 및 RPC당
100개/256 KiB 상한이다. read/write transport는 소유자 dispose 시 회수한다.
기존 legacy 전체 저장소 읽기와 모든 worker 합산 예산까지 완료했다는 뜻은 아니다.

개발 영향 검사 결과:

- 주방 항목 journal 14개 PASS. 초기 검사에서 이 새 시험 파일의 이름 참조 오류로
  컴파일 실패했고 수정 후 해당 파일만 재실행했다. 나머지 4개 영향 파일은 같은 앱
  입력에서 117개 PASS다. 이 분할 결과는 최종-main 통합 전체 검증이 아니다.
- 변경 Dart 파일 정적 분석: 오류/경고/정보 0개.
- 실제 Chromium 154/Debian 13 격리 저장/구버전 호환/체크섬/1000건/페이지 새로고침
  6개 PASS. 공식 recipe의 고정 Chromium 156/Ubuntu 24.04 실행은 아직 미실행이다.
- PostgreSQL 17 격리 부분 fixture의 receipt/권한/다른 매장/다른 actor/동시 읽기
  7개 PASS. synthetic event 100001건에서 요청 100개, 30회 server P95 1.6577ms,
  response 33900 bytes다. 운영 실측 또는 전체 schema 복원 증거가 아니다.

이 단계는 항목 진행 명령의 복구를 보강한 것이다. 나머지 batch/undo/packaging
명령에는 원래 actor/assignment scope와 transport deadline을 추가했지만 아직 기존
bool 결과/실패 후 저장 경로가 남아 있다. 전 도메인 규약 완료, T01–T16 전체 업무,
2시간 혼합 부하, 1배/3배 각각 12시간, 최종-main 전체 recipe 및 공식 배포는 미완료다.
원본 개발 로그는 `/workspace/scratch/pos-resilience-completion-dev/`에 보관한다.

### G3 계산대 메뉴 변경·QC 후속조치 — 추가 개발 증거

계산대의 취소/복구/수량 변경/메뉴 이동 6개 경로는 서버 확정과 후속 조회를
분리했다. 확정 뒤 조회 실패가 false로 바뀌지 않고, 처리 중 A→B 이동·dispose
뒤에는 A를 다시 불러오거나 B의 선택/오류를 덮지 않는다. 중복 클릭과 현재 매장과
다른 매장의 요청은 전송 전에 거부한다. 늦은 고객표시 응답도 원래 generation에서만
표시 추적/오류를 갱신한다. 기존 서버 명령/operation ID·원장 규칙은 유지했다.

QC 후속조치 생성/상태 변경은 원래 조회 generation과 필터를 보존하고, 매장/필터
전환·dispose 후 과거 응답이 화면을 변경하지 않는다. ReadEpoch checkpoint는 읽기를
새로 시작하지 않으며 A→B→A 복귀도 과거 응답을 다시 유효하게 만들지 않는다.
새 mutation RPC나 항목별 조회/자동 재시도를 추가하지 않았다.

영향 6개 시험 파일 49개가 함께 PASS, 변경 Dart 정적 분석은 오류/경고/정보 0개다.
원본은 `command-scope-final-affected.log`, `command-scope-final-analysis.log`다.
이 결과는 final-main 전체 recipe/금융 unknown 복구/전 도메인 전환 완료가 아니다.

### G1 현재 스키마 추출·복원 경로 — 초기 실험 이력(후속 결과는 아래 참조)

현재 관리형 HTTPS 카탈로그 조회로 POS 애플리케이션 객체 4516개, Office 8468개를
확보하고 추출 전후 정의 해시 일치를 확인했다. 함수 본문·타입·열·제약·인덱스·
트리거·RLS/GRANT·기본 권한과 실제 migration 이력 해시를 Git 밖 0700/0600 경로에
보관한다. 업무 행·Auth 비밀번호 해시·vault 값·cron 명령/예약 행은 수집하지 않았다.
관리형 Auth/Storage 및 확장 객체 의존성을 포함한 격리 복원·의미상 카탈로그 대조와
native pg_dump 재복원이 아직 필요하다. 현 시점의 카탈로그 확보를 전체 복원 PASS나
G1 완료로 기록하지 않는다. 운영 DB 스키마·업무 데이터는 이 추출로 변경하지 않았다.


### G1 현재 스키마·후보 마이그레이션·기존 거래 — 추가 검증

관리형 Auth/Storage 정의를 함께 확보한 현재 입력은 POS 4878개 객체, Office
8834개 객체다. 두 프로젝트 모두 재구성 → 의미상 카탈로그 대조 → native pg_dump
→ 별도 빈 격리 컨테이너 재복원 → 동일 대조를 통과했다. 테이블/열/함수/제약/인덱스/
트리거/RLS/테이블·열·함수 GRANT/기본 권한을 비교한다. PostgreSQL deparser의
UNION 분기 text 상수 기본 alias, ACL 집합 순서와 삭제 열의 물리 번호 공백만
정규화한다. 값·연산·출력 열·열별 권한 차이는 거부한다. 모르는 namespace/type/
언어/관계/rule/publication 형태도 별도 inventory에서 0인지 확인한다.

자료는 Git 밖 `/workspace/.private/db-snapshots-v2/`(디렉터리 0700/파일 0600)에
보관한다. `*-current-application-schema.sql`은 native schema-only dump이고,
Storage 버킷 참조 설정은 별도 JSON이다. POS 10개, Office 6개의 STANDARD 버킷
공개 여부·크기/MIME 제한만 보존하며 파일/객체·Auth 비밀번호 해시·업무 행·cron
예약/명령은 복사하지 않았다. fixture에서는 그 버킷 설정만 집합 INSERT 한다.

현재 전체 스키마를 복제한 격리 DB에서 다음 후보 SQL의 적용 및 자체 검사가 성공했다.
운영 적용은 아직 하지 않았다.

- POS: `20261101022105`, `20261101023409`, `20261101045728` 순서.
- Office: `20261101023410`. Office 소스는 별도 작업 공간/브랜치에서 읽는다.

POS 기존 거래 upgrade 시험은 500개 활성 주문선·취소 소비분·부분 결제 2건
(합계 16200000 VND)·재고 이력 1002건·비동기 invoice job 1건을 먼저 확정했다.
후보 3개를 적용한 전후 금융/수량/이력 9개 테이블의 행 수·내용 hash가 같았다.
적용 뒤 원본 500-line 결제/재고 시나리오도 다시 성공했다. 재현 데이터는 모두
격리 DB에서 생성했으며 실제 매장 거래·출력/발행 업체 호출은 생성하지 않았다.
별도 기존 `test_store_lifecycle_atomic_release.sh --deployed-schema`의 전체 시나리오도
현재 스키마와 참조 설정에서 통과했다(등록 지표: 계정 6개, 307ms, preview 1202 bytes).
단일 fixture의 관측이며 운영 성능 향상이나 전체 T01–T16 완료가 아니다.

버전 관리하는 추출/복원 도구는 `scripts/resilience/schema_*.sql`,
`schema_snapshot.py`, `integration_schema_snapshot.py`, `run_schema_fixture.py`다.
읽기 전용 SQL의 SCOPE는 도구의 고정 SCOPES와 같게 치환한다. 전체 identity/hash
manifest를 먼저 받고, 정렬된 identity 묶음으로 body를 읽어 각 hash와 대조한 뒤
전체 manifest를 다시 대조한다. 본문/비밀 값을 채팅·일반 로그·Git에 출력하지 않는다.
예전에 받은 동일 hash의 body는 재사용하고 추가/변경된 body만 다시 받는다.
bootstrap/unsupported inventory/버킷 설정은 각 고정 SQL로 별도 확보한다.

소유권·이미지 정책과 네트워크 격리/전체 로그/정리 확인을 포함하는 실행 예시는:

```bash
python3 -B scripts/resilience/run_schema_fixture.py pos \
  --snapshot-dir /workspace/.private/db-snapshots-v2 \
  --output /workspace/.private/NEW-pos-schema-upgrade-evidence \
  --native-roundtrip --candidate-upgrade --exercise-existing-transactions
```

Office는 `office --native-roundtrip --candidate-upgrade --office-root /absolute/Office`
옵션을 쓴다. output은 새 Git 외부 디렉터리여야 하며 기존 결과를 지우거나 덮어쓰지
않는다. 준비 검사는 Docker 시작 전에 수행한다. runner는 자신의 label/run ID만
정리하고 정리 실패·외부 run receipt·timeout·미완료를 PASS로 만들지 않는다.
이 개발 증거는 공식 배포 receipt가 아니며 main 전체 recipe/운영 적용을 대신하지 않는다.

Realtime 전송은 기존 SQL fixture의 append 어댑터로 모델링했다. 실제 Realtime
브라우저 전달, MISA·물리 출력, 모든 사업 참조 데이터·두 앱 생애주기와 G6 혼합/
G7 12시간 시험은 아직 별도 증거가 필요하다. 이 단계로 G0–G7 완료를 선언하지 않는다.

현재 schema/runner 도구 단위 검사 17개가 통과했다. 실제 versioned runner로 POS
기존 거래 upgrade를 실행해 PASS/exit 0/소유 resource 정리 확인을 기록했다.
원본 결과는 `/workspace/.private/resilience-pos-upgrade-evidence-20261101/result.json`과
동일 디렉터리의 전체 로그이며, 각 실행에 source/input/tool/log hash와 run ID를 묶는다.
운영 배포·1배/3배 각 12시간 시험은 아직 시작하지 않았다.


### G3 전역 세션 scope 연결 — 추가 구현

앱 root의 operation scope를 실제 Auth/profile 변경에 연결했다. actor·신뢰한 role·
활성 법인/매장·허용 매장/브랜드/법인·추가 권한을 반영하며, 정렬/중복 제거한 로컬
profile hash를 사용한다. 이 hash는 서버 authorization revision이 아니고 RLS를
대체하지 않는다. 사용자 수정 가능한 user_metadata나 표시 이름·토큰 갱신·loading/
오류는 권한 근거로 쓰지 않는다. 기존 일괄 매장 조회에 tax_entity_id 열만 추가했고
새 RPC·항목별 원격 조회·폴링은 추가하지 않았다. 기존 프로필 캐시와도 호환된다.

root의 eager listener가 A→B→A 전환도 세 번의 독립 lifetime으로 처리한다. 인증이
없거나 비밀번호/동의 절차가 필요한 bound session의 새 조회는 전송 전에 실패한다.
core가 Auth/화면을 역참조하지 않도록 Auth adapter를 root override에만 설치한다.

23개 실제 데이터 FutureProvider(인증 단순 상수 provider 제외)에 session generation을
연결했다. 이전 generation의 Future는 현재 캐시를 덮지 않는다. QC 후속조치/issue
두 notifier도 scope 변경 때 이전 목록·진행 중 조회 lifetime을 폐기한다. 기존 수동
로그아웃 목록에서 빠졌던 두 상태를 포함한 수정이다. 확정된 QC 후속 쓰기는 사용자
전환 뒤에도 확정으로 반환하고 옛 매장을 재조회하지 않는다. 아직 다른 모든 legacy
StateNotifier나 결제 unknown 처리까지 전역 규약을 적용한 것은 아니다.

개발 증거: 초기 새 scope/QC 검사 23개 PASS, 기존 인증/매출/관리자 scope 관련
5개 파일 50개 PASS, 변경 Dart 파일 정적 분석 오류/경고/정보 0개. 추가 100회
동일 profile 갱신/100회 scope 변경 검사는 별도 최종 로그에 기록한다. 이는 실제
기기·혼합 부하·12시간 관측 또는 최종 main 전체 검증/운영 배포 증거가 아니다.
원본 로그: operation-scope-binding-test.log, operation-scope-existing-regressions.log,
operation-scope-analysis.log, operation-scope-binding-final.log.


### G3 단일 결제 결과 원장 — 서버 계약 추가, 계산대 연결 미완료

`20261101094500_payment_command_receipts.sql`은 새 private schema/결과 원장과
`process_payment_once_v1`, `get_payment_command_receipts_v1`만 추가한다. 기존 단일/
합산/비매출 결제·프로모션 결제 내부 함수들의 정의 hash는 적용 전후 같았다.
원래 Auth/업무 profile/매장과 operation UUID를 묶어 직렬화하며, 같은 요청은 처음
확정된 결과를 돌려준다. 같은 UUID에 다른 금액·수단·주문을 넣으면 거부한다.
서버 오류 시 금융 변경과 결과 원장을 함께 rollback한다. 조회는 UUID 최대 100개를
집합 처리하고 현재 유효한 본인 역할·매장 접근을 다시 확인한다. PIN·토큰·전체
요청을 기록하지 않는다. 이력은 중복 방지 근거이므로 자동 만료/삭제하지 않는다.

PaymentService에는 원래 UUID를 받는 별도 API와 결과 조회·식별 검증을 추가했다.
**기존 계산대 호출을 이 API로 전환하거나 durable intent/recovery UI를 연결한 것은
아니다.** 분할 결제의 항목별 호출, 합산/비매출/인쇄 등 복구도 아직 남아 있다.
이 단계만으로 운영 결제 응답 유실 문제가 해결됐다고 보고하지 않는다.

현재 스키마의 권한 함수는 `user_accessible_stores(uuid) RETURNS SETOF uuid`다.
초기 작은 fixture가 반환 열 이름을 만들어 후보 KDS 조회의 호환성 오류를 놓쳤다.
45728/94500의 호출에 명시적 위치 열 alias를 쓰고 작은 fixture도 실제 scalar 반환으로
수정했다. 실제 현재 스키마의 주방 사용자 조회와 기존 KDS 7개 검사가 통과했다.
두 DB의 실제 migration 이력을 다시 읽었으며 신규 후보 5개 버전은 모두 미적용이었다.
기존 운영에 적용된 migration을 수정한 것이 아니다.

시험 중 pinned Supabase 이미지의 supautils 권한 오류 GRANT 안내 hook이 익명
함수 실행 거부 시 signal 11을 발생시키는 것을 확인했다. 변경 없는 빈 이미지의
단순 함수로도 재현됐다. 권한/역할/RLS를 바꾸지 않고 owned 시험 연결의 PGOPTIONS에
`-c supautils.hint_roles=`만 지정했다. 익명 함수 실행이 실제로 거부되고 DB가 살아
있는지 복원 전에 검사한다. 운영 설정은 변경하지 않았다. 이 격리 이미지 재현을
운영 DB의 야간 장애 원인으로 단정하지 않는다. 실패 실행과 원본 로그도 보존한다.

영향 검증: 새 클라이언트/기존 프로모션 복구 15개 PASS, 결제·분할·합산·비매출·
인쇄/세금 관련 기존 계약 12개 파일 75개 PASS, 새 Dart 분석 오류/경고/정보 0개.
스키마/runner 단위 22개 PASS. native current-schema 실행은 후보 POS 4개를 순서대로
적용하고 이전 9개 금융/수량 이력 hash 보존과 원래 500-line 시나리오를 통과했다.
새 금융/권한 시나리오 22개도 PASS: 응답 폐기 뒤 조회/동일 ID 재전송, 변경 payload
거부, 다른 사용자/매장·비활성 사용자·익명·private 테이블 차단, 4-worker 8회 전달,
결제·재고 차감·invoice job 각각 1회, 서로 다른 payload 동시 충돌을 검증했다.

실제 native 결과는 `/workspace/.private/resilience-payment-receipts-evidence-20261101-v4/`에
보관했다(PASS, exit 0, 37.82초, owned resource 정리 확인). 이 실행은 개발 중 dirty
source 증거이며 final-main 전체 검증/배포 receipt가 아니다. 기록의 replay 시간에는
충돌/조회 후속 검사도 포함하므로 단일 RPC/P95 또는 운영 성능 수치로 쓰지 않는다.
원본 개발 로그: payment-receipts-client-test.log, payment-service-existing-contracts.log,
payment-receipts-client-analysis.log, payment-schema-tools-final-unit.log,
kds-scalar-access-contract.log 및 fixture-acl-isolation-probe-v2~v6.log.

향후 현재 스키마를 다시 추출할 때 pos_command_private가 존재하면 manifest에도
포함해야 한다. 알려진 신규 namespace는 선택적으로 허용하되 실제 inventory에
존재하는 schema를 manifest에서 빼거나, 없는데 있다고 선언하면 거부한다.
실행 예시에 `--exercise-payment-receipts`를 더하면 native 금융/권한 검사를 포함한다.
운영 배포·2시간 혼합 부하·1배/3배 각 12시간 시험은 아직 시작하지 않았다.


### G3 설정·리포트 전환 — notifier와 호출 화면 함께 연결

설정과 리포트 notifier 두 개도 root session scope에 연결했다. 상태만 폐기하면 같은
매장의 사용자/권한 변경 뒤 화면 초기화 조건이 충족되지 않아 빈 화면이 남을 수
있었다. 실제 두 화면의 초기 조회 기준을 사용자·매장·session generation으로
바꾸고, 구세대 microtask/PIN 후속 단계·오류/toast를 현재 화면에 적용하지 않는다.
설정 화면은 요청한 사용자/매장의 확인된 데이터만 입력란에 동기화한다.

설정 저장은 원래 view generation을 유지한다. 중복/동시 양식 전송, 최초 조회 중
저장을 막고 저장 중 같은 범위의 불필요한 조회를 생략한다. 이전 조회가 저장값을
되돌리거나, 무효화된 Future가 다음 조회를 계속 가로막는 일이 없도록 처리했다.
A→B→A·계정 전환·dispose 뒤 확정된 저장은 true를 유지하며 이전 상태를 덮지 않는다.
per_person_charge=NULL 저장/조회가 실제로 표시값도 지운다. 같은 범위의 일반 갱신은
사용자가 아직 저장하지 않은 입력과 포커스를 보존한다.

21개 영향 검사 PASS: 새 실제 설정/리포트 위젯 2개, 설정 명령 10개, 기존 배경 갱신
1개/화면 계약 4개/리포트 조회 1개, 기존 설정 대화상자·휴대폰 작업 공간·미저장
입력/포커스 3개. 변경 Dart 분석 오류/경고/정보 0개다. 원본은
settings-report-session-views.log, settings-existing-overlay-regressions.log,
settings-unsaved-and-phone-regressions.log, settings-report-scope-analysis.log다.
기존 미리 채운 UI fixture는 view predicate를 명시적으로 공급하며, 새 전환 시험은
실제 notifier/factory/root Auth binding과 두 화면을 사용한다.

설정의 전송 결과 불명 서버 계약, 엄격한 PIN 조회 실패 표현, 모든 인쇄/파일 단계의
권한·자원 정리, 나머지 legacy notifier는 여전히 별도 잔여다. 위 시험을 전 도메인
규약·혼합 부하·최종 main 전체 검증·운영 배포·12시간 시험 완료로 표시하지 않는다.


### G5 네이티브 JSON 작업자 누적 — 재현/수정/실측

Postgrest 2.6.0은 임시 PostgrestClient마다 네이티브 JSON isolate를 만든다. KDS
gateway와 이번 복구 코드의 조회/명령 client 두 곳은 HTTP만 닫고 JSON worker를
닫지 않았다. 실제 native Flutter VM에서 gateway 조회 100회를 실행했을 때 worker를
포함한 isolate 수가 3→103으로 늘었다. 운영 DB/실제 네트워크 없이 mock HTTP와
실제 KDS gateway/Postgrest/VM service를 사용한 재현이다.

세 경로 모두 JSON worker를 정리하며, KDS RPC의 전체 deadline에는 JSON 초기화/
인코딩/디코딩도 포함한다. HTTP 취소는 기존 물리 abort 경로를 유지한다. 정리
실패/지연은 최대 2초의 별도 예산과 상수 크기 진단 counter에 남긴다. 확정된 주방
명령/증빙 첨부 결과를 failed/queued로 바꾸거나 원래 전송 오류를 덮지 않는다.
증빙 처리도 HTTP wrapper를 닫고 같은 JSON 정리 규칙을 사용한다. 새 조회/자동
재시도/DB 변경을 추가하지 않았다. 나머지 증빙 metadata batch/scope 검토는 별도다.

수정 뒤 정상 100회, 권한 거부 100회 각각 실제 isolate 수 2→2였다(각 warmup
포함 HTTP 101회, 동시성 1). `native_rpc_resource_probe.dart`는 기본 *_test.dart
자동 실행 밖의 명시적 entry이며, 공식 recipe에 `native-kds-json-resources`로
등록했다. `--enable-vmservice --machine`으로 두 경우를 필수 실행한다. 공식 count
parser도 2 PASS/0 FAIL/0 SKIP으로 판정했다. VM 통계 조회에 실패하면 PASS/skip으로
대체하지 않는다. 관련 runtime 검사 39개, 증빙 재시도 1개와 native 2개가 통과했고
검증 recipe 도구 계약 28개도 통과했다. 변경 Dart 분석 오류/경고/정보 0개다.

원본 개발 로그: native-kds-resource-before.log(재현 FAIL),
native-kds-resource-after.log, native-kds-resource-errors.log,
native-kds-resource-final-entry.log, kds-rpc-resource-affected.log,
proof-owned-resource-regression.log, kds-rpc-resource-analysis.log,
native-resource-recipe-contract.log. 개발 Linux native debug VM의 작은 합성 응답
시험이다. 웹의 YAJsonIsolate는 worker를 만들지 않으므로 이 실측을 웹 야간 지연
원인이나 운영/실기기 성능 향상의 증거로 바꾸지 않는다. 실제 웹 혼합 부하, 전체
자원/worker 합산 예산, 최종 main 전체 recipe와 운영/12시간 시험은 여전히 미완료다.

### G3/G4 조회 요청의 수명·상한과 리포트 연속 조건 변경

설정/리포트의 읽기는 공유 Auth HTTP client를 닫지 않는 OwnedReadSession을 사용한다.
원래 actor/JWT를 포착하고 물리 전송 전 사용자 변경을 거부한다. SDK의 만료 토큰
갱신은 공유하며 자동 업무 재시도를 추가하지 않는다. 조회 세션은 table GET/HEAD와
검토한 RPC만 허용하고 INSERT/UPDATE/DELETE 및 미등록 RPC를 전송 전에 거부한다.
전체 조회 예산은 15초이며 JSON 초기화·연속 읽기 간격도 포함한다. 리포트 응답은
4 MiB, 설정 metadata는 응답당 128 KiB를 넘으면 명시적으로 실패한다. 합계를 자르는
방식으로 성공 처리하지 않는다. 설정의 두 고정 조회는 한 예산을 사용한다.

같은 리포트 진행 요청 20회는 한 Future/HTTP 요청을 공유한다. 날짜를 빠르게
100회 바꾸면 실행 중 요청과 마지막 후속 조회만 남긴다. 이전 HTTP/JSON 정리가
끝난 후 다음 client를 시작하며, 새 조건을 요청하는 즉시 이전 합계를 숨긴다.
완료 데이터를 무기한 캐시하지 않으며 새 폴링/이벤트를 도입하지 않는다.

개발 영향 검사 고유 26개 PASS(앞선 25개와 추가 연속 조건 변경 1개). 실제 TCP
응답 중단, 공유 Auth transport 보존, 두 만료 세션의 인증 갱신 1회, 원래 JWT 보존,
actor 변경 전송 0회, 크기/시간 초과 및 화면/저장 회귀를 포함한다. 마지막 리포트
4개 재실행과 Dart 분석 0건의 로그는 report-coalescing-tests.log,
owned-read-final-coalescing-analysis.log이며 앞선 증거는 owned-read-lifetime-final.log다.
이 수치는 합성 client 검사이며 전체 DB 비용/운영/실단말/12시간 증거가 아니다.

실제 PostgreSQL/PostgREST의 리포트·엑셀 대상 검사는 별도 개발 fixture로 실행한다.
도구 이미지 복제 시 디스크 부족과 Flutter 내부 의존성 초기화 지연을 확인했으므로
이 실패는 PASS로 집계하지 않는다. 오프라인 SDK 내부 의존성 준비로 지연 원인을
확인했다. 후속 개발 실행은 소유한 작은 네트워크 anchor와 기존 관리형 Debian 13
호스트 도구를 사용하며 Ubuntu 24.04 최종 recipe 증거로 대체하지 않는다. 공식 전체
검사 전에는 기존 디스크 사전 점검을 다시 충족해야 한다. 금융 fixture는 실패 시
종료된 소유 컨테이너 로그를 보존하고 준비 루프를 즉시 종료하도록 수정했다.

후속 실제 PostgreSQL 17.6.1.104 + PostgREST 14.5 개발 실행은 7 PASS/0 FAIL/0 SKIP,
전체 실행 56.43초, 소유 resource 정리 확인으로 끝났다. 기존 혼합 입력 계산과
일치, 페이지를 넘는 배달 합계, 매장/전체/Excel·분할 결제 합계, 베트남 자정 경계,
새 조회 실패 후 이전 표시/내보내기 제거, 늦은 날짜 범위 응답 폐기를 검사했다.
증거: `/workspace/.private/owned-read-postgrest-evidence-20261101-v7/result.json` 및
동일 폴더 `focused-postgrest.log`. source SHA와 working patch hash가 기록된 개발
검사이며 final-main/운영 receipt가 아니다. v1~v6 환경 실패는 그대로 보존한다.

### G3 근태 실제 입력 화면·명령의 session 경계

직원 번호/사진 근태 notifier도 root operation scope에 연결했다. 사진 업로드가
완료됐을 때 원래 사용자/매장이 더 이상 유효하지 않으면 근태 저장 RPC를 시작하지
않는다. 이미 서버가 확정한 원래 근태 결과는 화면 종료 뒤에도 true를 유지하고
새 화면 state에 쓰지 않는다. bound 로그아웃·다른 매장 요청은 전송 전에 거부한다.
실제 입력 화면은 사용자·매장·역할·session generation이 바뀌면 기존 사진/직원 번호/
완료 타이머를 정리한다. 카메라가 떠 있는 동안 계정을 바꾼 경우도 이전 결과를
버리며, 같은 사용자의 표시/토큰 갱신은 미리보기를 지우지 않는다.

개발 영향 검사 16개 PASS: 명령/사진/기존 계약 13개, 기존 실제 근태 제출·오프라인
화면과 두 계정 전환 시나리오 3개다. 로그는 attendance-scope-command-tests.log,
attendance-session-widget-tests.log다. 전체 자동 분석 결과는 별도 로그에 기록한다.
사진 처리의 크기·메모리 상한, 앱 재시작 뒤 unknown 근태의 내구성 있는 복구, 다른
legacy 근태/급여/직원 관리 경로는 여전히 잔여다. 기존 사진+직원+행동 결과 재확인
계약은 보존했으며 이 영향 검사를 전체 근태/전역 규약 완료로 표시하지 않는다.

### G3/G4 결제 증빙의 metadata 일괄 조회·원래 사용자 보존

기존 flush는 파일마다 매장의 세금 법인을 다시 조회했다. 이제 적격 파일 최대
10개를 먼저 고르고 distinct 매장의 id/tax_entity_id만 한 번 조회한다(최대 10행,
64 KiB). 경로가 이미 저장된 파일은 이 조회도 하지 않는다. 기존 원래 storage 경로/
업로드/서명 완료 상태를 유지하며 세금 법인이 없으면 임의 unknown 경로를 만들지
않고 해당 파일만 조치 필요로 남긴다. 새 주기나 자동 재시도를 추가하지 않았다.

같은 actor의 동시 flush는 Future 하나를 공유한다. 큐 진입 당시 사용자와 원래 JWT를
고정해 metadata/업로드 대기 중 계정이 바뀌면 이후 물리 전송을 시작하지 않는다.
이미 끝난 업로드는 보존하며 원래 actor가 명시적으로 재개하면 서명/첨부부터
이어진다. 같은 사용자의 토큰 갱신은 진행 작업의 원래 Authorization을 바꾸지
않는다. Auth snapshot 코드는 설정/리포트와 공통 사용하며 공유 Auth는 닫지 않는다.

고유 개발 검사 19개 PASS: 새 proof batch/scope 8개, 기존 영구 거절/재개 1개,
owned-read 8개, 실제 TCP deadline 2개. 추가한 원래 Bearer 존재 조건도 1개 대상
재실행으로 확인했다. 합성 HTTP 10파일 라운드에서 metadata 1회, 전체 필요한 호출
31회, 동시 handler 최대 1이었다. 11파일은 10+1 배치로 처리했다. 파일별 업로드/
서명/첨부라는 실제 개별 객체 부작용은 유지하며 거대한 업로드 한 개로 바꾸지
않았다. 실제 DB RLS 실행 계획·운영 업로드 성능/실단말 측정으로 바꾸지 않는다.
로그: proof-batch-scope-final-tests.log, proof-batch-scope-extended-tests.log,
proof-original-token-assertion.log, proof-batch-scope-analysis-zero.log(분석 0건).
초기 잘못된 fixture/검사 경로 실패는 proof-batch-scope-tests.log에 보존한다.

actor가 없는 구형 큐의 서버 권한 계약은 그대로이며 소유권 이행 완료를 주장하지
않는다. 전체 큐/원본 파일 크기·이미지 처리 메모리·로컬 정리 결과 분리와 다른
도메인의 G3/G4/G5 적용은 계속 잔여다. 운영/12시간 시험은 아직 시작하지 않았다.

### G1/G2 실제 두 스키마의 최초 법인 연결 계약

작은 연결 fixture의 같은 업무 검사 20개를 실제 POS/Office schema-only 복원으로도
실행했다. 각각 별도 PostgreSQL 17.6.1.104 컨테이너이며 network=none이다. 기존
runtime 함수·Auth 테이블·RLS/GRANT·FK·트리거를 대체하지 않는다. POS 4,878개와
Office 8,834개 원본 객체의 semantic catalog를 대조한 뒤 후보 migration을 적용한다.
기존 native pg_dump bytes/순서를 보존하는 restore 조합 코드를 공통 helper로 모았다.

현재 스키마의 POS 사용자 profile.restaurant_id는 NOT NULL이다. 따라서 기존 플랫폼
관리자의 **다른 법인에 속한 기존 매장 맥락**을 명시적으로 만든다. 검사 대상 신규
법인은 매장이 0개이며 Office 법인/매장 소유 매핑은 미리 심지 않는다. “법인에 매장
0개”를 “전체 배포 DB에 매장 0개”와 혼동한 기존 작은 fixture 조건을 바로잡았다.
전체 빈 배포의 관리자 bootstrap 성공을 이 시험으로 주장하지 않는다. Office도 실제
필수 granted_by/reason과 permission catalog FK, 법인-브랜드 관계 무결성을 유지한다.
제약을 끄거나 nullable로 바꾸어 시험을 통과시키지 않았다.

20 PASS/0 FAIL/0 ERROR/0 SKIP, 전체 owned 실행 117.43초, 양쪽 컨테이너 정리 확인.
매장 없는 법인→명시적 기존/새 Office 법인, 첫 매장 manifest, 각 프로젝트의 다른
Auth/업무 ID, 동일 요청 20회·동시 승인, 응답 유실 뒤 재개, 만료/변조/원본 변경,
권한 회수/다른 actor·외부 법인 차단, 기존 매핑과 구매 연결을 검사했다. 원래 금융
함수 5개의 정의 해시는 이번 후보 적용 전후에도 같다. 과거 금융 이력 보존 시나리오와
동시에 초기화하지 못하도록 실행 모드를 분리했으며 POS/Office 두 fixture lock을
함께 잡는다. 로그/diagnostic은 원본 해시로 각 실행 폴더에 복사해 후속 실행과 섞이지
않는다. 도구/restore/lock 검사 26개도 PASS다.

증거: `/workspace/.private/resilience-native-legal-evidence-20261101-v4/result.json`,
동일 폴더의 `pos-office-native-legal-tests.log`, `pos-office-native-owned-office.log`.
원본 wrapper 로그는 native-legal-current-schema-run-v4.log,
도구 검사는 native-legal-schema-tooling-final-unit.log다. 앞선 v1~v3의 fixture 준비/
예외 adapter 실패는 그대로 보존한다. 운영 DB 변경·실제 Auth 로그인 서버·실제
Edge HTTP와 두 앱 화면 연결은 이 SQL 실행에 포함되지 않는다. POS 매장 개설/
준비부터 구매·근태·영업을 잇는 G2/G6, 데이터 규모별 실행 계획과 실제 단말·12시간/
최종-main 공식 배포는 계속 잔여다.

### G0/G1 실제 Auth 플랫폼 준비와 기존 staging 상태

기존 `globos-pos-staging`/`restaurant-office-staging` 두 프로젝트를 읽기로 확인했다.
각각 17/166개 migration이며 마지막 이력은 2026-09-15다. 현재 연결 함수·메뉴 할인
수량·KDS 실시간 계약이 없으므로 현재 후보용 준비 완료 환경으로 간주하지 않는다.
기존 staging/pilot 데이터·이력·계정은 수정하지 않았다. 새 유료 프로젝트/branch도
만들지 않았다.

현재 native schema를 복원한 클라우드 소유 DB에 실제 GoTrue v2.196.0을 붙이는
`scripts/resilience/auth_platform_fixture.py`를 추가했다. immutable 이미지 digest,
OS/아키텍처/실행 명령, 원본 schema·도구 hash를 검사한다. Auth의 `serve` subcommand로
이미 복원된 관리형 Auth schema를 사용하며 migration을 재실행/수동 applied 처리하지
않는다. 설정 근거는 Auth v2.196.0의 cmd/root_cmd.go와 cmd/serve_cmd.go다.
JWT/DB 비밀은 실행별 새로 생성해 private 환경 파일에만 보관한다. 실제 운영 계정/
비밀번호/토큰을 복사하지 않는다. 이름에 production project ref가 있는 schema 원본과
실제 접속 대상인 로컬 소유 컨테이너를 구분한다.

POS와 Office 각각 9개 preflight 조건 PASS: 실제 Auth Admin API 계정 생성, 비밀번호
로그인, 토큰 갱신, 합성 Auth user 1개 및 입력/이미지·정리 확인을 포함한다. 각각
25.78/26.83초, Docker 소유 resource 정리 확인이다. API session 본문/토큰은 로그에
출력하지 않는다. 데이터/서비스가 아닌 출력 경로로 비밀이 나가지 않도록 Git 내부/
상대/기존/심볼릭 링크 경로·다른 project 입력을 막는 검사 5개도 PASS다. 진단 수집
실패/공간 부족 때에도 소유 컨테이너 정리를 시도하고 실패/정리 결과를 남긴다.

증거: `/workspace/.private/resilience-real-auth-pos-final-20261101/result.json`,
`/workspace/.private/resilience-real-auth-office-final-20261101/result.json`,
auth-platform-guard-unit.log 및 native-auth-pos-final.log/native-auth-office-final.log.
별도 초기 probe/실패는 그대로 보존한다. 이 결과는 실제 Auth 환경 준비이며
로그인 스모크 운영 면제 범위를 바꾸지 않는다. 실제 두 앱·Edge·Realtime·Storage를
잇는 전체 업무/실단말 시험이나 12시간 PASS가 아니다.

앞선 host 개발 금융 fixture v7의 cleanupVerified는 Docker 컨테이너/네트워크만
확인한 값이었다. 해당 실행의 host TCP proxy 1개도 별도로 종료/확인했으며 원본
result를 고치지 않고 같은 private 폴더의 host-proxy-cleanup-correction.json에
기록했다. 새 Auth fixture는 소유 private IP를 직접 사용해 host proxy를 만들지 않는다.


### G1/G3 단일 전액 결제의 내구성 있는 복구

`20261101132612_payment_command_cancellation_barriers.sql`을 CLI로 생성해 기존
94500 receipt 다음에 추가했다. 원래 금융 함수 5개는 수정하지 않는다. 전액 의도는
선택 당시 payment count와 금액/수단을 보존하며 native 결제 후 주문이 실제 completed가
아니면 전체 트랜잭션을 롤백한다. 오래된 전액 표시가 새 항목 추가 후 부분 결제로
조용히 바뀌지 않는다. 같은 주문/payment count의 서로 다른 요청도 한 건만 청구한다.

결제 취소 RPC는 동일 actor/operation 잠금 안에서 이미 확정된 원본 영수증을 반환하거나
내구성 있는 취소 barrier를 남긴다. 이후 늦게 도착한 v1/v2 원본 요청도 청구할 수 없다.
현재 권한 회수와 다른 actor/order 재사용을 거부한다. 취소 응답 유실은 같은 취소를
재확인하며 결제를 다시 실행하지 않는다. 새 비공개 ledger에는 client/service_role의
직접 접근 권한이 없다.

계산대의 일반 단일 전액 결제를 새 coordinator에 연결했다. IndexedDB readwrite
transaction/고유 operation index와 별도 native SQLite FULL 동기화 transaction이
원래 요청을 먼저 보존한다. 일반 SharedPreferences map이나 메뉴 캐시를 사용하지
않는다. CAS 승자의 고유 sender만 HTTP를 보낼 수 있다. 미확인 요청은 원래 결과
조회 또는 취소 확정 전까지 해당 주문의 다른 수단·분할·합산·비매출 결제를 차단한다.
다시 로그인/새로고침 후 복구 패널에서 확인할 수 있다. 복구된 기존 결제를 새 수단으로
다시 출력하거나 증빙 창을 열지 않는다. 원래 확정은 저장 정리/조회/권한 전환 실패로
unknown이 되지 않으며 A→B→A의 뒤늦은 응답은 새 화면을 덮어쓰지 않는다.

로컬 ledger는 100건/총 256KiB/건별 8KiB, native DB 256 pages 이하, 동일 native
ledger당 실행 worker 1개/대기 100개 이하로 제한한다. 미확인 건은 자동 삭제하지
않고 full/corrupt/storage 실패 시 청구를 차단한다. SQLite는 isolate와 process 사이의
원자성을 제공하며 2초 busy timeout 후 실패를 반환한다. RPC는 Auth/응답까지 15초,
응답 512KiB, 입력 64KiB, 별도 JSON worker 정리 최대 2초다. 자동 청구 재시도는 없다.

검증 결과:

- native 금융·재고·인보이스 원본 함수 fixture: 이전 v1 22건 + 새 v2 20건 PASS,
  owned 전체 37.64초/정리 확인. 원래 500행 거래/9개 테이블 이력과 함수 정의 보존.
  실제 cancel/commit 동시 실행은 이 실행에서 commit-wins 분기를 관측했다.
- SQLite 8건, coordinator 8건, 실제 TCP RPC 6건, 계산대 복구 notifier 5건,
  ko/en/vi 좁은 폭 복구 패널 3건 PASS. 각 건수는 서로 다른 파일의 개별 결과다.
- 실제 Chromium IndexedDB 5건 PASS: 20개 동시 claim, 새로고침 후 원본 복구,
  CAS 충돌, 100건 상한과 terminal 정리, 손상된 저장소 차단.
- 기존 계산대/프로모션/명령 scope/화면 85건 PASS, 기존 receipt client 11건 PASS,
  schema/runner 도구 27건 PASS. v1 성공만으로 누락된 v2를 PASS로 올리지 않는 검사도 포함한다. 개발 정적 분석도 0 issue다.

개발 로그는 `/workspace/scratch/pos-resilience-completion-dev/`의
payment-cashier-ui-regressions-v4.log, payment-storage-panel-final-tests.log,
payment-command 별 boundary/coordinator 로그, payment-indexeddb-browser-tests.log에 있다.
SQL 증거는 `/workspace/.private/resilience-payment-command-v2-evidence-20261101/result.json`.
기록된 5개 migration/2개 fixture 입력 해시가 현재와 같은지 확인해 SQL을 이유 없이
재실행하지 않았다. source는 b925e533+당시 dirty tree인 개발 증거이며 최종 main receipt가
아니다. host Linux에는 libsqlite3.so.0만 있어 개발 전용 loader 경로를 사용했고 공식
Ubuntu Dockerfile에는 libsqlite3-dev를 명시했다. 새 공식 image/전체 recipe는 아직
실행하지 않았다. 초기 native library/동시 접근 및 테스트 준비 실패 로그도 보존한다.

분할·합산·비매출 자체의 원래 요청 journal/SQL 배치, 전체 런타임·업무 G6,
실단말·2시간 사전 부하·1배/3배 각 12시간·운영 배포는 계속 미완료다.


### G0/G2 실제 Auth·JWT API·Office Edge의 연결과 응답 유실

`scripts/resilience/owned_platform.py`와 loopback gateway/실행 wrapper를 추가해
동일 클라우드에서 두 프로젝트를 함께 실행했다. 현재 native POS/Office schema에
forward migration을 적용하고 실제 GoTrue v2.196.0과 PostgREST 14.5를 immutable
image digest로 사용한다. REST는 superuser 대신 authenticator 로그인에서 JWT role로
전환한다. 실제 Auth Admin API가 합성 사용자를 생성하고 실제 로그인/갱신 토큰을
사용한다. 서버 비밀·계정·SQL 진단은 private 출력 경로에만 둔다. 운영 계정/파일/
비밀번호 해시/cron 자료를 복사하지 않는다.

Office `pos-bridge/index.ts`와 전체 import 모듈의 업무 코드는 그대로 실행했다.
시험 adapter는 Deno.serve의 수신 port만 loopback 임의 port로 바꾸고, source/run/PID를
대조한다. URL import 11개 integrity는 원래 Office scripts/deno.lock과 같으며 도구용
packageJson workspace 기록만 제거한 별도 fixture lock을 frozen 모드로 사용한다.
DENO_NO_PACKAGE_JSON과 --no-npm으로 POS의 다른 도구 workspace도 끼어들지 않는다.
실제 코드의 외부 요청 권한은 loopback으로만 제한한다. 제품 Edge/DB 권한이나
전역 잠금파일을 변경하지 않았다.

기초 runtime 21조건 PASS, 58.58초/정리 확인 후, 실제 Edge 법인 흐름 36조건 PASS,
48.04초/정리 확인을 확보했다. 기존 다른 법인/매장에 속한 플랫폼 관리자 맥락만
provision하고 신규 법인과 소유 관계는 실제 API로 생성했다. Office Auth가 이미
기본 profile을 만드는 native trigger도 유지했다. 시험 관리자를 준비할 때 이 profile을
갱신하며 중복 INSERT나 trigger 해제로 해결하지 않는다.

검사 범위는 실제 로그인/갱신 → POS admin_upsert_tax_entity_v2 신규 법인 등록 →
매장 0개 확인 → 실제 Office 기존 onboarding action의 capability 발표 → 연결 preview/
확정 → POS 확인 transaction 후 HTTP 응답 강제 유실 → 동일 operation resume →
20회 HTTP resume이다. Office 법인/활성 link/ACK가 한 건이며 양쪽 Auth/업무 UUID는
서로 다르다. 익명 함수 ACL·프로젝트 key 혼용·private schema 노출도 차단했다.

단일 EOF 주입에서는 **Deno 전송 계층이 같은 buffered POST를 한 번 더 보내는 현상**을
관측했다. 코드는 fetch 1회였지만 실제 HTTP는 2회였고 원래 operation 덕분에 owner는
중복 생성되지 않았다. 지속적인 응답 유실을 주입한 최종 실행도 실제 2번 전송 후
unknown을 반환하고, 연결 복원 후 같은 요청을 복구했다. 이 관측을 모든 브라우저/
POS 장애의 원인으로 일반화하지 않는다. 재시도 반복문 유무만으로 모든 쓰기의
중복 전달 가능성이 없다고 가정하지 않으며, 남은 legacy 쓰기의 원래 ID/멱등성
전환은 계속 필요하다.

증거는 `/workspace/.private/resilience-two-platform-probe-20261101-v2/result.json`,
`/workspace/.private/resilience-real-legal-http-20261101-v4/result.json`, 개발 로그
real-legal-auth-rest-edge-v4.log다. source는 7ef7cca9+기록된 당시 도구 hash의 개발
증거다. 실행 중 도구 입력과 clean Office 45d6b8c8 source가 바뀌지 않았는지 검사했다.
후속 cleanup 보강은 별도 도구 검사로 검증하며 과거 receipt의 hash/시간을 덮어쓰지
않는다. gateway/경로/키/상한/응답 유실 검사 7개, owned process·진단·thread 종료/
입력 변경 검사 6개, shared schema registry/runner 27개 PASS다. 초기 setup/trigger/
잠금파일/EOF 기대값 실패와 그 소유 자원 정리 증거도 보존한다.

이 실행은 브라우저의 실제 두 앱 화면, 첫/추가 매장 개설부터 구매·근태·영업까지의
전체 G2/G6를 완료하지 않았다. 실제 Storage/Realtime/mail/printer는 NOT_PREPARED다.
없는 서비스를 501로 표시하며 가짜 업로드/이벤트/출력 성공을 반환하지 않는다.
실단말·2시간 혼합 및 각 12시간 시험, 운영 배포와 두 마감 관찰은 아직 시작하지 않았다.


### G2 첫/추가 매장의 실제 개설 API와 계정 worker

같은 독립 runtime에서 신규 법인 연결 이후 실제 admin_create_brand_v2로 브랜드/법인
관계를 만들고 admin_preview_store_registration_v1/admin_register_store_v1로 첫 매장과
추가 매장을 등록했다. 같은 request 재호출은 같은 매장이다. 기본 paperless
kitchen_floor와 별도 tray 사용 구성을 사용했다. Office 최초 법인/브랜드/매장 매핑은
사전에 심지 않는다.

실제 POS store-account-onboarding/index.ts/worker.ts도 원본대로 실행했다. 시험 adapter는
Office와 같이 local 수신 port만 지정하며, POS 함수의 원본 deno.json import map을
사용한다. GoTrue Admin API가 실제 Auth 계정을 만들고 원래 SQL이 고정 계정/요건/
station을 연결한다. 13개 계정 요구사항은 실제 12개 계정이다. 동일 브랜드 관리자는
두 매장에서 공유하며 중복 생성되지 않는다. 계정 유형별 API 생성은 provider에 bulk
create가 없는 필수 쓰기이고, 기존 worker의 최대 50개/동시 2/65초 제한과 2개 DB
준비·마무리 RPC를 유지한다. 새 항목별 DB 조회 경로를 만들지 않았다.

실제 Office store_mapping_sync에 선택한 두 store UUID manifest를 전달해, 두 매장 모두
앞서 확인한 동일 Office 법인 아래에 연결되는 것까지 확인했다. native Auth/REST/
양쪽 실제 Edge를 포함한 전체 owned 실행 53조건 PASS, 41.19초/정리 확인이다.
실행 중 입력 hash와 clean Office source가 유지됐다. 추가 Edge route allowlist/원래
Authorization/미지원 함수 차단을 포함한 gateway 8개, owned cleanup/input 6개 검사와
Deno port adapter type check도 PASS다.

증거: `/workspace/.private/resilience-first-additional-store-http-20261101-v1/result.json`,
개발 로그 first-additional-store-real-http-v1.log. 생성한 모든 계정 ID/역할/fixture용
비밀번호는 같은 private 폴더의 generated-pos-accounts.private.json에만 보관한다.
실제 운영 샘플 계정/Office 계정 private 파일과 혼용하지 않는다. DB/서비스는 종료된
격리 시험 계정이며 운영 계정으로 사용할 수 없다.

현재 두 매장의 workforce accounts_ready는 true지만 employees_active는 0이다.
테이블/출력 route/test job도 아직 없어 개점 readiness는 false다. **등록/계정 생성/
Office 연결 성공을 신규 매장 전체 영업/구매/근태 성공으로 표시하지 않는다.**
다음은 실제 설정 API·직원/근태·구매 흐름이며, 출력/단말 검증·암호 인계·운영 수락을
가짜 PASS로 저장하지 않는다. 브라우저 두 앱과 물리 장치 및 장시간 시험은 잔여다.


### G0 실제 POS Storage와 시험 자원 보강

실제 Storage API v1.81.0에서 업로드 → 10년 서명 URL → 원본 바이트 다운로드 →
삭제와 private bucket의 unsigned 접근 거부를 확인했다. 실제 POS Auth/REST를
포함한 POS 단독 component 시험 24조건 PASS, 73.19초/owned container·network 정리
확인이다. camera/직원 근태/Office Storage/Realtime/전체 업무 시험을 대신하지 않는다.
증거는 `/workspace/.private/resilience-real-storage-20261101-v4/result.json`이며
source 01518a95+당시 도구 hash의 개발 증거다. 초기 공간 부족/마이그레이션 hash
검증 실패 기록도 보존하며 최종 main 전체 검증 receipt로 올리지 않는다.

현재 운영에서 읽기 전용으로 확인한 Storage schema 97개 object fingerprint가 native
snapshot과 같음을 검사했다. 실제 migration 74개(ID 0–73)의 참조는 private 파일에만
둔다. 원본 Storage API의 supported freeze-at 설정으로 신규 74번을 적용하지 않는다.
버전 간 upstream script amendment로 기존 2/62번 hash 두 개만 supported
migration-hash refresh를 사용해 갱신한다. 시작 전후 schema fingerprint, ID/name 목록이
같고 허용한 두 hash 외에는 변경이 없음을 검사한다. 원본 참조 이력은 수정하지 않는다.
**시작 후 hash까지 원본과 동일하다고 주장하지 않는다.**

이 클라우드 Docker VFS에서 upstream Storage 다층 image의 복사량으로 disk가
부족해졌다. 같은 upstream digest의 전체 root filesystem과 runtime config를 검증한
단일 layer projection을 기존 image policy에 등록했다. 부분 image/파일 생략은 없다.
main fixture PG data는 기존 helper를 통해 container당 1GiB tmpfs, Storage 파일은
256MiB tmpfs, API는 1 worker/DB pool 4/파일 5MiB로 제한한다. anchor도 명시적 tmpfs를
쓰며 owned container 삭제에 -v를 사용해 그 container의 anonymous volume을 함께
정리한다. 과거 결과의 container/network 정리만으로 volume까지 정리했다고 소급하지
않는다. 기존 출처 불명 volume은 삭제하지 않았다.

사용 중이지 않은 예전 공개 Flutter tools image와 검증한 정확한 cache 두 ID만
제거해 공간을 확보했다. 사용자 코드/시험 증거는 보존한다. VFS에서 큰 SDK 설치 후
WORKDIR가 전체 파일을 다시 복사하는 원인도 찾아 Dockerfile의 WORKDIR를 앞당겼다.
Flutter tools 의존성은 같은 설치 단계에서 먼저 준비한다. **새 공식 tools image 빌드와
실행은 아직 미검증**이다. image-layout 구조 2건, image policy 12건, gateway 10건,
owner 7건, CLI scope 3건, Storage source/history guard 5건, schema/runner 27건은 각각
개별 도구 검사 PASS다. 두 프로젝트 전체 stack이나 장시간 부하 PASS가 아니다.

서비스 JWT는 실제 1배/3배 장시간 계획을 수용하도록 fixture에서만 48시간으로
발급하고 anchor 수명은 36시간이다. 실제 Auth 1시간 session은 정상 갱신을 계속
사용해야 한다. 물리 단말·2시간 혼합·각 12시간 시험 및 운영 배포는 아직 미실행이다.


### G2 신규 두 매장의 초기 비밀번호·직원·사진 근태 연결

같은 독립 두 프로젝트 runtime에서 신규 법인 → 첫/추가 매장 → 실제 고정 계정
생성 → Office 매핑에 이어, 각 매장의 실제 관리자와 계산대 계정으로 최초 로그인/
비밀번호 변경/새 비밀번호 로그인을 실행했다. 원본 complete-initial-password-change
Edge가 실제 Auth password를 변경하고 native trigger의 generation이 1 증가한 뒤
must_change_password가 false가 되는 것을 확인했다. 시험 계정 비밀번호는 private
계정 파일만 갱신하며 운영 계정은 수정하지 않았다.

이 Edge는 import.meta.main일 때만 legacy std HTTP listener를 시작한다. 제품 함수를
고치거나 handler를 대체하지 않고 Deno --preload로 port adapter를 먼저 실행하여
원본 index.ts가 main module로 남도록 했다. Deno.serve와 legacy Deno.listen 모두
loopback 임의 port를 사용하며 함수별 readiness/log/lock을 구분한다. 실제 Deno의
두 listener·main semantics·잘못된 source 거부 3개 검사와 adapter type check PASS다.
초기 password 함수의 기존 고정 URL 의존성을 새 deno.lock에 기록했고 기존 SDK
integrity는 동일하다. network는 여전히 loopback만 허용한다.

각 매장 관리자가 실제 직원 등록 API로 직원을 만들고 계산대 계정이 해당 매장의
private bucket에 사진을 올려 서명 URL의 원본 바이트를 받았다. 실제 photo-backed
attendance RPC로 clock_in/out 2회(매장당 4개, 총 8개 사건)를 기록했다. 상대 매장의
근태 입력과 사진 업로드는 각각 거부된다. Auth 고정 계정과 workforce 직원은
별도 record이며 임의로 같은 ID를 부여하지 않는다.

실제 양쪽 DB/Auth/REST + Office/POS 개설/POS password Edge + POS Storage를 포함한
97조건 PASS, 전체 77.41초/owned 자원 정리 확인이다. 증거는
`/workspace/.private/resilience-new-store-workforce-http-20261101-v1/result.json`,
개발 로그 new-store-workforce-real-http-v1.log다. source 7c63afad+입력 hash의 개발
시험이며 최종 main 통합 release receipt가 아니다. 시험 중 입력과 clean Office
source를 고정했고 운영 DB를 쓰지 않았다.

앞선 Storage 전용 시험의 1x1 JPEG는 바이트 왕복은 성공했지만 추가 client decode
확인에서 잘못된 이미지임을 발견했다. 그 증거를 카메라/이미지 표시 검증으로
소급하지 않는다. 새 748-byte 96x72 합성 JPEG를 사용하고 실제 앱과 같은 Dart image
decoder 검사도 추가했다. 사진 fixture는 실제 사람/카메라 자료가 아니다.

실제 카메라 촬영, 물리 출력/암호 인계/운영 수락, 두 앱 전체 브라우저,
part-timer/급여/구매·입고/판매·마감 전체, 나머지 도메인·혼합/12시간·운영 배포는
계속 잔여다. 이번 개별 직원/근태 성공만으로 신규 매장 전 프로세스 완료를 선언하지
않는다.


### G3 인증 명령의 실제 늦은 응답·중복 전송 결함 수정

신규 매장 초기 인증을 확인하면서 AuthNotifier의 own-password/consent 명령도
분석했다. 수정 전 재현 5건 모두 FAIL이었다: 이전 password 성공/실패가 새 actor의
error를 설정, 이전 consent 성공이 새 actor의 gate를 해제, 동시 password 20회가
실제 20회 전송, dispose 후 응답이 폐기된 notifier를 사용했다. 야간 장애 당시의
직접 원인이라고 일반화하지 않고 별도 재현된 전역 상태 결함으로 기록한다.

별도 actor generation과 원본 JWT를 고정한 AuthCommandSession을 적용했다.
동일 actor의 단순 profile refresh는 명령을 무효화하지 않으며 새 로그인·actor 변경·
logout·dispose는 원래 명령의 HTTP만 취소한다. shared Auth는 유지한다. password와
consent는 각자 in-flight 한 건으로 제한하고 후속 profile 조회도 원본 auth_id/JWT를
사용한다. 다른 actor의 gate/error/cache/navigation을 변경하지 않는다.

원래 Edge/SQL 계약은 유지한다. 명령 전체 15초, 입력 16KiB/응답 64KiB이며 과대
응답은 JSON decode 전에 차단한다. 새 JSON worker를 만들지 않는다. 타임아웃/
응답 유실 후 password 쓰기를 자동 재전송하지 않는다. 비밀번호는 메모리 요청에만
있고 journal/Git/log에 저장하지 않는다. 미확인 password 결과의 재시작 복구 계약은
별도 잔여이며 이 변경만으로 모든 Auth 명령을 완료 처리하지 않는다.

인증 초기화/기존 password·consent 계약 46건 PASS(위 5건 포함), 실제 TCP 경계 8건
PASS(원본 JWT·후속 조회, 빈 profile 거부, 503 단일 전송, 미확정 ack, 64KiB 상한,
실제 body deadline/공유 transport 생존, 전환/입력 상한)다. 개발 로그
`auth-command-scope-before-v2.log`, `auth-command-scope-after.log`,
`auth-command-transport-after.log`, `auth-command-affected-analysis-final.log`를 보존한다.
초기 테스트 fixture compile 실패와 lint 4건도 보존한 뒤 수정했다. 최종 main 전체
recipe/운영/장시간/실단말 증거를 대신하지 않는다.

### G3/G5 근태·결제 증빙 사진의 처리 및 전송 상한

근태/결제 증빙 사진의 원본 readAsBytes → full decode/resize에는 입력 byte/pixel/
동시 처리 상한이 없었다. 새 bounded_photo 경로는 파일 5MiB, 정적 이미지 4Mi pixel/
변 8192 이하를 codec 전에 확인하고 촬영/선택 단계에서 1600x1600 제한을 요청한다.
파일은 stat 후 고정 범위 stream으로 읽고 읽기 전체 10초/정리 1초, 출력 JPEG 1MiB
이하다. 근태 800/q70, 증빙 1400/q78을 유지하며 작은 이미지를 키우지 않는다.
native codec worker는 앱당 한 개이고 image buffer 대기 queue를 만들지 않는다.
web compute는 UI event loop 실행이라는 한계를 명시한다.

첫 경계 시험에서 JPEG startDecode/readInfo도 DCT block을 먼저 할당한다는 점을
확인했다. 65535x65535 헤더 시험은 약 6.3GB RSS로 커졌고 실패/중단됐다. library
전에 모든 JPEG SOF·sampling을 확인하도록 보강했고 같은 시험은 즉시 거부된다.
다중 frame/과도 sampling/PNG huge dimensions도 decode 전에 거부한다. 정적
JPEG/PNG/WebP를 처리하고 압축된 PNG text/profile은 decode/preview 복사본에서
제외한다. animation/그 외 format은 재촬영/다른 이미지 안내로 거부한다. 이 정책을
임의의 모든 파일 형식에 대한 무제한 호환성으로 설명하지 않는다.

유효한 소형 palette lossless WebP에서 image 4.8.0 자체의 IndexError도 발견했다.
원본 library direct decode 3개 크기에서도 재현됐다. 해당 decoding은 미해결이며
알기 쉬운 사진 오류로 반환한다. 성공 fixture를 바꿔 lossless 호환 PASS로 숨기지
않는다. JPEG/PNG/lossy WebP 실제 변환과 거부 경계를 구분해 검사한다.

근태 사진은 codec/file await 전에 원본 Auth를 고정한다. 처리 중 actor 변경은
upload를 시작하지 않고 upload 도중 변경은 새 actor로 sign 요청을 보내지 않는다.
기존 성공 upload path의 명시적 sign 재시도 계약은 보존한다. upload+sign 전체
30초, sign retry 15초/응답 64KiB, storage retry 0으로 제한하며 shared Auth는 유지한다.

개발 native 사진/근태·기존 proof batch 36건, 별도 원본 Auth transfer 3건, 실제
Chromium 사진 경계 11건 PASS, 영향 분석 0 issue다. browser 결과에는 기존 lossless
codec 오류 안내 조건도 포함되며 실제 decoding 성공과 구분한다. 로그는
bounded-photo-native-and-services-v4.log, attendance-photo-original-auth-tests-v2.log,
bounded-photo-chromium-v3.log, bounded-photo-affected-analysis-final.log다. 초기 XFile
range 오류/잘못된 시험 응답/메모리 급증/codec 실패/lint 기록을 보존한다. 최종 main/
실카메라/최소 단말/전체 앱 메모리/혼합·12시간/운영 증거를 대신하지 않는다.

남은 파일 작업은 proof 영속 queue의 총 bytes/건수/원래 owner 이관 및 미확정
교체/정리 의미, 다른 file/export 경로의 예산과 실제 최악 크기 메모리 측정이다.
근태 미확인 결과의 재시작 복구와 다른 legacy 도메인도 계속 잔여다.


### G4 계산대 갱신의 원본 Auth·물리 요청 수명

계산대 pricing/serving orders/emergency summary/progress/completed 읽기를 한
OwnedReadSession으로 묶었다. 원본 JWT를 고정하고 매장 전환·root scope reset·
dispose 때 해당 view의 HTTP만 물리 취소한다. shared Auth는 유지한다. 비동기/HTTP
job 전체 15초, 개별 response 4MiB, JSON worker 정리 별도 2초다. 동기 Dart 모델
계산의 CPU preemption이나 총 앱 메모리 상한을 구현했다고 주장하지 않는다.

기존 한 번 실행+최신 후속 한 번 refresh 병합을 보존한다. 실제 TCP 7조건 PASS:
store 전환/초기화/dispose, body stall deadline, 과대 response, 20회 동시 갱신과 원본
JWT 유지다. 빈 queue의 20회 갱신은 snapshot 2회(가격 2 + 주문 4 GET)로 실행되며
중단된 옛 store는 가격 GET 이후 주문 조회를 시작하지 않는다. 기존 계산대 명령/
복구와 합한 실행 27건, 별도 pricing/promotion/item-ordering 18건 PASS, 분석 0 issue다.
로그 cashier-owned-read-and-command-tests.log,
cashier-owned-read-pricing-regressions.log, cashier-owned-read-analysis-final.log.
가격/할인/VAT/결제 횟수/항목 정렬과 승인된 읽기 결과 뒤 realtime 연결을 보존한다.

이 변경은 summary/detail/keyset paging을 완료하지 않았다. 기존 serving 상세
전체 projection과 날짜 필터는 유지한다. 후속 날짜 경계 변경은 native
**table_order_is_current**를 따라야 한다. reset policy가 켜진 이전 일자 dine-in은
서버의 ORDER_OPERATIONS_CLOSED로 결제가 금지된다. 반면 reset 대상이 아닌
열린 과거 주문까지 오늘 created_at 필터로 숨기는 문제는 별도 조회 계약에서
해결해야 한다. 단순 날짜 필터 제거로 이미 마감된 주문을 재결제하게 만들지 않는다.
G4 규모별 실행 계획/행/bytes, 전체 도메인/G6 혼합·G7 장시간/운영은 계속 잔여다.


### G3/G5 결제 증빙 확정과 로컬 정리 결과 분리

서버 attach_payment_proof가 성공한 다음 local file 삭제만 실패해도 이전 코드는
queued=true/업로드 미완료를 반환했다. owned 임시 directory만 chmod 555로 바꾼
실제 Unix 파일 삭제 실패로 이 문제를 재현했고 원래 FAIL 로그를 보존한다.

확정된 server ack 뒤 attached marker와 로컬 retirement를 분리했다. 새 클라이언트는
서버 확정 상태를 유지하고 cleanupPending만 기록한다. 삭제/retirement가 실패하면
확인된 queue record를 보존한다. 새 서비스 instance에서 보존된 attached marker를
읽으면 metadata/upload/sign/attach HTTP 없이 로컬 정리만 재개한다. 잘못된 marker에
signed URL이 없으면 자동 삭제하지 않는다. 업로드 뒤 attach 응답이 미확인이면
원래 object/sign URL을 보존해 재업로드 없이 연결 단계만 명시적으로 재개한다.

관련 outcome 3개+기존 proof batch/scope 8개, 총 11개 focused 검사 PASS, 영향 분석
0 issue다. 로그 proof-outcome-cleanup-before.log, proof-outcome-cleanup-final.log,
proof-outcome-analysis-final.log. 실제 Unix file fault와 가짜 HTTP 업무 응답을 구분한다.
새 native DB/Storage proof 전체 시나리오나 실제 권한·12시간 증거로 올리지 않는다.

이는 전체 proof queue 이전의 완료가 아니다. 원래 owner 없는 legacy record,
여러 legacy tab/process의 동시 SharedPreferences 쓰기, 모든 local marker가 실패한
미확인 결과, queue 총 건수/bytes와 immutable local 파일 교체는 계속 잔여다.
이 변경만으로 모든 클라이언트의 server attachment replay가 없어졌다고 하지 않는다.
운영 DB/Edge/web와 혼합·장시간 시험은 아직 시작하지 않았다.


### G0/G2 실제 양쪽 Realtime과 신규 매장의 주방 권한·이벤트

Realtime v2.143.3의 immutable upstream image 전체 filesystem/runtime config를 검증한
389,946,368-byte single-layer projection을 등록했다. 21,096 entries, 실제 20.22초,
원본 tar 제거/정리 확인이다. digest와 rootfs/config/inventory SHA는 image policy에
있다. VFS에서 다층 복사량이 커지는 이전 문제를 반복하지 않도록 처음부터 같은
검증된 projection 경로를 사용했다. 운영 image/서버 설정은 변경하지 않았다.

운영에서는 각 DB의 realtime.messages 정책과 routine hash/migration version 같은
읽기 전용 metadata만 private 파일로 캡처했다. POS 정책 1개, Office 0개, 각 routine
18개/이력 91개다. 운영 tenant 설정·JWT secret·event·업무 row는 복사하지 않는다.
실제 pinned self-host installer가 격리 DB에서 자체 platform migration/seed를 실행한다.
운영 이력 91개를 실행했다고 가짜 INSERT하지 않는다. 기존 application/Auth/Storage
catalog는 전후 동일해야 하고, 메시지 정책은 원본 집합과 표현식/역할까지 같아야 한다.
Realtime platform 자체가 운영의 모든 object와 byte-identical하다고 주장하지 않는다.

초기 trial에서 APP_NAME 누락, owned container 이름 누락, fixture admin password
변경 뒤 controller credential 불일치를 차례로 발견해 수정했다. namespace 설정이
빠진 trial은 public에 control table 네 개를 만들었고 catalog 보존 guard가 거부했다.
공식 Supabase compose의 DB_AFTER_CONNECT_QUERY=SET search_path TO _realtime 및
별도 schema를 사용해 해결했다. 이 실패들은 모두 격리 DB에만 있었고 정리 확인했다.
psql fingerprint는 실제 transaction에서 SET LOCAL을 적용하도록 보강했다. 실패와
원래 receipt는 덮어쓰지 않는다. 실제 release config eval도 DB 복원 전에 검사한다.

POS 단독 실제 Auth/REST/Realtime API preflight 17조건(47.76초), 실제 Dart SDK
WebSocket join/서버 broadcast+ack/권한 없는 private KDS topic 거부 포함 18조건
(78.67초)이 각각 PASS다. tenant health의 db_connected/replication_connected는
subscription 이전에는 false일 수 있으므로 health 응답만으로 이벤트 전달을 PASS로
바꾸지 않는다. 실제 message 최대 276 bytes를 관측했다. 각 서버는 512MiB/1CPU,
기본 DB pool 2, scheduler 2와 WebSocket heap 8MiB를 사용한다.

추가로 두 DB/Auth/REST/실제 Office·POS Edge/POS Storage/양쪽 Realtime을 함께 실행해
신규 법인 → 첫/추가 매장 → worker → 초기 비밀번호 → 직원/사진 근태를 다시 연결했다.
새 주방 계정도 실제 첫 비밀번호 변경을 마친 뒤 자기 매장의 control/kitchen channel을
구독했다. WAL/DB가 연결된 것을 확인하고 **native SQL realtime.send의 kds_change**를
수신했다. 다른 신규 매장 channel은 permission 오류로 거부됐다. 이는 주문 완료/
tray/floor 인계 자체를 실행한 시험과 구분한다. 새 매장의 physical acceptance는 false다.

전체 owned 실행 108 parent 조건 PASS, 148.33초/정리 확인이다. 내장 기본 protocol
검사는 양쪽 합계 6개, 별도 POS scoped KDS 검사는 7개이며 parent 108과 단순 합산해
다른 통합 완료 수치로 만들지 않는다. 증거:
`/workspace/.private/resilience-two-project-kds-realtime-20261101-v8/result.json`,
개발 로그 two-project-new-store-kds-realtime-v8.log. 앞선 v1–v7의 실패/단독 preflight와
원래 hash도 보존한다. source 6b29d953+기록된 dirty helper 입력의 개발 증거다.

후속 source-binding 보강은 image policy, 실행할 forward SQL, 두 Edge 전체 tracked
module/lockfile을 실행 전후 비교한다. 같은 index.ts basename도 서로 다른 경로로
구분한다. 이 검증 전용 변경은 별도 owner/input guard 8개, CLI guard 5개, reference
6개, image policy 12개 검사로 확인하며 v8의 원래 시간/hash를 고치거나 전체 fixture를
이유 없이 재실행하지 않는다. Dart probe 정적 분석은 0 issue다.

남은 환경은 실제 두 앱이 쓰는 API gateway의 WebSocket 연결, Office Storage,
전체 브라우저/업무·부하 manifest와 물리 장치다. source/message RLS와 직접 SDK
성공만으로 실제 앱 KDS handoff·구매·입고·전체 기능/장시간/운영을 완료 처리하지
않는다. 운영 DB/Edge/web, 2시간 혼합, 각 12시간 및 두 마감 관측은 아직 시작하지 않았다.

### G0 양쪽 Storage와 공통 API 주소의 실제 WebSocket

Office Storage 101개 객체 fingerprint `1dfa2f7694baa5229772951b3f93e81b8e78a356a30c78d38e08bdf9ae8f1d64`와
실제 migration reference 74개를 읽기 전용으로 확인했다. native snapshot과 일치한다.
POS attendance-photos 및 Office quality-evidence의 실제 private bucket에서 각각
upload → sign → 원본 bytes download → unsigned download 거부 → delete/metadata 제거를
실행했다. 이 기본 transfer는 service-role 검사이며 Office 사용자 업무 권한 PASS는 아니다.
양쪽 Storage 시작 전후 native schema가 유지되고, 검토한 historical hash 2/62만
upstream의 지원되는 refresh를 허용한다. 원래 reference는 바꾸지 않는다.

시험용 공통 loopback API 주소의 `/realtime/v1/websocket`을 실제 Realtime에 연결했다.
원래 프로젝트 key/localhost Origin/정상 handshake만 허용하며 tenant Host만 전달한다.
HTTP 16개·WebSocket 32개·전체 handler 48개, 전달 buffer 16KiB, idle 120초와 연결
13시간 상한을 둔다. server 종료는 이 run이 소유한 양 끝 socket만 닫는다.
SDK probe도 이 공통 주소를 사용해 실제 DB kds_change를 수신한다.

`/workspace/.private/resilience-two-project-gateway-storage-20261101-v9/result.json`:
119 parent 조건 PASS, 189.33초, cleanup=true. 원본 SHA는 90d5ac57와 기록된 dirty
tool hashes이며 전후 모든 입력 동일성을 확인했다. Office SHA는 45d6b8c8이다.
receipt SHA256 `63f94ee9e48a56ea2d799dc58dd149e6affd9292083f8f7c30446d17379cc208`.
종료 후 HTTP/WS active는 양쪽 모두 0, WS peak 각각 1, 전달 bytes POS 12,146 /
Office 2,810이다. 별도 TCP transport/isolation 13개와 CLI guard 5개, Dart analyze
0 issue도 통과했다. 이는 전체 브라우저·실제 주문 handoff·T01–T16·2시간·각 12시간·
최종-main recipe·운영 배포·물리 장치 검증을 대신하지 않는다. mail/printer는 미준비다.

### G1/G2/G3 실제 주문 재전송 결함과 두 전달 정책

현재 native schema에는 선택형 create_order_with_client_mutation_id 및 그 원장이
없다. 감사 기준을 그대로 사용해 실제 API를 실행한 결과, 기존 영업일 API는 일반
create_order로 넘어갔다. 첫 생성 후 같은 mutation ID 재전송이 TABLE_NOT_AVAILABLE로
실패했다. 이 선택형 계약이 없을 수 있음을 지원하는 기존 코드의 복구 결함이며,
운영 DB refresh나 감사 값이 잘못됐다는 판단이 아니다.

CLI로 생성한 `20261101185522_order_creation_command_receipts.sql`을 앞선 다섯 POS
후보 뒤에 추가했다. 기존 영업일 API signature를 유지하고 actor/store/원래 mutation ID,
요청 hash와 실제 order ID를 한 transaction에 보관한다. 같은 요청은 원래 결과를
반환하고 수량/테이블/영업일을 바꾼 ID 재사용은 거절한다. 현재 native 역할 목록을
대조해 주문 actor·매장 권한을 유지했다. 원래 create_order의 할인/가격/재고/세금/
인쇄/주방 처리와 금융 함수는 수정하지 않는다. 영업일/운영 종료 보호도 유지한다.
요청 ID 160자, 500개 line/1MiB, 결과 조회 100개 상한이다. 원장에는 앱 직접 권한이
없으며, 기존 함수 owner와 migration role이 다른 경우 기존의 검토된 DB definer에만
private usage·해당 원장 SELECT/INSERT·helper 실행을 준다. v4가 이 차이를 실제로
검출했고 보완 후 native 권한으로 재실행했다.

`/workspace/.private/resilience-new-store-order-handoff-20261101-v6/result.json`:
**155 parent 조건 PASS, 104.17초, cleanup=true**. 원본 SHA는 6766243e와 기록된 dirty
입력, Office는 45d6b8c8이다. receipt SHA256:
`2930ceef312702a78846a4c50b9dfda2ebb78ccf77d40fd1a560601e165ac9ab`.
실제 양쪽 Auth/REST·Office/POS Edge·POS Storage와 첫/추가 매장·직원/사진 근태를
기반으로 다음을 확인했다.

- 각 매장의 관리자 API로 구역/테이블/카테고리/메뉴를 등록한다. 승인 정책이 없으면
  INVOICE_POLICY_REQUIRED이며 부분 메뉴가 남지 않는다. 시험용 단위·출처를 명시한
  합성 invoice policy만 실제 super admin API로 승인한다. 운영 단위를 추정하지 않는다.
- 개시 승인이 없는 매장은 주문을 거절하며 부분 주문이 남지 않는다. 이후 KDS 단계는
  **영업 개시 상태를 명시적으로 설정한 격리 소프트웨어 fixture**다. field verification,
  credential handover, physical acceptance를 성공으로 위조하거나 실제 승인 RPC에
  허위 장치 결과를 넣지 않았다. 따라서 신규 매장 개시 완료 증거가 아니다.
- 실제 주문 commit 뒤 HTTP acknowledgement를 유실시키고 원래 receipt를 조회한 뒤
  같은 mutation으로 복구한다. 수량 변경 재사용 거절, 다른 actor receipt 숨김,
  101개 조회 거절, 두 요청 동시 최초 생성의 단일 order도 확인했다.
- kitchen_floor / kitchen_tray_floor 모두 수량 2를 1개씩 완료·인계·서빙한다.
  원래 완료 event 재전송/receipt는 중복 완료를 만들지 않고 실제 station snapshot에
  지정 구역의 주문이 나타난다. 다른 매장 floor는 ITEM_UNAVAILABLE로 숨기며 실제
  존재하는 대상 수량이 바뀌지 않는다. 최종 수량 2·원래 금액 100,000·결제 0을 확인했다.

v1의 invoice policy, v2의 개시 차단은 실제 필요한 선행 조건이다. v3의 원래 주문
재전송 실패, v4의 definer ACL, v5의 scoped not-found 응답까지 원본 실패/정리 증거를
보존한다. 전체 실패 이력을 PASS로 고치지 않는다. 앞선 양쪽 Storage/Realtime 119와
이 155를 더해 전체 통합 완료 수치로 만들지 않는다.

공식 parser로 준비한 `scripts/cloud_deployment/plans/20261101_pos_resilience_completion.json`
에는 POS 7개 SQL을 의존 순서와 실제 SHA256으로 고정했다. Office SQL/Edge/web는
별도 공식 단계다. 추가형 원장/확정 기록을 유지한 web rollback을 계획하며 populated
원장 삭제나 migration history 수정은 하지 않는다. 이 파일 준비는 운영 적용이 아니다.

실제 Office 권한 catalog 62개(8 domain)의 domain/action/display_name만 읽기 전용으로
`/workspace/.private/office-permission-catalog-reference-20261101.json`에 0600 보관했다.
이는 양쪽 새 업무 fixture의 기준 설정용이며 사용자/매출/문서/비밀번호 복제가 아니다.
아직 전체 구매/급여/문서 업무를 실행했다는 증거는 아니다.

### G3 결제 증빙 대기열 손상 보존

잘못된 JSON envelope를 빈 대기열로 취급하거나 잘못된 member를 걸러내고 다시
저장해 기존 증빙 기록을 버릴 수 있는 경로를 3개 실패 검사로 재현했다. 이제 전체
shape·필수 identity/date·상태 type·중복 payment ID를 검사하고 손상 시 원문을
보존한다. 기존 queue 검사를 새 사진 파일 생성보다 먼저 수행한다. 잘못된 결제 ID가
문자열 null로 바뀌어 전송되지 않는다. 복구 정보를 버리거나 잘못된 HTTP를 보내지 않는다.
6개 outcome 검사 및 기존 batch/scope/retry와 합계 15개 PASS, Dart analyze 0 issue다.
원본 로그 proof-malformed-queue-before.log / proof-malformed-queue-after.log /
proof-malformed-queue-analysis.log를 보존한다. queue 총량·다중 탭 원자성·owner 없는
legacy 복구·나머지 결과 규약은 계속 잔여이며 이 수정으로 완료 처리하지 않는다.

전체 브라우저/구매/입고/급여/마감, 나머지 33개 domain 전환, 혼합·실단말·2시간 사전
부하, 동결 1배/3배 각 12시간, 최종 main 전체 recipe 및 공식 운영 배포는 아직 미완료다.
현재 12시간 작업은 백그라운드에도 실행 중이지 않다. 기존 운영 로그인 smoke 면제는
NOT_RUN_OWNER_WAIVER로 유지한다.

### G2 구매·회계 연결과 동일 transaction의 권한 회수

실제 Office 권한 catalog에서 확인한 purchase/view와 finance/view를 신뢰된 기존
합성 운영자 context에 포함하고, 실제 procurement_onboarding_sync를 첫/추가 매장
매핑 뒤에 실행했다. 법인/매장 owner를 seed하지 않고 기존 운영자의 승인된 업무
권한을 모델링한다. 두 신규 매장의 requester/store manager/receiver/Office 구매/
회계 준비 상태가 실제 bridge와 native roster에서 true가 되는 것을 확인했다.

같은 합성 Office profile을 정지시키는 명시적 fault를 주입하자 office_connected는
false인데 accounting 준비 상태가 true로 남았다. 만료 기록은 clock_timestamp()지만
후속 recompute가 transaction 시작 now()로 검사해, 방금 만료시킨 행을 같은
transaction에서 유효한 것으로 계산했다. 실제 Office 정지는 반영됐으므로 이것을
정지 계정의 금융 실행 성공이나 운영 권한 침해로 확대 해석하지 않는다.

CLI 생성 `20261101192425_procurement_readiness_observation_time.sql`은 native
connect_procurement_stores의 검토된 유효 정의 hash를 확인한 뒤, 함수 진입의 관측
시각을 한 번 잡아 기존 8개 시간 비교/기록에 사용한다. 앞선 만료 statement 뒤의
시각으로 준비 상태를 계산하며 추가 query나 행별 호출을 만들지 않는다. 원래 owner/
ACL·signature를 유지했는지 transaction 안에서 확인한다. 공식 POS plan은 7개다.

`/workspace/.private/resilience-store-procurement-readiness-20261101-v2/result.json`:
162 parent 조건 PASS, 109.00초, cleanup=true. 원본 source e7fb8c38+기록된 dirty
helper/SQL 입력, Office 45d6b8c8이다. receipt SHA256:
`d12e8654094ec797b78a8a0f604dddd0c563f98db29ba11d9ef54fc5215c7a5d`.
실제 신규 법인/두 매장/근태/주문/두 KDS 정책과 함께, 정지 시 구매·회계 해제,
복구 시 재연결과 활성 roster 4행의 중복 없음까지 확인했다. 두 매장 모두 정지
후 accounting=false, 복구 후 true다. v1의 실제 잘못된 준비 상태/실패 증거도 보존한다.
이것은 구매 신청→승인→PO→검수/입고 전체 완료 증거가 아니다.

Office 변경은 현재 Office 지침과 기존 정상 PR 게시 승인에 따라 draft PR #224
(45d6b8c8)로 등록했다. GitHub Actions/runner 성공을 새 배포 전제조건으로 추가하거나
설정을 바꾸지 않았다. POS PR #655와 함께 검토하며 두 저장소의 최종 공식 gate는
계속 필요하다.

다음 결합 시험은 이 변경과 양쪽 Storage/Realtime·원장 private namespace까지 함께
고정해 실행한다. gateway의 HTTP 지연과 장시간 WebSocket 수명은 별도 bucket으로
기록해, 연결 유지 시간을 요청 지연으로 오인하지 않는다. 운영/2시간/각 12시간은
여전히 미실행이며 실단말 접속 경로와 전체 업무/혼합 시나리오가 남아 있다.
