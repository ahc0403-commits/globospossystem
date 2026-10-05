# 구매 운영 전환·교육·시범 기록 — 2026-10-05

상태: 실행용 기록 양식 준비. 실제 매장 배포·활성화·교육·UAT·2주 관찰 미실행. 소스 검증은 [구현 결과](/Users/andreahn/globos_pos_system/docs/implementation/pos_procurement_process_implementation_20261005.md)를 참고한다.

## 매장·담당자 확정

사용자가 시범 매장을 **BUNSIKCLUB 빈탄점**으로 지정했고 **공용 역할 ID, 부재 대리자 없음**을 확정했다. POS와 Office의 매장 ID는 `8bc9eef5-dcd5-46b1-b931-23f77132322c`다. 계정은 개인별로 발급하지 않으며 역할 roster의 직원번호/HR person은 필수가 아니다.

| 역할 | 공용 ID | Auth 시스템·subject ID | 권한·생성 상태 |
|---|---|---|---|
| 최초 발주·PR 작성 | `bt_pr1` | POS·신규 생성 후 기록 | `inventory_orderer`, 빈탄점만. 생성 준비; 미생성 |
| Store Manager | `bunsik_sm1` | POS `c7441909-4b4f-40da-83e2-59cbf7957555` | 활성 `store_admin/store_manager`, 빈탄점 접근 확인 |
| Brand Manager | `bunsik_bm1` | POS `9a7f1aaf-209b-458e-b09d-562067c808d9` | 활성 `brand_admin/brand_manager`, 빈탄점 접근 확인 |
| 구매팀 | `bunsik_purchase1@globos.world` | Office·신규 생성 후 기록 | `purchase_store`, `office_staff`, 빈탄점 구매 view/create/edit/submit/approve만. 미생성 |
| 수령자 | 기존 `bt_order` 유지 | POS `4cde54f0-9a28-41ec-99ec-ba2e3fea2d48` | 활성 `inventory_orderer`, 빈탄점 접근 확인. 별도 수령 ID 추가 없음 |
| 입고 검증 | `bt_verify1` | POS·신규 생성 후 기록 | 매장 범위 `inventory_accounting`, 빈탄점만. 생성 준비; 미생성 |
| 회계·현금 실행 | 기존 native Finance 권한 사용 | 실제 UAT 실행 계정 기록 필요 | 구매팀에 Finance/admin 권한을 자동 부여하지 않음 |

부재 대리자는 지정하지 않는다. 요청자·SM·BM·구매·검증 ID를 분리하고 같은 ID의 자기 승인·연속 단계 승인을 거부한다. 서로 다른 공용 ID를 같은 사람이 사용하는지는 시스템에서 식별할 수 없으므로 감사는 계정 기준이다. 개인 계정 모드는 실제 HR 연결을 유지한다. 직원 선결제·환불·상환의 지급 대상은 공용 역할 ID와 별개이며 실제 Office 직원 연결을 계속 요구한다.

**기존 법인 검증 공용 계정 `account`는 유지한다.** 새 `bt_verify1`은 기존 singleton을 바꾸지 않고 매장 fixed-account requirement로 발급한다. `admin_prepare_procurement_store_account`는 요구 행만 준비하고 Auth를 만들지 않는다. 이어 기존 `provision-fixed-pos-account`를 실제 Super Admin JWT로 호출한다. 법인 접근 grant를 추가하지 않는다.

Office의 현재 빈탄점 법인은 `AKJ` (`10000000-0000-0000-0000-000000000001`)이며 Photo Objet 매장들도 같은 법인에 매핑되어 있다. 따라서 `purchase_entity/group` 대신 새 `purchase_store` 템플릿을 사용한다. 법인·브랜드·매장 연결은 기존 master를 유지하고 발급 직전 다시 대조한다. 계정 발급은 기존 `manage-office-account`의 검증된 활성 master를 통해 진행하고 최초 비밀번호 변경 절차를 유지한다.

[비밀정보 없는 계정 발급 명세](/Users/andreahn/globos_pos_system/docs/operations/pos_procurement_account_manifest_20261005.json)에 native API 입력과 확인 계정을 정리했다. 임시 비밀번호는 명세/저장소/로그에 넣지 않고 발급 시 보안 입력으로 전달한다. 실제 Auth 생성·초기 비밀번호 변경·접근 UAT·roster 저장은 미실행이다. roster의 유효기간은 기록 범위이며 기존 Auth 권한을 부여/회수하지 않는다.

## 전환 전 데이터

| 확인 대상 | 기록할 증거 | 현재 상태 |
|---|---|---|
| 공식 사업장·법인·납품 주소/연락처 | 기존 master ID·문서 검토자 | 미확정 |
| 업체·품목·처리 유형·단위/환산·가격/VAT 유효일 | 실제 master/export 및 확인일 | 미확정 |
| 비용·취득 clearing·AP·은행/현금·직원 채무 계정 | 실제 활성 COA·회계 책임자 확인 | 미확정 |
| 자산/CCDC 등록 기준·원가·책임자/위치 | 기존 승인된 native 등록 | 미확정 |
| 기존 PR/PO·부분입고·미결 이슈·Invoice·선급 잔액 | 전환 시각·번호·정책·원장 잔액 | 미수행 |

기존 건은 원 policy/hash·실제 날짜·실제 승인으로 이어 처리한다. 과거 브랜드 승인이나 PR을 소급 생성하지 않는다. Word/Excel에 적힌 계정정보를 운영 설정에 자동 복제하지 않는다.

## 릴리스 기록

1. 검토용 변경을 확인하고 두 DB migration 목록·기존 canonical Finance/HR 선행 버전·생산 migration history를 대조한다.
2. 정확한 pushed head SHA의 필수 GitHub CI를 통과한다. 로컬 통과만으로 release gate PASS를 기록하지 않는다.
3. Office의 clean exact origin/main, 고정 프로젝트·migration history 조건을 충족하고 운영 배포에 대한 명시 확인을 받는다. POS는 기존 production deploy script를 사용한다.
4. 호환 migration과 bridge/UI를 적용한다. 새 매장 정책은 아직 활성화하지 않는다.
5. 아래 UAT를 실제 계정·검증된 매장에서 수행하고 출금/재고/증빙/원장 마감 결과를 확인한다.
6. 담당자·마스터·UAT가 확인된 매장과 구매 유형만 명시 활성화한다. 실제 공급업체 발송/결제는 해당 책임자의 권한으로 실행한다.

| 상태 | SHA/버전·시각 | 실행자·증거 | 결과 |
|---|---|---|---|
| 소스 검토 | 로컬 review branch | source manifest·diff | 준비 |
| 필수 CI | 리뷰 PR head 실행 중 | exact head 완료 결과 필요 | 미완료 |
| 운영 배포 확인 | 없음 | 사용자 명시 확인 필요 | 미완료 |
| POS migration | 미적용 | production wrapper evidence 필요 | 미완료 |
| Office migration | 미적용 | history/고정 project evidence 필요 | 미완료 |
| bridge/UI 배포 | 미배포 | release identity/build/deploy evidence 필요 | 미완료 |
| 매장 활성화 | 없음 | 실제 정책·담당자 확인 필요 | 미완료 |
| 실제 UAT | 미실행 | CSV에 담당자·실제 문서/전표·결과 기록 | 미완료 |

## 역할별 교육과 시범

[SOP](/Users/andreahn/globos_pos_system/docs/operations/pos_procurement_sop_20261005.md)를 순서대로 실습한다. 주방은 PR·반려 수정·6+4 입고, SM은 수량 조정과 자기 승인 거부, BM/구매팀은 조건 변경·재승인·무가격 발송, 검증자는 독립 확정과 반품, Finance는 대조/보류·회사 선급 충당·직원 보전·자산 clearing을 실제 담당 계정으로 확인한다.

교육 이수 기록: 역할 / 담당자 / 교육 일시 / 사용 매장 / 실습 문서 번호 / 성공·차이 / 재교육 일시. 현재 이수자는 기록하지 않았다.

활성화 후 최소 2주 동안 관찰한다. 시작일과 종료일은 실제 활성화 뒤 정하며 예정일을 완료일로 기록하지 않는다.

| 주기 | 확인 항목 | 실제 기록 |
|---|---|---|
| 매일 | 단계별 대기·입고 확정 지연·미결 이슈·회계 보류·원본 갱신 실패·중복 | 미실행 |
| 각 납품/지급 | 실제 합격/반품 수량·PO 잔량·AP/선급/직원 잔액·현금/은행 | 미실행 |
| 첫 주·둘째 주 마감 | 교육/공용 계정 처리·가격 차이·업체 납기·영수증·처리시간·네트워크 p50/p95 | 미실행 |
| 확대 결정 | 미해결 차이·지급/재고 중복 없음·실제 역할/마스터·책임자 승인 | 미실행 |

운영 지표의 열린 승인 경과시간 p95와 실제 완료 처리시간을 구분한다. 각 승인 다음 업무일, 입고 확정 납품 당일, 회계 대조 증빙 수령 후 2업무일은 계획 초안이며 실제 근무일과 책임자가 SLA를 확정한다. 반복 구매 제안은 사람 승인 후 PR로 전환하며 자동 발주나 새 모니터 일정을 만들지 않았다.

## 중단·복구

차이가 있으면 신규 PR 생성을 중단하고 진행 건과 실제 원장을 유지한다. 동일 command/proof로 재시도하며 중복 건을 만들지 않는다. 게시 전표 오류는 기존 조정/역분개 절차를 사용한다. 확정 입고·지급 삭제, 원장 숫자의 직접 덮어쓰기, 과거 승인 생성으로 복구하지 않는다. 원인·영향·복구 증거와 재개 확인을 남긴다.

## SAMPLE 연습 매장 추가

사용자가 동일 역할의 연습용 공용 ID를 요청했다. 신규 `sp_pr1`·`sp_verify1`·`sp_purchase1@globos.world`를 빈탄점 계정과 별도로 발급한다. 기존 `sp_order`·`bunsik_sm2`·`bunsik_bm1`·`account`는 유지한다. 샘플에도 HR 직원 연결과 대리자는 필요 없다.

POS SAMPLE 매장·기존 역할 접근을 운영 DB에서 읽기 전용으로 확인했다. Office에는 SAMPLE 매장 연결이 없어, 승인된 운영 전환에서 고정 범위 설정 SQL로 별도 비세무 교육 법인·매장 연결을 만든 뒤 `purchase_store` 계정을 발급한다. 새 Auth·Office 연결·roster·정책·실습은 아직 미실행이다.

[샘플 발급·실습 절차](/Users/andreahn/globos_pos_system/docs/operations/pos_procurement_sample_training_20261005.md)를 먼저 수행하고 U33·U34 및 적용 가능한 U01–U29를 실제 샘플 계정으로 확인한다. 이후 빈탄점 실사용 UAT·활성화·2주 시범을 진행한다. 필수 CI의 새 head 결과는 외부 최종 검증 기록을 기준으로 한다.
