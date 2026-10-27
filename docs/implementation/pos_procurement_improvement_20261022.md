# 2026-10-22 POS 구매 업무 개선

> Reconciled 2026-10-27: historical source and operational observations below retain their original SHA/time and have not been revalidated by this transfer. Current verification follows cloud-first `CLAUDE.md` and the full committed candidate/exact-main gate; historical CI or local-only wording is not a current release requirement. No production action is authorized by this document.

> 2026-10-24 소유자 정책: 앞으로의 자동 검증은 최종 후보·깨끗한 exact-main SHA에 묶인 전체 로컬 증거를 사용한다. GitHub는 commit/push 보관 용도이며 Actions/runner 성공은 필수 증거가 아니다. 기존 공식 배포·운영 검증은 유지하고 실행 스크립트·원격 보호 규칙의 남은 의존성은 우회하지 않는다. 아래 과거 실행 사실은 당시 이력이다.

상태: 2026-10-23 계정 복구·POS/Office 커밋·푸시·운영 배포·운영 로그인/PR 조회 검증 완료. [최종 운영 반영 기록](/Users/andreahn/globos_pos_system/design_artifacts/pos_improvement_20261022/production_release_20261023.md). 아래는 2026-10-22 구현 당시의 기록이며 당시 남은 절차는 위 최종 기록으로 완료를 확인한다.

## 확인한 장애와 운영 상태

- 첨부 PPT의 Office 구매계정은 활성 상태이며 정지되지 않았다. 첨부 비밀번호를 사용한 고정 Office 프로젝트의 인증 요청은 HTTP 400 `invalid_credentials`를 반환했다. 비밀번호나 세션 토큰은 이 문서에 기록하지 않는다.
- 첨부의 `PR-20261021-63AEDA6816`, `PR-20261020-F777394D50`, `PR-20261019-75D2A342A6`은 모두 policy 3, `office_review`, row version 3이다. 매장 승인은 저장돼 있다.
- Office의 기존 매장 구매권한과 POS 구매 역할 배정을 대조했다. 이 권한을 반영한 읽기 전용 POS RPC 결과에 세 PR과 `office_approve`가 포함된다. 실제 Office 로그인과 배포된 브리지를 통한 조회 성공을 의미하지는 않는다.
- `20261020153000` 통합 마이그레이션은 운영 DB에 적용됐으며, `bt_pr1`에는 requester·receiver·verifier가 모두 유효하다. 별도 계정 생성이나 기존 수령계정 삭제는 필요하지 않다.

## 변경 내용

- POS 주방 PR 화면에서 구매요청과 입고·검수를 직접 전환한다. 서버가 수령 권한을 확인한 계정에만 통합 전환을 표시한다.
- Office 구매 승인 권한이 있는 V2 `office_staff`는 PR 승인을 기본 화면으로 연다. 단일 매장은 현재 승인 단계와 오래된 제출 건부터 조회하며, 전체 PR 이력으로 전환할 수 있다. 여러 매장은 기존 범위 제한 승인함을 재사용한다. 기존 PR/PO 직접 링크를 보존한다.
- Office 기본 PR 화면은 기존 PO 목록을 먼저 읽지 않는다. 화면 식별자에 사용자·매장 범위를 포함해 범위 변경 시 이전 화면 상태가 재사용되지 않게 한다.
- 두 앱의 PR 상세·PDF는 부족분 우선 표시 후 각 그룹을 원재료 코드순으로 정렬한다. 기록된 코드를 우선 사용하고 코드 누락은 뒤에, 동일 코드는 원래 순서대로 표시한다. 원본 배열, 행 ID, 승인 해시, 단위, 금액과 감사 시각을 바꾸지 않는다.
- PR PDF에서 제출 시각을 제외한다. Office는 요청일·필요일을 별도로 표시하고 policy-3 PR의 승인란에서 BM 단계를 제외한다. 공급업체 PO의 정렬과 출력 계약은 유지한다.

## 작업 위치

- POS: `/Users/andreahn/globos_pos_system`, 현재 작업 사본의 관련 구매 파일과 새 테스트만 수정했다. 기존 `tri_system_data_flow_harness_test.dart` 및 두 미추적 테스트 파일은 보존했다.
- Office: 최신 `origin/main` `73fc711c`에서 만든 `codex/procurement-improvement-20261022` 분리 작업 사본 `/Users/andreahn/Documents/restaurant_office_app_procurement_20261022`. 원래 Office 작업 사본은 수정 전 스냅샷과 바이트 단위로 일치하게 복원해 사용자 변경을 보존했다.
- 미리보기: `design_artifacts/pos_improvement_20261022/`의 앱별 KO/EN/VI PR PDF. 모두 가상 자료다.

## 데이터 접근과 성능

- PR 목록은 기본 20건·최대 50건, 선택한 상세는 최대 200품목으로 제한하는 기존 RPC를 재사용한다. 정렬은 이미 받은 제한된 상세 자료에만 적용하며 추가 조회를 만들지 않는다.
- 다매장 승인함은 100매장 단위 RPC, 동시 최대 2배치다. 사용자 U명과 매장 S개가 같은 시점에 갱신하면 POS 승인함 조회는 U × ceil(S/100)개 배치에 비례하며, PR별 호출을 추가하지 않는다. 인증·범위 확인의 고정 호출은 별도다.
- 새 Office 진입 테스트는 기본 화면 조회 1회, 기존 PO 목록 조회 0회를 확인한다. 기존 페이지 테스트는 20/100개 요약과 1/20/200개 상세 품목에서 초기 목록 1회, 상세 선택 후 누적 2회를 확인한다. 이는 가짜 서비스 호출 계측이며 실제 네트워크 지연 측정이 아니다.
- 분리 DB 성능 회귀 검증: 2/20/100매장 × 100/1,000/10,000 PR의 9개 조합에서 50행·RPC 1회, PR 관계 반복 스캔 없음. 이번 실행의 최대 DB 실행 시간은 185.106ms였다. 네트워크·Flutter 메모리는 측정하지 않았다.
- 통합 PR 계정 입고 SQL 검증: 6+4 수량 수령, 재시도 추가 재고 0, 논리 쓰기 RPC 1회. 이번 분리 DB 실행은 332.199ms였다. 운영 재고를 변경하지 않았다.

## 검증 기록

- POS 집중 검증 29건과 기존 입고 화면 검증 18건 통과.
- Office 최신 main 기반 구매·승인함 집중 검증 32건 통과.
- 두 앱 정적 분석 통과. Office KO/EN/VI 검사와 브리지 Deno 테스트 31건 통과.
- Office 최신 main 기반 release web build 통과.
- 두 앱 3개 언어 PR PDF의 텍스트 추출로 코드순·요청일·필요일·제출 시각 비표시와 원본 보존을 확인했다. 최종 베트남어 PDF 두 종류, POS 베트남어 모바일 화면, Office 구매 담당자 화면을 가상 자료로 렌더링해 확인했다.
- POS 전체 `bash scripts/check_repo.sh` 최종 종료 코드 0. Flutter 전체 테스트, SQL/API 및 Edge 계약, Node 검사, release web build, 배포 계약, diff 검사까지 통과했다. 첫 실행에서 변경된 섹션 이름을 찾던 기존 테스트 두 곳을 새 문구에 맞게 수정한 후 전체 검증을 다시 실행했다.

## 운영 반영 전 남은 단계

1. 코드 검토·관련 검증을 완료하고 각 앱의 정식 release 절차와 정확한 main SHA의 로컬 전체 검증 게이트·원격 push 확인를 통과한다.
2. Office의 기존 `manage-office-account` 비밀번호 재발급 경로로 구매계정의 기존 Auth ID와 5개 매장 구매 권한을 유지한다. 임시 비밀번호는 보안 경로로 전달하고 기존 최초 변경 절차를 따른다.
3. 사용자 확인 후 두 앱의 승인된 운영 배포 경로를 실행한다. 실제 구매 승인, 발주, 공급업체 전송, 입고 재고 반영은 테스트 목적으로 실행하지 않는다.
4. 재발급 후 실제 구매계정 로그인과 첨부 PR 3건의 승인 버튼·연결 PO·입고 표시를 다시 확인한다. 소스 및 분리 DB 검증을 운영 검증으로 표시하지 않는다.

Office `AGENTS.md`는 운영 변경에 대해 “Changes to production environments, including deployments and database mutations, require ... explicit confirmation.”을 요구한다. 이번 구현 요청만으로 운영 배포·비밀번호 재발급을 실행하지 않았다.

## 검토용 결과물

- [POS 베트남어 PR PDF](/Users/andreahn/globos_pos_system/design_artifacts/pos_improvement_20261022/pos-pr-vi.pdf)
- [Office 베트남어 PR PDF](/Users/andreahn/globos_pos_system/design_artifacts/pos_improvement_20261022/office-pr-vi.pdf)
- [POS 모바일 전환 화면](/Users/andreahn/globos_pos_system/design_artifacts/pos_improvement_20261022/pos-pr-mobile-vi.png)
- [Office 구매 승인 화면](/Users/andreahn/globos_pos_system/design_artifacts/pos_improvement_20261022/office-buyer.png)
- [Office 기능 변경 패치](/Users/andreahn/globos_pos_system/design_artifacts/pos_improvement_20261022/office-improvement.patch)
