# Build Tasks: 메뉴별 판매 분석

Generated from: `.design/2026-08-menu-sales-analytics/DESIGN_BRIEF.md`
Date: 2026-08-13

Implementation status: Foundation, Core UI, Interactions & States,
Responsive & Accessibility, focused SQL/Dart/Widget verification, and the full
repository gate are complete locally. Performance measurement against
representative production-scale data, live-data reconciliation, operational UX
approval remain open. Production deployment is tracked by the exact-SHA release
gate rather than these implementation checkboxes.

## Foundation

- [ ] **현재 리포트와 메뉴 집계 fixture 고정**: 기존 매출·시간대·Excel 테스트를 먼저 통과시키고, 정상 주문·분할결제·취소 품목·서비스 품목·직원식·할인·콤보·환불·HCM 자정 경계를 포함한 작은 SQL fixture와 기대 순위를 문서화한다. _Reuses as-is: `ReportNotifier`, `reportUtcRange`, existing report/payment/business-time tests; creates a menu-analytics SQL fixture; no production mutation._
- [ ] **메뉴 정체성 스냅샷 보존**: 앞으로 메뉴 삭제 후에도 같은 메뉴로 집계할 수 있는 nullable 보고용 UUID 스냅샷을 `order_items`에 additive로 추가하고 현재 `menu_item_id`를 backfill하며, 신규 행은 서버 트리거로 자동 캡처한다. 이미 연결을 잃은 과거 행은 이름 fallback으로 표시한다. _Modifies: new Supabase migration only; reuses `order_items.display_name` and current menu FK; creates no Office coupling and changes no payment RPC payload._
- [ ] **매장별 메뉴 판매 RPC 구현**: `[start,end)` 기간, 마지막 매출 결제 시각, 중복 제거, 제외 규칙을 적용해 summary/menu/hour/top-menu-hour/scope를 반환하고 접근 가능한 매장만 허용한다. 실제 실행계획으로 필요성이 확인된 인덱스만 추가한다. _Creates: `get_store_menu_sales_analytics` and focused SQL contract tests; reuses `orders`, `order_items`, `payments`, `payment_adjustments`, `user_accessible_stores`; read-only DB slice._

## Core UI

- [ ] **메뉴 분석 모델과 독립 조회 상태 연결**: RPC 응답을 typed model로 파싱하고 store/start/end를 키로 한 독립 read-only provider를 만들어 매출 리포트 실패와 메뉴 분석 실패가 서로 가리지 않게 한다. _Creates: menu-sales models/provider under `lib/features/report/`; reuses Supabase client and `reportUtcRange`; does not expand `ReportSummary` with raw rows._
- [ ] **가장 많이 팔린 메뉴 요약 구현**: 선택 기간의 1위 메뉴, 총 판매수량, 판매 메뉴 수, 분석 대상 POS 주문을 한 지표 strip에 표시하고 메뉴 판매금액과 전체 리포트 매출의 범위 차이를 설명한다. _Creates: reusable menu analytics summary widget; modifies `ReportsTab` only to place the panel; reuses `ToastMetricStrip`, `PosDataPanel`, current date header and design tokens._
- [ ] **메뉴 순위 vertical slice 구현**: 판매수량 기본 순위와 판매금액/포함 주문 정렬, 상위 10개/전체 보기, 수량·주문·금액·비중·피크 시간, 이름 변경/fallback 품질 표시를 한 패널에서 완성한다. _Creates: desktop/tablet ranking table and phone ranking cards in the menu analytics panel; reuses current money formatting and responsive primitives; depends on menu RPC/model._
- [ ] **시간대별 메뉴 분석 구현**: 0~23시 판매수량/판매금액 토글 차트와 상위 5개 메뉴 heatmap을 제공하고, phone에서는 선택 메뉴 24시간 차트와 피크 시간 카드로 단순화한다. _Creates: hourly chart/heatmap components using existing layout primitives; no new chart dependency; depends on menu RPC/model._
- [ ] **채널과 데이터 범위 표시**: 메뉴별 dine-in/takeaway/POS delivery 수량을 보조 표시하고 외부 Deliberry/Photo, 비메뉴 금액, 환불/void 미배분 건수·금액을 명시해 전체 매출과 메뉴 판매금액 차이를 설명한다. _Modifies: new menu analytics panel only; reuses `orders.sales_channel` and existing report totals; creates no external payload parser._

## Interactions & States

- [ ] **기간·새로고침 동기화**: 기존 시작/종료일, 오늘/이번 주/이번 달, 조회와 새로고침이 같은 HCM 범위로 메뉴 provider를 갱신하며 stale 응답이 다른 매장/기간에 나타나지 않게 한다. _Modifies: `ReportsTab` provider wiring; reuses current controls and selected store; creates no second date selector._
- [ ] **부분 상태 완성**: 메뉴 분석만의 loading, localized error/retry, empty, 전체 매출만 존재하는 partial-scope 상태를 구현하고 기존 매출·운영 예외·일일 마감은 계속 사용할 수 있게 한다. _Creates states inside the new panel; reuses `PosEmptyState` and loading primitives; does not replace the whole reports workspace._
- [ ] **Excel 메뉴 시트 추가**: 기존 다운로드에 `Menu Sales`와 `Menu by Hour` 시트를 추가하고 기간, POS-only 범위, 제외 규칙, 미배분 조정 안내와 기본 판매수량 순위를 포함한다. 메뉴 분석 로드 전에는 잘못된 빈 시트를 저장하지 않도록 다운로드 상태를 명시한다. _Modifies existing report export boundary or creates a focused menu-sales exporter; reuses current `excel` package and FileSaver; depends on typed analytics data._
- [ ] **KO/VI/EN 문구 연결**: 메뉴 순위, 판매수량, 피크 시간, 데이터 범위, fallback identity, 환불 미배분과 모든 상태 문구를 ARB에 추가하고 생성 localization을 갱신한다. _Modifies: `lib/l10n/app_ko.arb`, `app_vi.arb`, `app_en.arb` and generated localization via the existing workflow; creates no hard-coded UI copy._

## Responsive & Accessibility

- [ ] **Phone/Tablet/Desktop 배치 검증**: 390×844에서는 지표·순위 카드·선택 메뉴 시간 차트가 세로로 읽히고, 768×1024/1024×768에서는 표와 시간 분석이 줄바꿈되며, 1440×900에서는 순위와 heatmap을 한 시야에 비교할 수 있게 한다. _Modifies new menu analytics widgets only; reuses `ToastResponsiveScrollBody` and existing report breakpoints._
- [ ] **큰 글자와 조작 접근성 적용**: 100%/130%/200% 글자, 긴 메뉴명/VND 금액에서 overflow 없이 읽히고 정렬·전체 보기·지표 토글에 48dp 터치 영역, 키보드 포커스, Semantics와 색상 외 선택 표시를 제공한다. _Modifies new widgets; reuses POS touch/density/color tokens._

## Verification & Release Safety

- [ ] **SQL 정확성·권한 테스트 통과**: 분할결제 마지막 시각, HCM 자정, 취소/서비스/비매출 제외, 할인 후 금액, 콤보 1회, 이름 변경/fallback, 환불 경고, 허용/차단 매장과 빈 기간을 DB fixture로 검증한다. _Creates focused Supabase SQL tests and a repository contract test for function grants/search path; reuses existing test harness conventions._
- [ ] **Dart 집계·파싱·정렬 테스트 추가**: 숫자/문자 JSON 값, 0 분모 비중, 동률 정렬, 24시간 zero-fill, top-5 선정, malformed optional fields와 export rows를 검증한다. _Creates focused unit tests for the new models/exporter; reuses existing report test patterns._
- [ ] **Widget 회귀 테스트 추가**: 핵심 지표, 세 정렬, 상위 10개/전체 보기, hourly toggle, 환불/scope 경고, loading/error/empty/partial 및 phone/tablet/desktop overflow를 검증하고 기존 report contract keys를 보존한다. _Creates menu-analytics widget tests; modifies existing reports contract tests only where the new panel is intentionally embedded._
- [ ] **성능 기준 확인**: 대표 매장의 오늘/7일/31일/1년 fixture에서 RPC 실행계획과 응답 크기를 기록하고, 목표 응답시간을 넘을 때만 정확한 partial/composite index를 추가한 뒤 재측정한다. _Reuses PostgreSQL `EXPLAIN (ANALYZE, BUFFERS)` in non-production validation; modifies only the new additive migration if evidence requires._
- [ ] **저장소 검증 실행**: 변경 Dart 포맷, localization generation, 관련 SQL/Dart/Widget tests, `flutter analyze`, 전체 `flutter test`, `bash scripts/check_repo.sh`, `git diff --check`를 통과한다. _Reuses project gates; no production apply or deployment in the planning task._
- [ ] **운영 반영 전 실데이터 대사**: 접근 허용 관리자 계정으로 같은 기간의 대표 주문 10건을 영수증/주문행/메뉴 순위와 대사하고, 분할결제·할인·환불 표시를 확인한다. 별도 배포 요청이 있을 때만 `scripts/deploy_pos_production.sh`를 사용하고 exact pushed head SHA의 GitHub Actions를 확인한다. _Reuses production gates in `CLAUDE.md`; no direct Supabase/Vercel bypass._

## Follow-up (별도 승인)

- [ ] **외부 배달 메뉴 정규화 계약 설계**: Deliberry payload 버전과 내부 메뉴 매핑 키가 확정될 때 `external_sales` 메뉴를 별도 정규 테이블/스냅샷으로 수집해 POS 메뉴 분석과 안전하게 합친다. _New future data contract; explicitly not part of MVP._
- [ ] **카테고리 역사 분석 설계**: 주문 시점 category id/name 스냅샷이 필요하다는 운영 요구가 확인되면 카테고리별 수량·금액·시간 분석을 추가한다. _New future snapshot/UI; explicitly not inferred from current mutable category tables._
- [ ] **품목 단위 환불 계약 설계**: 환불 대상 `order_item_id`와 수량/금액이 기록되는 mutation이 승인될 때만 메뉴 순매출과 반품수량을 계산한다. _New future payment-adjustment contract; never estimates allocation._

## Review

- [ ] **운영 UX 승인**: 매장 관리자가 10초 안에 1위 메뉴, 판매수량, 피크 시간, 채널 차이와 환불 미배분 여부를 찾을 수 있는지 확인한다.
- [ ] **독립 정확성 검토**: 변경이 결제/재고/MISA/일일 마감 mutation, Office `restaurants` coupling, 다중 매장 권한을 건드리지 않고 지표 계약과 SQL 결과가 일치하는지 Critical/High/Medium/Low/Confirmed 기준으로 검토한다.
