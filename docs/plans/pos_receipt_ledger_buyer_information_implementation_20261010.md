# POS 영수증 원장 · 구매자 정보 구현 보고서

> 이 문서는 당시 소스 검증 기록이다. 최신 main 통합·운영 적용 절차와 API 버전은 [통합 배포 문서](../pos/POS_RECIPIENT_TAX_BOUNDED_RELEASE_20261011.md)를 참조한다.
2026-10-10 · 로컬 소스/검증 완료 · 운영 DB 미적용 · 미배포

현재 채팅의 배달비·첨부·영수증 개선과 별도로 전달받은 POS 원장 계획을 구현했다. 신규 MISA 조회·전송·발행·정정·상태 관리·포털 연결 기능은 추가하지 않았다. 기존 결제와 비동기 외부 연동 계약은 유지하며, 새 구매자 수정 RPC는 POS 정보만 저장한다.

## 구현 결과

| 범위 | 구현 |
| --- | --- |
| 진입·집계 | 매출신고의 일반/빨간 영수증 카드 클릭으로 해당 원장 열기. 선택한 HCM 날짜·법인·Restaurant 기준 유지. 전체 합계의 Photo 포함과 두 카드의 Restaurant 기준을 구분. 샘플 제외, 기존 super-admin 보고서 권한 유지. |
| 목록 | 실제 영수증 번호·시각·매장·결제수단·공급가·VAT·결제액. 이미 보고서/Excel을 위해 받은 목록을 재사용해 검색·정렬·50건 페이지 처리. 실제 번호가 없는 이력은 기존 POS 번호 규칙으로 표시. 보고서 receipt_id는 order UUID이며 결제 ID와 구분. 합산 결제 번호가 같아도 기존 보고서의 주문별 집계 단위를 바꾸지 않음. |
| 상세 | 기존 저장 품목·수량·단가·세금, 실제 결제 ID별 지급액/수단/시각. 회사명·번호 유형/원본·구매자명·주소·전화·이메일/CC·단위코드·구매자 ID·메모·증빙을 확인. PC 큰 창, 모바일 전체 화면. |
| 번호 | VN 세금코드, 개인사업자 대표 ID, 일반 개인 CCCD, 외국 세금번호, 여권/외국 개인 ID를 구분. 문자열과 선행 0 보존. 숫자 길이·문자·하이픈·확장번호 001~999 검사. 추정 체크섬/공식 등록 확인을 구현하지 않음. |
| 공통 양식 | 캐셔 즉시 정보 등록, 관리자의 기존 정보/증빙 편집, 직접주문 상담, 원장 상세에 같은 양식 사용. KO/VI/EN 오류, 잘못된 번호의 현재 길이와 하이픈 전후 길이 표시, 저장/엔터 시 해당 필드 검증·번호 포커스. 캐시 자동완성은 기존 기능을 유지하며 등록 확인으로 표현하지 않음. |
| 기존 데이터 | 잘못된 기존 번호는 변경하지 않고 원본과 오류 표시. 사용자가 유형/번호를 확인해 수정. 캐셔의 정보 나중에 받기와 관리자 미확정 저장 경로 유지. 미확정 정보는 결제 완료를 막지 않음. |
| 수정 | 저장/취소·선택 필드 사전 입력. 생략된 선택 필드와 증빙 보존, 명시적 필드 비우기 지원. 매장 접근 검사와 buyer_version으로 동시 수정 거절. 새 저장은 결제/품목/판매자/외부 발행 상태를 바꾸지 않음. 원장 저장은 구매자 정보를 확정하며 미완성 정보는 기존 관리자 접수 화면에서 보류 가능. |
| 직접주문 | 연결된 POS 접수와 request 원본을 같은 트랜잭션에서 갱신. 이후 재동기화와 구 5필드 클라이언트가 선택 정보/번호 유형을 지우지 않도록 보호. 연결 영수증들의 새 버전을 한 저장 응답으로 반환해 해당 캐시만 갱신. |
| 접근·회귀 | 새 Photo 구매자 등록 차단, Photo 매출 합계/일반 Excel 경로 유지. 일반 음식 결제에 번호 입력이나 MISA 응답을 요구하지 않음. 기존 동결 세금/품목 snapshot과 발행 이력 보존. |

## 조회·저장 비용

- 원장 페이지는 `pos_receipt_ledger_batch` 1회, 최대 50건. 상세 열기는 0회, 구매자 저장은 `pos_save_buyer_information` 1회. 응답에서 상세와 결제 내역을 같이 받으며 선택 필드 수정 후 전체 날짜를 다시 조회하지 않는다.
- 화면별 캐시는 로그인 세션·날짜·법인·종류·정확한 주문 ID 페이지로 분리, 60초 만료, 최대 20페이지. 같은 요청 공유, 검색 250ms 지연, 읽기 동시 실행 1개, 대기 중 지나간 조회 취소. 로그인 변경 시 이전 원장 상세 재사용 차단.
- 실제 사용 중인 보고서의 LATERAL 최신 작업/법인 이력/품목 집계와 영수증별 결제수단 함수 호출을 집합 기반 CTE·사전 집계·config JOIN으로 교체. 기존 최신 결제일, 분할결제 금액, 판매자 snapshot 우선순위, VAT/품목, 최종 확정 상태 및 샘플/Photo 제외 유지.
- 최초 매출신고/Excel 보고서가 이미 전체 날짜 데이터를 받는 계약은 유지했다. 새 상세 메타데이터를 날짜 전체에 붙이지 않고 해당 50건만 받는다. 서버 상세 권한/날짜/법인/일반·빨간 구분/중복·개수 재검증 후 반환한다.

## 검증

| 검사 | 결과 |
| --- | --- |
| 앱/테스트 정적 분석 | `dart analyze --fatal-infos lib test` PASS, No issues found |
| 최종 기능 Flutter | 15개 파일 175 PASS + 별도 채팅/인쇄/PDF 5개 파일 28 PASS = 203 PASS, 0 실패 |
| 언어/다이얼로그 계약 | 새 다이얼로그 3개를 운영 테스트에 등록. 145개 진입점, 모바일, 200% 글씨, KO/VI/EN 번호 오류·취소·실패·선택 정보 검사 PASS |
| 구매자 SQL | 번호 유형/형식·선행 0·부분 패치·선택 정보/증빙·명시적 비우기·매장 권한·원본 동기화·잘못된 기존 번호 수정 PASS |
| 일반 결제 회귀 | 잘못된 기존 요청 번호가 있어도 음식 결제 완료 PASS. process_payment 정의 전후 MD5 동일 |
| 구매자 경합 | 두 독립 DB 세션의 동일 버전 저장에서 성공 1건/충돌 1건 PASS |
| 연결 영수증 | 직접주문 11개 주문 일괄 정보 갱신/각 수정 버전 반환/이후 동기화 PASS. 결제와 MISA 작업 행 전후 동일 |
| 배달·첨부 통합 | 기존 정책·채팅·출력·환불·조리·예약·배차 경합 통합 SQL PASS |
| 웹 release | 최종 소스 `flutter build web --release` PASS. 운영 업로드 없음. 기존 Wasm dry-run/Cupertino font 경고 남음 |
| 전체 저장소 | 전체 Flutter는 1,881 PASS / 94 SKIP / 5 FAIL. 변경 중 발견한 3건(새 필드 기대값·번역·진입점 등록)은 수정 후 관련 검사 PASS. 기존 생성 locale SHA와 Admin 10/9개 탭 테스트 이름의 불일치 2건 잔존. 전체 PASS로 보고하지 않음. |
| check_repo | 기존 감사 Dart 문서의 warning 1/info 3으로 정적 분석 단계 중단. 앱/테스트 정적 분석과 구분. 뒤 단계 모두 통과했다고 보고하지 않음. |

SQL은 자동 삭제되는 로컬 PostgreSQL fixture에서 실행했다. 운영 자격 증명이나 운영 데이터는 사용하지 않았다.

측정 로그: `/tmp/globos-ledger-sql-final.log`, `/tmp/globos-ledger-integrated-final.log`, `/tmp/globos-combined-feature-final.log`, `/tmp/globos-ledger-print-chat-final.log`, `/tmp/globos-ledger-static-final.log`, `/tmp/globos-ledger-web-final.log`, `/tmp/globos-ledger-flutter-full.log`, `/tmp/globos-ledger-check-repo.log`.

## 실제 크기·성능 측정

동일 로컬 fixture에서 1회 보고서 + 첫 페이지를 함께 측정했다. 각 주문은 1개 합성 품목이며 운영 서버 부하/네트워크 지연을 포함하지 않는다.

| 날짜 전체 주문 수 | 기존 보고서 응답 | 새 페이지 응답 | 보고서+첫 페이지 시간 |
| --- | ---: | ---: | ---: |
| 10 | 8,809 bytes | 2,218 bytes (10건) | 7.76 ms |
| 100 | 83,511 bytes | 10,698 bytes (50건) | 10.70 ms |
| 1,000 | 830,513 bytes | 10,698 bytes (50건) | 87.32 ms |

페이지 호출 함수 실제 카운터는 1회, 기존 영수증별 결제수단 함수 카운터는 0회다. 두 독립 세션의 동시 읽기는 각각 1회 호출과 50건 응답으로 PASS했다. Flutter 실제 위젯에서도 페이지 1회/상세 0회/저장 1회를 확인했다.

`EXPLAIN ANALYZE BUFFERS`는 외부 Function Scan과 내부 집합 SQL 모두 실행했다. 요청한 50개 주문의 지급·품목을 집합 집계하며 기존 인덱스 경로를 모사한 fixture의 실행 계획/버퍼/행 수를 로그에 남겼다. SQL 계획의 nested-loop/index scan은 엔진의 JOIN 처리이며 영수증마다 별도 RPC나 집계 함수를 실행하는 앱 구조와 구분한다. 실제 운영 실행 계획, 다품목·큰 증빙 metadata의 최대 응답, 클라이언트 heap과 운영 동시 접속 처리량은 측정하지 않았다.

## 변경 경로

- [530 구매자 정보/동기화](/Users/andreahn/globos_pos_system/supabase/migrations/20261010053000_pos_buyer_information.sql)
- [540 원장/보고서 일괄 조회](/Users/andreahn/globos_pos_system/supabase/migrations/20261010054000_pos_receipt_ledger.sql)
- [원장 UI](/Users/andreahn/globos_pos_system/lib/features/restaurant_sales_export/pos_receipt_ledger.dart), [조회/캐시 서비스](/Users/andreahn/globos_pos_system/lib/features/restaurant_sales_export/pos_receipt_ledger_service.dart)
- [공통 번호 검사](/Users/andreahn/globos_pos_system/lib/features/red_invoice_intake/buyer_number.dart), [공통 양식](/Users/andreahn/globos_pos_system/lib/features/red_invoice_intake/buyer_information_form.dart)
- [실제 위젯 렌더링 예시](/Users/andreahn/globos_pos_system/docs/plans/pos_receipt_ledger_preview_20261010.png): 합성 데이터, 실제 글꼴 로드. 화면 배치와 잘못된 원본 번호의 오류 표시를 확인했다. 운영 브라우저/매장 화면 확인과 구분.
- [앞서 구현한 배달비/첨부/영수증 보고](/Users/andreahn/globos_pos_system/docs/plans/direct_order_recipient_delivery_implementation_20261010.md)

번호 형식 근거는 [등록 세금번호 구조 문서](https://www.meinvoice.vn/wp-content/uploads/2026/07/TT90-2026-Dang-ky-thue.pdf)의 10자리·10자리-3자리/001~999, [개인사업자 12자리 안내](https://helpv4.meinvoice.vn/kb/misa-meinvoice-xu-ly-hoa-don-dap-ung-quy-dinh-su-dung-so-dinh-danh-ca-nhan-thay-cho-ma-so-thue-ap-dung-ho-kinh-doanh/), [일반 개인 CCCD와 사업자 번호 구분](https://helpv4.meinvoice.vn/kb/mot-so-van-de-lien-quan-den-lap-hoa-don-theo-nghi-dinh-254-2026-nd-cp/), [외국 구매자 안내](https://helpv4.meinvoice.vn/kb/xuat-hoa-don-cho-khach-le-ca-nhan-nguoi-nuoc-ngoai-nghi-dinh-254-2026-nd-cp/)이다. 이 근거를 POS 형식 검증에만 사용했으며 공식 등록 상태/외부 발행의 적법성 확인으로 표시하지 않는다.

운영 DB 마이그레이션 적용, 정확한 pushed HEAD의 GitHub Actions release gate, 운영 배포와 실제 매장 확인은 수행하지 않았다. 배포가 요청되면 기존 production runbook 및 deploy script 절차를 사용해야 한다.
