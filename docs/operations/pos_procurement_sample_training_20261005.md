# SAMPLE 구매 연습 계정·실행 절차 — 2026-10-05

사용자 요청: 빈탄점과 동일 역할의 공용 ID를 샘플 매장에도 발급하여 구매 과정을 연습한다. 개인별 ID·HR 연결·부재 대리자를 요구하지 않는다. **현재는 발급 명세와 설정 SQL 준비 상태다. 실제 신규 Auth·Office SAMPLE 연결·roster·정책 활성화·연습은 미실행이다.**

## 계정

| 역할 | 빈탄점 | SAMPLE 연습 | SAMPLE 상태 |
|---|---|---|---|
| 최초 발주·PR | `bt_pr1` | `sp_pr1` | 신규 POS `inventory_orderer`, 샘플 매장만; 미생성 |
| SM | `bunsik_sm1` | `bunsik_sm2` | 기존 활성 POS 계정·샘플 접근 확인 |
| BM | `bunsik_bm1` | `bunsik_bm1` | 기존 브랜드 역할 유지·샘플 접근 확인 |
| Office 구매팀 | `bunsik_purchase1@globos.world` | `sp_purchase1@globos.world` | 신규 `purchase_store`; 미생성 |
| 수령 | `bt_order` | `sp_order` | 기존 활성 POS 계정·샘플 접근 확인 |
| 입고 검증 | `bt_verify1` | `sp_verify1` | 신규 POS `inventory_accounting`, 샘플 매장만; 미생성 |

같은 로그인 문자열로 별도 매장 계정을 중복 발급할 수 없으므로 샘플 단축 코드 `SP`를 사용한다. 역할·승인 단계는 빈탄점과 동일하다. 기존 법인 검증 `account`도 유지한다. 신규 샘플 ID는 빈탄점 접근 grant를 받지 않는다. 기존 BM은 브랜드 범위가 유지되므로 실습마다 SAMPLE 매장을 선택한다. 공용 계정 감사는 ID 기준이며 실제 개인을 식별하지 않는다.

## 매장 연결과 발급

- POS SAMPLE ID: `3a268807-771f-4fd4-84fe-e1b0b00de40a`, 활성 `BunsikClub SAMPLE`, 코드 `SP`.
- 브랜드: `a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878`.
- POS 비세무 샘플 법인: `8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1`, `PENDING_SAMPLE_STORE_TAX_PROFILE`.
- Office에는 현재 SAMPLE 매장 연결이 없다. 준비 SQL은 동일 매장 ID에 명시적 POS 연결을 만들고 새 Office 교육 법인 `BUNSIK_SAMPLE_TRAINING`을 사용한다. 예정 Office 법인 ID는 `8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1`이며 아직 Office에 생성되지 않았다. 현재 AKJ 및 빈탄점 법인·매장은 변경하지 않는다.

1. 기존 두 PR을 검토·병합하고 정확한 운영 main CI·migration history·고정 프로젝트·배포 확인 조건을 충족한다. 기존 구매 migration 13개/POS·12개/Office와 호환 앱/bridge를 적용한다.
2. 승인된 Office DB 절차에서 [고정 샘플 연결 설정 SQL](/Users/andreahn/Documents/procurement-release-20261005/office/scripts/operations/configure_procurement_sample_scope.sql)을 실행한다. 거래·Auth·구매 권한을 자동 생성하지 않는다. 다른 매장 연결·법인 식별자·비활성 매장과 충돌하면 전체 트랜잭션을 취소하며 기존 행을 덮어쓰지 않는다.
3. 실제 POS Super Admin으로 `admin_prepare_procurement_store_account`와 native `provision-fixed-pos-account`를 사용해 `sp_pr1`·`sp_verify1`을 발급한다. Office 실제 master로 `manage-office-account`를 호출해 샘플 매장 범위 `purchase_store`·`office_staff` 계정 `sp_purchase1@globos.world`를 발급한다. 정확한 입력은 [발급 명세의 training_stores](/Users/andreahn/globos_pos_system/docs/operations/pos_procurement_account_manifest_20261005.json)에 있다.
4. 초기 비밀번호 변경·활성 상태·샘플 매장 접근을 확인한다. 임시 비밀번호는 보안 입력으로 전달하고 문서·로그에 저장하지 않는다. Auth ID는 실제 발급 결과에서 기록한다.
5. 샘플의 requester/SM/BM/buyer/verifier 공용 roster를 실제 Auth ID로 배정한다. HR person과 deputy는 비운다. 자기 승인·같은 ID의 다른 승인 단계·빈탄점 무단 접근 거부를 확인한다.
6. 실제 계정 U33을 통과한 뒤 SAMPLE에 새 정책을 활성화하고 U34 및 해당하는 기존 UAT를 수행한다. 샘플 실습 결과와 빈탄점 실사용 UAT 기록은 각각 매장 ID·문서 번호로 구분한다.

## 연습 순서

`sp_pr1` PR 작성 → `bunsik_sm2` 수량 Adjust → `bunsik_bm1` Agree → `sp_purchase1` 구매 Approval → 가격 없는 PO 문서 생성 → `sp_order` 6개+4개 부분 수령 → `sp_verify1` 독립 검증으로 연습한다. 이어 반려·가격 변경 재승인·불량/반품·동일 요청 재시도·타 매장 접근 거부를 확인한다.

실습 문서·발송 참조·업체 회신 증빙에는 교육용임을 표시한다. 실제 업체 발송과 실제 은행 출금은 실습에 포함하지 않는다. 회계 단계는 승인된 샘플 COA·기간·해당 Finance 권한을 준비한 뒤 수행하며, 구매 계정에 Finance/admin 권한을 자동 추가하지 않는다. 준비되지 않은 회계 조건은 blocker로 기록한다. 기존 재고·가격 master는 먼저 확인하며 자동 복제·삭제하지 않는다.

[UAT 기록표](/Users/andreahn/globos_pos_system/docs/operations/pos_procurement_uat_20261005.csv)의 U33·U34와 적용 가능한 U01–U29에 실행 계정, 샘플 store ID, 실제 문서 번호, 결과·오류를 기록한다. 빈탄점의 교육·2주 실사용 시범 완료로 샘플 연습을 대체하지 않는다.
