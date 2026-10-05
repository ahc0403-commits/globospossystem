# Deliberry 사용 종료 구현

작성: 2026-10-05. 아래 상태 표는 최초 구현 검증 시점의 기록이다. 이후 운영 릴리스 증거는 별도 배포 보고서로 관리한다. 사용자의 “삭제하든지 닫던지 해라. 안쓴다.” 결정에 따라 신규 처리를 닫고 과거 기록은 보존한다.

| 상태 | 결과 |
|---|---|
| 소스 구현 | 완료 |
| 로컬·격리 검증 | 통과 |
| 운영 migration 적용 | 미실행 |
| 운영 Edge·앱 배포 | 미실행 |
| 운영 종료 확인 | 미실행 |

## 닫은 경로

- 관리자 화면의 Deliberry 정산 메뉴를 모든 역할에서 숨긴다. 기존 화면을 직접 열어도 한국어·영어·베트남어 종료 안내만 표시하며 DB를 호출하지 않는다. provider 직접 호출도 DB 접근 전에 종료한다.
- `deliberry-webhook`, `deliberry-dispatcher`, `generate-settlement`, `generate_delivery_settlement`를 HTTP 410 / `DELIBERRY_INTEGRATION_RETIRED` 응답으로 교체한다. DB, 외부 배달 API, credential, 요청 body를 읽지 않는다. 구독자나 오래된 스케줄이 같은 URL을 호출해도 신규 처리는 발생하지 않는다.
- 두 정산 함수 모두 기존 코드에서 Deliberry 정산을 생성하므로 함께 닫는다. 일반 POS 결제와 MISA 인보이스 흐름은 이 대상에 포함되지 않는다.
- DB migration `20261005050000_deliberry_retirement.sql`은 전용 원장 네 테이블의 쓰기 권한을 회수하고 쓰기·TRUNCATE trigger를 항상 활성화한다. 공용 `external_sales`는 Deliberry 행만 보호한다. 기존 수신·승인·거절·준비·재시도·재처리·입금 확인 RPC 실행 권한도 회수한다.
- migration은 `cron.job`의 이름/명령에서 Deliberry 및 두 정산 endpoint를 찾고 해당 job만 해제한다. pg_cron과 선택적인 operational 테이블이 없는 환경도 지원한다.
- 배포 스크립트에 네 endpoint의 교체 배포와 무인증 HTTP 410 확인을 추가했다. 다른 응답이나 네트워크 실패는 배포 검증 실패로 처리한다.

## 보존 범위

과거 `external_sales`, `delivery_settlements`, `delivery_settlement_items`, `deliberry_operational_orders`, `deliberry_operational_order_events` 행을 삭제하거나 수정하지 않는다. 기존 SELECT/RLS, 조회·대사 RPC, 모델 및 Office의 과거 매출 조회 계약을 보존한다. Deliberry 기록은 읽기 전용이 되므로 과거 정산의 입금 확인 같은 변경도 닫힌다.

Direct Order의 배달/포장, Grab·BE 등 배달 링크, 인원수, 기존 주문 접근, POS 결제·매출, MISA, 다른 provider의 공용 매출 기록을 계속 사용한다. 사용 종료는 Deliberry 연동에 한정한다.

전체 N+1 계획의 F08/F09는 성능 개선에서 제외하고 종료 검증 W07로 바꿨다. 과거 감사 결과는 감사 당시의 근거로 남겼다.

## 검증 증거

| 검사 | 결과 |
|---|---|
| 변경 Dart 정적 분석 | 오류 없음 |
| 관련 Flutter 회귀 8개 파일 | 39 통과, 1 건너뜀 |
| Edge 응답·body 미접근 테스트 | 6 통과 |
| Edge format/lint, 변경 shell 문법 | 통과 |
| PostgreSQL 15 격리 SQL 실행 | `DELIBERRY_RETIREMENT_SQL_TEST=PASS` |
| 기존 migration gate·clean checkout 배포 계약 | 통과 |
| HTTP 410 배포 검증 계약 | 통과 |

SQL 시험은 실제 기존 settlement/D1 migration을 실행한 fixture에 적용했다. 다섯 테이블의 기존 JSON 원장 동등성, 소유자/service_role의 쓰기 차단, authenticated 이력 읽기, RPC 차단, replication 역할 차단, cron 선택 해제, 다른 provider의 쓰기, 정상 POS 주문·결제, 재적용 및 선택적 schema 부재를 확인했다. pg_cron 실행 자체는 격리 fixture로 재현한 것으로 운영 cron 상태를 확인한 증거는 아니다.

Flutter의 건너뛴 1건은 외부 Office 저장소가 없어 수행하지 못한 교차 저장소 정적 계약 검사다. Office 앱은 수정하지 않았다. 전체 `check_repo.sh`, release web build와 정확한 pushed SHA의 GitHub Actions release gate는 이번 로컬 검증에서 실행하지 않았다.

기존 cron credential 검사에서 두 정산 handler가 환경 변수를 읽도록 강제하던 실패를 재현하고, 종료 후에는 credential을 읽지 않는 계약으로 수정해 6개 검사를 통과했다.

재현:

```bash
bash test/deliberry_retirement_sql_test.sh
deno test --no-config supabase/functions/_shared/retired_deliberry_test.ts
bash test/deliberry_retirement_deploy_contract_test.sh
bash test/pos_deploy_clean_worktree_checks_test.sh
```

## 운영 반영 조건

현재 checkout에는 사용자 소유의 여러 미커밋/미추적 작업이 함께 있다. [CLAUDE.md](/Users/andreahn/globos_pos_system/CLAUDE.md)의 clean release checkout 및 정확한 pushed HEAD의 `POS release contract` 조건을 충족하지 않았으므로 운영 배포를 실행하지 않았다.

릴리스 시 변경 범위와 선행 migration을 확정하고 정확한 SHA의 필수 CI를 통과한 뒤 `scripts/deploy_pos_production.sh`로 네 endpoint, `--migration supabase/migrations/20261005050000_deliberry_retirement.sql`, 앱을 반영한다. 스크립트가 preflight와 `verify_deliberry_retirement.sql`을 실행하고, 네 endpoint가 HTTP 410인지 확인한다. 이후 운영 원장 보존, 대상 cron 해제, 메뉴 제거를 확인해야 운영 종료 완료로 판정한다.

종료 결정에 역행하는 자동 재활성화 rollback은 제공하지 않는다. 재개하려면 새 명시적 사용자 결정과 별도 migration이 필요하다. 예기치 않은 영향은 과거 기록을 보존하는 수정 migration으로 해결한다.
