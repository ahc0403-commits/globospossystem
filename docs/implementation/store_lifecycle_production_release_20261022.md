# 매장 생애주기 운영 배포 기록 (2026-10-22)

사용자 승인: 필수 CI 확인 후 운영 DB 적용·배포 및 분식클럽/전가복 주문·결제·주방 인계·매출 신고·발주 재검증.

- 대상: Supabase `ynriuoomotxuwhuxxmhj`, Vercel `globospossystem`, URL `https://globospossystem.vercel.app`.
- 적용 전 확인: 두 매장 활성, 미결 주문 각 0건. 분식클럽 `kitchen_tray_floor`, 전가복 `kitchen_floor`; `jgbt_tray1` 비활성, `jgbt_floor_1f`→저장 2F, `jgbt_floor_2f`→저장 3F.
- 적용 전 운영에는 `20261021163000` 이후 일반 옵션/다중 주방 기반 12개와 생애주기 23개가 미적용이었다. 이번 배포에서 35개를 적용했다. 이미 적용된 `20261021230000_owner_sales_reporting`은 재적용하지 않았다.
- 35개를 하나의 원자적 배포 묶음으로 적용하는 이유: 의존 함수 교체·가드·입고 원장의 중간 상태를 기존 클라이언트에 노출하지 않기 위함이다. `scripts/build_store_lifecycle_release.py`가 정본을 결합하고 해시를 고정한다. 적용과 component 이력 기록은 같은 transaction이다.
- 기존 매장/동선 설정, 계정·배정, 메뉴 판매 ID/가격/세금/선택, 발행 영수증 본문을 적용 전후 비교한다. 차이는 전체 rollback한다. 기존 매장의 준비/품질/로트 기능을 일괄 강제하거나 새 workflow를 활성화하지 않는다.
- 배포는 공식 `scripts/deploy_pos_production.sh`의 DB-only→web-only 두 단계다. 각각 깨끗한 exact `origin/main` SHA와 `POS release contract` 성공을 요구한다. 검사·계정 검증을 생략하지 않는다.
- 운영 검증은 실제 매출/공급업체 발주를 추가하지 않는 읽기 검증과, 배포된 schema를 복제한 격리 DB의 실제 프로시저 회귀를 함께 사용한다. 외부 신고·실제 지급·공급업체 전송은 실행하지 않는다.

## 적용 전 증거

현재 운영 schema만 export(업무 데이터 없음): `/tmp/globos-lifecycle-production-before-schema-20261022.sql`.
기존 전체 검사: `/tmp/globos-lifecycle-final-check2.log` exit 0; 최신 Flutter 2,495 통과/98 skip.
운영 배포 묶음의 원자적 rollback/실제 적용·component 이력·기존 흐름·결제 parity·주방 인계·신고·품질/입고·보류 로트·폐점·소속 이전 리허설 통과: `/tmp/globos-lifecycle-atomic-rehearsal7.log`. 최종 리허설 `/tmp/globos-lifecycle-atomic-final.log` 및 적용 후 schema 검증 모드 `/tmp/globos-lifecycle-deployed-mode-local3.log`도 통과했다. 최초 리허설의 보존 검증 SQL 컬럼/시그니처 및 로컬 권한·과거 영수증 fixture 누락을 수정하고 전체를 다시 통과했다. CI·SHA·운영 적용·배포·사후 검증 결과는 실행 후 기록한다.

운영 Auth 준비/테스트 데이터 위생 검사: exit 0, `/tmp/globos-lifecycle-auth-preflight.log`. PR: https://github.com/ahc0403-commits/globospossystem/pull/614 .

## 구형 발주 화면 호환성 보완

운영 적용 직전, 기존 `procurement_workspace_page` 호출도 일괄 50행으로 바뀌어 구형 화면에서 51번째 이후 수요 근거가 숨는 경계를 발견했다. 운영 적용 전에 자동 파이프라인을 중지했다(운영 DB 미적용 확인).

새 화면은 `demand_page_size=50`을 명시하고, 해당 요청만 키셋 페이지를 반환한다. 구형 요청은 기존 2,000품목 상한 내 전체 근거를 유지한다. 61품목 fixture에서 구형 61행과 새 화면 50+11행, 중복/누락 없음, 양방향 전환 후 구형 61행 유지를 실제 workspace RPC로 검증했다. 수정된 원자적 bundle 재적용/rollback·기존 흐름 재검증도 통과했다: `/tmp/globos-lifecycle-compat-atomic.log`.

이 보완을 포함한 최종 커밋의 CI와 병합 커밋 CI 성공 후에만 운영 적용한다.

## 운영 적용·배포 완료

작업자: 사용자 승인을 받은 Codex. 아래 시각은 모두 `Asia/Ho_Chi_Minh`(UTC+7), 2026-10-22 기준이다.

- 배포 소스: `54aa5963d61bd4c72c1dcb2aedf3085483387a1c`, freshly fetched `origin/main`과 동일하며 DB·웹 배포 직전 작업 트리가 깨끗했다.
- PR: [전체 구현 #614](https://github.com/ahc0403-commits/globospossystem/pull/614), [구형 발주 클라이언트 호환성 #615](https://github.com/ahc0403-commits/globospossystem/pull/615). 두 PR의 검사와 병합 커밋 검사를 모두 확인했다.
- 정확한 운영 소스 SHA의 CI 4개 성공: [POS release contract](https://github.com/ahc0403-commits/globospossystem/actions/runs/39680396788), [재고·매장 동선](https://github.com/ahc0403-commits/globospossystem/actions/runs/39680396861), [발주 SQL](https://github.com/ahc0403-commits/globospossystem/actions/runs/39680396732), [Windows 빌드](https://github.com/ahc0403-commits/globospossystem/actions/runs/39680396948).
- 05:03 이후 공식 스크립트 DB-only dry-run 및 실제 적용 실행. 분석·회귀검사, 운영 프로젝트, exact-main SHA, 필수 CI 검사 모두 통과했다. 검사 생략 옵션은 사용하지 않았다.
- DB bundle: `20261022200000_store_lifecycle_release`, SHA-256 `767a472ab8d107529a596f662b8e79c35c9f7ea5eb3aa26a79bcdaae2a983c5c`. 35개 component 변경과 component 이력을 하나의 transaction으로 커밋했다. 적용 내 보존 검사 및 별도 사후 검증 모두 성공했다.
- 05:04:47 DB 적용 후 CLI bundle 이력 등록 단계에서 로컬 파일 경로 오류가 발생했다. 아래 복구를 완료한 후에만 웹 배포했다.
- 05:05:48 bundle 이력 등록과 운영 조회 검증 완료. 최종 운영 DB 조회에서도 component 35개와 bundle 이력 모두 존재함을 확인했다.
- 05:07:31 공식 스크립트 web-only 배포 완료. [운영 POS](https://globospossystem.vercel.app) HTTP 200 및 지정 운영 계정 `sp_pos` 로그인·활성 POS profile 조회 성공. 해당 계정은 별도 매장 소속이므로 이를 분식클럽/전가복의 실제 비밀번호 로그인 증거로 해석하지 않는다.
- Vercel deployment `dpl_5M1B7s493wDSot8Pvi47D561DXcU`, [고유 배포 URL](https://globospossystem-eu0zzsjxu-andres-projects-c63d3b09.vercel.app), `READY`, `production`. 운영 alias가 이 배포를 가리키며 metadata `githubCommitSha`가 위 소스 SHA와 일치한다. Vercel connector로도 재확인했다.
- 05:07:39 웹 배포 후 두 매장 운영 조회 재검증 성공. 05:08:53 실제 배포된 운영 schema를 새로 export한 뒤 격리 DB의 실제 프로시저 회귀검증 전체 성공.

### DB 이력 등록 중단과 복구

설치된 Supabase CLI 2.84.2는 `migration repair --status applied`에서 `supabase/migrations/<version>_*.sql`을 요구했다. 이번에 검토한 원자적 bundle은 `scripts/releases/`에 있으므로, SQL 커밋과 사후 검증이 성공한 뒤 이력 등록 단계에서 파일을 찾지 못했다. 이 시점에 웹 배포는 실행하지 않았다.

DB SQL을 재적용하지 않았다. 공식 `deploy_pos_production.sh`의 preflight를 다시 실행해 깨끗한 exact-main·필수 CI·운영 프로젝트를 확인하고, 공식 SQL helper로 커밋된 component와 기존 매장 보존을 재검증했다. 별도 임시 CLI 프로젝트를 공식 `supabase init`/`link`로 같은 운영 프로젝트에 연결하고, 검토된 bundle과 바이트가 동일한 파일을 CLI가 요구하는 경로에 제공했다. 공식 배포 스크립트의 `run` helper로 CLI 이력 등록 단계만 재개했다. 이후 본 프로젝트의 이력 조회에서 bundle 존재를 확인하고 임시 프로젝트를 삭제했다. 연결 임시 파일을 다른 작업 사본에서 복사하거나 migration SQL을 다시 실행하지 않았다.

웹 배포 후 후속 실행기의 `readback` 변수 누락도 수정했다. 제품 코드나 DB의 오류가 아니며 웹을 재배포하지 않고 읽기 검증 단계부터 이어서 완료했다.

### 배포 후 업무 흐름 검증

| 흐름 | 실제 운영 확인 | 배포된 schema의 격리 DB 회귀 |
| --- | --- | --- |
| 주문 | 두 매장 활성·`legacy_operational=true`; 기존 담당 계정 8개의 KDS 설정·snapshot 범위 정상 | 기존 주문 진입·처리, 공유 단층 구역/담당자, pickup/delivery 흐름 통과 |
| 결제 | 지정 운영 계정 로그인/profile 성공; 운영에 검증용 결제를 만들지 않음 | 500행 부분 결제, 이미 소비된 재고의 취소, 1,002개 원장 행, 재시도 및 비동기 전자영수증 작업 통과. 적용 전에는 세금/서비스 요금/할인 20조합의 구·신 결제 결과 동일성도 검증 |
| 주방 인계 | 분식클럽 `kitchen_tray_floor`, 전가복 `kitchen_floor`; 전가복 체커 비활성 및 담당 층 배정 보존 | 기존 분식클럽/전가복 처리·부분 인계, 다중 주방 병렬/조합 주문, pickup/delivery 및 구역별 인계 통과 |
| 매출 신고 | 각 매장의 소속 법인으로 실제 신고 조회 API를 호출해 2행씩 검사; 행별 매장 ID와 법인 접근 범위 확인 | 신고 배치·고정 identity 및 기존 판매 신고 흐름 통과. 소유자 확정과 신고 가능 여부의 분리 유지 |
| 발주 | 구형 근거 조회 전가복 101행·분식클럽 102행 유지; 새 명시적 페이지 호출은 각각 50행 | 구형 61행/신규 50+11행의 중복·누락 없음, 고정 PO 품질 기준, 검사 수량·기한·권한 거부, 재시도, 합격/보류/거절 입고 분리, FEFO·원장 정합성 통과 |

추가로 미결 PO의 폐점 차단, 폐점 후 신규 발주 차단, 소속 이전의 과거 기록 보존·기존 범위 회수·재시도까지 통과했다. 신규 workflow는 두 기존 매장에 자동 게시하지 않았다. `jgbt_floor_1f`→저장 2F, `jgbt_floor_2f`→저장 3F와 `jgbt_tray1` 비활성도 최종 운영 조회에서 확인했다.

검증은 **실제 운영의 읽기·로그인 + 실제 배포 schema를 복제한 격리 DB의 프로시저 실행**이다. 운영에 테스트 주문·결제·PR/PO·신고를 생성하지 않았다. 실제 은행 결제, 외부 MISA 신고·발행, 공급업체 전송, 실물 단말·프린터 출력은 이번 검증 범위에 포함하지 않는다.

### 실행 증거

로컬 전체 Flutter 최종 후보: 2,495 통과 / 기존 skip 98개, exit 0. CI 성공은 위 exact SHA 링크에서 확인할 수 있다. 운영 배포와 사후 검증의 로컬 로그는 다음과 같다(임시 경로이므로 장기 보관본은 아님).

- DB dry-run: `/tmp/globos-lifecycle-production-db-dry-run.log`
- DB 원자적 적용·보존 검사와 최초 CLI 경로 오류: `/tmp/globos-lifecycle-production-db-apply.log`
- 이력 등록 복구·존재 확인·두 매장 조회: `/tmp/globos-lifecycle-production-history-recovery.log`
- 공식 웹 배포·HTTP·로그인: `/tmp/globos-lifecycle-production-web-deploy.log`
- 웹 배포 후 실제 운영 조회: `/tmp/globos-lifecycle-production-post-web-readback.log`
- 운영 schema export: `/tmp/globos-lifecycle-production-after-schema-20261022.sql` (schema만, 업무 데이터 없음)
- 배포된 schema 전체 회귀: `/tmp/globos-lifecycle-production-deployed-schema-regression.log`, 최종 `STORE_LIFECYCLE_DEPLOYED_SCHEMA=PASS`
- Vercel 배포 조회: `/tmp/globos-lifecycle-vercel-after.json`

05:09 최종 상태: 운영 DB 적용·이력 정합성·웹 배포·후속 회귀검증 모두 완료. 확인한 회귀검사에서 기존 두 매장의 기능 단절을 발견하지 않았다. 이 보고서 수정은 배포 후 결과 기록이며, 위 배포 소스 SHA의 제품 코드를 변경하지 않는다.
