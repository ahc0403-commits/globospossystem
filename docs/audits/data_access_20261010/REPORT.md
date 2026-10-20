# 데이터 접근·갱신·메모리 집중 검증 — 2026-10-10

## 결론과 검증 범위

현재 작업 트리에서 전역 성능 지침에 어긋나는 경로를 확인했다. N+1 외에도 **화면에 필요하지 않은 이력 조회, 페이지 선택 전 전체 집계, 다른 매장 데이터 스캔, 중복 갱신과 무제한 요청 중첩, 영구 오류의 파일 재업로드, 압축 파일 전체 파싱 후 제한 검사**가 남아 있다.

- 기준: `/Users/andreahn/.claude/CLAUDE.md`의 데이터 접근·성능/검증 규칙과 루트 `CLAUDE.md`.
- 대상: Flutter 화면→provider/service→RPC, 현재 유효 SQL 정의, Edge dispatcher/helper. 마이그레이션 순서와 실제 호출자를 대조했다.
- 소스 목록·해시는 1,642개 파일을 수집했다. 이는 조사 기준선이며 모든 파일의 모든 분기를 동적 검증했다는 뜻은 아니다. 미커밋 변경도 포함한다.
- 실제 앱 함수에 모의 HTTP를 연결한 측정, 실제 SQL 본문을 실행한 격리 PostgreSQL 측정, 실제 Excel 파서의 AOT 프로세스 측정을 수행했다.
- **운영 DB·운영 외부 API·운영 배포 상태는 조회하지 않았다.** 구현 및 재현용 감사 자료만 다루었고 제품 코드는 수정하지 않았다.
- 이전 10월 5일 감사 결과를 현재 코드에 그대로 적용하지 않았다. 최신 직접주문 목록, KDS 집계 개선, 은퇴한 Deliberry 경로를 다시 구분했다.

[개선계획](/Users/andreahn/globos_pos_system/docs/plans/data_access_performance_improvement_plan_20261010.md) · [재현 방법과 원시 증거](README.md) · [검사 결과](test_summary.json)

## 실측 결과

여기서 HTTP 요청·반환 행·본문 bytes는 **모의 전송으로 실제 클라이언트/handler를 실행한 값**이다. DB 실제 스캔 행과 구별한다. 시간은 같은 호스트의 다른 작업 영향을 받았고, 운영 SLO나 개선률의 근거로 사용하지 않는다.

| 실행 경로 / 입력 | 요청·행·전송량 측정 | 의미 |
|---|---|---|
| 테이블 갱신 1회 → 100회 동시 진입 | HTTP 2 → 200, 최대 동시 1 → 100, 본문 26,172 → 2,617,200 B | 점포별 진행 중 조회를 공유하지 않음 |
| Super Admin 최초 조회 1회 + 강제 갱신 100회 | HTTP 101, 최대 동시 100 | 기존 조회를 기다린 뒤 각 호출이 다시 시작 |
| 발주 이력 100 / 1,000 / 10,000건 | HTTP는 모두 8회, 반환 행 203 / 2,003 / 20,003, 응답 73,179 / 729,279 / 7,299,279 B | 화면 이력은 모두 3건; 요청 수만 보면 놓치는 문제 |
| 같은 발주 이력 조회 | 최대 요청 URL 4,765 / 45,265 / 450,265 B | 모든 과거 ID가 하나의 IN 조건에 들어감 |
| 증빙 첨부가 403/42501로 거절, flush 2회 | HTTP 8회, 업로드 2회, 서로 다른 경로 2개, 업로드 본문 33,506 B | 성공한 파일 업로드까지 재시도 |
| 없는 고정 계정 찾기, Auth 사용자 10,000명 | 11회, 10,000명, 4,639,922 B | 이메일 하나를 찾기 위해 사용자 전체 metadata 전송 |
| 긴급 푸시 1,000건 | claim 10 + 완료 RPC 1,000 + FCM 1,000 + OAuth 1, 최대 동시 1 | 건수 제한은 있으나 직렬 왕복 누적·시간 제한 부재 |
| MISA 활성화 fixture, 같은 법인 50건 | DB 352회 중 설정·토큰 읽기 150회 | 현재 소스의 기본 비활성 경로를 명시적으로 켠 실험 |

발주 10,000건은 서버 행 제한을 두지 않은 모의 응답이다. 운영 API가 더 작은 행 제한을 적용하면 같은 양을 받는다고 단정할 수 없고, 대신 상품별 최근 이력이 누락될 수 있다. 실제 배포의 행·URL 제한은 미확인이다.

### SQL: 고정된 결과에 무관한 과거 데이터가 미치는 영향

`postgres:15`, 2 CPU·1 GiB 임시 컨테이너, 포트 비공개, 현재 함수 본문과 최소 합성 스키마를 사용했다. 권한 guard는 stub이므로 전체 RLS 검증이 아니다. 각 실험의 관련 인덱스·원문·실행계획을 [sql/](sql/)에 보관했다.

**메뉴 분석: 조회일 주문 100건, 메뉴 20개 고정.**

| 조회일 밖 과거 주문 | payments 실제 스캔 행 | orders 실제 스캔 행 | paid_orders 집계 메모리 | 응답 bytes | 서버 시간 중앙값, 7회 |
|---:|---:|---:|---:|---:|---:|
| 100 | 200 | 200 | 64 KiB | 37,287 | 42.001 ms |
| 1,000 | 1,100 | 1,100 | 193 KiB | 37,287 | 19.031 ms |
| 10,000 | 10,100 | 10,100 | 1,681 KiB | 37,287 | 102.155 ms |

조회일 결과는 같은데 기간 밖 이력을 모두 읽는다. 시간의 비단조적 변화는 측정 잡음이 있으므로 행·메모리 증가와 구분한다. 메뉴별 최고 시간대 계산에서는 20회 CTE 스캔 × (반환 1행 + 제외 19행) = 400회 행 검사가 확인됐다.

**재고 원가: 대상 매장 상품 100개 고정.** 타 매장 상품 100 / 1,000 / 10,000개에 따라 공급가 스캔은 200 / 1,100 / 10,100행, 정렬 메모리는 39 / 126 / 1,095 KiB였다. 반환은 모두 100행·25,092 B이며 서버 시간 중앙값은 6.115 / 11.190 / 20.644 ms(각 5회)였다.

`Actual Rows × Actual Loops`는 scan 노드의 출력 행 수다. 위 표의 orders/payments/공급가 scan은 필터 제거 행이 0이어서 검사한 행 수와 일치한다. 일반적인 처리량은 `Rows Removed by Filter`와 index recheck도 따로 확인해야 한다. 예를 들어 재고 fixture의 inventory_products는 출력 100행 외에 타 매장 100행을 필터에서 버린다. 노드별 출력·제거 행과 BUFFERS의 물리 I/O를 구분하고, 부모/자식 노드의 행을 합산하지 않았다. 집계/정렬 메모리는 해당 노드의 보고값이며 전체 DB 프로세스 메모리가 아니다.

### Excel: 작은 압축 파일도 제한 검사 전에 크게 확장

실제 `parsePhotoSalesImportWorkbook`을 Dart 3.11.4 AOT 실행파일에서 호출했다. 크기별 독립 프로세스 3회이며 입력·출력의 정확성도 검사했다.

| 데이터 행 | 압축 파일 | 파싱 중앙값 | 관측된 최대 프로세스 RSS | 결과 |
|---:|---:|---:|---:|---|
| 100 | 3,428 B | 32.1 ms | 21.4 MiB | 허용 |
| 1,000 | 17,904 B | 402.2 ms | 54.6 MiB | 허용 |
| 10,001 | 163,815 B | 2,931.6 ms | 109.9 MiB | 행 제한으로 뒤늦게 거절 |

10,001행 파일의 해제 크기는 2,257,580 B, 시작 RSS는 약 15.2 MiB였다. 그 크기의 시간 범위는 1,213.8–4,050.2 ms였다. RSS는 전체 AOT 프로세스 값이며 Flutter UI/browser heap이나 실제 프레임 정지는 측정하지 않았다. UI에서 동기 파서를 호출하는 연결은 소스로 확인했다.

## 확인된 개선 대상

P1은 자주 실행되는 경로의 부하 증폭 또는 대량 입력의 자원 위험, P2는 관리·상세 경로 또는 범위 축소가 필요한 경로다. 이 우선순위는 운영 빈도 실측 없이 정한 구현 우선순위다.

### F01 · P1 · 같은 자원의 갱신 요청이 제한 없이 겹침 — 재현 완료

- [테이블 이벤트 콜백](/Users/andreahn/globos_pos_system/lib/features/table/table_provider.dart:161)은 [loadTables 호출](/Users/andreahn/globos_pos_system/lib/features/table/table_provider.dart:192)을 이벤트마다 실행한다. [55행](/Users/andreahn/globos_pos_system/lib/features/table/table_provider.dart:55)의 테이블 조회와 [225행](/Users/andreahn/globos_pos_system/lib/features/table/table_provider.dart:225)의 활성 주문·품목 조회가 매번 반복된다. 이벤트 E개, 같은 화면 U개면 최대 `2EU` 요청이며 동시성은 이벤트 수와 함께 늘어난다.
- [Super Admin _catalogLoad](/Users/andreahn/globos_pos_system/lib/features/super_admin/super_admin_provider.dart:348)는 `force:true` 호출들이 기존 Future를 기다린 후 guard를 다시 확인하지 않는다. [화면의 staff/settings 이벤트](/Users/andreahn/globos_pos_system/lib/features/super_admin/super_admin_screen.dart:109)가 진입점이다.
- 두 측정은 실제 메서드 재진입을 검증했다. 실시간 서버가 반드시 100개를 한 번에 전달한다는 검증은 아니다. 전송 이벤트→메서드 연결은 코드 근거다.
- 개선 방향: 점포·자원별 진행 중 요청 1개와 후속 갱신 1개, 변경 ID 집합 병합. 기존 `CoalescedRefresh`를 활용할 수 있다.

### F02 · P1/P2 · 중복 구독과 이벤트 병합이 조회 범위를 넓힘 — 소스 확인

- [주방 공통 피드](/Users/andreahn/globos_pos_system/lib/features/kitchen/kitchen_screen.dart:284)가 [provider의 전체 갱신](/Users/andreahn/globos_pos_system/lib/features/kitchen/kitchen_provider.dart:312)을 요청해 기존 변경 ID 50개 배치 경로를 우회한다. 단일 변경이 부분 갱신과 전체 갱신을 연속 유발할 수 있다. 활성 주문 A개 전체 갱신은 현재 페이지 계약상 약 `ceil(A/100)+2` 요청이다.
- [캐시어 공통 피드](/Users/andreahn/globos_pos_system/lib/features/cashier/cashier_screen.dart:293)와 [결제 provider 직접 구독](/Users/andreahn/globos_pos_system/lib/features/payment/payment_provider.dart:1636)에도 중복 책임이 있다. 실제 서버 이벤트 빈도·중복량은 미측정이다.
- [PosLiveEvent.merge](/Users/andreahn/globos_pos_system/lib/core/services/live_refresh_service.dart:71)는 다른 매장 이벤트를 합치면 ID를 null로 만든다. [매출 갱신](/Users/andreahn/globos_pos_system/lib/features/super_admin/super_admin_provider.dart:727)은 null을 전체 매장으로 해석한다. S개 중 C개 매장 변경이 S개 집계로 확대된다. S=500,C=2이면 **대상 매장 수**는 250배이며 지연·bytes가 반드시 250배라는 뜻은 아니다.
- 개선 방향: 영역별 갱신 책임 통합, 변경 매장 ID 집합 유지, 연결 복구용 전체 동기화와 변경 이벤트 구분.

### F03 · P1 · 발주 상세의 최근 이력 3건을 위해 전체 이력을 전송 — 재현 완료

- [과거 발주행 조회](/Users/andreahn/globos_pos_system/lib/core/services/inventory_service.dart:1450) → [모든 ID의 입고행 조회](/Users/andreahn/globos_pos_system/lib/core/services/inventory_service.dart:1470) → [상품별 3건만 유지](/Users/andreahn/globos_pos_system/lib/core/services/inventory_service.dart:1565).
- [발주 상세 UI](/Users/andreahn/globos_pos_system/lib/features/inventory_purchase/inventory_purchase_screen.dart:1303)에서 실행한다. 공급상품 S개, 관련 과거 발주행 H개·입고행 R개이면 추가 조회는 2회지만 전송·메모리는 `O(H+R)`, 화면 결과는 최대 `3S`다.
- 개선 방향: 서버에서 상품별 최신 3개 ID를 먼저 선정한 뒤 그 ID의 입고를 일괄 집계. 여러 상품에 전체 LIMIT 3을 걸어 일부 상품을 누락시키면 안 된다.

### F04 · P1 · 메뉴 분석이 기간 밖 이력과 메뉴별 집계를 반복 — SQL 실측 완료

- [유효 함수의 paid_orders](/Users/andreahn/globos_pos_system/supabase/migrations/20260915200000_menu_display_localization.sql:676)는 전체 결제를 주문별로 묶은 뒤 HAVING으로 마지막 결제 시각을 제한한다. [최고 시간대](/Users/andreahn/globos_pos_system/supabase/migrations/20260915200000_menu_display_localization.sql:807)도 메뉴별로 CTE를 다시 검색한다.
- [실제 호출자](/Users/andreahn/globos_pos_system/lib/features/report/menu_sales_analytics.dart:359). 요청 1회여도 이력 H와 메뉴/시간 집계 `M×T`에 작업량이 의존한다.
- 개선 방향: 날짜 후보 주문→후보의 전체 결제로 마지막 결제 시각 확정, 시간대 순위도 일괄 산출. 단순 날짜 필터 이동은 기간 이후 추가 결제된 주문의 포함 의미를 바꿀 수 있다.

### F05 · P1/P2 · 재고 화면 선로딩·중복 집계·타 매장 스캔 — 일부 SQL 실측

- [화면 진입](/Users/andreahn/globos_pos_system/lib/features/inventory_purchase/inventory_purchase_screen.dart:229)은 선택 탭과 관계없이 9개 provider를 로드한다. 고정된 9개 병렬 호출 자체를 무제한 병렬로 판정한 것은 아니다.
- [공급상품 조회](/Users/andreahn/globos_pos_system/lib/core/services/inventory_service.dart:769)는 500행 OFFSET 페이지를 끝까지 보유하고, [기본 화면](/Users/andreahn/globos_pos_system/lib/features/inventory_purchase/inventory_purchase_screen.dart:1828)은 상품 미선택 시 10개만 표시한다. C개 상품이면 대략 `2+floor(C/500)` 요청과 `O(C)` 메모리다.
- [원가 supplier_cost](/Users/andreahn/globos_pos_system/supabase/migrations/20260506011000_inventory_cost_analysis.sql:43)가 매장 필터 전에 전체 공급상품을 정렬한다. 위 SQL 실측으로 타 매장 규모에 따른 스캔 증가를 확인했다.
- [overview](/Users/andreahn/globos_pos_system/supabase/migrations/20260506000000_inventory_purchase_office_contracts.sql:579)는 발주 상태를 집계 내부에서만 필터링하고, [588행](/Users/andreahn/globos_pos_system/supabase/migrations/20260506000000_inventory_purchase_office_contracts.sql:588)은 동시에 화면에서 요청한 stock-status 집계를 다시 실행한다. 중복 집계 횟수는 정적 경로 근거다.
- 개선 방향: 선택 탭·상품으로 lazy load, 현재 매장 상품 집합을 먼저 정한 SQL, 공통 소비 집계 공유, 상태 조건을 입력 범위에 적용.

### F06 · P2 · 영수증 페이지를 고르기 전에 당일 전체 품목 JSON 생성 — 소스 확인

- [get_receipt_ledger 품목 집계](/Users/andreahn/globos_pos_system/supabase/migrations/20260915200000_menu_display_localization.sql:1130)는 전체 당일 품목을 집계하고, [1340행](/Users/andreahn/globos_pos_system/supabase/migrations/20260915200000_menu_display_localization.sql:1340)에서 LIMIT/OFFSET을 적용한다. 정확한 합계·건수도 페이지마다 재계산한다.
- [기존 영수증 화면 서비스](/Users/andreahn/globos_pos_system/lib/features/receipt_ledger/receipt_ledger_service.dart:16)는 현재 라우터에 연결돼 있다. 신규 `pos_receipt_ledger_batch`의 50개 제한과 혼동하지 않는다.
- 페이지 P개, 당일 결제 D개·품목 I개에 대해 대략 `P×(D+I)`의 전처리 위험이다. 이 RPC의 실제 실행계획·응답 시간은 미측정이다.
- 개선 방향: 얇은 헤더로 페이지 선정 후 해당 키의 품목만 집계. 정확한 합계는 별도 집계에서 유지하고 범위·revision별 재사용.

### F07 · P2 · 요약·매출 추이에 예외 상세 전체를 포함 — 소스 확인

- [요약 SQL](/Users/andreahn/globos_pos_system/supabase/migrations/20260905060000_store_report_summary.sql:118)은 모든 증빙 누락·발행 실패 상세를 JSON으로 반환하고, [클라이언트 검증](/Users/andreahn/globos_pos_system/lib/features/report/report_provider.dart:383)은 전체 건수와 상세 배열 길이 일치를 강제한다.
- [추이 provider](/Users/andreahn/globos_pos_system/lib/features/report/revenue_history_provider.dart:25)는 같은 응답을 받아 dailyBreakdown만 사용한다. 날짜 D일, 예외 X건·본문 길이 B면 응답이 `O(D+XB)`이며 목록을 열지 않아도 비용이 발생한다.
- 개선 방향: 요약·추이 projection과 예외 상세 키셋 페이지를 분리. 총건수의 정확성은 유지하고 계약을 명시적으로 버전 변경한다.

### F08 · P2 · 직원 한 명 급여를 위해 매장 전체 월 자료 재조회 — 소스 확인

- [선택 직원 출퇴근 조회](/Users/andreahn/globos_pos_system/lib/features/admin/tabs/attendance_tab.dart:293) 후 [급여 계산](/Users/andreahn/globos_pos_system/lib/core/services/payroll_service.dart:174)이 전체 매장 월 로그·수당·직원을 수집하고 [204행](/Users/andreahn/globos_pos_system/lib/core/services/payroll_service.dart:204)부터 직원 필터를 적용한다.
- E명×월 L개 이벤트면 개인 조회에도 `O(EL)` 자료와 약 `ceil(EL/500)` 로그 데이터 페이지가 필요하다(종료/일관성 확인 호출은 별도). 100명×60개는 12개 데이터 페이지다.
- 개선 방향: 직원 조건을 서버 조회와 revision 범위까지 전달. 전체 급여 내보내기의 완전성은 유지한다. 표시용 로그의 제한·필드가 다르므로 검증 없이 그대로 재사용하면 안 된다.

### F09 · P1 · Excel 제한 검사가 전체 디코딩·복제 뒤에 실행 — 실제 파서 실측

- [전체 파일 읽기와 동기 파싱](/Users/andreahn/globos_pos_system/lib/features/photo_sales_import/photo_sales_import_screen.dart:618), [전체 시트 행렬 복제](/Users/andreahn/globos_pos_system/lib/features/photo_sales_import/photo_sales_import.dart:109), [뒤늦은 행 제한](/Users/andreahn/globos_pos_system/lib/features/photo_sales_import/photo_sales_import.dart:309).
- [공용 decoder](/Users/andreahn/globos_pos_system/lib/core/utils/excel_workbook_decoder.dart:38)에는 압축·해제 바이트/시트/셀 예산이 없다. 형식 보정 경로는 재압축·재디코딩도 한다. 메뉴·재료·레시피 import도 같은 방식의 예산 검증이 필요하다.
- 개선 방향: 파일 길이→ZIP 예산→시트/셀/행 예산을 읽는 단계부터 적용하고 필요한 시트만 처리. 작업 동시성 1과 UI 외부 실행을 함께 설계한다.

### F10 · P2 · 영구 오류에도 증빙 파일을 새 경로에 반복 업로드 — 재현 완료

- [실패 큐 유지](/Users/andreahn/globos_pos_system/lib/core/services/payment_proof_service.dart:119), [timestamp 기반 새 Storage 경로](/Users/andreahn/globos_pos_system/lib/core/services/payment_proof_service.dart:153).
- 403/42501 첨부 실패에도 이미 완료된 업로드를 기록하지 않아 다음 flush가 파일부터 재전송한다. 재연결당 flush 경로이며 지속적인 자동 무한루프라고 판정하지 않았다.
- 개선 방향: 안정적인 작업 ID·업로드 완료 단계 보존, 첨부만 재시도, 권한 오류는 사용자 조치 상태로 전환하고 일시 오류만 재시도.

### F11 · P2 · 긴급 푸시의 직렬 왕복과 시간·오류별 재시도 제한 부족 — handler 재현

- [100건×최대 10배치](/Users/andreahn/globos_pos_system/supabase/functions/emergency-fulfillment-dispatcher/index.ts:57), [timeout 없는 FCM 요청](/Users/andreahn/globos_pos_system/supabase/functions/emergency-fulfillment-dispatcher/index.ts:74), [건별 완료 RPC](/Users/andreahn/globos_pos_system/supabase/functions/emergency-fulfillment-dispatcher/index.ts:98).
- 건수·최대 시도 10회 제한은 있다. 문제는 전체 실행시간 상한과 일시/영구 오류 구분·jitter가 없다는 점이다. fixture에서 404/UNREGISTERED도 30초 후 재시도 상태로 전달됐다. 실제 DB 재시도 계약은 [claim SQL](/Users/andreahn/globos_pos_system/supabase/migrations/20260810170000_emergency_digital_fulfillment.sql:1095)로 확인했다.
- 개선 방향: 작은 claim, 제한된 동시성, 개별 timeout·전체 시간 예산, 완료 배치, lease 회수, 상태/body를 함께 보는 오류 분류. 디바이스별 외부 전송 자체와 줄일 수 있는 DB 왕복을 구별한다.

### F12 · P2 · 고정 계정 검색에 전체 Auth 사용자 디렉터리 사용 — helper 재현

- [findAuthUserByEmail](/Users/andreahn/globos_pos_system/supabase/functions/provision-fixed-pos-account/index.ts:53)은 1,000명씩 최대 20페이지를 읽는다. [프로필 부재 분기](/Users/andreahn/globos_pos_system/supabase/functions/provision-fixed-pos-account/index.ts:186)에서 호출하며 매장/법인 설정 UI에 연결돼 있다.
- 10,000명 없는 이메일은 11회·약 4.64MB의 fixture JSON, 20,000명은 20회·약 9.30MB 후 검색 제한 오류였다. 페이지 상한은 있지만 한 계정 탐색에 무관한 사용자 metadata를 전송한다.
- 개선 방향: service-role 전용 정확 일치 ID 조회나 명시적 계정 매핑. 일반 클라이언트에 Auth 디렉터리 접근 권한을 새로 열지 않는다.

### F13 · 활성화 전 개선 · MISA N+1과 동시 dispatcher의 중복 발송 시도 — 조건부 재현

- [dispatcher 작업 루프](/Users/andreahn/globos_pos_system/supabase/functions/meinvoice-dispatcher/index.ts:156)에서 법인·설정·캐시 토큰을 작업마다 재조회한다. 성공 N건은 `2+7N` DB 호출이고 이 중 `3N`이 같은 설정·토큰 읽기다.
- [pending 선택](/Users/andreahn/globos_pos_system/supabase/functions/meinvoice-dispatcher/index.ts:135)은 원자적 claim이 아니다. 핸들러 2개·고유 작업 10개 fixture에서 발송 시도 20회가 발생했다. **실제 송장이 2배 발행됐다는 뜻은 아니다.** 공급자의 RefID 멱등성/중복 응답은 검증하지 않았다.
- 저장소 기본 설정은 dispatch disabled이며 자동 스케줄을 확인하지 못했다. 운영 활성화 여부는 미확인이다. 비활성 경로를 성능 개선 때문에 활성화하지 않는다.
- 개선 방향: claim+lease, 고유 법인 일괄 설정 조회·토큰 공유, 완료/이벤트 저장 배치. 결제 완료의 MISA 독립성 유지.

## 추가 적용 상태 확인 대상

SePay [webhook](/Users/andreahn/globos_pos_system/supabase/functions/sepay-webhook/index.ts:85)은 매칭 입금마다 FCM dispatcher를 호출하지만, [Windows polling 전환 migration](/Users/andreahn/globos_pos_system/supabase/migrations/20260806120000_sepay_windows_only_alerts.sql:3)은 FCM 기기를 비활성화한다. 해당 migration 적용 환경에서는 불필요한 Edge 기동·빈 claim, Firebase 설정이 있으면 OAuth 호출까지 발생할 수 있다. 실제 배포 설정을 확인한 뒤 provider별 분기 제거를 결정한다.

## JOIN 행 증폭과 정상 보호 장치

**검토한 주요 경로에서는 독립적인 일대다 관계 JOIN으로 결과 행이 곱해지는 결함을 확정하지 못했다.**

- 메뉴 분석은 결제를 주문별 선집계 후 품목과 연결한다. 영수증도 결제수단·배분·품목을 ledger key별로 따로 집계한다.
- `users.auth_id`, 단독 영수증 `order_id`, 합산 영수증 canonical key의 유일성 계약을 확인했다. 직접주문 번역의 `(request_id, menu_item_id)`도 UNIQUE이므로 해당 조인을 증폭 문제로 분류하지 않았다.
- 최신 직접주문 목록은 페이지 1–200개를 먼저 선정하고 관계별로 일괄 집계한다. 이전 버전의 상관 쿼리 지적을 현재 결함으로 재사용하지 않았다.
- `CoalescedRefresh`, 주방 keyset 100개·변경 ID 50개, 신규 POS 영수증 batch 50개·캐시 20페이지, 재무 조회 keyset 500개·revision 확인은 유효한 보호 장치다.
- 직접주문 번역은 10개 배치, 직접주문 푸시는 50개 claim·동시성 8·timeout 10초·오류 구분을 구현했다. 긴급 푸시와 같은 구현으로 취급하지 않았다.
- 작은 매장 목록, 고정된 소수의 `Future.wait`, 필수 개별 외부 전송/쓰기, 의도된 전체 내보내기 자체를 자동으로 N+1 결함으로 판정하지 않았다.

이 결론은 위 호출 경로의 범위에 한정한다. 대량 데이터·실제 RLS·쓰기 동시성·장애 상황을 포함한 전 시스템 무결성이나 운영 성능을 보증하지 않는다.

## 실행한 검증과 남은 측정

- 기존 관련 Flutter 테스트 **46개**, 실제 동작 계측 테스트 **7개**, 합계 **53개 통과**. 상세는 `test_summary.json`과 원본 로그에 있다. 문제 동작을 재현하는 테스트의 PASS는 성능 지침을 충족한다는 뜻이 아니다.
- SQL 2개 경로×3개 규모의 실제 내부 실행계획·타이밍·응답 크기 측정. Docker fixture는 종료했다.
- Excel 실제 파서 3개 규모×3회, Edge 실제 handler/helper 모의 전송으로 호출·행·bytes·동시성 측정.
- 운영 HTTP p95/p99, 실제 모바일/브라우저 heap, SQL 전체 RLS 비용, 대표 운영 데이터 분포, 다중 점포 실제 이벤트 빈도는 미측정이다. 전체 앱 빌드·전체 테스트를 이 감사의 완료 근거로 주장하지 않는다.
- 최종 snapshot에서 다른 작업의 소스 변경 8개를 확인해 `scope_summary.json`에 기록했다. 보고서·계획이 직접 인용한 소스는 초기/최종 해시가 같았다. 이후 감사 소스 해시와 다른 변경이 생기면 해당 경로를 재검증해야 한다.
