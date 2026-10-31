# POS 야간 성능 저하·전체 기능 회귀 방지 통합 개선 계획

- 문서 기준일: 2026-10-31 / 시각: 베트남 UTC+7
- POS 분석 기준 SHA: `ecd9c26f8003a654b2b29dc1409f9cc298d5b08e`
- Office 연결 경계 참고 SHA: `8b24d58836b6014d62c498c3f17c106b7da398e8`
- 문서 상태: **기존 조사와 개선 계획 통합 완료. 아래 코드 수정·DB 변경·배포·신규 통합 검증은 미실행.**
- 범위: POS 전체 기능과 공통 기반, 신규 법인·브랜드·매장 개설, 일상 운영·마감·변경·폐쇄, POS↔Office 연결 경계.
- 통합 원칙: 두 보고서를 이어 붙이지 않고 공통 원인·수정 대상을 합쳤다. 이 파일에 조사 결과, 전체 기능 범위, 우선순위, 구현 방향, 완료 기준, 검증·배포 절차를 함께 담았다.

## 1. 목표와 핵심 판단

**야간에도 주문·결제·주방 전달이 안정적으로 동작하고, 한 기능을 수정해도 다른 기능이나 신규 법인·매장 업무가 무너지지 않게 한다.**

야간 지연과 기능 회귀에는 공통 연결이 있다. 화면 변경 하나가 공통 주문 테이블, 할인·재고·세무 트리거, 실시간 이벤트, 여러 단말의 후속 조회까지 영향을 준다. 이 상태에서 DB가 느려지면 상태 확인·재시도·전체 재조회가 추가되고, 화면에서는 저장 결과를 확인하지 못하거나 오래 기다리는 문제가 나타날 수 있다.

이를 N+1 하나로 설명하지 않는다. 다음을 함께 개선한다.

1. 업무 명령·결과·재시도의 일관성.
2. 조회·이벤트·캐시·대기열·화면 작업의 비용과 범위.
3. 최종 DB 계약과 앱·Office·테스트 구성의 일치.
4. 새 법인과 첫 매장을 포함한 전체 생애주기의 초기 설정.
5. 기능 경계·운영 추적·통합 검증·배포 호환성.

**최초 야간 장애를 촉발한 특정 쿼리나 자원은 아직 확정되지 않았다.** 확인된 지연·소스 결함·구조적 위험·추가 측정이 필요한 가설을 구분해 실행한다. 모든 과거 장애가 같은 원인이라는 결론도 내리지 않는다.

## 2. 확인된 사실과 증거의 범위

### 2.1 야간 운영 지표

2026-10-31 운영 로그 중 09:00–21:03 집계에서 확인한 값이다. 아래 P95는 원본 서버 응답 시간이며, 사용자 클릭부터 화면 완료까지의 시간이나 SQL 실행 시간만을 뜻하지 않는다.

| 현지 시각 | API 요청 수 | 원본 서버 응답 P95 | 5xx 수 |
|---|---:|---:|---:|
| 17:00–17:59 | 15,041 | 0.223초 | 0 |
| 18:00–18:59 | 17,010 | 1.315초 | 43 |
| 19:00–19:59 | 22,066 | 5.005초 | 224 |
| 20:00–20:59 | 17,078 | 17.436초 | 693 |
| 21:00–21:03만 | 323 | 19.770초 | 286 |

- 21시 행은 3분 구간이며 5xx 비율은 약 88.5%다. 요청 수에는 재시도·상태 확인이 포함되므로 주문 건수와 다르다.
- 전날 20시: 15,464건 / P95 258.4ms. 당일 20시: 17,078건 / P95 17,435.8ms. 요청은 약 10.4% 증가했지만 지연은 약 67.5배다. 요청 구성까지 같다는 의미는 아니다.
- 매장 ID를 식별할 수 있는 주문 조회에서 전가복 빈탄과 분식클럽 빈탄 모두 지연이 증가했다. 모든 주문 동작을 개별 측정한 값은 아니다.
- PostgreSQL의 명시적 statement timeout 325건, 첫 확인 시각 18:20:11. 실시간 연결을 확보하지 못해 약 12초 대기 후 폐기하는 오류도 확인했다.
- 16:00–21:03의 `process_payment`: HTTP 500 29건, 503 10건. `qr_place_order`: 500 62건, 503 6건, 522 11건.
- HTTP 실패만으로 거래 미처리를 판정할 수 없다. 서버가 이미 확정했을 가능성을 고려해 결과 조회·멱등성으로 중복 처리를 막아야 한다.
- 당시 확인한 운영 웹 SHA는 분석 SHA와 일치했다. 원본 서버 지연이 확인되어 브라우저 캐시만으로 설명할 수 없다.
- 직접 DB 진단과 advisor는 연결 시간 초과로 실패했다. CPU/RAM/IOPS·현재 연결/잠금·복제 지연·실행 계획·운영 유효 함수 전체 대조는 미확보다. 메모리 누수·OOM·교착 상태를 최초 원인으로 확정하지 않았다.

### 2.2 전체 코드 분석 범위

- 추적 파일 3,275개를 목록화하고 코드·설정 텍스트 2,672개를 전수 색인했다.
- 33개 기능의 주요 진입점·상태·서비스·DB·검증 연결을 정적으로 검토했다. 기능 목록은 8절에 모두 포함했다.
- 모든 파일의 모든 분기를 수작업 검토하거나 모든 기능을 운영에서 실행한 결과는 아니다.
- `lib/` 103개 파일이 `main.dart`를 import하며, 33개 기능을 포함하는 171개 파일의 순환 의존 묶음을 확인했다. 이는 소스 결합도이며 런타임 무한 재귀나 장애의 직접 증명은 아니다.
- 623개 마이그레이션 파일을 색인했다. 기존 함수 본문 문자열 수정·별칭 연결·행 트리거가 누적되어 최종 조합을 확인해야 한다.
- 33개 기능 모두 테스트 직접 참조는 있지만, 이는 실행 커버리지나 기능 정상 판정이 아니다.
- Office는 별도 DB·별도 Auth다. 이번 범위는 법인·매장 매핑과 POS 업무 계약의 연결 경계이며 Office 전체 코드 감사는 아니다.

### 2.3 전체 기능에서 확인한 주요 문제

| ID | 판단 | 확인 내용 | 통합 작업 |
|---|---|---|---|
| F1 | HIGH / 소스 계약 불일치 | 매장 없는 최고관리자를 최초 온보딩으로 보내지만, 화면은 DB가 요구하는 브랜드를 전달하지 않음 | U07 |
| F2 | HIGH / 개설 연결 공백 | POS 법인 등록 RPC의 UI 호출 미발견. Office 자동 연결은 동일 법인의 기존 연결 매장을 기준으로 하므로 새 법인의 첫 연결을 스스로 만들 수 없음 | U07 |
| F3 | HIGH / 구조 확인 | 함수 본문 문자열 수정·별칭·트리거 누적과 부분 fixture 때문에 최종 DB 계약을 추적·검증하기 어려움 | U02, U05 |
| F4 | HIGH / 검증 연결 공백 | 기본 검사와 신규 법인부터 업무 종료까지의 E2E 사이에 공백. 현재 스키마 검증은 입력 제공 시 조건부 실행 | U01, U11, U12 |
| F5 | MEDIUM / 의존성 확인 | 103개 main 역참조와 171개 파일의 순환 의존 관계 | U09 |
| F6 | MEDIUM / 비동기 경합 경로 | QC는 매장 변경 후 이전 요청의 늦은 응답을 반영하지 않도록 하는 세대 보호가 없음 | U08 |
| F7 | MEDIUM / 결과 계약 차이 | 저장 확정·전체 재조회·오프라인 대기·결과 불명이 기능별로 다르게 표현됨 | U03, U08 |
| F8 | HIGH / 운영 증상 확인 | 광역 조회·메뉴 이벤트·폴링·재시도·DB 작업·연결 대기가 함께 성능 위험을 만듦 | U01, U04, U05, U06, U10 |

F2는 별도의 수동 등록 절차까지 없다고 확정한 판단이 아니다. F6는 운영의 타 매장 쓰기나 권한 유출을 확인한 것이 아니다. F7은 중복 결제 또는 KDS 허위 완료가 발생했다는 확정 판단이 아니다.

## 3. 유지해야 할 업무 규칙과 보호 장치

개선 과정에서 다음을 변경하거나 우회하지 않는다.

- 전가복 빈탄은 실제 운영 매장이다. 삭제·폐쇄 매장의 운영 목록 노출과 과거 실제 매출의 귀속은 구분한다. 샘플 매출은 전체 리포트에서 제외한다.
- 전가복 빈탄은 **주방 → 지정 층** 전달이며 체커를 재활성화하지 않는다. 분식클럽의 **주방 → 트레이 → 층** 경로는 유지한다.
- 전가복의 조리 시작과 명시적 수량별 층 전달을 구분한다. 기존 저장 층/고객 표시 층 매핑, 배달·픽업과 홀 전달의 차이, 과거 큐 스냅샷을 보존한다.
- 기존 할인 카테고리와 50% 설정을 유지한다. 메뉴별 잔량 설정·주문 차감·취소 복구·잔량 표시·소진 후 정상가·후불 할인 스냅샷을 모두 보존한다.
- 마지막 할인 수량의 원자성, 결제·재고·취소의 정확성, 이력·발행 문서의 불변성을 유지한다. 잠금 제거로 정확성을 희생하지 않는다.
- 실제 미결제 주문을 페이지 제한이나 영업일 경계 때문에 누락하지 않는다. 목록은 요약/페이지로 줄이고 필요한 모든 주문에는 접근할 수 있어야 한다.
- `process_payment`의 원자적 업무 계약을 유지한다. MISA 장애가 결제 완료를 막지 않도록 비동기 발행을 유지한다.
- POS Auth와 Office Auth, 로그인 계정과 직원, POS ID와 Office ID를 구분한다. 이름·동일 UUID만으로 소유 법인을 추정하지 않는다.
- 물리 `restaurants`와 Office가 사용하는 열/식별자, 법인·브랜드·매장 범위 및 RLS를 보존한다.
- 구매 정책 3, 검수된 누적 수량의 원자적 입고, 부족분 이력, 중복 재고·지급 방지, 발행 문서와 실제 전송 증거의 구분을 유지한다.
- 폐기된 Deliberry, Photo 자동 매출 수집, 자동 22:20 매출 확정을 재활성화하지 않는다. 고객 배달비 비활성 규칙도 유지한다.
- 기존 계정 생성 작업의 재개·멱등성, 구매 operation journal, 근태 결과 불명 확인, KDS 확정 후 조회 실패 보호, 현재 개설 readiness를 재사용한다.
- 운영 로그인 스모크의 기존 사용자 면제는 유지하며 **NOT_RUN**으로 기록한다. 격리 테스트와 운영 스모크는 서로 다른 증거다.

## 4. 실행 순서와 의존 관계

**순서는 야간 안정화 → 공통 처리 비용/계약 개선 → 신규 법인·매장 완결 → 구조·상태 정리 → 통합 검증과 안전한 운영 적용이다.**

| 순서 | 작업 묶음 | 선행 조건 | 종료 기준 |
|---|---|---|---|
| 0 | U01 기준선/진단 + U02 최종 계약 확인 | 현재 SHA·배포·DB 이력·기존 실행/검증 증거 확인 | 증상·지연 단계·DB 계약과 미확보 지표가 구분됨 |
| 1 | U03 결과 처리 + U04 요청/이벤트 + U05 DB 비용 + U06 백그라운드 작업 | U01 측정, DB 변경은 U02 계약 확인 | 거래 정확성을 유지하며 불필요한 대기·요청·반복 계산 감소 |
| 2 | U07 법인/첫 매장 + U08 범위/비동기 상태 | U02 계약·U03 결과 규약 | 새 법인 첫 매장과 기존 매장이 동일 업무를 완주 |
| 3 | U09 모듈 경계 + U10 장시간 화면 비용 | 안정화된 공개 계약·영향 기능 목록 | 변경 영향 범위 축소, 장시간 사용 비용 안정 |
| 전 단계 | U11 기능/성능 검증 + U12 배포/호환성 | 각 작업의 변경 범위·증거 | 최종 SHA에 연결된 정확성·성능·배포 결과 |

- U01과 기능 목록 정리는 다른 작업의 출발점이며 거대한 관측 시스템을 먼저 만드는 작업이 아니다.
- U02의 최종 DB 계약 확인은 트리거·할인·결제 변경보다 먼저 한다. 정본 정리는 각 변경 범위부터 단계적으로 진행한다.
- 신규 개설 경로 수정은 전체 모듈 분리가 끝날 때까지 기다리지 않는다. 범위를 분리할 수 있으면 공통 안정화와 함께 진행한다.
- 긴급 안정화와 장기 구조 개편을 한 번의 거대한 변경으로 묶지 않는다. 실제 릴리스마다 최종 통합 코드 기준으로 검증한다.
- **같은 릴리스의 DB 단계를 옮길 때마다 전체 검증·웹 배포를 반복하지 않는다.**

## 5. 통합 작업 목록

### U01 — 야간 병목 기준선과 전체 기능 추적

**문제:** 다수 매장의 지연은 확인했지만 최초 병목과 각 요청·트리거·후속 조회의 기여율은 미확정이다.

**구현/조사**
- 18:00–21:03의 API·DB·Realtime·cron·외부 작업 지표를 같은 시간축에 연결한다.
- 관리 지표를 우선 이용하고, 연결 가능 시 제한된 읽기 전용 진단으로 대기 이벤트·차단 쿼리·pg_stat_statements·풀 점유·복제 지연을 확인한다. 실패한 운영 진단을 반복해 부하를 추가하지 않는다.
- 33개 기능과 공통 RPC·트리거·이벤트·권한·테스트·배포 자산을 하나의 영향 목록으로 유지한다.
- 기존 operation_id/audit 기록에 법인·매장·단말·앱 SHA·계약 버전을 연결한다. UI 대기/네트워크/DB 확정/큐/후속 표시/외부 전달 시간을 구분하고 개인정보·토큰은 기록하지 않는다.

**완료 기준**
- 느림이 DB 계산·락·연결 대기·백그라운드 자원 경쟁·단말 중 어느 단계인지 근거로 분류한다.
- CPU 병목은 연산/용량, 잠금은 차단 트랜잭션/순서, 연결 적체는 요청·풀·처리 시간에 맞춰 조치한다. 증설·재시작을 추측으로 선택하지 않는다.
- 새 기능/RPC/트리거가 영향 목록과 검증 연결 없이 추가되면 누락을 식별한다.

### U02 — DB 최종 계약과 테스트 구성 일치

**문제:** 과거 SQL 조각과 부분 fixture의 성공이 현재 최종 함수·트리거·RLS 조합의 성공을 의미하지 않는다.

**구현**
- 대상 함수·뷰·트리거·정책·권한·인덱스 및 RPC 입출력의 현재 유효 정의와 해시를 확보한다.
- 기존 마이그레이션 이력은 보존한다. 새 변경부터 명시적인 정본 정의와 forward migration을 사용하고 문자열 패치 의존을 줄인다.
- 현재 스키마를 반영한 격리 fixture와 신규 설치 fixture를 준비한다. Office read/write 허용 계약과 식별자 매핑도 비교한다.
- DB 먼저 적용되는 동안 이전 웹과 새 웹이 요구하는 계약을 명시한다.

**완료 기준**
- 신규 DB/지원 버전 업그레이드 DB에서 동일한 업무 불변식이 성립한다.
- 과거 SQL 문자열 존재 확인과 실제 최종 DB 실행 증거를 구분한다.
- 배포 전후 실제 migration 이력·유효 함수·권한의 일치를 확인하며 적용 이력을 임의로 보정하지 않는다.

### U03 — 저장 결과·재시도·결제 성공 표시 통일

**문제:** 결제 확정 뒤 전체 목록 조회를 기다리거나, 오프라인 대기와 서버 완료가 같은 반환형으로 표현되는 경로가 있다.

**구현**
- 공통 결과 규약을 `confirmed / queued / unknown / rejected`로 명시한다. 업무별 상태 전이는 해당 도메인에 남긴다.
- 서버에서 확정된 결제는 전체 목록 재조회와 분리해 즉시 성공 상태로 반영하고 변경 주문만 갱신한다.
- 요청 operation_id를 유지하며 중복 클릭·재접속에도 같은 업무 요청의 결과를 확인한다.
- 응답 유실은 `unknown`으로 두고 기존 거래 결과를 조회한다. 확정 후 조회 실패 때문에 쓰기를 다시 실행하지 않는다.
- 기존 구매 저널·KDS outbox·근태 확인 동작을 보호하며 다른 저장 경로에도 일관된 상태를 적용한다.

**완료 기준**
- 결제·주방·입고·근태·설정 저장에서 commit 직후 응답 유실, 중복 클릭, 재연결에도 중복 효과가 없다.
- 사용자 화면이 서버 확정·전송 대기·결과 확인 필요를 구분한다.
- 결제 확정 표시 시간과 목록 최신화 시간을 각각 측정한다.

### U04 — 요청·실시간 이벤트·캐시·재시도 조정

**문제:** 정상 상태의 반복 설정 조회, 일반 menu 이벤트를 통한 전체 메뉴 재조회, 겹치는 복구 요청이 추가 비용을 만든다.

**구현**
- 할인 잔량 변화와 메뉴 구성 변경을 구분하고 변경 메뉴 ID/잔량을 제한된 일괄 조회로 갱신한다.
- KDS 설정·가격·정책 등 상대적으로 덜 변하는 데이터는 접근 범위·정책 버전·TTL·무효화 기준을 정해 재사용한다.
- 정상 업무 응답으로 연결 상태를 갱신하고 불필요한 health 조회를 줄인다. 실제 전달 지연과 복구 요구는 유지한다.
- 동일 조회 자원은 실행 중 요청 1개와 병합된 후속 요청 1개를 기본 조정 단위로 삼는다. 쓰기 명령과 서로 다른 필수 업무를 하나의 막히는 큐로 합치지 않는다.
- 실제 HTTP 취소, 대기열 길이/최대 대기 시간, 재시도 횟수/전체 시간·backoff/jitter를 명시한다. 권한·검증 오류는 재시도하지 않는다.
- 재시도 예산은 상위 스냅샷·내부 RPC·SDK를 합쳐 계산한다. 공유 Auth client를 종료해 다른 요청을 끊지 않는다.

**완료 기준**
- 같은 데이터·활성 단말·QR 손님 수에서 업무당 요청과 이벤트로 인한 후속 조회가 감소한다.
- 서버측 구독 범위와 권한 보호를 유지하며 주방 전달/복구 목표를 만족한다.
- 논리적 timeout 후에도 실제 요청이 계속 누적되지 않는다.

### U05 — 할인·트리거·조회·집계의 DB 비용 개선

**문제:** 주문 항목마다 할인/후처리가 반복되고, 응답은 작아도 내부에서는 당일 전체 집계가 수행될 수 있다.

**구현**
- 항목별 변경에서 영향받은 주문 집합을 모아 할인/가격 동기화를 주문 단위로 수행하도록 설계한다. 실제 적용 함수·트리거 체인을 먼저 확인한다.
- 할인 잔량 예약·취소 복구·후불 snapshot·잠금 순서·마지막 수량 경쟁 조건을 보존한다.
- 결제 목록은 필요한 요약/현재 페이지를 우선 받고 선택 주문의 상세를 조회한다. 오래된 미결제 주문의 접근 경로와 정확한 합계는 유지한다.
- KDS 현재 큐와 완료 이력을 분리하고, 커서 LIMIT 앞의 집계량·중첩 관계·RLS 비용·인덱스를 실행 계획으로 확인한다.
- 결제 임시 DDL, 출력 보류/준비 작업, 반복 건수/요약 집계의 비용을 측정해 집합 처리·요약 재사용·적정 인덱스를 적용한다.
- 큰 OFFSET 또는 거대한 단일 응답으로 대체하지 않는다. 관계별 사전 집계/제한된 배치/키셋을 실제 규모에 맞게 선택한다.

**완료 기준**
- 항목·주문·매장 수 증가에 따른 호출/스캔/잠금 시간이 기록되고 불필요한 항목별 원격 왕복이 없다.
- 모든 할인·가격·결제·재고 불변식이 유지된다.
- 전후 실행 계획, 읽은 행, 전송 bytes, 처리 시간, 잠금 대기, 인덱스 쓰기 비용을 함께 비교한다.

### U06 — 백그라운드 작업과 거래 처리의 자원 경쟁 제어

**문제:** 알림·출력·발행·cron 작업의 지연과 실패가 거래 처리와 겹친다. 외부 API가 최초 원인인지는 미확정이다.

**구현**
- 현재 활성 cron/dispatcher를 확인하고 작업별 배치 크기·동시성·전체 시간·재시도 예산을 설정한다.
- 기존 MISA의 제한 배치/동시성·설정 일괄 조회, 계정 생성 worker의 제한과 재개를 보존한다.
- claim/lease/ack와 오류·결과 불명·외부 완료 상태를 구분한다. 외부 부작용이 있는 작업은 자동 재전송 전에 결과를 확인한다.
- 거래 처리에 불필요한 동기 외부 호출을 제거하고 자원 경쟁을 줄인다. 출력 결과처럼 개별 확인이 필요한 작업을 무조건 하나의 ack로 합치지 않는다.
- 폐기된 외부 통합·자동 수집·자동 매출 확정은 활성 작업 목록에서 제외한다.

**완료 기준**
- 결제·주방·출력·발행·알림 동시 실행에서 queue age와 오류율이 예산 안에 있고 거래 완료가 외부 서비스에 종속되지 않는다.
- 장시간 실패 후에도 작업 폭주·중복 인쇄/발행/알림을 예방할 수 있다.

### U07 — 신규 법인·첫 매장·추가 매장 개설 완결

**문제:** 기존 매장에서는 보이지 않는 최초 진입 계약 불일치와 POS↔Office 최초 연결 문제가 있다.

**구현**
- 매장이 없는 최고관리자도 법인/브랜드 준비와 현재 매장 등록 경로에 접근하게 한다.
- 최초 온보딩을 현재 등록 서비스에 연결하고 필수 법인·브랜드·slug/config를 올바르게 전달한다.
- POS tax_entity와 Office legal_entity의 소유 관계를 명시적으로 등록·검증한다. 기존 매장 앵커가 없는 첫 연결을 별도 단계로 처리한다.
- 법인·브랜드·매장 → 계정/직원/권한 → 구역/주방/층/기기 → 메뉴/옵션/할인/세무/수금 → 재고/구매/Office → 개설 검증 순서를 관리한다.
- 현재 store_lifecycle/readiness와 계정 생성 작업을 확장한다. 미사용·필수 미설정·검증 실패를 구분하고 중단 지점부터 중복 없이 재개한다.
- 법인 이전·휴점·폐쇄 시 미결 업무, 적용 시점과 과거 발행 문서/매출 이력을 보존한다.

**완료 기준**
- 기존 seed와 특정 매장 ID에 의존하지 않는 새 법인 A/B·브랜드·첫 매장에서 판매·결제·주방·구매·근태·마감·리포트까지 완료한다.
- 기존 법인의 추가 매장, 내부/외부 소유 유형, 샘플 매장도 적절한 정책으로 처리한다.
- 법인/매장 간 읽기·쓰기 접근을 거부하고, 샘플 매출을 전체 리포트에서 제외한다.

### U08 — 사용자·법인·매장 범위와 비동기 상태 표준화

**문제:** 기능마다 캐시 키·조회 세대·응답 폐기·로그아웃 정리 기준이 다르다.

**구현**
- 사용자/권한 버전·법인·매장·조회 조건을 명시한 scope와 캐시 키를 사용한다.
- 요청 세대 번호와 mounted/활성 범위를 확인해 이전 매장의 늦은 응답을 폐기한다. QC 경로를 포함한다.
- 진행 중 요청 공유, TTL, 변경 ID/범위 무효화, 화면 비활성/로그아웃/권한 변경 시 구독·타이머 정리를 적용한다.
- 저장 실패와 조회 실패, 오래된 값과 실제 0건을 구분하고 권한 오류를 빈 결과로 숨기지 않는다.

**완료 기준**
- A→B 매장/법인 전환, 사용자 교체, 응답 역전, 탭 복귀, 저장 중 scope 변경에도 다른 범위의 결과를 표시/반영하지 않는다.
- 기존 테이블·고객 표시·워크플로 설정의 세대 보호를 보존하며 같은 보호 기준을 확장한다.

### U09 — 모듈 경계와 책임 분리

**문제:** 공통 진입점 역참조와 거대 화면 때문에 변경 영향 범위가 넓고 테스트 격리가 어렵다.

**구현**
- main의 Supabase client·환경·테마를 하위 공통 계층으로 옮기고 서비스에 의존성을 주입한다.
- 화면 → 업무 서비스 → 저장소 방향으로 경계를 고정한다. 업무별 상태 머신은 각 기능에 남기고 새 거대 공통 controller를 만들지 않는다.
- 구매/계산대/관리 화면은 화면 구성·명령·조회·계산의 책임별로 점진적으로 분리한다.
- 새 main 역참조·순환 의존을 검사하고 새 코드부터 차단한다.

**완료 기준**
- main 역참조 103개를 단계적으로 0개로 줄인다. 분석상 간선 제거 효과와 실제 리팩터링 결과는 별도 기록한다.
- 기능 테스트가 전체 앱 초기화 없이 실행되고 공개 계약/기존 업무 동작이 유지된다.
- 파일 줄 수 감소만을 성과로 판단하지 않는다.

### U10 — 장시간 화면·메모리·네트워크 비용 개선

**문제:** 시계/강조의 빈번한 상위 화면 갱신과 취소되지 않는 요청은 장시간 사용 비용을 늘릴 수 있다. 현재 메모리 누수는 확정되지 않았다.

**구현**
- KDS 시계·강조 표시만 부분 갱신하고 불필요한 전체 rebuild를 줄인다.
- 화면 전환·재연결·탭 숨김/복귀에 따라 타이머/구독/worker/네트워크 요청이 정리되는지 측정한다.
- 최소 사양 운영 단말에서 데이터 1배/3배, 8–12시간 사용의 프레임·long task·heap·활성 구독/요청 수를 측정한다.
- 대량 Excel/카탈로그는 실제 파일 크기와 메모리 한도를 기준으로 배치/스트리밍/worker를 사용한다. Photo worker의 timeout·종료 보호를 유지한다.

**완료 기준**
- 화면 전환·재연결을 반복해도 살아 있는 요청·구독·타이머가 누적되지 않는다.
- 안정 구간에서 GC 이후 기준 heap이 지속 상승하지 않고, 최대 입력 크기에 대한 peak memory가 기록된다.
- UI CPU 문제와 서버/매장 회선 문제를 구분해 보고한다.

### U11 — 전체 업무·성능·실패 복구를 하나의 검증 목록에 연결

**문제:** 개별 단위/문자열/SQL/인코더 검증만으로 실제 업무 연결과 밤 시간 혼합 부하를 보장할 수 없다.

**구현**
- 기존 테스트를 보존하고 최종 DB 구성·다중 역할·신규 법인·기존 매장·샘플/폐쇄/법인 이전 E2E를 보완한다.
- 실제 브라우저 다운로드, worker 자산, 출력/오디오 어댑터와 실기기 증거를 구분한다.
- 동일 SHA·데이터·장비·동시성·쿼리 조건으로 전후 정확성과 성능을 측정한다.
- 개발 중에는 영향 검증을 실행하고, 최종 main에서는 공식 전체 절차를 한 번 실행한다. 새 전체 검증을 후보/DB/웹 단계마다 추가하지 않는다.
- 기능 목록·11개 성능 지침·검증 명령·측정 산출물을 연결한다.

**완료 기준**
- 거래·할인 잔량·재고·근태·원장·매출 합계가 업무 연쇄 전체에서 일치한다.
- 응답 유실·동시 실행·권한 변경·장시간 사용·오래 열린 단말을 포함한 범위가 명시된다.
- 미실행/면제/실패를 PASS나 통합 완료로 바꾸지 않는다.

### U12 — 중복 없는 공식 배포와 이전 단말 호환

**문제:** DB·Edge·웹·worker·오래 열린 단말의 버전 조합이 다르면 개별 검증 성공 후에도 장애가 발생할 수 있다.

**구현**
- 기존 인증된 클라우드 환경에서 도구·설정·대상·DB 이력·실행 중 작업을 먼저 확인한다.
- 깨끗한 최신 origin/main과 같은 최종 SHA에서 공식 배포 스크립트를 사용한다.
- 릴리스 계획에 필요한 DB 변경을 의존 순서대로 묶고 DB를 먼저 적용한다. 통합 웹은 해당 릴리스에서 한 번 배포한다.
- 공식 entrypoint가 소유한 전체 검증을 한 번 실행하고 같은 invocation 내 유효한 증거만 재사용한다. 임의 receipt 수입·skip PASS·무조건 재실행을 하지 않는다.
- 운영 설정으로 빌드하고 SHA·배포 ID·URL·자산 bytes·Edge/DB 계약을 대조한다.
- 이전 웹+새 DB, 새 웹+새 DB의 호환을 확인한다. 롤백은 데이터/DB 계약 호환성을 확인한 범위에서 수행한다.

**완료 기준**
- READY나 빌드 성공만으로 완료 판정하지 않는다. 필요한 업무/운영 확인과 미실행 범위를 함께 보고한다.
- 단계별 시작/종료/마지막 진행·증거를 기록해 실패 시 완료 단계부터 확인한다.
- 현재 공식 절차의 재사용 경계를 지키며, 전체 검증·일반 빌드·웹 배포를 중복하지 않는다.

## 6. 성능 목표와 측정 계약

다음은 **제안 목표이며 현재 달성값이 아니다.** U01에서 대상 API·데이터 크기·매장/단말 수·네트워크 조건과 측정 위치를 고정한 뒤 기준선과 함께 사용한다.

| 항목 | 제안 목표 / 측정 방법 |
|---|---|
| 주요 목록 읽기 | API별 P95 500ms 이하 목표. 서버 응답과 화면 완료 시간을 별도 기록 |
| 결제 | 결제 서버 처리 P95 1초 이하 목표. 확정 응답 후 다음 UI 갱신에서 결과 반영; 전체 목록 갱신 대기는 별도 |
| 주방 → 지정 층 | 정상 변경 반영 P95 2초 이하 목표, 누락 복구 약 5초 수준의 기존 요구 유지 |
| 같은 조회 자원 | 실행 중 1개 + 병합 후속 1개를 기본 조정 단위로 사용; 대기 시간/실제 취소까지 확인 |
| 호출/이벤트 | 거래당 원격 호출·SQL 호출·후속 이벤트/조회 수를 측정. 제한된 배치와 불필요한 항목별 호출을 구분 |
| 데이터 처리 | 읽은 행·JOIN 단계 결과·전송 bytes·서버/클라이언트 집계 범위·페이지 크기 기록 |
| DB | P95/P99, 잠금 대기, 연결 대기, CPU/IO/복제 지연, 인덱스 읽기·쓰기 비용 비교 |
| 장시간 단말 | 실제 최소 사양 단말·8–12시간·1배/3배 데이터에서 heap/프레임/구독/실제 요청 수 기록 |
| 초기 회귀 경보 | 동일 조건에서 호출·전송량·P95가 기준선보다 20% 이상 악화하면 원인 검토. 더 느린 기준선을 자동 승인하지 않음 |
| 정확성 | 중복 결제·중복 입고·할인 초과 배정·타 법인 접근·주방 전달 수량 누락 0을 테스트 불변식으로 확인 |

단순 병렬화로 N+1 해결을 주장하거나, 응답 크기만 작다는 이유로 DB 작업량이 작다고 판단하지 않는다. 고정 상한으로 정상 업무를 누락시키는 방식도 사용하지 않는다.

### 데이터 접근·성능 지침 11개와 통합 작업 연결

| 번호 | 지침 | 적용 작업 | 완료에 필요한 증거 |
|---|---|---|---|
| 1 | 기존 경로까지 항목별 N+1 방지 | U04·U05·U11 | 항목/주문/매장 수별 호출 증가율과 트리거 후속 작업 |
| 2 | JOIN·일괄 API·집합 SQL, SQL 내부 반복 확인 | U02·U05 | 유효 함수/트리거 정의, 집합 처리 전후 실행 비용 |
| 3 | 필요한 행·열·관계와 서버 검색/정렬/페이지 | U04·U05·U10 | 읽은 행·응답 bytes·상세 조회/페이지 범위 |
| 4 | 일대다 JOIN의 중복/곱셈 증가 확인 | U05 | JOIN 단계 행 수·키 유일성·관계별 집계·합계 검증 |
| 5 | 인덱스·실행 계획·키셋 및 읽기/쓰기 비용 | U01·U05 | 실제 규모 실행 계획·스캔/락·페이지 중복/누락·인덱스 비용 |
| 6 | 중복 요청·전체 재조회·캐시 무효화·폴링 최소화 | U03·U04·U08 | 이벤트 한 건이 만드는 후속 요청 수와 전달/복구 지연 |
| 7 | 사용자/테넌트/조건별 캐시·TTL·무효화·in-flight 공유 | U04·U08 | 사용자/매장 전환·권한 변경·동시 조회·응답 역전 검사 |
| 8 | 병렬 요청·배치 크기 상한 | U04·U06 | 실제 동시 요청/대기열 길이/최대 시간, 제한 배치 처리 |
| 9 | 일시 오류만 제한 재시도, backoff/jitter, 쓰기 멱등성 | U03·U04·U06 | 계층 합산 예산·실제 취소·응답 유실·중복 부작용 검사 |
| 10 | 대용량 페이지·배치·스트리밍 | U05·U10 | 최대 입력/출력 크기·peak heap·프레임·취소/부분 실패 |
| 11 | 반복 전체 건수·대형 집계 억제 | U04·U05 | 요약 호출 빈도·실행 계획·정확성과 최신성을 유지한 재사용 |

## 7. 전체 생애주기 검증

| 단계 | 반드시 연결할 업무 | 핵심 통과 기준 |
|---|---|---|
| 법인 생성 | POS/Office 법인·소유 관계·세금번호·접근 범위 | 기존 매장이 없어도 최초 연결을 명시적으로 완성; 다른 법인 접근 차단 |
| 브랜드 연결 | 법인-브랜드 관계·관리자·직영/가맹 정책 | 복수 법인/소유 유형·잘못된 연결 거부 |
| 매장 등록 | 식별자·업태·영업시간·구역/주방/층·전달 경로 | 필수 계약 충족, request_id 재시도 시 중복 생성 없음 |
| 계정/인력/기기 | 고정 계정·직원·역할·단말·출력/고객 표시 | 계정과 직원 분리, 최소 권한, 미완료 작업 재개 |
| 영업 준비 | 메뉴/옵션/가격/할인·세무·수금·재고/구매·Office | 실제 필요한 capability와 readiness 충족, 필수 미설정 안내 |
| 일상 운영 | 주문·추가/취소·결제/환불·주방/층·배달·구매/입고·근태·QC | 수량/금액/권한 불변식, 동시성·응답 유실·복구 성공 |
| 마감/보고 | 영업일·현금·정산·발행·급여·리포트·Excel/PDF | 원장/집계 일치, 실제 다운로드, 대형 집계와 거래 동시 처리 안정 |
| 변경/폐쇄/이전 | 정책 변경·미결 업무·법인 이전·과거 이력·샘플/삭제 분류 | 구버전 단말 호환, 열린 업무 보호, 과거 소유/문서 보존 |

## 8. 전체 기능 적용 목록

**33개 영역 모두 대상이다.** 아래 업무 목록은 일부 신고 사례만 고치는 방식으로 범위가 축소되지 않도록 유지한다. 관리자 영역에는 메뉴·직원·급여·근태·재고·세금계산서·마감·보고·설정·QC·감사 하위 업무가 포함된다.

| 기능 영역 | 포함 업무 | 정적 검토에서 남긴 적용/검증 메모 |
|---|---|---|
| `admin` | 메뉴/옵션/할인·직원/급여·근태·재고·세금계산서·마감·보고·테이블/프린터·QC·감사 | F3·F4·F5·F6·F8. 관리자 하위 업무도 전체 목록에 포함. |
| `attendance` | 키오스크 근태·사진·직원번호·지문 | 현재 unknown 보호는 보존. 신규 직원/매장, 날짜 경계, 업로드 후 응답 유실 실행 필요. |
| `auth` | 로그인·초기 비밀번호·동의·세션 복구·역할/매장 선택 | F5·F6 및 혼합 버전 호환. 별도 Office Auth와 합치지 않음. |
| `cashier` | 주문 편집·결제·할인·할인 증빙·수금/환불 UI | F3·F7·F8. 단일 화면 수정 영향이 주문/재고/리포트까지 이어짐. |
| `customer_display` | 고객용 결제/주문 표시 | 보호 장치 있음. 오래 열린 단말과 계정 변경 E2E 미실행. |
| `delivery` | 외부 배달 정산 legacy | 폐기된 코드. 새 개설의 필수 단계로 넣거나 재활성화하지 않음. |
| `digital_receipt` | 공개 영수증·PDF·저장/출력 | 공개 token과 staff scope 혼용 금지. 브라우저 저장/인쇄 실제 실행 미검증. |
| `direct_order` | 고객 직접 주문·주소/배달·증빙·수정·직원 처리 | F3·F4·F7. 가용성/영업시간·잔량·증빙 바꾸기·중복 요청 검사 필요. |
| `emergency_fulfillment` | 주방 접수/완료·트레이·층 전달·오프라인 큐 | F3·F7·F8. 동시 부분 완료·신규 층/주방·워크플로 변경 검사. |
| `inventory` | 품목·재고·레시피·Excel 가져오기 | F3·F5·F8. 부분 조회·버전/단위·대량 입력과 음수/중복 방지 검증. |
| `inventory_purchase` | 구매 신청/발주·입고·문서·회계 전송 | F3·F6·F7·F8. 8,763줄 화면과 4,462줄 workflow 책임 분리. |
| `kitchen` | 일반 주방 주문 상태 | 새 매장 업태/전달 정책별 구성에 대해 기존 경로와 호환 검증 필요. |
| `onboarding` | 매장 없는 관리자 최초 설정 | F1: 필수 브랜드 미전달, 신규 초기 진입 실패 경로. |
| `order` | 주문 생성·추가·인원·취소/복구·포장 | F3·F7·F8. 작성/취소가 할인 수량·재고·주방에 만드는 영향 확인. |
| `payment` | 결제·합산/분할·취소/조정·지급 증빙 | F3·F7·F8. commit 성공과 UI 재조회 지연 분리, 정확한 불변식 검사. |
| `photo_inventory` | Photo 재고·조정 이력 | 업종 capability 및 저장/갱신 결과 분리. 실제 재고 변경 미실행. |
| `photo_ops` | Photo 근태·재고·급여·기간 운영 보고 | Photo 권한/기간/시간 경계 검증. 부분 조회 실패를 정상 0으로 바꾸지 않음. |
| `photo_sales_import` | 수동 매출 Excel 등록·반환 | Photo 자동 collector는 활성화하지 않음. 실제 worker asset·대량 파일 검증 필요. |
| `print_station` | 영수증 출력 스테이션 | device/lease/영수증 전용 정책 존재. 출력 성공 후 ack 유실은 실기기/어댑터 별도 검증. |
| `procurement` | 구매 workspace·품질검수·lot·재고·문서 | 좋은 명령 계약 참고점. Office 매핑/법인 소유·신규 공급업체 절차와 연결. |
| `qc` | 점검 template·입력·검토/후속 조치 | F6: 역순 응답의 이전 매장 결과 덮기 가능. 서버 권한 우회 확정 아님. |
| `qr_order` | QR 메뉴·주문·결제 요약 | 새 매장 QR/취소/추가 주문·메뉴 변경·가격 경계 E2E 필요. |
| `receipt_ledger` | 영수증 원장·검색/상세 | 정확한 summary 재사용 조건·페이지 중복/누락·실제 출력 실행 미검증. |
| `red_invoice_intake` | 사업자 정보·사후 인보이스 요청 | tax_entity/store identity, 발행 전후 수정 규칙과 권한 범위 보존. |
| `report` | 매출·메뉴 판매·예측·분석 그래프 | F3·F8. 대량 집계·금액 기준·삭제/샘플 제외가 목록/합계에 동일하게 적용되는지 검사. |
| `restaurant_sales_export` | 매출 Excel·일매출 보고/신고 | F4: 문자열/인코더 검증을 실제 브라우저 다운로드와 구분. 긴급 수정은 건드리지 않음. |
| `settings` | 할인·테이크아웃·회사 조회·프린터 진단 | 필수/미사용/미설정을 구분. 계정·매장 전환 후 설정 응답 경합 검사. |
| `store_procurement` | 구매 품목/공급업체·기준/품질·초기 계획 | 법인/Office 매핑/기초 재고·단위 준비가 신규 매장 첫 구매의 선행 조건. |
| `store_setup` | 매장 운영 설정·계정/직원·출력/기기·생애주기 | 이미 존재하는 개설 검사에 법인 첫 연결과 실제 통합 결과를 연결. 새 중복 시스템 금지. |
| `store_workflow` | 주방/트레이/층 경로·준비 보드 | 기존 명시적 상태 전이는 보존. 멀티주방·오프라인 장치·설정 변경 검사. |
| `super_admin` | 법인/브랜드/매장·네트워크 리포트·계정/개설 | F1·F2·F3. 법인 등록 RPC의 UI 호출 미발견; 새 법인 첫 매장 과정 필요. |
| `table` | 테이블/층 layout·현재 주문 preview | 부분 갱신 보호 확인. 이동·합산·날짜 경계와 신규 floor 상태 검사. |
| `waiter` | 테이블 접객·주문/인원·이동·취소·직원식사 | 새 업태·선/후불·서비스 품목·주방 라우팅의 연결 검증 필요. |

업무 화면 외에도 다음 기반을 포함한다.

| 공통 기반 | 통합 계획 범위 |
|---|---|
| Auth·terminal auth·gotrue fork | 세션/토큰 갱신·다중 단말·로그아웃·재시도·권한 변경 |
| main·router·permissions | 최초 개설 경로·역할 진입·모듈 역참조 |
| 공통 services/providers | 명령/조회/캐시/이벤트·결과 표현·scope·timeout |
| 결제/급여/시간 계산 | 통화·VAT·분할·수금·베트남 업무일/기간 불변식 |
| 프린터·오디오·플랫폼 어댑터 | claim/lease/ack·출력 결과·OS 지원·실기기 확인 |
| SQL/RLS/뷰/트리거/마이그레이션 | 최종 정의·권한·인덱스·법인/매장 경계·새 DB/upgrade 일치 |
| Edge/cron/외부 연동 | 계정·공개 주문/영수증·조회·MISA·SePay·알림·작업 동시성/복구 |
| web/native·worker/자산 | bootstrap·세션·브라우저 다운로드·기기별 동작·혼합 버전 |
| 테스트/검증/배포 | 영향 목록·현재 fixture·정확성/성능 통합·최종 SHA·한 번의 공식 실행 |
| Office 경계 | 별도 Auth/DB 유지, 법인/매장/직원 식별자 매핑과 허용된 업무 계약 |

## 9. 통합 검증 시나리오와 완료 조건

| ID | 시나리오 | 확인할 결과 |
|---|---|---|
| T01 | 기존 실제 매장 정상 영업 | 주문→주방→해당 전달 경로→결제→재고/세무→마감/리포트 일치 |
| T02 | 새 법인 A/B와 첫 매장 | 기존 seed/매장 ID 없이 개설부터 판매·구매·근태·보고 완주, 상호 접근 거부 |
| T03 | 기존 법인의 추가 매장 | 계정·영역·메뉴·설정·Office 연결 및 첫 거래 완결 |
| T04 | 할인 마지막 수량 동시 주문/취소 | 초과 할인 0, 취소 복구, 소진 후 정상가, 후불 snapshot 보존 |
| T05 | 결제/입고/근태/주방 응답 유실 | commit 이후 응답이 없어도 재확인으로 복구, 중복 효과 0 |
| T06 | 동시 부분 완료·트레이/층 전달 | 전가복/분식클럽 경로 각각 보존, 선택 수량만 전달, 누락/중복 없음 |
| T07 | 야간 혼합 부하 | 주문·QR·할인·결제·주방·출력·리포트·백그라운드 작업을 실제 동시성으로 조합 |
| T08 | 오래 열린 단말·재연결·응답 역전 | 이전 응답 폐기, 요청/타이머 누적 방지, 정확한 최신 상태 복구 |
| T09 | 실제 파일 출력 | 브라우저에서 Excel/PDF 다운로드, 내용·합계 확인; worker와 OS별 출력 구분 |
| T10 | 샘플/삭제/폐쇄·법인 이전 | 전체 리포트 제외 정책, 실제 과거 매출/발행 문서 소유 이력과 권한 유지 |
| T11 | 이전 웹+새 DB / 새 웹+새 DB | 오래 열린 단말에서도 업무 호환, 필요 시 정확한 갱신 안내 |
| T12 | 신규 DB/upgrade DB | 최종 업무 계약·RLS·권한·트리거 구성이 동일한 불변식을 만족 |

### 실행 기준

- 운영과 분리된 fixture DB·계정·스토리지·외부업체 테스트 대체 수단을 사용한다. 새 법인·주문·결제 테스트를 운영에 임의 생성하지 않는다.
- 기존 multi-account integration_test만으로 새 법인·전체 업무를 검증했다고 하지 않는다. 부족한 시나리오는 구현하고 실제 명령을 공식 inventory에 등록한다.
- 테스트 데이터·단말 수·동시 사용자·데이터량·오류 주입 조건·최대 시간·허용 자원을 기록한다.
- source SHA·DB 계약·설정·도구·lockfile·환경·원본 로그·측정값을 같은 증거에 묶는다.
- 기능 단위 PASS, 통합 PASS, 성능 목표 충족, 운영 반영 확인은 각각 구분한다.
- 과거/현재 입력이 다른 테스트 결과는 무조건 합산하지 않는다. 같은 유효 입력에 대한 공식 재사용 규칙만 따른다.

### 기존 검증 명령의 사용 위치

아래는 관련 수정 후 실행할 기존 명령이다. 이 문서 작성 과정에서는 실행하지 않았다. 공식 레시피에 이미 포함된 검사를 별도로 다시 실행하라는 뜻이 아니다.

| 대상 | 명령 | 사용 조건 |
|---|---|---|
| 할인 수량 정확성 | `bash scripts/test_menu_discount_quantities.sh` | U05 변경 중 영향 검증. 최종 통합 완료를 이 결과 하나로 대체하지 않음 |
| 매장 계정 개설 | `bash test/store_account_onboarding_sql_test.sh` | U07 영향 검증. 최초 UI/새 법인 E2E는 추가 구현 필요 |
| 기존 기능/업그레이드 | `bash scripts/test_store_operating_upgrade.sh /absolute/isolated/current-schema.sql` | 실제 provenance가 확인된 schema-only 입력을 격리 DB에서 사용 |
| 배포된 스키마의 생애주기 | `bash scripts/test_store_lifecycle_atomic_release.sh /absolute/isolated/current-schema.sql --deployed-schema` | 현재 배포 스키마용 모드. 적용 전 스키마에는 그에 맞는 스크립트 모드를 사용 |
| 공식 최종 검증/배포 | `scripts/deploy_pos_production.sh`의 현행 절차 | 현재 release-plan·대상·인증 확인 후 공식 entrypoint가 전체 검증 실행 |
| 신규 통합/성능 검사 | T02·T05·T07·T08·T11의 미충족 범위 | 새 명령은 구현 후 등록. 아직 없는 명령을 실행했다고 표시하지 않음 |

## 10. 운영 반영 절차 — 중복 검증을 늘리지 않기

1. **변경 전 준비:** 실제 수정 범위와 영향 기능, 실행 중 긴급 작업, 기존 변경을 확인한다. 공식 환경·설정·인증·배포 대상·DB 이력과 필요한 도구를 먼저 확인한다.
2. **개발 단계:** 변경과 위험에 맞는 테스트/측정을 실행한다. 코드·입력 변경 또는 새로운 실패가 있을 때만 관련 검사를 반복한다.
3. **통합 코드 확정:** 커밋/원격 확인 후 깨끗한 최신 `origin/main == HEAD`에서 릴리스를 준비한다. 사용자 변경을 덮거나 보호 설정을 완화하지 않는다.
4. **공식 검증:** 배포 entrypoint가 `run --kind exact-main --profile production-checks`를 소유한다. standalone 전체 검증을 먼저 강제하고 같은 검증을 entrypoint에서 다시 실행하는 절차를 만들지 않는다.
5. **DB → 웹:** 필요한 변경을 release-plan의 의존 순서로 적용하고 이력을 확인한다. 통합 웹은 운영 설정으로 한 번 빌드/배포한다. 실제 변경 대상 Edge/worker 자산의 버전도 일치시킨다.
6. **증거 재사용:** 현재 구현은 같은 invocation의 온전한 SHA/input-bound 증거를 재사용한다. 다른 실행의 임의 receipt로 대체하지 않는다. 소스·도구·lockfile·recipe 변경이나 증거 손상 시 유효성을 다시 판단한다.
7. **장애/중단 처리:** 마지막 로그·단계 상태·DB 실제 적용/배포 결과부터 확인한다. 결과가 불명확한 쓰기를 재전송하거나 완료된 DB 단계를 처음부터 반복하지 않는다. 현재 스크립트가 지원하지 않는 재개 기능을 있다고 가정하지 않는다.
8. **완료 확인:** 최종 SHA·적용 migration·DB/Edge/웹 계약·배포 URL/ID·자산 동일성·영향 기능·운영 오류/지연을 확인한다. 기존 로그인 스모크 면제는 NOT_RUN으로 기록한다.
9. **결과 보고:** 새 실행/같은 실행 내 재사용/면제/실패/미실행을 분리한다. 단계 시간과 전체 경과 시간을 구분해 불필요한 중복이나 대기를 식별한다.

현재 공식 근거: `CLAUDE.md`, `docs/pos/POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md`, `docs/pos/local-verification/LOCAL_VERIFICATION.md`. 구현 시 최신 본문과 스크립트를 다시 대조한다. 과거 릴리스의 고정 plan 경로를 새 릴리스에 그대로 사용하지 않는다.

## 11. 완료 판정과 결과 기록

각 U 작업은 다음 기록이 있어야 완료로 판정한다.

| 필드 | 기록 내용 |
|---|---|
| 작업/기능 | U ID, 영향받는 기능·RPC·트리거·이벤트·권한·단말 |
| 문제 근거 | 소스 경로/행, 운영 관측 또는 격리 재현, 확정/가설 구분 |
| 수정 | 실제 변경, 유지한 업무 규칙, 필요한 DB/Edge/웹 계약 |
| 동일성 | 최종 SHA, 스키마/설정/lockfile/도구/환경/fixture 식별 |
| 정확성 | 상태 전이·권한/테넌트·금액/수량·중복/응답 유실 결과 |
| 성능 | 호출/이벤트·행/bytes·P95/P99·락/풀·CPU/IO·heap의 전후 값 |
| 적용 | migration 실제 이력, 배포 ID/URL, 자산·앱/DB 버전 일치 |
| 미완료 | 미실행·환경 차이·승인된 면제·남은 가설과 다음 확인 방법 |
| 시간 | 시작/종료/단계 시간, 재사용/외부 대기/오류 복구 포함 전체 경과 |

최종 완료는 코드 존재·개별 테스트 성공·배포 READY 중 하나로 대체하지 않는다. 범위에 필요한 정확성·성능·개설/운영 연결·배포 후 증거를 함께 판단한다.

## 12. 근거 위치와 미실행 사항

### 12.1 소스 근거

아래 링크는 분석 SHA에 고정되어 있다. 이 파일 자체에 판단과 계획을 포함했으며 링크는 추가 확인용이다.


- **F1 매장 없는 최고관리자의 최초 온보딩이 DB 필수 조건을 충족하지 못함** — [lib/core/router/app_router.dart:123](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/core/router/app_router.dart#L123) · [lib/features/onboarding/onboarding_provider.dart:53](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/onboarding/onboarding_provider.dart#L53) · [lib/core/services/store_service.dart:16](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/core/services/store_service.dart#L16) · [supabase/migrations/20260711090000_legal_entity_brand_store_hierarchy.sql:989](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/supabase/migrations/20260711090000_legal_entity_brand_store_hierarchy.sql#L989) · [supabase/migrations/20261022090000_store_registration_areas.sql:189](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/supabase/migrations/20261022090000_store_registration_areas.sql#L189)
- **F2 새 법인의 첫 매장은 기존 매장 자동 연결만으로 해결되지 않음** — [supabase/migrations/20260711090000_legal_entity_brand_store_hierarchy.sql:582](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/supabase/migrations/20260711090000_legal_entity_brand_store_hierarchy.sql#L582) · [lib/features/super_admin/super_admin_provider.dart:553](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/super_admin/super_admin_provider.dart#L553) · [lib/features/super_admin/super_admin_screen.dart:1672](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/super_admin/super_admin_screen.dart#L1672) · [OFFICE:supabase/migrations/20261019105000_verified_pos_store_mapping.sql:9](https://github.com/ahc0403-commits/restaurant_office_app/blob/8b24d58836b6014d62c498c3f17c106b7da398e8/supabase/migrations/20261019105000_verified_pos_store_mapping.sql#L9) · [supabase/migrations/20261022170000_store_operational_acceptance.sql:70](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/supabase/migrations/20261022170000_store_operational_acceptance.sql#L70)
- **F3 DB의 최종 동작이 누적 문자열 수정과 별칭 연결에 의존함** — [supabase/migrations/20261030083942_paperless_bottleneck_diagnostics.sql:7](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/supabase/migrations/20261030083942_paperless_bottleneck_diagnostics.sql#L7) · [supabase/migrations/20261022210000_kds_partial_item_handoff.sql:13](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/supabase/migrations/20261022210000_kds_partial_item_handoff.sql#L13) · [supabase/migrations/20261029084212_attendance_staff_input_recovery.sql:31](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/supabase/migrations/20261029084212_attendance_staff_input_recovery.sql#L31) · [supabase/migrations/20261030083248_menu_discount_quantities.sql:185](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/supabase/migrations/20261030083248_menu_discount_quantities.sql#L185) · [test/store_account_onboarding_sql_test.sh:18](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/test/store_account_onboarding_sql_test.sh#L18)
- **F4 검증 수가 많아도 새 법인부터 업무 종료까지의 연결을 보장하지 못함** — [scripts/check_repo.sh:22](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/scripts/check_repo.sh#L22) · [scripts/check_repo.sh:44](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/scripts/check_repo.sh#L44) · [scripts/local_verification/recipe.json:1](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/scripts/local_verification/recipe.json#L1) · [integration_test/full_multi_account_smoke_test.dart:1](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/integration_test/full_multi_account_smoke_test.dart#L1) · [test/legal_entity_brand_store_hierarchy_contract_test.dart:68](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/test/legal_entity_brand_store_hierarchy_contract_test.dart#L68) · [scripts/tests/data_access/browser/export_probe.dart:1](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/scripts/tests/data_access/browser/export_probe.dart#L1)
- **F5 33개 기능이 앱 진입 코드에 역으로 의존함** — [lib/main.dart:15](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/main.dart#L15) · [lib/main.dart:68](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/main.dart#L68) · [lib/core/services/store_service.dart:3](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/core/services/store_service.dart#L3) · [lib/core/router/app_router.dart:1](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/core/router/app_router.dart#L1)
- **F6 매장 전환과 늦게 도착한 조회 결과를 처리하는 기준이 기능별로 다름** — [lib/features/qc/qc_provider.dart:38](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/qc/qc_provider.dart#L38) · [lib/features/admin/tabs/qc_tab.dart:102](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/admin/tabs/qc_tab.dart#L102) · [lib/features/table/table_provider.dart:70](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/table/table_provider.dart#L70) · [lib/features/store_workflow/workflow_setup_card.dart:32](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/store_workflow/workflow_setup_card.dart#L32) · [lib/features/customer_display/customer_display_provider.dart:236](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/customer_display/customer_display_provider.dart#L236)
- **F7 저장 완료·조회 갱신·오프라인 대기 상태의 표현이 통일되지 않음** — [lib/features/payment/payment_provider.dart:1125](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/payment/payment_provider.dart#L1125) · [lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart:3143](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart#L3143) · [lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart:3052](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart#L3052) · [lib/features/attendance/attendance_kiosk_provider.dart:81](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/attendance/attendance_kiosk_provider.dart#L81) · [lib/features/procurement/procurement_workspace.dart:231](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/procurement/procurement_workspace.dart#L231)
- **F8 갱신·조회·DB 부하·재시도·화면 작업을 함께 통제해야 함** — [lib/features/payment/payment_provider.dart:449](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/payment/payment_provider.dart#L449) · [lib/core/services/live_refresh_service.dart:140](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/core/services/live_refresh_service.dart#L140) · [supabase/migrations/20261030083248_menu_discount_quantities.sql:189](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/supabase/migrations/20261030083248_menu_discount_quantities.sql#L189) · [packages/gotrue/lib/src/gotrue_client.dart:1117](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/packages/gotrue/lib/src/gotrue_client.dart#L1117) · [lib/core/utils/deadline_http_client.dart:7](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/core/utils/deadline_http_client.dart#L7)
- **KDS 읽기·감시** — [lib/features/emergency_fulfillment/kds_realtime_sync.dart:248](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/emergency_fulfillment/kds_realtime_sync.dart#L248)
- **KDS 감시/복구** — [lib/features/emergency_fulfillment/kds_realtime_sync.dart:568](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/emergency_fulfillment/kds_realtime_sync.dart#L568)
- **할인 잔량/이벤트/재계산** — [supabase/migrations/20261030083248_menu_discount_quantities.sql:63](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/supabase/migrations/20261030083248_menu_discount_quantities.sql#L63)
- **QR 메뉴 갱신** — [lib/features/qr_order/qr_order_screen.dart:234](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/qr_order/qr_order_screen.dart#L234)
- **분식 KDS 제한 이력** — [supabase/migrations/20261023060000_bunsik_kds_bounded_history.sql:469](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/supabase/migrations/20261023060000_bunsik_kds_bounded_history.sql#L469)
- **건강 확인 timeout** — [lib/core/services/connectivity_service.dart:232](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/core/services/connectivity_service.dart#L232)
- **화면 타이머** — [lib/features/emergency_fulfillment/emergency_fulfillment_screen.dart:209](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/features/emergency_fulfillment/emergency_fulfillment_screen.dart#L209)
- **갱신 요청 병합** — [lib/core/utils/coalesced_refresh.dart:3](https://github.com/ahc0403-commits/globospossystem/blob/ecd9c26f8003a654b2b29dc1409f9cc298d5b08e/lib/core/utils/coalesced_refresh.dart#L3)

### 12.2 통합에 사용한 기존 산출물

- 야간 조사: `report.html`, `evidence.json`의 운영 집계와 성능 11항목 대조.
- 전체 구조 감사: `full-audit/audit-report-data.json`, `report.md`, `inventory.json`, `architecture-proof.json`, 기능별 점검표.
- 추적 파일/코드 색인, source dependency 및 정적 교차 계약 확인은 기존 감사 증거다. 이 문서 작성에서 제품 테스트를 새로 실행한 것은 아니다.
- 원본 집계의 보조 필터 전체는 당시 세션 도구 호출 기록에 있으며, 집계 JSON만으로 모든 조회를 재현할 수 있다고 주장하지 않는다.

### 12.3 현재 남은 검증

- 운영 CPU/RAM/IOPS·현재 연결/잠금·실행 계획·복제 지연·유효 함수/cron 전체 대조.
- 실제 단말의 네트워크/heap/프레임·매장 회선·8–12시간 및 혼합 부하 전후 측정.
- 신규 법인/첫 매장/전체 업무 E2E, 현재 최종 스키마와 모든 영향 기능의 통합 실행.
- 실제 브라우저 Excel/PDF 다운로드와 기기별 출력/오디오, 이전 웹+새 DB 호환 실행.
- 기존 승인된 운영 로그인 스모크 생략은 유지하며 NOT_RUN.
- 외부 authoritative scope v1.4와 개인 Mac 전역 지침 파일은 앞선 클라우드 조사에서 접근하지 못했다. 현재 프로젝트의 portable 지침과 소스 근거를 사용했다.

### 12.4 기존 두 계획과 통합 작업의 대응

| 기존 계획 | 통합 작업 |
|---|---|
| 야간 P0: 서버 원인 확정/운영 안정화 | U01·U02·U06 |
| 야간 P1: 결제/공통 요청 비용 | U03·U04 |
| 야간 P1: 할인/트리거/조회 | U02·U05 |
| 야간 P2: 장시간 화면 | U10 |
| 야간 P2: 성능 기준 강제 | U01·U11 |
| 전체 기능 계획 1: 영향 목록 | U01·U11 |
| 전체 기능 계획 2: 새 법인/첫 매장 | U07 |
| 전체 기능 계획 3: DB 정본/통합 계약 | U02·U05 |
| 전체 기능 계획 4: 저장/재시도 계약 | U03 |
| 전체 기능 계획 5: 모듈 경계 | U09 |
| 전체 기능 계획 6: 범위/비동기 상태 | U08·U04 |
| 전체 기능 계획 7: 전체 업무 E2E/성능 | U11·U10 |
| 전체 기능 계획 8: 운영 추적 | U01·U06 |
| 전체 기능 계획 9: 배포/이전 단말 호환 | U12 |

**이 파일은 통합 실행 계획이다. 문서 작성만으로 성능 개선·회귀 해결·운영 배포가 완료된 것은 아니다.**


