# 확장성 변경 후 회귀 수정

작업일: 2026-09-05. 기준 소스: `afb8d8c9e17a95634340ffe7c55ec262563d2a75`.
작업 브랜치: `codex/scalability-regression-audit`.

사용자 지시: 확인된 회귀를 개선하되 **배포 금지**. 원본 작업 디렉터리를 보존하고
`/Users/andreahn/.codex/worktrees/pos-scalability-regression`에서 작업했다.
Git push, PR 생성/병합, Vercel 배포, 운영 DB 변경은 수행하지 않았다.

## 수정 내용

| 심각도 | 재현된 문제 | 수정 | 회귀 방지 검증 |
| --- | --- | --- | --- |
| HIGH | 같은 금액인 메뉴로 프로모션 대상을 바꾸면 계산대 갱신 이벤트가 없음 | 실제 할인 배분 변경도 부모 `order_discounts`를 한 번 갱신해 기존 주문 이벤트 트리거를 사용 | 실제 관리자 RPC, 이벤트 1회, 다른 주문/매장 보존, 동일 저장·20회 동기화 쓰기 0회, 실패 시 이벤트까지 롤백 |
| HIGH | 초기 기준점 조회 중 다른 이벤트와 병합된 배달 주문 INSERT 알림이 누락 | 병합 전의 domain/table/operation 조합을 보존하고 신규 주문 여부 검사에 사용 | 일반 주문 및 fallback과 병합된 INSERT 알림 1회, 후속 polling 중복 없음, UPDATE를 신규 주문으로 오인하지 않음 |
| MEDIUM | 주문·결제 병합 이벤트가 근태 화면을 다시 만들어 입력 상태가 초기화 | 관리자 탭 revision에 실제 영향 domain만 반영 | 실제 AdminScreen/AttendanceTab State 유지, 관련 근태 이벤트 및 명시적 전체 재동기화는 반영 |
| MEDIUM | 결제와 병합된 입금 INSERT가 즉시 알림을 실행하지 않음 | 보존된 원래 SePay INSERT를 인식해 기존 cursor 기반 drain 호출 | 단독·병합·fallback 병합 모두 polling 전에 알림, 이후에도 총 1회 |

### 이벤트 처리

`lib/core/services/live_refresh_service.dart`의 `PosLiveEvent.merge`가 원래 변경 종류를
중복 없는 tuple 집합으로 보존한다. domain/source/type을 독립 집합으로 합치지 않으므로
서로 다른 이벤트의 속성을 조합한 가짜 INSERT가 만들어지지 않는다.
행 내용이나 주문 ID를 저장하지 않으며 기존 350ms 병합 구간과 조회 경로를 유지한다.
단독 fallback 자체는 INSERT로 취급하지 않고, 실제 INSERT와 병합되면 그 INSERT는 보존한다.

소비자 수정 파일:

- `lib/features/direct_order/direct_order_arrival_alert_host.dart`
- `lib/core/services/bank_transfer_alert_coordinator.dart`
- `lib/features/admin/admin_screen.dart`

### 할인 SQL

새 마이그레이션은 `supabase/migrations/20260905090000_promotion_allocation_live_refresh.sql`이다.
이미 적용된 `20260905030000` 파일은 수정하지 않았다. 기존 함수와의 실행 논리 차이는
부모 UPDATE 조건에 실제 배분 변경을 포함하는 것이다. 주문 ID 조건은 OR 식 바깥에 유지했다.
VAT 계산·배분·권한·결제 함수는 변경하지 않았다. 동일 동기화는 기존 조기 반환으로 쓰기 0회를 유지한다.

사전/사후 점검 SQL도 준비했다:

- `scripts/preflight_promotion_allocation_live_refresh.sql`: 기존 부모 이벤트 트리거의 테이블, 동작 종류, 함수, domain 인수 확인
- `scripts/verify_promotion_allocation_live_refresh.sql`: 함수, 멱등성 조건, 권한 확인

이 파일들은 향후 별도 배포 요청 시 지정 운영 배포 절차로 검토·적용할 대상이며, **현재 운영 DB에는 적용하지 않았다**.

## 검증

`bash scripts/check_repo.sh`가 종료 코드 0으로 완료됐다. 아래 결과는 로컬 수정 파일 기준이며 GitHub 릴리스 게이트 결과가 아니다.

| 검증 | 결과 |
| --- | --- |
| 변경부 집중 Flutter 테스트 | 23개 통과 |
| 정적 분석 | 문제 없음 |
| 전체 Flutter 테스트 | 1,326개 통과, 일반 실행에서 94개 skip 표기 |
| 실제 PostgreSQL/PostgREST 급여 테스트 | 별도 격리 환경에서 19개 통과 |
| 실제 PostgreSQL/PostgREST 금융·시급·보고서 테스트 | 별도 격리 환경에서 73개 통과 |
| 프로모션 SQL | 기존 회귀 + 새 배분 이벤트 회귀 + 24가지 기존 계산 대조 + 마이그레이션 재적용 + 실제 동시 row lock 검증 통과 |
| 인덱스 격리 검증 | 통과 |
| Edge Function / Node 계약·보안 검사 | 통과 |
| 배포 스크립트의 로컬 fixture 검사 / Photo Objet SQL | 통과 (실제 배포 실행 아님) |
| Flutter 웹 release 빌드 | 성공 (`build/web`) |
| 변경 Dart 포맷 / diff 공백 검사 | 통과 |

일반 Flutter 실행에서 skip한 DB/API 92건은 위의 전용 컨테이너 검사에서 모두 실행해 통과했다.
나머지 2건은 미검증이다: Windows 전용 native exit 검사와 Office 교차 저장소 정적 계약 검사.
Office 검사는 해당 체크아웃에 `supabase/migrations/472_pos_sales_event_import_and_bucket_posting.sql`이 없어 건너뛰었다.
이 문제를 숨기기 위해 테스트를 제거하거나 skip 조건을 변경하지 않았다.
웹 빌드는 성공했으나 Cupertino 아이콘 폰트 관련 경고가 기록됐다. 이번 작업에서 폰트 구성을 변경하지 않았다.

증거:

- [집중 테스트 로그](/Users/andreahn/.codex/artifacts/pos-scalability-20260905/regression-fix-logs/focused.log)
- [독립 프로모션 SQL 로그](/Users/andreahn/.codex/artifacts/pos-scalability-20260905/regression-fix-logs/promotion.log)
- [전체 검사 로그](/Users/andreahn/.codex/artifacts/pos-scalability-20260905/regression-fix-logs/check-repo.log)
- 기존 실패 증거는 `/Users/andreahn/.codex/artifacts/pos-scalability-20260905/regression-logs/`에 그대로 보존했다.

## 검증 한계와 적용 상태

| 구분 | 상태 |
| --- | --- |
| 소스 수정 | 로컬 작업 브랜치에서 구현 |
| 새 마이그레이션 | 폐기 가능한 테스트 DB에만 적용·재적용 |
| 운영 DB | 이번 수정 미적용 |
| 웹/단말 배포 | 미실행 |
| GitHub exact-head CI / 릴리스 게이트 | 미실행, PASS로 판정하지 않음 |
| 운영 현장 검증 | 미실행 |

실제 매장의 결제·취소·환불·급여 확정·프린터 출력·MISA 발행을 실행한 결과가 아니다.
특히 프로모션 테스트의 결제 하부는 settlement spy이므로 실제 결제 엔진 종단 검증으로 해석하지 않는다.
운영에 이미 존재하는 할인 갱신 결함은 이 로컬 수정만으로 해결된 상태가 아니다.
추후 배포가 허용되면 필요한 CI와 배포 절차, 해당 화면의 실제 알림·갱신 확인을 별도로 수행해야 한다.
