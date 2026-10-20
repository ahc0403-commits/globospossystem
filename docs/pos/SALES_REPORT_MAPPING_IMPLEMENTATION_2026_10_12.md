# POS 매출신고 매핑 개선 구현 기록

2026-10-12 / Asia/Ho_Chi_Minh. **소스 구현·운영 DB 적용·POS 웹 배포 완료.**

[계획](SALES_REPORT_MAPPING_IMPROVEMENT_PLAN_2026_10_12.md)을 기준으로 구현했다. MISA 접속·가져오기·발행·전송·이메일 시험은 제외했다. 자동화 프로젝트와 운영 원본 XLSX는 변경하지 않았다. 기존 사용자 수정 위에 이번 변경을 추가했으며, 적용 대상 기존 파일의 시작 시점 사본을 `/tmp/pos-sales-20261012-baseline/`에 보존했다. 전역/프로젝트 지침을 읽었고 수정 경로의 추가 하위 지침 파일은 없었다.

## 적용한 동작

- 공통 XLSX: A 텍스트, 첫 품목만 B:J, 다음 행 실제 공란. 17열/8행 헤더, 품목 원순서, VAT와 공급가액 유지. 읽기 전용 파서가 전체 자료를 읽도록 worksheet dimension도 수정했다.
- 메뉴·물티슈: 개별 및 일괄 승인, 매장/법인 제한, 기간·버전·근거·실제 승인 ID 전달. 유형 승인은 메뉴 ID를 만들지 않는다. 73개 메뉴+물티슈 초기 JSON은 사용한 파일의 원문과 하루 적용기간을 그대로 보존한다. 소스 구현 당시에는 운영 DB 등록 전이었다. 이후 정식 배포로 초기 승인 74건을 등록했다.
- SQL/RPC/모델/파일: 승인 유형·ID·버전·기간·매장·근거와 원품목 ID, 원본 단가, 계산서 단가·할인을 보존한다. Photo는 기존 수동 입력·서비스 계약을 유지한다.
- 저장 전 검증: 기본 수량 1/금액 0/추정 세율을 제거했다. 모든 품목의 오류를 영수증·품목·필드별로 반환하고 화면에서 페이지로 표시한다. 저장 호출 전에 중단하는 화면 시험을 추가했다.
- 미발행 재검증: 저장된 v2+를 다시 사용하지 않고 판매 원본과 판매시각 승인을 읽는 별도 함수로 재조립한다. 이전 버전 보존, 동일 내용 무변경, 보호/오류/동일/갱신 건수와 영수증별 사유를 반환한다.
- 과거 보호: 제공된 완료 보고를 출처·SHA-256·미검증 외부 보고 상태로 보존한다. 10/11 AKJ 569건을 보수적으로 보호하고 임의 MISA 식별자나 성공 상태를 만들지 않는다. 버전 변경 트리거와 claim 필터에서도 보호한다.
- 집계/명세: 영수증·원품목·출력 행 수를 구분하고 소수 원장 금액과 품목별 HALF_UP 반올림 예상액/차이를 표시한다. 생성 ID·내용 해시·실제 파일 SHA-256 명세를 제공한다.
- 조회: 100건 keyset 및 최대 2개 원본 스트림 유지. 페이지 전진·중복·범위 검사, 세션별 진행 중 조회 공유, 승인 revision과 원본 fingerprint 비교를 추가했다. 원본 후보에 날짜·가능한 법인 매장·커서를 밀어 넣고 실제 실행계획을 확인했다.

## 파일

| 구간 | 파일 |
|---|---|
| 공통 생성/검증 | `lib/features/admin/einvoice_misa_workbook.dart`, `sales_export_validation.dart` |
| 개별/일괄 승인 | `lib/features/admin/widgets/invoice_profile_editor.dart`, `invoice_mapping_import_dialog.dart`, `lib/features/restaurant_sales_export/invoice_mapping_service.dart` |
| 모델/서비스/화면 | `lib/features/restaurant_sales_export/{restaurant_sales_export,combined_sales_export,daily_sales_summary,daily_sales_report_service,restaurant_sales_export_screen}.dart` |
| Photo 연결 | `lib/features/photo_sales_import/{photo_sales_import,photo_sales_registered_export}.dart` |
| 새 DB 계약 | `supabase/migrations/20261012010000_sales_invoice_mapping_contract.sql`, `20261012020000_sales_export_page_contract.sql` |
| 초기 매핑/인계 | [초기 승인 JSON](invoice_mapping_initial_20261011.json), [XLSX v3 수신 계약](SALES_XLSX_V3_CONTRACT.md) |

적용된 과거 마이그레이션은 수정하지 않았다. 물리 `restaurants`와 매장 연결 FK, 결제/VAT 마스터, 운영 배포 플래그, 포토 자동 수집 설정은 변경하지 않았다.

## 로컬 확인

- 관련 Flutter 시험, 전체 `dart analyze --fatal-infos`, Docker 소유 임시 DB의 실제 마이그레이션/RPC/trigger/claim 시험을 실행했다.
- 9품목/10수량 기준 영수증, 91개 결제 조합, 일반·사업자 연락처, 할인, 물티슈, 8%/10% 콤보, Photo, 누락 숫자/NaN/기간/타매장/중복, 파일 저장 전 오류, 이전 버전 보존/재실행/claim/발행/수동 완료 보호를 검사했다.
- 10/11 수정 파일의 숫자만 읽어 익명 영수증/품목으로 만든 로컬 대조에서 **569건/1,034행/연속 공란 465행**, 수량·단가·공급가액·세율·VAT 전체 일치를 확인했다. 원장 **71,213,724.81**, 품목별 반올림 **71,213,723**, 차이 **1.81 VND**. 원본 파일이나 실제 신고는 재처리하지 않았다.
- 합성 1배/10배 시험은 각각 569/5,690 영수증, 1,034/10,340 출력 행이다. SQL에서는 8개의 콤보 분할을 포함해 원품목 수 1,026/10,260도 별도 확인했다.

최종 관련 Flutter 시험 **82개 통과**, 전체 Dart 정적 분석 **오류 없음**, SQL harness **PASS**. [기계 판독 검증 결과](sales_mapping_local_verification_20261012.json)에 최종 성능 수치와 대조 결과를 기록했다.

## 성능 해석과 운영 반영 조건

RPC 동등 호출 수는 기본 규모 8회, 10배 59회다. SQL 시험은 단일 임시 DB의 호출 시간이며 네트워크·운영 장비 성능은 포함하지 않는다. 첫 식당 페이지는 해당 일자의 후보 1,050건을 읽고 100건을 반환했다. Photo 후반 커서는 인덱스로 남은 140건을 읽고 100건을 반환했다. LIMIT을 실제 읽은 행 수로 표현하지 않는다.

원본 fingerprint는 동시 수정 감지를 위해 각 페이지에서 선택 일자·법인의 원본을 일괄 집계한다. 추가 RPC나 품목별 조회는 없지만 하루 범위를 재읽는 비용이 있으며, 최종 SQL 성능 시험에 포함했다. 대규모 조회가 더 늘면 변경 revision을 원본 트랜잭션과 연동하는 후속 최적화가 필요하다.

XLSX 생성은 메모리에 전체 파일을 보유한다. 10배 시험의 프로세스 최대 RSS는 약 1 GiB였고, Flutter 시험 실행기·fixture·인코딩·재읽기 객체를 포함한다. 작은 운영 단말의 메모리 적합성을 확인한 수치는 아니다. 스트리밍/별도 worker 전환은 아직 하지 않았다.

새 RPC 화면과 DB 마이그레이션은 운영에 함께 반영했다. 소스 구현 단계에서는 운영 승인 데이터 등록, `scripts/check_repo.sh` 전체 배포 검사, 정식 `scripts/deploy_pos_production.sh`의 pushed SHA/GitHub 게이트 및 운영 배포는 이번 소스 구현에서 실행하지 않았다. 자동화 소비자의 첫 행 상속/새 명세 지원은 위 수신 계약을 인계해야 한다.


## 운영 반영 완료

2026-10-12 사용자 요청으로 운영 DB 마이그레이션 3건과 초기 승인 74건을 정식 게이트로 적용했고, main `4c8e1b4e`를 운영 웹에 배포했다. 전체 검사·정확한 SHA의 GitHub 검사·운영 로그인 확인 및 원본 보존 해시 비교가 통과했다. [운영 반영 기록](SALES_REPORT_MAPPING_PRODUCTION_2026_10_12.md)을 참조한다. 초기 승인은 10/11 하루이며 MISA 외부 검증은 제외했다. 앞선 문단의 미실행 항목은 소스 구현 당시의 기록이다.
