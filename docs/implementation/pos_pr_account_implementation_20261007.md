# POS PR 계정 개선 구현 결과 — 2026-10-07

첨부 PPTX의 7장과 [개선 계획](/Users/andreahn/globos_pos_system/docs/plans/pos_pr_account_improvement_20261007.md)을 기준으로 PR 계정의 화면·저장 처리·조회 계약·출력 양식을 수정했다. **소스 구현과 격리 로컬 검증을 완료했으며, 운영 DB 적용·배포·실제 계정 인수는 수행하지 않았다.** 기존 사용자 수정·미추적 파일을 보존했고 커밋·push·배포는 실행하지 않았다.

## 1. 구현 내용

| 첨부 요구 | 반영 내용 |
|---|---|
| R01·R02·R06: 생성 건 표시·신규 우선·실제 PR 번호 | 3단계 구매 정책을 사용하는 PR 계정의 기본 화면을 실제 PR 목록으로 연결. 저장 응답 ID 선택, 검색·유형·기간·커서 초기화와 목록 상단 이동. 작성일/ID 내림차순 커서로 조회 |
| R03·R04·R05·R10: 용어 정리 | 구매요청 관리 / 구매요청·승인 / 구매내역 / 구매요청 목록 적용. 기존 PO의 실제 번호·이력은 별도 진입에서 유지 |
| R07·R17: 상태·두 날짜 | 목록에 실제 PR 상태, 원래 작성일인 요청일, 납품 희망일인 필요일 표시. 일시는 베트남 시간 기준으로 정리 |
| R08·R09: 수정·삭제 반영 | 본인 초안/반려 저장 결과 재조회, 입력 보존, 버전 충돌·재시도 처리. 삭제는 확인 후 이력 있는 취소로 처리하며 활성 목록·선택 상세·건수 갱신 |
| R11·R12·R13·R14: 필터 | 처음으로 버튼 제거, 전체/원재료/도구·비품/음료/기타, PR 검색, 최근 1개월/사용자 달력 기간 적용. 기존 stationery는 도구·비품 필터에 포함하고 저장값 보존 |
| R15·R16·R18: PR 화면 정리 | 요청자 화면의 운영지표·수요 영역 제거. 서버 집계 상태별 건수와 구매요청 현황 표시. 재고 수량을 보존하고 옆의 ISO 갱신시각 제거 |
| R19·R20: 작성 창 단순화 | 채널·권장 공급업체 선택 제거. 활성 매장/브랜드 범위의 유일한 우선 가격으로 예상가격 자동 계산. 동순위 가격은 견적 필요. 기존 Shopee·공급업체 값은 수정 시 보존 |
| R21: 출력 양식 | A4 PR 전용 기본정보·8열 품목표·천 단위 금액·수량 정밀도·합계·승인표. 긴 다국어 품목 줄바꿈, 반복 머리글·페이지, 합계와 승인표를 한 페이지에 묶음 |

기본 PR 진입은 `inventory_orderer` + `three_stage_required` 조건에 적용한다. 정책이 활성화되지 않은 매장의 기존 PO 흐름을 임의로 PR로 전환하지 않는다. 입고 화면, 기존 PO 조회와 명시적 PO 상세 링크는 계속 동작한다. 첨부의 접속 정보로 로그인하거나 운영 데이터를 작성하지 않았다.

## 2. 변경 파일과 계약

- [PR 작업공간](/Users/andreahn/globos_pos_system/lib/features/procurement/procurement_workspace.dart), [기본 진입](/Users/andreahn/globos_pos_system/lib/features/inventory_purchase/inventory_order_workflow_screen.dart), [날짜·금액·가격 선택](/Users/andreahn/globos_pos_system/lib/features/procurement/procurement_presentation.dart), [KO/EN/VI 문구](/Users/andreahn/globos_pos_system/lib/features/procurement/procurement_process_labels.dart).
- [PDF 생성기](/Users/andreahn/globos_pos_system/lib/features/procurement/procurement_document_pdf.dart): 서버가 산출한 예상 공급가·VAT·합계를 우선 사용한다. 예상가격 미등록 시 견적/산출 대기로 표시하며, 공급업체용 PO에는 가격·내부 승인·은행정보를 출력하지 않는다.
- 새 [migration](/Users/andreahn/globos_pos_system/supabase/migrations/20261007010000_procurement_pr_account.sql)과 [적용 후 읽기 전용 검증](/Users/andreahn/globos_pos_system/scripts/verify_procurement_pr_account.sql). 이미 존재하는 migration은 수정하지 않았다. 배포 스크립트의 `verify_<migration_slug>.sql` 규칙에 맞춘 파일이다.
- [공유 계약](/Users/andreahn/globos_pos_system/docs/procurement/PROCUREMENT_V2_CONTRACT.md)에 필터·정렬·집계·자동 예상가격을 기록했다. `request_sort=created`가 명시된 경우에만 작성일 커서를 사용한다. 기존 Office 호출의 기본 updated_at 정렬을 보존한다.
- Office의 음료 유형 선택/출력/KO·EN·VI 표시만 보강했다: [작성 화면](/Users/andreahn/Documents/restaurant_office_app/lib/features/procurement/procurement_workspace.dart), [PDF 라벨 전달](/Users/andreahn/Documents/restaurant_office_app/lib/features/inventory_purchase/presentation/inventory_purchase_page.dart), [문구](/Users/andreahn/Documents/restaurant_office_app/lib/app/i18n/app_strings.dart). bridge에는 유형을 제한하는 별도 enum이 없음을 확인했다. Office Auth, 지급·회계·물리 테이블 이름은 변경하지 않았다.

신규 유형 `beverage`는 구매 분류다. 재고/비재고/자산 및 VAT 규칙을 대체하지 않는다. 자동 예상가격은 라인에 가격·환산·VAT·출처를 스냅샷으로 저장하며 최종 공급업체를 확정하지 않는다. 가격 후보와 재고는 요청 품목 전체를 한 번에 처리한다.

후속 “계획 구현해” 요청에서는 응답 유실 뒤 작성 창에서 재시도할 수 없는 문제를 실패 테스트로 재현하고 수정했다. 완료 여부가 불확실하면 작성 창의 버튼이 **같은 요청 재시도**로 바뀌고, 저장해 둔 키·원본 입력을 그대로 보낸다. 확인 중에는 입력과 중복 클릭을 차단한다. 서버가 명시적으로 거절한 경우에는 재시도 기록을 정리하고 입력 수정이 가능하다. 저장 성공 후 목록 조회만 실패한 경우에는 성공과 조회 실패를 구분하며, 새로고침 성공 시 완료 안내로 돌아온다.

계획의 A02·A07·A13 검증도 보강했다. 검색·음료 필터와 다음 페이지에서 저장해도 생성 건이 선택되는지, 같은 프레임의 중복 클릭과 응답 유실 재시도가 같은 명령을 보내는지, 저장 후 조회 실패가 신규 PR 재생성을 일으키지 않는지 확인했다. 예상가격 없는 초안은 3언어 PDF의 실제 추출 텍스트에서 견적 필요·불완전 합계·승인 대기를 검사했다. [PDF 인수 검사](/Users/andreahn/globos_pos_system/scripts/tests/procurement_pr_pdf_acceptance.py)는 PDF 위젯 테스트가 만든 1/11/50품목 및 가격 미등록 예시 12개를 읽어 확인한다.

## 3. 검증 결과

| 검사 | 결과 | 범위·증거 |
|---|---|---|
| 수정 전 재현 | 확인 | 저장한 PR ID가 선택되지 않고, 공급처 선택을 숨기면 기존 가격 계산이 누락되는 위젯 실패를 먼저 재현 |
| POS 관련 테스트 | **60개 통과** | `flutter test test/features/procurement test/inventory_workflow_all_stores_widget_test.dart test/dialog_sheet_entrypoint_coverage_contract_test.dart` |
| 앱·테스트 정적 분석 | **통과** | `dart analyze --fatal-infos lib test` |
| 구매 SQL·동시성 | **통과** | `bash scripts/test_procurement_v2.sh`: 새 migration과 verify 적용, 기존 승인/입고/회계 계약, PR 저장·수정·삭제·scope·ownership·버전·정확한 재시도·음료·페이지·Office 호환 |
| Office 관련 테스트 | **25개 통과** | `./scripts/run_office.sh unit-test test/features/procurement` |
| Office 정적 분석·다국어 검사 | **통과** | 변경 경로 Dart 분석, add/check i18n 스크립트 3개 |
| PDF 내용 | **통과** | POS·Office KO/EN/VI 내부 PR/공급업체 PO 12개, 200품목 끝 행·비고·날짜·승인·금액·공급업체 비공개 필드 확인 |
| PDF 레이아웃 | **통과** | POS 1/11/50품목 × 3언어 및 가격 미등록 초안 × 3언어 실제 내용 검사. 머리글 반복, 합계/승인표 같은 최종 페이지, 베트남어·수량 소수·A4 폭 확인. 200품목 PR은 11페이지 |
| 화면 검증 | **통과** | KO/EN/VI × 390/1440px와 390px 작성 창 재시도 위젯 검증. 실제 KO·VI 재시도 PNG와 KO 가격 미등록 PDF 열람. 작은 화면의 입고/기존 발주는 메뉴로 제공 |
| 웹 release build | **통과** | `flutter build web --release`; 로컬 `build/web` 생성. 배포하지 않음 |
| 전체 저장소 gate | **미통과** | 아래의 기존 감사 자료 분석 경고와 기존 테스트 불일치가 남음 |

최종 전체 Flutter 실행은 **1,748개 통과, 94개 skip, 2개 실패**였다. PR 개선과 관계없는 두 항목은 보존했다. 최초 검증 대비 구매 기능 검사 9개를 추가했고 새 실패는 없었다.

1. `test/direct_order_arrival_alert_test.dart`: 생성 번역 파일 `lib/l10n/app_localizations.dart`의 현재 해시가 고정된 기대 해시와 다르다. 이번 변경은 ARB·생성 번역 파일을 직접 수정하지 않았다.
2. `test/route_operational_state_coverage_contract_test.dart`: 기존 관리자 운영 테스트에서 `all ten Admin tabs render localized selected operational workspaces` 표기를 찾지 못한다. 해당 관리자 테스트·경로는 이번에 변경하지 않았다.

`bash scripts/check_repo.sh` 재실행은 기존 `docs/audits/n_plus_one_20261005/kds_probe.dart`·`scan.dart`의 분석 경고/info **4건**에서 중단됐다. 사용자 감사 파일은 수정하지 않았다. 나머지 스크립트 부분을 동일 명령 그대로 별도로 실행해 퇴역 계약, 각 SQL/API 검사, Edge 검사, Node 검사, 배포 shell/migration gate fixture, VAT 무결성, release build, whitespace 검사를 완료했다. 이는 전체 gate를 통과했다는 뜻이 아니다.

실행 로그: [최종 POS 관련 테스트](/tmp/pos-pr-followup-focused.log), [SQL](/tmp/pos-pr-final-sql.log), [Office](/tmp/pos-pr-office-tests.log), [최종 앱 분석](/tmp/pos-pr-followup-analyze.log), [최종 전체 gate](/tmp/pos-pr-followup-repo.log), [최종 전체 Flutter](/tmp/pos-pr-followup-full-flutter.log), [최초 나머지 검사](/tmp/pos-pr-after-test-checks.log), [200품목 PDF 내용](/tmp/pos-pr-final-pdf-content.log), [추가 PDF 인수 검사](/tmp/pos-pr-followup-pdf-acceptance.log), [최종 웹 build](/tmp/pos-pr-followup-web-build.log), [응답 유실 수정 전 실패](/tmp/pos-pr-followup-repro.log). 후속 수정은 POS 작성 창·검증에 한정되어 SQL·Office 검사 결과는 최초 통과한 동일 소스의 기록이다. 임시 로그는 로컬 보존이며 릴리스 CI 증거가 아니다.

## 4. 조회 비용

| 매장 PR 수 | 부모 페이지·다음 페이지 판단용 | 범위 전체 대기 건수 | 로컬 내부 SQL EXPLAIN 시간 | 화면 API 호출 |
|---:|---:|---:|---:|---:|
| 100 | 21 | 100 | 0.316ms | 1 |
| 1,000 | 21 | 1,000 | 0.794ms | 1 |
| 10,000 | 21 | 10,000 | 4.720ms | 1 |

요약은 실제 응답 시 20건과 `has_more`로 변환된다. 위 측정은 조회 내부 CTE의 격리 DB 실행이며 네트워크·운영 부하·운영 p95를 포함하지 않는다. [측정 JSON](/Users/andreahn/globos_pos_system/docs/implementation/pos_pr_account_20261007/pr_query_performance.json), [측정 코드](/Users/andreahn/globos_pos_system/scripts/tests/procurement_pr_query_performance.py).

20/100개 목록 × 선택 상세 1/20/200품목 위젯은 최초/선택마다 한 번 읽는다. SQL 관계 집계에 요청별 correlated SubPlan이 없음을 확인했고, 가격 스냅샷도 일괄 INSERT/CTE로 처리한다. 기존 공급업체/PO/수요 조회의 100/1,000/10,000개 fixture도 통과했다.

## 5. 검토용 결과물

아래 PDF/화면은 수정한 앱 코드에서 **가상 데이터**로 생성했다. 운영 문서나 실제 승인 기록이 아니다. 최초 계획의 별도 시안 PDF와 구분한다.

- PR 출력: [한국어](/Users/andreahn/globos_pos_system/docs/implementation/pos_pr_account_20261007/pr_example_ko.pdf), [영어](/Users/andreahn/globos_pos_system/docs/implementation/pos_pr_account_20261007/pr_example_en.pdf), [베트남어](/Users/andreahn/globos_pos_system/docs/implementation/pos_pr_account_20261007/pr_example_vi.pdf).
- 화면: [한국어 데스크톱](/Users/andreahn/globos_pos_system/docs/implementation/pos_pr_account_20261007/screen_ko_1440.png), [베트남어 모바일](/Users/andreahn/globos_pos_system/docs/implementation/pos_pr_account_20261007/screen_vi_390.png). 같은 폴더에 3언어 × 2크기 PNG가 있다.
- 추가 검토 자료: [가격 미등록 초안 PDF](/Users/andreahn/globos_pos_system/docs/implementation/pos_pr_account_20261007/pr_incomplete_ko.pdf), [작성 창 재시도](/Users/andreahn/globos_pos_system/docs/implementation/pos_pr_account_20261007/screen_retry_ko_390.png). 각각 같은 폴더에 KO/EN/VI 예시가 있다.

## 6. 운영 반영 전 남은 작업

운영 반영 상태는 모두 미수행이다. 실제 계정·매장 정책·현재 DB 함수 버전은 조회하거나 변경하지 않았다.

1. 기존 작업과 이번 변경을 리뷰 가능한 커밋으로 정리하고, 전체 검사 불일치를 해결한다. 정확한 pushed SHA의 필수 CI가 성공해야 release gate 통과로 판단한다.
2. 기존 구매 migration 의존성과 운영 migration 이력을 확인한 뒤 새 migration을 정해진 POS 배포 gate로 적용하고 `verify_procurement_pr_account.sql`을 실행한다. Office 음료 라벨 변경도 해당 앱의 gate로 릴리스한다.
3. 실제 PR 정책/계정에서 작성→재진입→수정→삭제, 제출 후 변경 차단, 구매팀/브랜드 승인, 진행 중 PO 입고, PDF 출력 인수를 수행한다.

코드 구현, 격리 DB 적용, 운영 배포, 현장 UAT는 각각 별도의 상태다. 이번 결과는 앞의 두 상태에 대한 증거이며 운영 릴리스 완료 보고가 아니다.
