# 법인 수금 계좌·다음날 입금액·MISA 원장 연결 구현

작성일: 2026-10-11. 사용자의 통합 수정 계획과 실행 지시를 반영한 **소스 구현 및 로컬 검증 보고서**다. 운영 DB 마이그레이션, 운영 배포, 실제 계산서 발행·정정은 수행하지 않았다.

후속 비교에서 발견된 일반 영수증 연락처와 추가 결제 방식은 [보완 결과](/Users/andreahn/.codex/worktrees/corporate-sales-release-prep/globos_pos_system/docs/pos/INVOICE_CONTACT_PAYMENT_FIX_2026_10_11.md)에 구현·검증했다. 후속 마이그레이션 `20261011203000_invoice_contacts_payment_methods.sql`도 운영 미적용이며 사용자의 배포 금지를 유지한다. 아래 검증 수치는 최초 구현 시점의 기록이다.

## 반영한 동작

### 법인 계좌

사용자가 제공한 이미지의 **MSB / BIN 970426 / 80002014298 / AKJ INTERNATIONAL CO., LTD**를 AKJ 법인의 초기 수금 계좌로 등록하는 마이그레이션을 추가했다. 다른 법인 계좌를 일괄 변경하지 않는다.

- 법인별 계좌를 `tax_entity_collection_accounts`에서 버전으로 관리한다. Super Admin이 매출신고 화면에서 변경하며, 해당 매장의 cashier·고객 결제 화면·직접 주문은 같은 설정을 사용한다. 아직 매출이 없는 운영 법인도 계좌 설정을 할 수 있다.
- 고객 화면에 이미 제시한 주문과 기존 직접 주문 세션은 당시 계좌를 보존한다. 새 결제 안내와 새 세션은 현재 계좌를 사용한다.
- 직접 주문 설정의 계좌 입력은 법인 공통 설정으로 관리한다. 처음 직접 주문 설정을 만드는 매장도 법인 계좌를 가져온다.
- 계좌 조회는 매장 접근 권한을 확인한다. 계좌 변경은 Super Admin만 가능하다.

주요 파일: `lib/core/payments/collection_bank.dart`, `lib/core/services/collection_bank_service.dart`, cashier/customer display/direct order 화면, `20261011200000_corporate_collection_accounts.sql`.

### 매출신고 화면의 다음날 입금액

선택 영업일·판매 법인에 대해 다음 금액을 별도로 표시한다.

**다음날 매출 입금액 = 등록된 Photo 매출 총액 + 레스토랑 현금 매출**

입금 대상일은 베트남 영업일의 다음 날짜다. 레스토랑 계좌이체 매출은 별도 표시하고 위 합계에 다시 더하지 않는다. 혼합 결제는 현금의 실제 `amount_portion`만 합산한다.

Photo의 현재 입력 경로는 Super Admin Excel 수동 등록이다. 성공한 등록 기록이 없으면 Photo를 0원으로 확정하지 않고 입금액 확인 필요 상태를 표시한다. 모든 수동 마감이 완료되고 레스토랑 실사 입금액과 원장 현금 매출이 일치할 때 확정 표시한다. 현금 환불·배달비 지급/회수·과부족과 실사 입금액도 별도로 표시한다. 원장 매출 합계를 실사액에 맞춰 수정하지 않는다.

초기 화면은 `get_pos_daily_sales_summary` 1회로 법인별 합계를 읽는다. 상세 내역/다운로드는 선택 법인에 대해서만 100건 이하의 keyset 페이지로 조회한다. 식당·Photo 읽기는 최대 2개 흐름이며, 영수증마다 별도 RPC를 만들지 않는다. 요약과 상세의 건수·합계가 변하면 새로 조회하도록 중단한다.

주요 파일: `lib/features/restaurant_sales_export/daily_sales_summary.dart`, `daily_sales_report_service.dart`, `restaurant_sales_export_screen.dart`, `20261011202000_sales_reporting_pages.sql`.

### 결제 의미와 품목 상세

- BANKTRANSFER는 `CK`, 현금은 `TM`, 현금+은행이체는 `TM/CK`로 출력한다. 신용카드·ATM·실제 전자지갑과 다른 혼합 결제도 실제 구성으로 출력한다. 의미가 불명확한 QR은 전자지갑으로 변환하지 않고 내보내기를 막는다.
- 식당의 실제 주문 항목·수량·판매 당시 세율·공급가액·VAT를 유지한다. 개별 메뉴를 세율별 `Dịch vụ ăn uống / 수량 1`로 합치는 처리를 제거했다. 소수 수량도 유지한다.
- 할인 반영 후 공급가액을 실제 수량으로 나눈 VAT 전 단가를 출력한다. 원장에 보관한 원래 가격·할인·금액을 수정하지 않는다. 원장의 세액이 맞지 않으면 계산으로 고쳐 내보내지 않고 검증 오류로 중단한다.
- SKU별 승인된 베트남어 계산서 명칭·실제 판매 단위와 적용 기간을 `menu_invoice_profiles`에 보존한다. Super Admin 메뉴 편집에서 승인한다. 이름·단위를 AI로 생성하거나 일괄 승인하지 않는다.
- **음료 세율과 세율 계산기를 변경하지 않았다. 콜라 10%·환타 8%를 판매 스냅샷에서 그대로 사용한다.** 명칭·단위 승인도 VAT 마스터를 수정하지 않는다.
- 실제 SKU로 판매한 단일 세트는 원장의 판매 단위를 따른다. 이미 존재하는 혼합 세율 세트의 세율별 부분 정보는 기존 `tax_breakdown`을 유지한다. Photo의 정상 서비스 `Lần`은 식당 SKU 승인 규칙으로 차단하지 않는다.

MISA 본문은 기존 필수 17열과 8행 헤더를 유지한다. 별도 `POS Ledger` 시트에 영업일·법인·영수증/품목/SKU ID·엑셀 순번/행·원본 해시·스냅샷 버전·품목 해시·실제 결제 구성을 연결한다. 엑셀 내부 순번은 실제 발행 계산서 번호가 아니다.

주요 파일: `lib/features/admin/einvoice_misa_workbook.dart`, `restaurant_sales_export.dart`, `photo_sales_registered_export.dart`, `lib/features/admin/widgets/invoice_profile_editor.dart`, `20261011201000_invoice_ledger_export_contract.sql`, `supabase/functions/_shared/meinvoice.ts`.

### 미발행 작업과 발행 원본

계좌/결제 설정 변경만으로 기존 작업의 수정 완료를 표시하지 않는다. 매출신고 화면의 명시적 미발행 스냅샷 재검증 작업은 날짜·법인·최대 100개 ID 범위를 확인하고, 아직 claim·발행 시도가 없고 MISA 식별자가 없는 작업만 갱신한다. 이전 스냅샷을 별도 버전에 보관한다.

발행된 스냅샷과 이미 dispatch가 시작된 스냅샷은 변경을 차단한다. 승인 명칭·단위가 없거나 옛 QR 표기가 남은 식당 작업은 신규 claim을 허용하지 않는다. 기존 Photo 서비스 작업은 별도 계약에 따라 유지한다. 기존 판매 원장을 다시 쓰거나 대체 계산서를 신규 매출로 추가하지 않는다. 실제 기발행 정정은 기존 MISA 포털과 제공된 정정 절차에 따른다.

### 자동화 연결

다음 자동화 소스에 POS 요약/페이지 어댑터를 추가했다.

`/Users/andreahn/Documents/Codex/2026-09-12/files-pasted-by-the-user-full-2/outputs/akj-automation`

`akj/pos_reporting_contract.py`, `akj/globos.py`, `akj/data.py`에서 선택 법인의 원장 응답을 별도 승인 명세로 연결하고, MISA 엑셀과 품목 ID·행 수·수량·금액·세율·결제 의미를 비교한다. 명세는 다운로드 엑셀에서 생성하지 않는다. 실제 인증된 브라우저의 요청 정보는 페이지 조회에만 사용하고 저장하거나 로그에 남기지 않는다.

자동화가 보관하는 원본 응답 SHA-256과 POS 시트의 원본 버전/해시 연결은 각각의 계약을 유지한다. 기존 원장 검증·재개 보호·중복 방지·개발 중 MISA 읽기 전용 제한을 보존했다. 설치된 앱 번들을 다시 만들거나 실제 MISA 사이트로 가져오기/발행하지 않았다.

최신 main의 정식 배포 목록에 이미 있는 `meinvoice-dispatcher`를 보존하고, 변경된 네이티브 payload 검증을 추가했다. `scripts/check_repo.sh`에 신규 원장 SQL 및 네이티브 계산서 테스트를 추가했고, 배포 스크립트의 대상 확인·기존 인증/커밋/CI 조건을 유지했다.

## 검증 결과

| 범위 | 결과 |
|---|---|
| Flutter 전체 테스트 | 1,922개 통과, 기존 97개 skip. 이후 혼합 결제·실사 차이·계좌 모달 등 마지막 변경의 관련 16개 재검증 통과 |
| 정적 분석 | `flutter analyze --no-pub`: 문제 없음 |
| Web 릴리스 빌드 | `flutter build web --release`: 성공. 기존 WASM 사전 검사/폰트 경고는 남아 있음 |
| 법인 계좌·원장·페이지 SQL | `bash test/corporate_sales_export_sql_test.sh`: PASS. 소유한 일회성 Docker DB에 선행 함수와 실제 신규 마이그레이션을 적용 |
| 기존 음료 세율 SQL | `bash test/beverage_sugar_vat_sql_test.sh`: PASS |
| 네이티브 MISA payload | 3개 테스트 통과: 9행/10개·기존 금액/세율, 소수 수량, Photo 단위 예외. Dispatcher `deno check` 및 변경 TS 포맷 검사 통과 |
| 자동화 전체 테스트 | 382개 통과. 마지막 결제 매핑 변경 후 관련 42개 재검증 통과 |
| Dart→Excel→Python 대조 | 실제 Dart 생성 파일을 Python에서 검증. 품목 축약·잘못된 전자지갑·품목 ID·세율 변조를 거부 |
| 배포 경로 회귀 | 배포 Auth guard Flutter 테스트, clean worktree/마이그레이션 모의 검사 및 변경 shell 문법 검사 통과. 운영 명령 실행 결과가 아님 |

BC-20261008-023320의 알려진 기준 금액을 사용한 테스트 자료에서 **9개 항목 / 수량 10개 / 공급가액 406,000 / VAT 33,560 / 총액 439,560 VND / CK / 콜라 10%·환타 8%**를 확인했다. 테스트 명칭·품목 ID는 합성 자료다. 이번 구현 작업에서 실제 운영 영수증을 재조회하거나 실무 메뉴 명칭을 승인한 결과는 아니다.

SQL 페이지 검증은 영수증 205건·주문 품목 1,845행을 생성해 100/100/5건, 3회 응답, 동일 시각의 중복/누락 0건을 확인했다. 마지막 실행에서 첫 페이지 JSON은 534,533바이트, 3페이지 함수 호출 전체는 181.74ms였다. 반환 범위와 fixture 실행 시간이며 물리 DB scan 행 수나 운영 네트워크 응답 시간은 아니다. 클라이언트의 최초 요약 1회는 별도 테스트로 확인했다.

## 운영 반영 순서와 남은 조건

1. 기존 변경을 보존한 검토 가능한 커밋을 구성하고 해당 pushed SHA의 필수 GitHub Actions 검증을 통과한다. 작업 시작 당시 이미 다수의 미커밋 사용자 변경이 있었으며 이를 임의로 commit/push하지 않았다.
2. 계좌 → 계산서 원장 계약 → 매출 요약/페이지 순서로 세 마이그레이션을 운영 절차에 따라 적용한다. 실제 선행 함수의 anchor가 다르면 마이그레이션은 중단된다.
3. `scripts/deploy_pos_production.sh`로 POS와 변경된 dispatcher를 정식 반영하고 연결된 자동화 소스 버전을 함께 검증한다. 설치 앱의 배포는 기존 자동화 배포 절차를 따른다.
4. 회계 담당자가 실제 SKU 명칭·판매 단위와 적용일을 승인한다. 과거 미발행 거래는 해당 거래일을 포함하는 첫 승인 이력이 필요하다. 실제 원장/영수증 수치와 비교한 뒤 화면에서 미발행 작업을 명시적으로 재검증한다.
5. 운영 화면에서 법인 계좌·새 QR·수동 Photo 등록·현금 마감·다음날 입금액, 선택 법인의 Excel/원장 명세를 확인한다. 실제 MISA 가져오기/미리보기와 과거 작업 재개는 읽기 검증을 먼저 완료한다. 기발행 원본은 보존하고 필요한 정정은 별도 절차로 처리한다.

프로젝트 `CLAUDE.md`의 릴리스 조건: “The release gate passes only when required GitHub Actions checks succeed on the exact pushed head SHA.” 로컬 검증은 이 조건을 대신하지 않는다. 현재 보고서의 완료 범위는 소스 구현과 위 로컬 검증이다.

관련 계획: [POS 수정 계획](/Users/andreahn/Documents/Codex/2026-09-12/files-pasted-by-the-user-full-2/outputs/akj-automation/reports/01-pos-improvement-plan-2026-10-11.md) · [자동화 수정 계획](/Users/andreahn/Documents/Codex/2026-09-12/files-pasted-by-the-user-full-2/outputs/akj-automation/reports/02-automation-improvement-plan-2026-10-11.md) · [기발행 정정 절차](/Users/andreahn/Documents/Codex/2026-09-12/files-pasted-by-the-user-full-2/outputs/akj-automation/reports/03-issued-invoice-correction-procedure-2026-10-11.md)

배포 후보와 원자적 적용 순서는 [배포·필수 CI 준비 기록](POS_CORPORATE_RELEASE_PREPARATION_2026_10_11.md)을 따른다. 이 후보는 기존 14시 마이그레이션 번호 충돌을 피한 새 번호와 단일 트랜잭션 패키지를 사용한다.
