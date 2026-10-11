# 일반 영수증 연락처·결제 신고 매핑 보완 결과

확인일: 2026-10-11. 사용자의 “계획대로 진행해. 배포는 금지” 지시에 따라 **POS·자동화 소스 수정과 로컬 검증을 완료**했다. 운영 DB, 운영 POS, 설치된 자동화 앱에는 이번 변경을 반영하지 않았다. 실제 MISA 가져오기·발행·신고·고객 이메일 발송도 실행하지 않았다.

## 반영한 변경

### 일반 영수증의 연락처

일반 소비자 영수증도 원장에 이메일·전화번호가 있으면 계산서 작업의 `buyer_snapshot`과 MISA 엑셀 G/H열에 보존한다. 정보가 없으면 공란을 허용한다. 전화번호는 문자열로 출력해 앞자리 0을 유지한다. 사업자 계산서에 적용하던 별도 필수 정보 검증은 그대로 둔다.

네이티브 계산서 생성기는 기존에도 `buyer_snapshot`의 이메일을 `BuyerEmail`, `ReceiverEmail`에 전달하고 이메일이 있을 때만 `IsSendEmail=true`를 설정한다. 이 경로를 수정할 필요 없이 일반 영수증의 이메일+전화, 이메일만, 전화만, 공란 네 경우를 추가 검증했다. 자동화의 이메일 대상 수 역시 각각 1/1/0/0이다. 이는 발송 대상을 판별한 결과이며 실제 발송 결과가 아니다.

서버 원장 조회의 연락처 선택은 다음과 같다.

- 편집 가능한 intake가 있으면 그 연락처를 사용한다. 명시적으로 지운 이메일을 옛 작업 스냅샷에서 다시 채우지 않는다.
- intake가 없으면 기존 작업의 연락처 스냅샷을 사용한다. 새 고객 정보를 추정하지 않는다.
- 발행 완료, MISA 식별자 존재, dispatch claim 또는 발행 시도가 있는 작업은 보관된 연락처를 사용한다.

연락처도 원본 해시 계산과 스냅샷 변경 감지에 포함한다. 아직 발행 시도가 없는 작업을 명시적으로 재검증하면 이전 `buyer_snapshot`을 다른 스냅샷 필드와 함께 보관하고 버전을 증가시킨다. 같은 내용으로 재검증하면 변경 건수 0이며 불필요한 버전을 만들지 않는다. 이미 발행·claim된 작업의 연락처 변경은 차단한다. 기존 이력에 보관하지 않았던 연락처는 복원할 근거가 없어 새 이력 열을 NULL로 둔다.

### 빠진 여섯 결제 방식

SQL, Dart 엑셀, 네이티브 payload 전달, 자동화 원장 검증에서 다음 의미를 일치시켰다. 자동화 매핑 버전은 `pos-payment-v3`다.

| POS 원장 코드 | 명세 분류 | 계산서 결제 표기 | 처리 기준 |
|---|---|---|---|
| MOMO, ZALOPAY, SHOPEEPAY | EWALLET | Ví điện tử | 실제 지갑 구분은 원장 결제 목록에 보존 |
| VNPAY | GATEWAY | VNPAY | 현재 원장에 실제 자금 경로가 없어 제공자 이름을 유지 |
| VOUCHER | VOUCHER | Voucher | 원장에 기록된 지급 수단을 유지하며 새 할인으로 계산하지 않음 |
| CREDITSALE | CREDITSALE | Chưa thu tiền | 외상·미수 구분을 유지하며 현금 수금으로 집계하지 않음 |

기존 CASH/TM, BANKTRANSFER/CK, CREDITCARD/Thẻ quốc tế, ATM/Thẻ ATM과 기존 E-Pay 별칭도 유지한다. 현금+이체는 `TM/CK`, 다른 혼합 결제는 실제 구성의 표기를 일정한 순서로 결합한다. 서로 다른 지갑의 표시 문자열이 같아도 원장 명세와 `POS Ledger`에는 실제 결제 코드들을 남긴다. 미분류 QR·SERVICE·알 수 없는 결제 코드는 계속 차단한다.

자동화는 원장의 결제 코드·실제 결제 구성·계산서 문자열을 독립적으로 대조한다. 단순히 엑셀의 문자열을 명세로 복사해 검증을 통과시키지 않는다. 잘못된 현금·은행이체 표기나 원장의 분류 코드 불일치는 가져오기 전에 중단한다.

**VNPay의 실제 자금 경로와 VNPAY/Voucher/Chưa thu tiền 및 혼합 문자열의 실제 MISA 가져오기 수용 여부는 운영 연결로 확인하지 않았다.** 이번 로컬 계약은 결제 의미를 보존하는 구현이며 MISA 실연동 완료를 뜻하지 않는다.

### 금액·세율·다음날 입금액

**콜라 10%·환타 8%를 유지했다. 음료 마스터 세율이나 세율 계산기를 변경하지 않았다.** 판매 당시 수량·공급가액·VAT·총액과 할인 표현을 그대로 사용한다.

다음날 매출 입금액은 기존 구현대로 등록된 Photo 매출 총액+레스토랑 CASH의 실제 결제 부분 금액이다. 계좌이체는 별도로 표시한다. 지갑·VNPay·Voucher·Credit Sale 금액을 현금 입금액에 더하지 않는다. 여섯 신규 방식과 현금의 혼합 결제 시험에서도 현금 부분만 합산됐다. 법인 수금 계좌 및 Photo 수동 등록 경로에는 이번 보완으로 새 변경을 넣지 않았다.

## 검증 결과

| 범위 | 결과 |
|---|---|
| 수정 기능 Flutter | 25개 통과: 연락처 4조건, 13개 단독 별칭·78개 혼합 조합, 실제 엑셀, 기준 거래 |
| 관련 Flutter 회귀 | 34개 통과: 결제 계약, Photo 등록, 계산서 화면·기반·구매자·dispatch 계약 |
| Dart 정적 분석·포맷 | 변경 관련 5파일 문제 없음, 포맷 변경 필요 없음 |
| 원장·연락처·매핑 SQL | 소유한 일회성 Docker DB에 실제 선행·신규 마이그레이션을 적용해 PASS |
| 음료 세율 SQL 회귀 | PASS: 기존 메뉴·혼합 세트·할인·부분 결제·권한 시나리오 포함 |
| 네이티브 MISA payload | 15개 통과, dispatcher `deno check` 통과, TS 포맷 검사 통과 |
| 자동화 전체 | **513개 통과, skip 0개, 125.30초** |
| Dart→Excel→자동화 | 실제 Dart 생성 엑셀 91개와 독립 원장 명세를 대조해 모든 단독·두 방식 혼합 조합 통과 |

기준 거래 BC-20261008-023320과 같은 합계를 가진 합성 자료에서 **메뉴 9행·수량 10개·공급가액 406,000·VAT 33,560·총액 439,560 VND·CK·콜라 10%·환타 8%**를 확인했다. 원래 품목 ID/행 연결과 Photo 서비스 단위 예외도 보존됐다. 실제 운영 거래 재조회나 실무 메뉴 명칭 재승인 결과는 아니다.

SQL은 연락처 수정·원본 해시 변경·이전 버전 보관·공란 유지·변경 없는 재검증·발행본과 claim된 작업 보호·권한 제한을 확인했다. 추가 여섯 결제의 단독 및 CASH 혼합 12개 영수증에서도 품목 수·수량·VAT·총액을 대조했다.

페이지 성능은 합성 영수증 205건·품목 1,845행을 **100/100/5건, 3회 응답**으로 읽었다. 최종 실행의 첫 페이지 JSON은 **534,533바이트**, 세 응답 합계는 **1,095,919바이트**, 세 함수 호출 시간은 **224.18ms**였다. 기존 비교 보고서의 534,533바이트는 첫 페이지 측정값이므로 세 페이지 합계로 해석하지 않는다. 최초 요약 1회는 별도다. 이는 반환 범위 및 로컬 fixture 시간이며 운영 네트워크·물리 DB scan 행·MISA 시간은 측정하지 않았다.

새 연락처 선택 함수는 메모리 내 값만 다루며 영수증별 DB/RPC 조회를 추가하지 않는다. 원장 읽기는 선택 영업일·법인·최대 100개 ID 범위의 기존 배치 계약을 유지한다.

## 변경 위치와 재현

- [일반 영수증 연락처](/Users/andreahn/.codex/worktrees/corporate-sales-release-prep/globos_pos_system/lib/features/restaurant_sales_export/restaurant_sales_export.dart:566)
- [Dart 결제 문자열](/Users/andreahn/.codex/worktrees/corporate-sales-release-prep/globos_pos_system/lib/features/admin/einvoice_misa_workbook.dart:354)
- [로컬 전용 신규 마이그레이션](/Users/andreahn/.codex/worktrees/corporate-sales-release-prep/globos_pos_system/supabase/migrations/20261011203000_invoice_contacts_payment_methods.sql)
- [공통 결제 기대값](/Users/andreahn/.codex/worktrees/corporate-sales-release-prep/globos_pos_system/test/fixtures/invoice_payment_contract.json)
- [SQL 시나리오](/Users/andreahn/.codex/worktrees/corporate-sales-release-prep/globos_pos_system/test/sql/invoice_contacts_payment_methods_test.sql)
- [자동화 결제 계약](/Users/andreahn/Documents/Codex/2026-09-12/files-pasted-by-the-user-full-2/outputs/akj-automation/akj/invoice_payment_contract.py)
- [자동화 검증 시나리오](/Users/andreahn/Documents/Codex/2026-09-12/files-pasted-by-the-user-full-2/outputs/akj-automation/tests/test_invoice_contacts_payment_methods.py)

실제 Dart 파일 대조는 `GLOBOS_CONTACT_PAYMENT_OUTPUT`에 로컬 출력 디렉터리를 지정해 `test/corporate_sales_reference_test.dart`를 실행한 뒤, 같은 변수를 자동화 pytest에 전달한다. 기존 기준 파일 대조에는 `GLOBOS_REFERENCE_OUTPUT`으로 생성한 엑셀을 `GLOBOS_REFERENCE_WORKBOOK`, 원본 합성 JSON을 `GLOBOS_REFERENCE_SOURCE`로 전달했다. 공통 매핑 대조에는 `GLOBOS_PAYMENT_CONTRACT`로 위 기대값 JSON을 전달했다. SQL 재현 명령은 `bash test/corporate_sales_export_sql_test.sh`이며 운영 자격 증명·호스트 포트를 사용하지 않는다.

## 현재 반영 상태

**배포 금지 상태를 유지한다.** 신규 마이그레이션은 로컬 테스트 DB에만 적용됐다. POS 배포, 운영 스냅샷 재검증, 설치 자동화 앱 교체, 예약 변경, 실제 신고·발송을 수행하지 않았다. 다수의 기존 미커밋 변경을 보존했고 commit/push하지 않았다.

향후 별도로 운영 반영이 허용될 때는 기존 14:00→15:00→16:00 마이그레이션 이후 이 17:00 마이그레이션과 POS·자동화 버전을 함께 반영해야 한다. 설치 앱은 이번 자동화 소스 수정과 아직 일치하지 않는다. 기존 미발행 작업도 날짜·법인·선택 영수증 범위를 지정해 명시적으로 재검증해야 하며 설정 변경만으로 수정 완료 처리하지 않는다. 이후 실제 MISA 가져오기/미리보기에서 새 결제 표기·연락처·메뉴·금액을 확인하는 단계가 남아 있다.

이번 결과는 운영 배포 준비 완료나 실제 신고 완료를 선언하지 않는다. 사용자의 배포 금지 때문에 위 운영 작업은 실행 범위에서 제외했다.

관련 문서: [기존 구현 결과](/Users/andreahn/.codex/worktrees/corporate-sales-release-prep/globos_pos_system/docs/pos/CORPORATE_COLLECTION_SALES_EXPORT_2026_10_11.md) · [이번 보완의 근거가 된 비교 보고서](/Users/andreahn/Documents/Codex/2026-09-12/files-pasted-by-the-user-full-2/outputs/akj-automation/review/2026-10-11/pos-automation-comparison.md)

배포 후보와 원자적 적용 순서는 [배포·필수 CI 준비 기록](POS_CORPORATE_RELEASE_PREPARATION_2026_10_11.md)을 따른다. 이 후보는 기존 14시 마이그레이션 번호 충돌을 피한 새 번호와 단일 트랜잭션 패키지를 사용한다.
