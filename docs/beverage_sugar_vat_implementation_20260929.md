# 음료 당류 VAT 구현 기록

작성일: 2026-09-29. 최초 구현 기준: `cc4de81a` + 기존 작업 변경 사항.
배포 준비: 별도 worktree에서 최신 main `c2633f01`에 음료 VAT 변경만 이식했다. 기존 작업 폴더는 보존했다.

| 상태 | 결과 |
|---|---|
| 소스 구현 | 완료 |
| 격리 DB migration 적용·검증·복원 | 완료 |
| 운영 DB migration 적용 | 미실행 |
| 앱 운영 배포 | 미실행 |
| 운영 결제·실제 MISA 전송 검증 | 미실행 |

## 구현 범위

- 메뉴 추가·수정에 음료 당류 분류, 라벨 총당류(g/100ml), 분류 근거와 적용 VAT 표시를 추가했다. 한국어·베트남어·영어를 지원한다.
- 대상 청량음료는 **5g/100ml 초과 10%, 이하 8%**다. 정확히 5.00은 8%다. 법적 범위와 공식 출처는 [계획서](beverage_sugar_vat_improvement_plan_20260929.md)에 기록했다.
- 정확한 숫자가 없으면 구간과 근거를 함께 입력한다. 숫자와 분류의 충돌, 음수, 비정상 숫자, 권한 밖 변경은 거부한다. 주류와 콤보 부모에 음료 당류 분류를 중복 적용하지 않는다.
- 기존 `food/alcohol` 업무 분류는 보존한다. `effective_vat_rate`는 서버가 산출하며 클라이언트에서 임의 세율을 저장하지 않는다.
- 메뉴 Excel에 `음료당류분류`, `총당류(g/100ml)`, `세금분류근거` 열을 추가했다. 분류 값은 `not_applicable/lte_5/gt_5`다. 구버전 파일이나 세금 열이 모두 빈 행은 기존 설정을 유지한다.
- 주문 당시 세율을 `vat_profile_snapshot`에 고정한다. 메뉴 수정 후 부분 결제도 원래 세율을 유지한다. 직접 주문은 요청 시점부터 견적·결제 승인까지 세율을 보존한다.
- 콤보는 주문 당시 구성품 단품 가격 × 수량 비율로 메뉴 금액을 배분한다. 정상 가격 비율을 기본안으로 채택했고 별도 회계 배분 가격은 추가하지 않았다. 선택 음료와 고정 구성 콤보를 모두 처리한다.
- 결제 예상액, 서버 결제, 자동 프로모션 할인 기준/배분액, 서비스차지를 같은 세율 기준으로 계산한다. 두 자리 소수 금액과 결정적인 잔여액 배분을 유지한다.
- 혼합 콤보의 최종 공급가·VAT·합계를 `vat_breakdown`에 저장한다. 내부 부모 `vat_rate=-1`은 MISA enqueue·일별 export·Red Invoice 원장 fallback에서 실제 8%/10% 행으로 확장한다.
- 결제 함수의 기존 래퍼와 비수익 결제 동시성 처리, MISA 비동기 처리, 발행된 증빙을 보존한다. 완료된 과거 주문은 소급 재계산하지 않는다.

## 분식클럽 메뉴 조정

운영 DB를 읽기 전용으로 확인했다. BunsikClub Binh Thanh와 BunsikClub SAMPLE에 각각 5개 메뉴가 있으며 모두 `food` 분류, 단가 18,000 VND, VAT 별도 가격 방식이었다.

| 메뉴 | 기존 계산 | 적용 목표 | 대상 수 |
|---|---:|---:|---:|
| Coca-Cola | 8% | 10% | 2 |
| Strawberry Sting | 8% | 10% | 2 |
| Coca-Cola Zero | 8% | 8% | 2 |
| Fanta Orange | 8% | 8% | 2 |
| Sprite | 8% | 8% | 2 |

`20260929020000_bunsik_beverage_vat.sql`은 매장 ID와 메뉴 ID 10개를 고정한다. 이름·상태·기존 분류가 예상과 다르면 중단한다. 정확한 당류 숫자는 NULL로 두고 사용자 확인 근거를 기록한다. 가격과 업무 분류는 변경하지 않는다.

대상 매장에 미완료 POS 주문이 있으면 적용을 거부한다. 진행 중 직접 주문 요청은 기존 세율 스냅샷이 유효할 때만 보존한 채 전환하며, 취소·재계산하지 않는다. 변경 전 데이터를 전용 백업 테이블과 감사 로그에 남긴다.

## 핵심 파일

- `lib/core/payments/beverage_tax.dart`, `vat_allocation.dart`, `payment_total_calculator.dart`
- `lib/features/admin/widgets/beverage_tax_editor.dart`, `tabs/menu_tab.dart`
- `lib/core/services/menu_service.dart`, `lib/features/admin/providers/menu_provider.dart`
- `lib/features/admin/menu_import/menu_excel_import.dart`, `menu_excel_roundtrip.dart`
- `lib/features/payment/payment_provider.dart`, `lib/l10n/app_{ko,vi,en}.arb`
- `supabase/migrations/20260929010000_beverage_sugar_vat.sql`
- `supabase/migrations/20260929020000_bunsik_beverage_vat.sql`
- `scripts/{preflight,verify,rollback}_{beverage_sugar_vat,bunsik_beverage_vat}.sql`
- `test/beverage_sugar_vat_test.dart`, `test/beverage_sugar_vat_sql_test.sh`, `supabase/tests/beverage_sugar_vat_test.sql`

## 검증

- 전체 정적 분석: 통과.
- 전체 Flutter 테스트: **1,599 통과, 94 건너뜀, 실패 0**.
- 당류 0/4.99/5.00/5.01 경계, 잘못된 입력, 메뉴 수정 원자성, 권한 거부, Excel 왕복 및 구버전 보존: 통과.
- 8%/10% 혼합 200,000 공급가 → 218,000 결제; 10% 할인 → 196,200 결제/16,200 VAT; 서비스차지 5% → 228,900 결제: Flutter 및 SQL 검증 통과.
- 실제 SQL 결제·프로모션 함수로 부분 결제, 메뉴 변경 후 세율 보존, 콤보 분할 증빙 및 서비스차지를 검증했다. 직접 주문은 실제 견적 함수와 요청 스냅샷·승인 시 이관을 검증했다.
- 두 migration 및 preflight/verify/rollback을 소유한 일회용 PostgreSQL 컨테이너에서 적용·검증·복원했다. 운영 DB에는 적용하지 않았다.
- 운영 함수의 **52개 변경 지점**을 읽기 전용 문자열 교체 시뮬레이션으로 확인했으며 불일치는 0개다. 실제 배포 시에도 예상 코드와 다르면 migration이 원자적으로 실패한다.
- `scripts/check_repo.sh`는 Flutter 검사 이후 메뉴 SQL 테스트 DB의 초기 생성 경쟁으로 1회 중단됐다. 해당 단계 재실행이 통과했고, 스크립트의 나머지 단계도 별도로 실행해 모두 통과했다. 단일 연속 실행 성공으로 보고하지 않는다.
- 추가 SQL/API, 프로모션, 성능 인덱스, 직접 주문 Edge, Node·보안 스캔, 배포 셸 계약 및 기존 VAT 무결성 검사: 모두 통과.
- `flutter build web --release`: 통과. 기존 Wasm 호환성·Cupertino 폰트 경고는 남아 있다.
- `git diff --check`, `git show --check --format= HEAD`, 새 SQL 테스트 셸 구문 검사: 통과.

로컬 실행 로그: `/tmp/beverage_check_repo.log`, `/tmp/beverage_menu_sql_retry.log`,
`/tmp/beverage_check_repo_remaining.log`, `/tmp/beverage_sql_tests.log`, `/tmp/beverage_web_build.log`.

실제 QR/직접 주문의 전체 운영 UI 흐름, 물리 영수증, 외부 MISA 발행 성공은 배포 후 검증 대상이다. 테스트 fixture의 부분 테이블/권한 모의와 실제 운영 연동을 동일시하지 않는다.

## 적용 순서와 복원

1. 기존 작업 변경을 보존하면서 배포할 소스를 확정하고, 정확히 pushed head SHA의 필수 GitHub Actions `POS release contract` 성공을 확인한다.
2. 공식 `scripts/deploy_pos_production.sh`로 `20260929010000_beverage_sugar_vat.sql`과 앱을 배포한다. 주문 유입을 멈춘 전환 시점에 기존 클라이언트 세션을 갱신한다.
3. 대상 매장 미완료 POS 주문이 없고 기존 직접 주문의 세율 스냅샷이 유효한 것을 확인한 후 같은 스크립트의 `--db-only --migration supabase/migrations/20260929020000_bunsik_beverage_vat.sql` 경로로 상품별 분류를 적용한다.
4. 적용 후 verify SQL, 매장별 세율, 새 주문의 8%/10% 혼합 결제, 콤보, 자동 할인, 영수증과 MISA 증빙을 확인한다.

메뉴 복원은 이후 주문에 대한 설정만 되돌리고 이전 주문/증빙을 보존한다. 이후 관리자 편집이 있으면 복원을 거부한다. 기능 복원은 새 세금 스냅샷을 사용하기 전만 허용하며, 사용 후에는 기록을 이해하는 코드와 스키마를 유지한 상태에서 후속 수정을 적용한다.

원래 작업 폴더에는 이 작업 전부터 다수의 미커밋 변경이 있다. 배포 작업은 별도 worktree에서 수행하며 원래 폴더 146개 변경 파일의 보존 해시를 기록했다. 원래 폴더를 임의로 커밋·정리하거나 배포 게이트를 우회하지 않는다. 로컬 검사 성공은 운영 release gate PASS를 의미하지 않는다.
