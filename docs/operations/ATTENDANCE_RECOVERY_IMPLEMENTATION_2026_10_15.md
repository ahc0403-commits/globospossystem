# 근태 장애 복구 및 재시도 개선 — 2026-10-15

진행 상태: 운영 DB 장애 복구 및 실제 사진 저장 기능 검사 완료(10:05 베트남 시간). 웹 개선 배포 완료 및 운영 확인 완료(10:34 베트남 시간).

10:47 후속 확인: [7개 매장별 검증 보고서](ATTENDANCE_SEVEN_STORE_VERIFICATION_2026_10_15.md). 운영 비기록 검사와 격리 저장 검사는 모두 통과했다. 분식클럽 실제 출근 4건·사진 4개는 정상이며, 포토 6개 매장의 실제 입력은 아직 발생하지 않았다.

## 범위

기존 근태 역할 허용 목록·라우팅·고정 계정 역할·매장 경계를 유지한다. 키친·트레이·층별 계정에 근태 권한을 추가하지 않는다.

## 변경

- DB: 공용 Storage의 `inventory_receipt_statement_objects_write` 정책 한 개를 현재의 공개 승인 래퍼 함수에 다시 연결한다. 기존 발주 승인·버킷 조건을 유지한다.
- 앱: 사진 처리·업로드·서명 링크 오류를 구분하고 촬영 사진과 직원번호를 유지한다. 성공한 업로드를 재사용하며, 응답 유실 시 재전송 대신 저장 결과를 확인한다.
- 포토 근태: 같은 제출 처리를 사용하며, 저장 후 대시보드 갱신 실패가 재입력을 유도하지 않도록 한다.

## 소스 및 검증

- [DB 복구 PR #572](https://github.com/ahc0403-commits/globospossystem/pull/572): main `c2f7c573aa52c6bcc69e88938dd6a56514ca11bc`에 병합.
- [앱 개선 PR #573](https://github.com/ahc0403-commits/globospossystem/pull/573): main `fcd4bf1008842559c9bd6863d84d45fc4ec06cc4`에 병합. [최종 main CI](https://github.com/ahc0403-commits/globospossystem/actions/runs/38675420699) 성공.
- 격리 PostgreSQL: 기존 권한 오류 재현, 복구 후 근태 사진 INSERT 성공, 타 매장·익명 업로드 거부, 기존 발주 승인 제한 보존 확인.
- `dart analyze --fatal-infos`: 통과.
- 제출 재시도·포토 근태·기존 화면 상태 집중 테스트: 통과.
- 모의 HTTP: 서명 링크 생성 실패 뒤에도 사진 업로드 1회, 서명 요청 2회, 저장 RPC 1회 확인.
- 웹 사전 빌드: 통과. 최종 배포 SHA의 빌드·배포 검증은 공식 스크립트로 별도 수행한다.
- 베트남어 오류·재시도 화면 렌더링 확인. 화면 내 실제 직원 데이터는 테스트 fixture다.

![포토 근태 오류 안내와 재시도](evidence/attendance_recovery_20261015/photo_ops_retry_vi.png)

## 운영 보존 기준

배포 전 근태 저장 함수와 ACL 해시:

- `record_employee_attendance(uuid,text,text)`: `63a7b06001c180e51a17c0d357a3def5`
- `record_employee_attendance_with_photo(uuid,text,text,text)`: `f6330765dd05c34de74a1dac4fcc68ae`
- 고정 계정 코드·역할·활성 상태 집계 해시: `35766a745a53cd1c1ab3ff5d7b694a5d`
- 대상 외 Storage 정책 표현식 집계 해시: `c756b2f85ad69c911072d40ed0414ddd`

## 운영 적용 결과

- 2026-10-15 10:05 Asia/Ho_Chi_Minh 검증: DB 복구 완료.
- main `c2f7c573aa52c6bcc69e88938dd6a56514ca11bc`의 [필수 릴리스 CI](https://github.com/ahc0403-commits/globospossystem/actions/runs/38672416940) 성공 후 공식 `scripts/deploy_pos_production.sh --db-only` 경로로 적용했다.
- 마이그레이션 `20261015023000`의 적용 전 검사·정책 변경·의존성 검증·원격 이력 반영과 확인이 모두 완료됐다.
- 기존 캐셔 계정으로 운영 Storage API 업로드 200(389.1ms), 서명 링크 생성 200(615.1ms)을 확인했다. 1픽셀 진단용 사진을 사용했고 검사 후 삭제했다. 실제 근태 행은 만들지 않았다.
- 기존에 실패하던 인증 역할의 비실행 INSERT 실행계획 검사도 성공했다.
- 위 근태 함수와 ACL, 고정 계정 역할, 대상 외 Storage 정책의 해시가 모두 변경 전과 일치했다.
- 근태 관련 공용 번역 파일은 기존 상태로 보존한다. 신규 문구는 근태 기능 내부에서 한국어·베트남어·영어로 제공한다. 기존 알림 보존 검사를 포함한 집중 테스트 38개가 통과했다.
- 앱 개선 배포: 2026-10-15 10:34 Asia/Ho_Chi_Minh 확인 완료. 최종 main SHA `fcd4bf1008842559c9bd6863d84d45fc4ec06cc4`의 CI 성공 후 공식 스크립트 `--web-only`로 배포했다.
- [운영 POS](https://globospossystem.vercel.app): HTTP 200, Vercel production READY, 기존 고정 계정 로그인 검사 성공.
- 배포 ID: `dpl_DtiFh94m2X7mS6m8mDeYNTZcXWAq`.
- 최종 웹 빌드 완료와 배포 출처 SHA를 확인했다. 운영 제공 JS와 로컬 최종 빌드의 SHA-256 일치 결과는 별도 증거 파일에 기록한다.
- 10:34 운영 재확인에서도 근태 함수·ACL과 고정 계정 역할 해시가 변경 전과 일치했다. 분식클럽 사진 포함 근태 4건은 유지되고, 포토 6개 매장은 복구 후 신규 입력이 없어 매장별 업무 입력 성공은 아직 미관측이다.
2026-10-15 10:06 확인: 분식클럽에 복구 후 사진 포함 근태 4건이 저장됐고 실제 저장 RPC의 HTTP 200 응답을 관측했다. 포토 6개 매장에서는 이 시점까지 복구 후 신규 입력이 없어 매장별 실제 입력 성공은 미검증이다.

저장 응답 유실 후 확인 조회는 기존 조회 권한과 최근 10건 범위를 사용한다. 확인할 수 없으면 관리자 확인을 안내하고 재저장을 자동 실행하지 않는다.

DB 배포 실행자: 이 요청의 Codex 에이전트. 민감한 환경 변수 값은 기록하지 않았다.

```bash
ENV_FILE=<secure-production-env> \
TEST_TARGETS="test/attendance_daily_guard_contract_test.dart test/attendance_kiosk_contract_test.dart test/role_routes_contract_test.dart test/router_role_guard_test.dart" \
CONFIRM_PRODUCTION_DEPLOY=DEPLOY_GLOBOS_PROD \
bash scripts/deploy_pos_production.sh \
  --migration supabase/migrations/20261015023000_attendance_storage_policy_rebind.sql \
  --db-only --yes
```

같은 인자로 `--dry-run`을 먼저 실행하고 적용했다.

장애 중 누락된 근태는 자동 생성하지 않았다. 실제 출퇴근 시각을 확인한 뒤 기존 관리자 수동 근태 절차로 보완할 별도 운영 항목이다.
