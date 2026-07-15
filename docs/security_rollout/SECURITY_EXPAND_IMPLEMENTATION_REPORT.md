# Security Expand → Migrate → Contract 구현 보고서

검증 기준일: 2026-07-15
범위: GLOBOSVN POS 소스 구현 및 로컬 검증만 수행

## 결론

| 중요도 | 항목 | 현재 상태 |
|---|---|---|
| CRITICAL | 기존 단일 보안 마이그레이션의 구/신 클라이언트 동시 중단 위험 | 호환 Expand와 별도 Contract 초안으로 분리했고 로컬 SQL 하니스에서 검증함 |
| HIGH | 응답 유실/재시작 후 결제 중복 | 서버 멱등성 장부와 재시작 유지 시도 ID를 구현함 |
| HIGH | 레거시 증빙 큐 파일의 선삭제/권한 범위 이탈 | 업로드와 v2 attach 모두 성공한 뒤에만 전용 큐 파일을 삭제함 |
| HIGH | 로컬 SHA PIN 검증·브루트포스 | bcrypt 서버 검증, 5회/15분 잠금, 성공 초기화, 레거시 업그레이드를 Expand에 추가함 |
| MEDIUM | 신규 `admin` 역할 제출과 강화 Function 계약 불일치 | 생성 UI/공유 유틸/서비스에서 제거하고 기존 `admin` 표시·라우팅은 유지함 |
| MEDIUM | Vercel 배포 후 구 플러터 웹 셰 잔류 | 앱 셰 5개 경로에 재검증 헤더를 추가하고 Flutter 3.41.6 생성 결과의 SW 해제 동작을 검증함 |
| CONFIRMED | 운영 적용 상태 | 운영에는 아무것도 적용하지 않음. 위험 해소 판정은 배포·관찰 후에만 가능함 |

## 확인된 저장소 근거

- 위험한 `20260715020000_remaining_security_hardening.sql`은 추적되지 않은 pending 파일이었고 Git 이력이 없었다. 이 파일만 제거하고 기존 applied 마이그레이션은 수정하지 않았다.
- Expand는 `payment_attempts`에 forced RLS·유니크 인덱스·제한 grant를 두고, 5-인자 `process_payment`를 추가하면서 4-인자 실행 권한을 유지한다 (`supabase/migrations/20260715020000_security_expand_compat.sql:6-75`, `:77-160`).
- v2 증빙 RPC는 활성 사용자, 역할, 매장 접근, 결제-매장 일치, object-path 형식을 서버에서 검사한다. 레거시 RPC는 Expand에서 유지된다 (`supabase/migrations/20260715020000_security_expand_compat.sql:162-265`).
- PIN verifier는 클라이언트 읽기 grant에 포함되지 않고, v2 setter/status/verify와 잠금 장부가 추가됐다. Expand 기간에는 구 클라이언트용 SHA 값과 레거시 RPC를 유지한다 (`supabase/migrations/20260715020000_security_expand_compat.sql:267-322`, `:324-541`).
- Flutter 시도 ID는 사용자·매장·주문·스플릿 순서·수단·금액을 해시한 범위로 저장되고, 7일/500건 상한으로 정리된다 (`lib/core/services/payment_attempt_store.dart:10-38`, `:41-147`). RPC 성공 후에만 정리한다 (`lib/core/services/payment_service.dart:48-93`, `:166-220`).
- 레거시 증빙 큐는 파싱·실존·canonical path·전용 파일명을 검사하며 upload/attach 성공 후에만 삭제한다 (`lib/core/services/payment_proof_service.dart:42-155`). 신규 저장은 v2 object path만 기록한다 (`:225-299`).
- 증빙 열람은 매장 segment를 검증한 후 Supabase Storage JWT/RLS download를 우선하고, 호환 기간에만 제한된 HTTPS Supabase 레거시 URL을 사용한다 (`lib/core/services/payment_proof_service.dart:170-223`, `lib/features/payment/payment_detail_screen.dart:154-278`).
- 신규 직원 생성 역할에 `admin`이 없고 서비스도 허용 목록 밖 역할을 거부한다 (`lib/core/utils/staff_role_utils.dart:94-116`, `lib/core/services/staff_service.dart:3-32`). 기존 `admin`의 표시/조작 호환 분기는 남아 있다 (`lib/core/utils/staff_role_utils.dart:111-143`).
- 현재 Flutter 클라이언트는 PIN v2 RPC만 호출한다 (`lib/core/services/pin_service.dart:3-34`). 상태 미확인/검증 오류 시 근태 접근은 fail-closed다 (`lib/features/admin/tabs/attendance_tab.dart`, `lib/features/admin/tabs/settings_tab.dart`).
- Vercel은 자산 전체가 아닌 앱 셰 5개에만 `must-revalidate`를 적용한다 (`vercel.json:6-26`).
- 배포 하니스는 한 번에 마이그레이션 하나만 받고, Contract를 거부하며, 두 보안 마이그레이션의 전/후 검증 파일을 강제한다 (`scripts/deploy_pos_production.sh:208-218`, `:591-622`, `:647-696`).
- Office 계약인 `restaurants(id, name, address, is_active)`를 변경하지 않았고, 두 settlement Function은 별도로 유지했다. WeTax Function에는 이 작업으로 추가 수정을 하지 않았고, MISA 코드를 생성하지 않았다.

## 가정과 증거 공백

- **가정:** 삭제한 이전 `020000` 파일은 미적용 상태였다. 근거는 untracked 상태와 Git 이력 부재이며, 금지 조건 때문에 운영 migration history는 조회하지 않았다. 운영 적용 전 read-only preflight으로 다시 확인해야 한다.
- **가정:** 로컬 SQL fixture의 기존 4-인자 `process_payment`는 현행 실제 바디의 최소 대역이다. 로컬 통과는 운영 데이터 분포·트래픽·수동 DB 변경을 증명하지 않는다.
- **확인 불가:** 과거 10년 signed URL의 실제 개수, 소유자, object 상태, 운영 RLS/catalog/grant, 전 터미널 버전, 실효 시도 ID 충돌률은 운영 접근 금지로 미검증이다.
- **범위 제외:** Moers 계정 기반 브라우저 수집은 벤더 API 부재에 따른 수용된 제약이며 취약점으로 판정하지 않았다. WeTax와 미구현 MISA도 이 롤아웃에서 제외했다.

## 호환성 행렬

| 클라이언트 | DB 상태 | 결과 | 근거 |
|---|---|---|---|
| 구 클라이언트 | Expand | 호환: 4-인자 결제, 레거시 증빙/PIN grant 유지 | Expand grant 및 로컬 fixture 통과 |
| 신 클라이언트 | Expand | 호환: 5-인자 결제, v2 증빙/PIN | Flutter 테스트 및 로컬 SQL 통과 |
| 신 클라이언트 | Contract 초안 | 호환: 레거시 grant 폐쇄 후 v2 경로 통과 | `test/security_expand_sql_test.sh:88-118` |
| 구 클라이언트 | Contract 초안 | 의도적 비호환 | Contract 전 전 터미널 전환 증거 필수 |

## Expand·Contract 경계와 복구

- Expand는 정상 migration 폴더에 있지만 구/신 계약을 모두 유지한다.
- Contract는 `docs/security_rollout/sql/security_contract_draft.sql:1-49`에 있으며, 명시적 session guard가 없으면 중단된다. 정상 migration 폴더 밖이고 현재 배포 하니스가 거부한다.
- Contract 전 app 문제는 Expand 데이터를 되돌리지 않고 이전 호환 app으로 롤백한다.
- Contract 후 누락된 구 클라이언트가 발견되면 롤아웃을 중지하고 guard된 `security_contract_emergency_regrant.sql:1-36`을 별도 승인 후 적용한다. Expand 신규 데이터는 삭제하지 않는다.

## 검증 결과

- `flutter analyze`: PASS, issue 0
- `flutter test`: PASS, 127 tests
- `flutter build web --release`: PASS; Flutter 3.41.6 생성 service worker의 unregister 계약 확인
- `bash test/flutter_web_cache_contract_test.sh`: PASS
- `npm test` (`scripts`): PASS, 44 tests
- `npm audit --omit=dev --audit-level=low` (`scripts`): PASS, 알려진 취약점 0
- `node scripts/scan_repository_secrets.js`: PASS; 시크릿 값은 출력하지 않음
- 변경된 non-WeTax Edge Functions `deno check`: PASS (`create_staff_user`, `generate-settlement`, `generate_delivery_settlement`)
- `bash test/security_expand_sql_test.sh`: PASS; Audit → Expand → replay → 동시 중복 결제 → Contract → emergency regrant를 일회용 로컬 DB에서 검증
- 배포 스크립트 dry-run/계약 테스트 4종: PASS
- 재시작 ID 100개 동시 호출 일치, 200건 정리; 결제 시도 250건 생성·동일 ID 재실행 후 결제/인보이스 각 250건 유지; PIN rate-limit 장부 250개 충돌 갱신; 증빙 큐 250개 성공 처리·재실행 멱등; 정리 후보 250개를 25개 이하 10배치로 보존하는 계획: PASS

## 과거 signed URL 정리 게이트

`scripts/inventory_legacy_payment_proofs.sql`은 aggregate-only read-only inventory이며 실제 URL/object명을 출력하지 않는다. 변경 모드는 없다. 향후 정리는 다음 순서와 게이트를 만족해야 한다 (`docs/security_rollout/LEGACY_PAYMENT_PROOF_URL_CLEANUP_RUNBOOK.md:5-30`).

1. 1건 canary 후 배치당 최대 25건
2. 신규 호환 object path로 copy
3. 크기/SHA-256 검증
4. DB `proof_object_path` 갱신
5. 해당 tenant 인증 JWT로 다운로드 및 해시 재검증
6. 레거시 URL 값 제거 후 UI 재검증
7. 모든 검증 성공 후에만 구 object 삭제

JWT 전체 회전은 정리 수단으로 사용하지 않는다. 불일치·소실·권한 오류 시 즉시 중지하고, 원본 증빙은 삭제하지 않는다.

## 준비된 배포 순서

1. Security Audit migration 한 개만 적용·검증
2. Expand migration 한 개만 적용·검증
3. 구 클라이언트로 Expand smoke
4. 호환 Flutter 배포
5. 전 터미널 새 세션 갱신 및 전체 영업 주기 1회 관찰
6. 엄격한 `create_staff_user` 배포
7. 별도 릴리스에서 Contract 전제조건 승인 후 적용
8. 다른 운영 작업으로 레거시 증빙 URL/object 정리

상세 중지/복구 순서는 `docs/security_rollout/SECURITY_EXPAND_CONTRACT_RUNBOOK.md:5-25`에 기록했다.

## 실행한 주요 명령

```text
dart format <changed Dart files>
flutter gen-l10n
flutter analyze
flutter test
flutter build web --release <local placeholder defines>
bash test/flutter_web_cache_contract_test.sh
(cd scripts && npm test)
(cd scripts && npm audit --omit=dev --audit-level=low)
node scripts/scan_repository_secrets.js
deno check supabase/functions/create_staff_user/index.ts
deno check supabase/functions/generate-settlement/index.ts
deno check supabase/functions/generate_delivery_settlement/index.ts
bash test/security_expand_sql_test.sh
bash test/pos_deploy_security_rollout_test.sh
bash test/pos_deploy_git_history_guard_test.sh
bash test/pos_deploy_clean_worktree_checks_test.sh
bash test/pos_deploy_psql_runner_test.sh
git diff --check
```

최종 보고서 텍스트 검색 명령의 shell quoting 실수로 repository-wide `deno check`가 추가로 한 번 실행되어 제외 대상 WeTax의 기존 타입 오류 5개를 재현했다. 이 검사는 소스 정적 검사만 수행했으며 파일, Function, 외부 런타임, 운영 상태를 변경하지 않았다. WeTax 파일은 수정하지 않았다.

## 실행하지 않은 검증과 이유

- 운영/연결 Supabase SQL, migration apply, migration history repair: 명시적 금지 범위
- Edge Function/Vercel 배포, 운영 Function 호출, 파일럿 Auth: 명시적 금지 범위
- Storage upload/download/copy/delete와 과거 signed URL 폐기: 명시적 금지 범위이며 증빙 보존 위험으로 별도 운영 승인 필요
- 운영 시크릿·로그·DB catalog 조회: 금지 범위. 발견 값을 출력하지 않음
- 의도적인 WeTax 검증/수정/배포: 사용자 지시로 보존·제외. 단, 위에 기록한 최종 검색 명령 인용 실수로 정적 검사 1회가 실행됐고 기존 오류만 재현됐으며 수정은 없었다.
- MISA 테스트/배포: 미구현 범위로 제외
- 운영 동시성·10× 트래픽/전 터미널 강제 새로고: 배포 전 수행 불가. 대신 로컬에서 저장 100 동시 호출/200 정리, 결제 시도 250건 생성·재실행, PIN 장부 250개, 증빙 큐 250개, 정리 후보 250개/25개 배치를 검증했고 별도로 동일 결제 2건을 실제 동시 호출했다.

## 남은 블로커와 Priority Fix List

1. **CRITICAL / 배포 전:** 운영 migration history 부재, preflight, exact-main, 파일럿 Auth를 독립 검토자가 확인한 후 Audit과 Expand를 각각 별도 호출로 적용한다.
2. **HIGH / Flutter 배포 전:** 구 클라이언트로 4-인자 결제·레거시 증빙·PIN·기존 `admin` 사용·완전 영업 주기를 Expand에서 smoke한다.
3. **HIGH / Contract 전:** 전 터미널의 신 셰 확인과 전체 영업 주기 1회 관찰 증거를 수집한다. 하나라도 구 클라이언트가 남으면 Contract를 하지 않는다.
4. **HIGH / 증빙 정리 전:** read-only inventory를 검토하고 별도 변경 도구, 보호된 manifest/backup, 1건 canary, 배치 한도, 롤백 담당자를 승인한다.
5. **MEDIUM / 운영 관찰:** 결제 attempt mismatch/replay, PIN lockout, 증빙 attach/download, 클라이언트 버전, staff 생성 실패에 대한 텐넌트 범위 알림과 감사 절차를 확인한다.

**이 작업에서 migration 적용, Edge Function 배포, Vercel 배포, 운영 쿼리, Storage 변경, 시크릿 회전, migration history 수정, release-gate PASS 선언은 어느 것도 수행하지 않았다.**
