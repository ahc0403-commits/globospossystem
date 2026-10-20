# 발주 흐름 통일과 기존 변경 보존 — 2026-10-20 최종 검증

최종 운영 소스는 `96f130abdd566f3f1a551a90e76404ab4558f112`이다. 첫 배포의 추가 검사에서 발견한 재고 화면 종료 오류는 롤백 후 수정·재배포했다. 비밀번호를 변경하지 않고 전체 36개 ID의 실제 인증을 다시 시도했으며, 실제 업무 화면의 확인 결과와 접근 제한은 아래에 구분했다.

시간 표시는 베트남 ICT(UTC+7) 기준이다. CI 원문과 기계 증거의 UTC 표기는 보존한다.

## 검증한 기존 변경 보존

- 로컬 보존 브랜치: `codex/review-existing-pos-work-20261019`
- 소스 보존 커밋: `2582f59405a42c48f0f337b796d4b19e3b9cf0d1`
- 검토한 소스·설정·테스트·필수 문서 608개를 명시적 NUL 경로 목록으로 스테이징했다. 스테이징 및 커밋의 파일 집합과 각 파일 SHA-256을 대조했다. `git add .`는 사용하지 않았다.
- 전체 검증: Node 22.23.3에서 `bash scripts/check_repo.sh` 종료 코드 0. Dart fatal-info 분석, Flutter 2,213개 통과/97개 기존 환경 조건부 건너뜀, SQL/API/Edge/성능/Node/보안 검사, 웹 릴리스 빌드 통과. 스크립트의 추가 집중 테스트도 통과했다.
- 새로 추가하는 파일까지 스테이징 후 공백 검사를 수행해 fixture/check 파일 2개의 공백만 정리했다. 셸 문법 검사와 스테이징 공백 검사를 재통과했다.
- Git bundle도 별도 생성·검증했다: `validated-source-2582f594.bundle` (기준 커밋 `cc4de81adb8870fd479cb12edd773cda635a01cd` 필요).
- 기존 작업의 기준 커밋은 9월 17일 코드다. 현재 main의 후속 수정을 되돌리지 않도록 이 보존 커밋은 운영 브랜치에 push/merge하지 않았다.
- 커밋 뒤 운영 문서·내보내기 파일·테스트 산출물 등 673개 파일을 미커밋 상태로 보존했다. 테스트하지 않은 운영 데이터 정정 SQL도 제외했다.
- 비공개 백업: `/Users/andreahn/.codex/backups/globos-pos-reviewed-20261019/`. 보존 자료 675개를 manifest와 SHA-256으로 검증했다. 테스트 재생성 산출물도 별도 압축 보관했고, 소스 외 파일은 검증된 보존 백업과 일치한다. 최초 조사 이후 재생성된 PDF/실패 이미지의 해시는 별도 기록에 명시했다. 기존 파일을 삭제하지 않았다.

## 실제 확인한 차이와 수정

1. 전가복에는 분식클럽 BT와 같은 발주 정책이 없었다. PR [#593](https://github.com/ahc0403-commits/globospossystem/pull/593)에서 정책 8개 항목을 통일하고, 기존 전가복 검수 담당자에게 누락된 검수 확정 단계만 추가했다. 기존 매장·역할 범위, 재고, 과거 문서는 보존했다.
2. 실제 관리자 로그인 후 전가복 관리 화면에서 **발주·승인·입고**로 이동하면, 선택한 전가복 매장이 유실되고 관리자 기본 매장인 분식클럽 BT 결재함이 표시됐다. PR [#595](https://github.com/ahc0403-commits/globospossystem/pull/595)의 `535f8a5c735c15ef23b0455b28977ed72dc08d0c`에서 목록·입고 상세 링크에 선택 매장을 전달하고 발주 화면의 조회·실시간 갱신·상세 복귀에 유지하도록 수정했다.
3. 이어서 기존 발주 화면의 **재고 관리** 복귀 버튼도 선택 매장을 버려 총관리자 첫 화면으로 돌아가는 문제를 실제 브라우저에서 재현했다. PR [#596](https://github.com/ahc0403-commits/globospossystem/pull/596)의 `37fd10e473974f888d0aaf0615bde7d6b95a7159`에서 총관리자의 유효한 매장별 재고 경로로 돌아가도록 수정했다.
4. 추가 계정 전환에서 재고 화면 종료 후 provider 접근 오류를 발견했다. PR [#597](https://github.com/ahc0403-commits/globospossystem/pull/597)에서 화면 종료·매장 또는 탭 변경 뒤의 오래된 비동기 후속 조회를 중단하도록 수정했다.
5. 일반 발주·회계 계정은 URL의 매장 지정으로 권한이 넓어지지 않는다. 관리자에게도 서버의 기존 매장 권한 검사가 적용되며, 접근 거부 시 기본 매장 자료로 대체하지 않는다. 쿼리 수를 늘리는 별도 조회는 추가하지 않았다.

같은 역할끼리 화면·정책·권한을 비교했다. 요청자·점장·검수자·회계의 서로 다른 업무 화면은 유지한다. 매장별 PR/PO 개수, 품목, 공급업체, 재고가 서로 다른 것은 정상 데이터 차이다.

## 검증 범위와 실제 로그인 결과

최종 전수 인증 시각은 **2026-10-20 08:29:43 ICT**다. 최종 웹 배포와 운영 도메인 전환 완료 뒤 다시 검사한 결과를 아래에 기재한다. 운영의 활성 매장은 분식클럽 BT·SAMPLE·전가복 BT 3개이며, 활성 프로필 **36개**(분식클럽 BT 15개·SAMPLE 8개, 전가복 13개)는 모두 고정 네이티브 ID다. 별도 Auth 연결 일반 프로필의 누락은 0개다. 배포 후 재조회에서도 계정 목록·역할·매장·초기 비밀번호 변경 플래그는 동일했다.

- 전수 API 검사는 회차별 동시성 1, 계정당 1회로 수행했다. 기존 공통 자격증명과 사용자가 지정한 관리자·BM의 별도 기존 자격증명을 사용했다. 브라우저 확인과 명시적인 재확인은 별도로 수행했으며 다른 비밀번호를 추측하지 않았다.
- **34/36개**에서 실제 비밀번호 Auth 인증과 로그인 사용자 프로필 검증이 통과했다.
- 발주 관련 **13/13개** 모두 실제 로그인 토큰으로 매장 접근·catalog/capability RPC 검증이 통과했다. 회계는 전용 접근·최종 검증 capability를 확인했다.
- 발주 ID별 인증·프로필·권한 RPC를 포함한 클라이언트 검사 시간은 1,234.6–1,812.6ms(중앙값 1,534.6ms), catalog 응답은 5,615–88,194bytes였다. 계정별 직렬 검증의 관측값이며 DB 실행 계획이나 성능 개선 수치로 해석하지 않는다.
- 발주 관련 13개 ID 모두 브라우저에서 새 로그인했다. **10개는 실제 발주·입고·결재 화면에 진입**했고, 3개는 아래의 초기 변경 화면에서 제한됐다.
- 비발주 역할 중 인증된 21개는 실제 토큰으로 발주 접근이 허용되지 않음을 확인했다. 프린트·주방 등 업무 화면을 열어 출력이나 주문 처리를 발생시키지 않았다.
- **`bt_tab1`, `bt_print`**는 지정된 기존 공통 자격증명으로 배포 전후 모두 Auth HTTP 400 `invalid_credentials`를 반환했다. 활성 프로필·확정된 이메일·미차단 상태는 정상이다. 유효한 기존 자격증명을 확인하기 전에는 두 계정의 로그인 성공으로 판정할 수 없다.
- `bunsik_bm1`은 공통 자격증명으로 최초 검사 시 실패했지만, 지정된 BM 별도 기존 자격증명으로 **최종 Auth·RPC·실제 브라우저 화면이 모두 통과**했다. 앞선 브라우저 검사의 입력값 갱신 문제로 남았던 실패 기록은 정정했다.
- **`jgbt_order`, `sp_order`, `sp_pr1`**은 실제 인증과 발주 RPC가 통과했으나, 브라우저에서 최초 비밀번호 변경 필수 화면이 표시됐다. 새 비밀번호를 입력하거나 초기 변경 플래그를 해제하지 않았다. 이 3개의 실제 발주 업무 화면은 미확인 상태다. 비발주 계정 `jgbt_floor_3f`에도 같은 초기 변경 플래그가 있으나 해당 업무 UI는 열지 않았다.

### 발주 관련 13개 ID

| ID | 업무 | 실제 인증·RPC | 브라우저 결과 |
|---|---|---|---|
| `andre` | 총관리자 | 통과 | PR 결재함 및 전가복 관리·재고·발주 왕복 이동 통과 |
| `account` | 회계 | 통과 | 원재료 발주·입고 |
| `bt_order` | BT 검수 | 통과 | 원재료 입고 관리 |
| `bt_pr1` | BT 요청자 | 통과 | 구매요청 관리·작성 창 |
| `bunsik_sm1` | BT 점장 | 통과 | PR 결재함 |
| `bunsik_sm2` | SAMPLE 점장 | 통과 | PR 결재함 |
| `bunsik_bm1` | 분식클럽 BM | 통과 | 원재료 발주·입고 |
| `sp_order` | SAMPLE 검수 | 통과 | 최초 비밀번호 변경 필수, 발주 화면 미진입 |
| `sp_pr1` | SAMPLE 요청자 | 통과 | 최초 비밀번호 변경 필수, 발주 화면 미진입 |
| `jg_bm1` | 전가복 BM | 통과 | 원재료 발주·입고 |
| `jgbt_order` | 전가복 검수 | 통과 | 최초 비밀번호 변경 필수, 발주 화면 미진입 |
| `jgbt_pr1` | 전가복 요청자 | 통과 | 구매요청 관리·작성 창 |
| `jgbt_sm1` | 전가복 점장 | 통과 | PR 결재함 |

### 같은 역할 간 비교

| 비교 | DB Auth 문맥 정책·capability | 실제 비밀번호 토큰 비교 | 실제 브라우저 비교 |
|---|---|---|---|
| `jgbt_order` / `bt_order` | 동일 | 동일 | 전가복 초기 비밀번호 변경 화면으로 제한 |
| `jgbt_pr1` / `bt_pr1` | 동일 | 동일 | 화면·필터·작성 버튼·입력 창 동일 |
| `jgbt_sm1` / `bunsik_sm1` | 동일 | 동일 | 결재함·필터·업무 버튼 동일 |
| `jg_bm1` / `bunsik_bm1` | 동일 | 동일 | 발주·입고 화면 구성·배치 동일 |
| `sp_order` / `bt_order` | 동일 | 동일 | SAMPLE 초기 비밀번호 변경 화면으로 제한 |
| `sp_pr1` / `bt_pr1` | 동일 | 동일 | SAMPLE 초기 비밀번호 변경 화면으로 제한 |
| `bunsik_sm2` / `bunsik_sm1` | 동일 | 동일 | 결재함·필터·업무 버튼 동일 |

DB Auth ID 문맥 13개 검사는 비밀번호 로그인과 구분한다. 정책 누락 0개, 역할별 7쌍 차이 0개다. 최종 실제 로그인 토큰으로도 **7쌍 모두 정책 8개 항목과 capability가 동일**했다. 브라우저에서는 요청자 1쌍·점장 2쌍·BM 1쌍의 제목·필터·업무 버튼 구성을 데이터 건수와 문서 내용을 제외하고 대조했다. 접근성 노드의 생성 순서와 화면 배치를 구분해 스크린샷도 확인했다.

두 브랜드의 요청자로 운영 구매요청 작성 창을 각각 열어 구매 유형·사유·필요일·품목·수량·단위·비고·추가/삭제·취소/저장 구성을 비교했다. 접근성 입력 항목과 스크린샷 배치가 동일했고, 저장하지 않고 취소했다. 검수·회계 화면은 최근 갱신 시각과 실제 입고 대상 목록이 나타날 때까지 확인했다. PR/PO·재고·출력·승인 데이터는 변경하지 않았다.

운영 관리자로 전가복 관리 → 재고 → 발주 → 기존 발주 → 재고 관리의 전체 왕복 경로를 확인했다. 발주 URL의 `storeId`와 복귀한 전가복 이름·재고 탭이 유지됐다. 빠른 왕복 3회 모두 선택 매장을 유지했고, 재고 화면에서 로그아웃한 뒤 다른 계정의 기존 비밀번호로 재로그인하는 경로도 통과했다. 각 화면은 목록 본문과 필터가 실제로 로딩된 상태를 확인했다. 최종 운영 세션의 브라우저 경고·오류는 0개다.

### 전체 36개 인증 목록

| 매장 | ID | 역할 | 실제 인증 | 발주 확인 |
|---|---|---|---|---|
| BunsikClub Binh Thanh | `bunsik_bm1` | `brand_admin` | 통과 | RPC 통과 |
| BunsikClub Binh Thanh | `bt_pos1` | `cashier` | 통과 | 접근 불가 확인 |
| BunsikClub Binh Thanh | `bt_tab1` | `cashier` | HTTP 400 | 인증 실패로 미확인 |
| BunsikClub Binh Thanh | `bt_customer` | `customer_display` | 통과 | 접근 불가 확인 |
| BunsikClub Binh Thanh | `bt_1f` | `emergency_station` | 통과 | 접근 불가 확인 |
| BunsikClub Binh Thanh | `bt_2f` | `emergency_station` | 통과 | 접근 불가 확인 |
| BunsikClub Binh Thanh | `bt_tray` | `emergency_station` | 통과 | 접근 불가 확인 |
| BunsikClub Binh Thanh | `account` | `inventory_accounting` | 통과 | RPC 통과 |
| BunsikClub Binh Thanh | `bt_order` | `inventory_orderer` | 통과 | RPC 통과 |
| BunsikClub Binh Thanh | `bt_pr1` | `inventory_orderer` | 통과 | RPC 통과 |
| BunsikClub Binh Thanh | `bt_kit` | `kitchen` | 통과 | 접근 불가 확인 |
| BunsikClub Binh Thanh | `bt_print` | `print_station` | HTTP 400 | 인증 실패로 미확인 |
| BunsikClub Binh Thanh | `print` | `print_station` | 통과 | 접근 불가 확인 |
| BunsikClub Binh Thanh | `bunsik_sm1` | `store_admin` | 통과 | RPC 통과 |
| BunsikClub Binh Thanh | `andre` | `super_admin` | 통과 | RPC 통과 |
| BunsikClub SAMPLE | `sp_pos` | `cashier` | 통과 | 접근 불가 확인 |
| BunsikClub SAMPLE | `sp_customer` | `customer_display` | 통과 | 접근 불가 확인 |
| BunsikClub SAMPLE | `sp_1f` | `emergency_station` | 통과 | 접근 불가 확인 |
| BunsikClub SAMPLE | `sp_tray` | `emergency_station` | 통과 | 접근 불가 확인 |
| BunsikClub SAMPLE | `sp_order` | `inventory_orderer` | 통과 | RPC 통과 / 초기 비밀번호 변경 필요 |
| BunsikClub SAMPLE | `sp_pr1` | `inventory_orderer` | 통과 | RPC 통과 / 초기 비밀번호 변경 필요 |
| BunsikClub SAMPLE | `sp_kit` | `kitchen` | 통과 | 접근 불가 확인 |
| BunsikClub SAMPLE | `bunsik_sm2` | `store_admin` | 통과 | RPC 통과 |
| JeonGabok Binh Thanh | `jg_bm1` | `brand_admin` | 통과 | RPC 통과 |
| JeonGabok Binh Thanh | `jgbt_pos1` | `cashier` | 통과 | 접근 불가 확인 |
| JeonGabok Binh Thanh | `jgbt_tab1` | `cashier` | 통과 | 접근 불가 확인 |
| JeonGabok Binh Thanh | `jgbt_customer` | `customer_display` | 통과 | 접근 불가 확인 |
| JeonGabok Binh Thanh | `jgbt_floor_1f` | `emergency_station` | 통과 | 접근 불가 확인 |
| JeonGabok Binh Thanh | `jgbt_floor_2f` | `emergency_station` | 통과 | 접근 불가 확인 |
| JeonGabok Binh Thanh | `jgbt_floor_3f` | `emergency_station` | 통과 | 접근 불가 확인 / 초기 비밀번호 변경 필요 |
| JeonGabok Binh Thanh | `jgbt_tray1` | `emergency_station` | 통과 | 접근 불가 확인 |
| JeonGabok Binh Thanh | `jgbt_order` | `inventory_orderer` | 통과 | RPC 통과 / 초기 비밀번호 변경 필요 |
| JeonGabok Binh Thanh | `jgbt_pr1` | `inventory_orderer` | 통과 | RPC 통과 |
| JeonGabok Binh Thanh | `jgbt_kit` | `kitchen` | 통과 | 접근 불가 확인 |
| JeonGabok Binh Thanh | `jgbt_print` | `print_station` | 통과 | 접근 불가 확인 |
| JeonGabok Binh Thanh | `jgbt_sm1` | `store_admin` | 통과 | RPC 통과 |

## 소스 검증과 운영 배포

### DB 배포와 발주 경로 수정

- PR [#593](https://github.com/ahc0403-commits/globospossystem/pull/593)은 `90c50968602e72d38796951fff7b33b292a785f0`로 정상 squash 병합했다. 필수 exact-main CI는 2026-10-19 18:00:12 ICT 성공했다.
- 깨끗한 최신 main에서 공식 `scripts/deploy_pos_production.sh --db-only`를 dry-run 후 전체 Flutter 테스트를 포함해 실행했다. 마이그레이션 적용·사후 검증·이력 기록 모두 종료 코드 0이었다. 건너뛰기 옵션을 사용하지 않았다.
- `20261019081922_procurement_all_store_parity.sql`은 정책 1개와 기존 검수자 단계 1개만 보완했다. 지정 운영 계정 `sp_pos`의 배포 후 실제 비밀번호 로그인 스모크도 통과했다.
- PR [#595](https://github.com/ahc0403-commits/globospossystem/pull/595)의 검증 head는 `535f8a5c735c15ef23b0455b28977ed72dc08d0c`, 병합 main은 `1a8e7c7789e4240df7fa3294f5a2e9953d31bd37`이다. Dart 4개·테스트 2개 파일로 선택 매장 전달과 조회 범위를 수정했다. 정적 분석·집중 테스트 17개, 필수 CI의 Flutter 2,357개/기존 조건부 건너뜀 98개와 나머지 저장소 검사·릴리스 웹 빌드·Windows 빌드가 통과했다.
- 실제 라우터로 선택 매장 유지·매장 변경 재조회·일반 계정의 URL 매장 무시·접근 거부 시 기본 매장으로 대체하지 않음을 검사했다. 재고 화면 발주 버튼과 입고 상세 링크에도 매장 전달 검사를 추가했다.
- 재고 복귀 경로 PR [#596](https://github.com/ahc0403-commits/globospossystem/pull/596)의 검증 head는 `37fd10e473974f888d0aaf0615bde7d6b95a7159`, 병합 main은 `b49bca46cd80e16fcd7cf7a2b2343b5abef807d7`이다. 소스 1개·위젯 테스트 1개로 복귀를 보완했다. 정적 분석·집중 테스트 20개와 [필수 CI](https://github.com/ahc0403-commits/globospossystem/actions/runs/39258357648)의 Flutter 2,360개/기존 조건부 건너뜀 98개, 나머지 검사·릴리스 웹 빌드·Windows 빌드가 통과했다.
- 로컬 실제 관리자 로그인으로 전가복 관리 → 재고 → 발주 → 기존 발주 → 재고 관리의 전체 왕복 경로를 확인했다. 복귀 URL은 `/admin/273b057e-3b69-46e3-93c1-6194c2802849?tab=inventory`이며 전가복 이름과 재고 탭을 유지했다.

### 첫 웹 배포, 오류 재현과 실제 롤백

- main `b49bca46cd80e16fcd7cf7a2b2343b5abef807d7`의 [필수 CI](https://github.com/ahc0403-commits/globospossystem/actions/runs/39261615911)가 통과한 뒤, 공식 web-only 배포 절차를 전체 테스트와 함께 실행해 종료 코드 0을 확인했다.
- 첫 배포 `dpl_FGkx7WyKUqRrGLZ6AdMqwmhp7pCm`은 2026-10-19 21:02 ICT에 READY/production과 운영 도메인 연결, HTTP 200·`sp_pos` 로그인 스모크를 통과했다. 이후 전수 인증 및 화면 비교에서 확인 가능한 범위는 통과했으나, 추가 계정 전환 검사에서 콘솔 오류 1건을 발견했다.
- 빌드된 JS의 스택과 소스를 대조해 `Cannot use "ref" after the widget was disposed.`를 재현했다. 재고 조회 중 화면을 떠나도 `_reloadStoreScope`가 후속 provider를 읽는 기존 결함이며, 이전 운영 소스에도 같은 코드가 있었다.
- 요청된 복구 절차에 따라 이전 READY 웹 배포 `dpl_29VfEgMDTCShDkz85x4yfLpFyHwu`로 실제 롤백했다. 운영 도메인의 소스 `1420cc1285ce2a233d93a9c254fc183bf1ce57b4` 복귀, HTTP 200과 지정 계정 실제 로그인 스모크 재통과를 확인했다. DB·계정·비밀번호는 변경하지 않았다. 첫 배포와 복구 증거 55개는 `login-qa/release-b49-rolled-back/`에 보존했다.

### 재고 조회 수명 주기 수정과 최종 재배포

- PR [#597](https://github.com/ahc0403-commits/globospossystem/pull/597)의 검증 head는 `779ca602a144be0239c991903528d3b14ae7fb9c`다. mounted 상태·현재 매장·선택 탭·조회 세대를 비동기 경계마다 확인해 무효화된 후속 조회를 중단한다. 이미 발행된 HTTP 요청을 강제 종료하는 변경은 아니다.
- 회귀 테스트 3개는 수정 전 화면 종료 오류, 이전 매장 후속 조회, 이전 탭 후속 조회를 각각 재현해 모두 실패했고, 수정 후 모두 통과했다. 정적 분석과 관련 테스트 23개가 통과했다. 로컬 실제 관리자 로그인에서 빠른 전가복 재고·발주 왕복 3회와 앱 오류 0개를 확인했다. 개발 서버의 기존 viewport 메타 경고는 구분했다.
- PR head의 [필수 CI](https://github.com/ahc0403-commits/globospossystem/actions/runs/39269371518)와 Windows 빌드가 통과한 뒤 정상 squash 병합했다. 최종 배포 대상 main은 **`96f130abdd566f3f1a551a90e76404ab4558f112`**이며 검증한 PR head와 전체 코드 트리가 동일하다. 이 main의 [필수 POS release contract CI](https://github.com/ahc0403-commits/globospossystem/actions/runs/39272286363)도 성공했다. Flutter **2,363개 통과·98개 기존 조건부 건너뜀**, fatal-info 정적 분석·나머지 저장소 검사·릴리스 웹 빌드를 확인했다.
- 세 발주 UI 수정의 최종 변경 경로는 PR #594 기준 7개다. 이전 운영 소스 `1420cc1285ce2a233d93a9c254fc183bf1ce57b4`와 최종 배포 대상 main의 전체 차이는 기존 main 변경을 포함해 53개 경로다. 기존 main의 정산·발주 문서 재시도·매장 오픈 프린터 설정·활성 매장 선택 수정을 포함한 영향을 검토했다.
- 필요한 마이그레이션 `20261019081922`, `20261019090000`, `20261019091000`, `20261019140000`, `20261019160000`은 모두 운영 이력에 존재함을 읽기 조회로 확인했다. 최종 web-only 배포에서 DB·Edge 변경을 재적용하지 않았다. Windows 설치와 실물 출력은 이번 발주 UI 검증 범위에 포함하지 않는다.
- 깨끗한 exact-main에서 공식 `scripts/deploy_pos_production.sh --web-only --mode prebuilt`를 dry-run 후 **`TEST_TARGETS=all`**로 실행했다. Flutter 2,363개·정적 및 Edge 검사·Vercel 릴리스 빌드·HTTP 200·`sp_pos` 실제 로그인 스모크가 통과하고 **2026-10-19 22:14:16 ICT 종료 코드 0**으로 완료됐다. 검증 생략 옵션은 사용하지 않았다.
- 최종 빌드는 **`dpl_4h7PCahuwFFsDiovRRpDAkyCi29T`**, 소스는 위 main `96f130ab...`로 확인했다. 이전 롤백 뒤 자동 도메인 할당이 비활성화돼 있어 새 빌드만으로 운영 도메인이 전환되지 않았음을 별도 검사에서 발견했다. [Vercel 공식 롤백 안내](https://vercel.com/docs/instant-rollback)에 따라 이미 공식 절차를 통과한 이 배포본을 promote했다. 재빌드나 검증 생략은 없었다.
- **2026-10-20 08:28:55 ICT**, 운영 도메인 `globospossystem.vercel.app`이 위 배포 ID를 반환하고 해당 배포의 alias 목록에 도메인이 연결됐음을 확인했다. promote alias 상태도 completed였다. READY/production·소스 SHA·HTTP 200을 대조했고, 운영 `main.dart.js`의 SHA-256이 공식 prebuilt 산출물과 정확히 일치했다.
- 도메인 전환 후 36개 ID를 새로 인증하고, 발주 관련 13개 ID도 새 운영 브라우저 세션에서 실제 비밀번호로 로그인했다. 위 ID별 표·7쌍 토큰 비교·4쌍 실제 화면 비교·두 작성 양식 비교가 최종 증거다. 빠른 전가복 왕복 3회 및 재고→로그아웃→다른 계정 재로그인 경로가 통과했고 최종 브라우저 경고·오류는 0개였다. 최종 배포에서 추가 롤백 사유는 관찰되지 않았다.

## 검증 근거와 남은 제한

비공개 근거는 `/Users/andreahn/.codex/backups/globos-pos-reviewed-20261019/`의 `verification/`, `login-qa/`에 보관한다. 최종 증거는 `production-after-summary.json`, `final-reviewed-source.json`, `verified-comparison-summary.json`, `all-account-login-results.json`, `browser-login-results.json`, `web-deploy.log`, `lifecycle-production-qa.json`, `final-production-asset-verification.json` 및 운영 스크린샷이다. 인증 결과나 이 문서에 비밀번호·토큰을 기록하지 않았다. 업무 문서 데이터가 보이는 스크린샷과 접근성 원문은 저장소에 포함하지 않는다. 브라우저 전용 플러그인이 제공되지 않아 세션에 제공된 CUA 브라우저 도구로 실제 UI를 확인했다.

비발주 `bt_tab1`·`bt_print`의 기존 자격증명 인증 실패와 발주 `jgbt_order`·`sp_order`·`sp_pr1`의 초기 변경 제한이 남아 있다. 전체 36개 ID의 실제 업무 화면을 모두 검증한 것으로 판정하지 않는다. 사용자의 비밀번호 변경 금지 지시에 따라 비밀번호 변경·초기화·초기 변경 플래그 해제·인증 제한 우회는 수행하지 않았다.

결과 문서는 실제 배포·CI·인증 증거의 ID와 수치, 링크·Markdown·공백 및 자격증명 누출 여부를 대조해 단독 커밋한다. 보존 브랜치의 과거 소스는 운영에 병합하지 않으며, 운영 코드 커밋과 결과 문서의 로컬 보존 커밋을 구분한다. 기존 미커밋 파일 680개의 해시와 존재 여부가 기준 증거와 동일함을 확인했다. 이후 다른 작업에서 추가된 출력물 8개도 삭제·수정하지 않았다. 결과 문서 외 미커밋 688개를 별도 해시 목록으로 보존하고 이번 문서 커밋에 포함하지 않는다.
