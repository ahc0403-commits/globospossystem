# 설계 브리프: 메뉴별 판매 분석

Date: 2026-08-13
Source: 사용자 요청과 현재 `ReportsTab`/`ReportNotifier`/Supabase 판매 계약 점검
Status: 로컬 구현·검증 완료 — 운영 DB 반영 및 배포는 하지 않음

## 목표

현재 매출·주문·결제수단 중심인 관리자 통계 화면에 메뉴별 판매 분석을 추가한다. 관리자가 선택 기간 안에서 어떤 메뉴가 가장 많이 팔렸는지, 어느 시간대에 어떤 메뉴가 강한지, 판매수량과 메뉴 판매금액이 어떻게 구성되는지를 한 화면에서 확인할 수 있어야 한다.

- 기본 순위는 `판매수량` 기준으로 제공하고 `메뉴 판매금액`과 `포함 주문 수`로 정렬 기준을 바꿀 수 있게 한다.
- 가장 많이 팔린 메뉴, 총 판매수량, 판매된 메뉴 수, 분석 대상 POS 주문 수를 빠르게 확인한다.
- 메뉴별 순위와 시간대별 판매량/판매금액, 상위 메뉴의 시간대 분포를 함께 제공한다.
- 현재 매출 리포트의 기간 선택, 매장 범위, KO/VI/EN 다국어와 반응형 레이아웃을 그대로 사용한다.
- 집계는 Flutter에서 원시 주문행을 내려받아 계산하지 않고, 매장 권한을 검사하는 읽기 전용 Supabase RPC에서 수행한다.

## 현재 구현 확인

### 재사용 가능한 부분

- `ReportsTab`의 선택 매장, 시작일/종료일, 오늘/이번 주/이번 달 빠른 범위와 새로고침 동작
- `reportUtcRange()`의 `Asia/Ho_Chi_Minh` 날짜 범위 변환과 기존 리포트 Provider 상태
- `order_items.display_name`, `quantity`, `paying_amount_inc_tax`의 판매 당시 이름·수량·할인/VAT 반영 금액 스냅샷
- `PosDataPanel`, `ToastMetricStrip`, `ToastWorkSurface`, `PosEmptyState`, 색상·간격·48dp 터치 토큰
- 기존 리포트의 loading/error/empty, compact scroll, desktop split layout와 Excel 다운로드 진입점
- `orders`, `order_items`, `payments`의 매장 RLS와 `user_accessible_stores()` 권한 계약

### 수정이 필요한 부분

- `ReportSummary`에는 메뉴 집계 모델이 없고 `ReportNotifier.loadReport()`는 결제·외부매출을 클라이언트에서만 합산한다.
- 시간대 차트는 현재 결제별 매출만 보여주며 메뉴별 판매수량이나 메뉴-시간 교차 분석이 없다.
- `ReportsTab`은 3,600줄이 넘으므로 새 메뉴 분석 UI를 같은 파일에 계속 추가하면 검토와 회귀 위험이 커진다.
- 기존 Excel에는 요약·결제수단·일별 매출만 있고 메뉴 판매 및 메뉴별 시간대 시트가 없다.
- 결제 후 환불/void는 `payment_adjustments`에 주문/결제 단위로만 기록되어 품목별 차감 귀속을 정확히 계산할 수 없다.
- `external_sales`와 Photo 매출에는 POS `order_items`와 동일한 정규화 메뉴 계약이 없다.

## 지표 계약

| 지표 | 정의 |
|---|---|
| 분석 대상 주문 | 선택 매장의 `orders.status='completed'`이며 하나 이상의 `payments.is_revenue=true` 행이 있는 주문 |
| 판매 완료 시각 | 한 주문에 속한 매출 결제 중 가장 늦은 `payments.created_at`; 분할결제가 여러 행이어도 주문·메뉴를 한 번만 집계 |
| 시간대 | 판매 완료 시각을 `Asia/Ho_Chi_Minh`로 변환한 0~23시 버킷 |
| 판매 메뉴 행 | `order_items.item_type='menu_item'`, `status<>'cancelled'`, `is_service_item=false`인 행 |
| 판매수량 | 대상 메뉴 행의 `quantity` 합계 |
| 포함 주문 수 | 해당 메뉴를 포함한 서로 다른 대상 주문 수 |
| 메뉴 판매금액 | 대상 메뉴 행의 `paying_amount_inc_tax` 합계; 주문 할인과 VAT를 반영하지만 결제 후 환불은 차감하지 않음 |
| 판매 비중 | 해당 메뉴 판매수량 / 분석 대상 전체 메뉴 판매수량 |
| 금액 비중 | 해당 메뉴 판매금액 / 분석 대상 전체 메뉴 판매금액 |
| 피크 시간 | 해당 메뉴의 판매수량이 가장 큰 HCM 시간대; 동률이면 이른 시간을 먼저 표시 |
| 가장 많이 팔린 메뉴 | 판매수량 내림차순, 동률이면 메뉴 판매금액 내림차순, 메뉴명 오름차순 |

### 제외 규칙

- 취소 주문·취소 메뉴 행, 직원식/기타 `is_revenue=false` 주문, 서비스 제공 메뉴(`is_service_item=true`)는 판매 순위에서 제외한다.
- 생성형 서비스차지와 물티슈 고정요금처럼 실제 `menu_item`이 아닌 행은 메뉴 순위에서 제외한다.
- 콤보는 판매된 콤보 SKU 한 개로 집계한다. `combo_components`의 구성 음료/품목을 별도 판매로 중복 집계하지 않는다.
- POS `orders/order_items`로 들어온 dine-in/takeaway/delivery 주문은 포함한다.
- `external_sales` 및 Photo 거래는 정규화 메뉴 항목이 없으므로 MVP 메뉴 분석에서는 제외하고 화면과 Excel에 `POS 메뉴 상세 기준`임을 명시한다.
- 부분 환불/void는 메뉴별 귀속 근거가 없으므로 판매수량이나 특정 메뉴 금액에서 임의 차감하지 않는다. 기간 내 미배분 조정 건수·금액을 별도 안내한다.

## 데이터 계약

### 읽기 전용 집계 RPC

새 `get_store_menu_sales_analytics(p_store_id, p_start_at, p_end_at)` RPC가 반개방 구간 `[p_start_at, p_end_at)`을 받아 다음을 한 응답으로 반환한다.

- `summary`: 대상 주문 수, 총 판매수량, 판매된 메뉴 수, 메뉴 판매금액, 환불/void 미배분 건수·금액
- `menu_rows`: 안정적인 메뉴 키, 표시 이름, 판매수량, 포함 주문 수, 메뉴 판매금액, 수량/금액 비중, 피크 시간, 채널별 수량
- `hour_rows`: 0~23시별 판매수량, 메뉴 판매금액, 대상 주문 수
- `top_menu_hour_rows`: 상위 메뉴의 시간대별 판매수량/판매금액(heatmap용)
- `scope`: 포함/제외 데이터 소스와 집계 버전

RPC는 `SECURITY DEFINER`와 고정 `search_path`를 사용하되, 호출자가 super admin이 아니면 `user_accessible_stores(auth.uid())`에 `p_store_id`가 반드시 존재해야 한다. `PUBLIC`/`anon` 실행 권한은 제거하고 `authenticated`/`service_role`만 허용한다.

### 메뉴 정체성

- 1차 그룹 키는 `menu_item_id`다.
- 현재 존재하는 메뉴가 삭제되어 FK가 `SET NULL` 되더라도 앞으로의 이력을 잃지 않도록, 주문 시 원래 UUID를 보존하는 nullable 보고용 스냅샷 키를 additive migration으로 도입하고 기존 연결 행을 backfill한다.
- 과거에 이미 메뉴 연결이 사라진 행은 `display_name` 기반 fallback 그룹으로 포함하고 응답에 `identity_quality='name_fallback'`을 표시한다.
- 기간 중 이름이 바뀐 동일 메뉴는 한 메뉴로 합치고 가장 최근 판매 스냅샷 이름을 표시하며 `name_changed_in_period=true`를 제공한다.
- 카테고리별 역사 분석은 현재 카테고리 스냅샷이 없으므로 MVP에 넣지 않는다. 필요하면 별도 승인 후 주문 시점 카테고리 스냅샷을 추가한다.

### 성능 경계

- 원시 `order_items`를 Flutter로 전송하지 않고 DB에서 주문·메뉴·시간대 단위로 축약한다.
- 기존 `payments(order_id)`, `payments(restaurant_id)`, `order_items(order_id)` 인덱스를 우선 사용한다.
- 실제 fixture와 대표 기간으로 `EXPLAIN (ANALYZE, BUFFERS)`를 확인한 뒤에만 `is_revenue=true` 결제 완료 시각 또는 메뉴 집계용 partial/composite index를 같은 additive migration에 추가한다.
- 보고서는 읽기 전용이며 결제, 재고 차감, MISA/e-invoice, 일일 마감 데이터를 수정하지 않는다.

## 화면 계약

### 1. 공통 기간과 범위

- 현재 리포트 상단의 매장·기간·빠른 범위·조회·새로고침을 메뉴 분석에서도 공통으로 사용한다.
- 날짜는 HCM 달력일이고 종료일은 UI에서 포함, RPC에서는 다음 날 00:00 직전이 아닌 exclusive end로 전달한다.
- 매출 요약 로드 실패와 메뉴 분석 로드 실패를 분리해 한쪽 실패가 화면 전체를 가리지 않게 한다.

### 2. 메뉴 판매 핵심 요약

- 선택 기간의 첫 메뉴 분석 영역에 `가장 많이 팔린 메뉴`, `총 판매수량`, `판매 메뉴 수`, `분석 대상 POS 주문`을 표시한다.
- 1위 메뉴 카드에는 판매수량, 포함 주문 수, 메뉴 판매금액, 수량 비중을 함께 표시한다.
- 전체 리포트 매출과 메뉴 판매금액이 다른 이유(서비스차지, 외부매출, Photo, 비메뉴 금액)를 짧은 범위 문구로 설명한다.
- 환불/void가 있으면 `품목별 미배분 조정 N건 / X VND` 경고를 표시하고 메뉴 순위를 자동 보정하지 않는다.

### 3. 메뉴 순위

- 기본은 판매수량 내림차순이며 `판매수량`, `메뉴 판매금액`, `포함 주문 수` 정렬을 제공한다.
- 각 행은 순위, 메뉴명, 판매수량, 포함 주문 수, 메뉴 판매금액, 비중, 피크 시간을 표시한다.
- desktop/tablet은 밀도 높은 표, phone은 동일 정보를 읽을 수 있는 세로 카드 목록을 사용한다.
- 상위 10개를 먼저 보여주고 `전체 보기`로 나머지를 펼친다. 검색은 메뉴 수가 많아 실제 운영에서 필요하다는 근거가 확인될 때 추가한다.
- 이름 변경이나 fallback identity는 경고 아이콘/설명으로 데이터 품질을 투명하게 표시한다.

### 4. 시간대 분석

- 0~23시 전체 버킷을 유지해 판매가 없는 시간도 0으로 보인다.
- `판매수량`/`메뉴 판매금액` 토글이 있는 시간대 막대 또는 선형 패널을 제공하고 숫자 레이블을 함께 표시한다.
- 상위 5개 메뉴 × 24시간 heatmap으로 어떤 메뉴가 어느 시간대에 집중되는지 보여준다.
- 색만으로 값을 구분하지 않고 각 셀의 툴팁/접근성 레이블에 메뉴명, 시간, 수량, 금액을 제공한다.
- phone에서는 heatmap을 가로 스크롤시키기보다 메뉴별 피크 시간 카드와 선택한 메뉴의 24시간 차트로 단순화한다.

### 5. 채널 분석과 내보내기

- 메뉴별 dine-in/takeaway/POS delivery 수량을 보조 정보로 제공한다. 외부 Deliberry `external_sales`는 포함하지 않는다.
- 기존 Excel에 `Menu Sales`와 `Menu by Hour` 시트를 추가하고 화면과 동일한 기간·범위·제외 규칙·미배분 조정 안내를 첫 행에 기록한다.
- 화면 정렬과 무관하게 Excel `Menu Sales`는 기본 판매수량 순위로 내보낸다.

## 구조 경계

- `ReportsTab`은 기간과 배치만 소유하고 메뉴 분석 모델·조회·패널은 `lib/features/report/` 아래 별도 파일로 만든다.
- 메뉴 분석은 `FutureProvider.family` 또는 동등한 독립 read-only provider로 분리해 기존 `ReportNotifier`의 매출 집계와 실패 상태를 바꾸지 않는다.
- 새 패널은 기존 Toast/Pos 디자인 토큰과 리포트 반응형 컨테이너를 재사용한다. 별도 차트 패키지는 도입하지 않고 현재 막대/레이아웃 primitive로 구현한다.
- 기존 매출, 운영 예외, 일일 마감, Paperless dashboard를 삭제하거나 의미를 변경하지 않는다.

## 상태와 접근성

- Loading: 메뉴 분석 영역 내부 skeleton/진행 상태만 표시한다.
- Error: 매출 리포트는 유지하고 메뉴 분석 영역에 재시도와 로컬화된 오류를 표시한다.
- Empty: `해당 기간에 완료된 POS 메뉴 판매가 없습니다`와 범위 변경 동작을 제공한다.
- Partial scope: 전체 매출은 있지만 POS 메뉴 상세가 없으면 외부/Photo 데이터 범위를 설명한다.
- 390×844 phone, 768×1024 tablet, 1024×768 tablet, 1440×900 desktop과 100%/130%/200% 글자 크기에서 overflow가 없어야 한다.
- 정렬, 전체 보기, 지표 토글은 최소 48dp 터치 영역, 키보드 포커스, 명시적 선택 상태와 Semantics 레이블을 갖는다.

## 범위 제외

- Deliberry/Photo 원시 payload를 추정 파싱해 내부 메뉴와 자동 매핑하는 기능
- 메뉴별 원가·마진·재고 소진 예측
- 고객·직원별 메뉴 선호도, 테이블별 분석
- 카테고리 이력 스냅샷 및 역사 카테고리 분석
- 부분 환불을 메뉴 행에 임의 배분하는 로직
- 실시간 스트리밍 대시보드, 자동 알림, 매출 예측
- 기존 결제·MISA/e-invoice·일일 마감 mutation 변경

## 완료 판정

- 동일 기간/매장에서 분할결제 주문의 메뉴가 한 번만 집계되고 마지막 매출 결제 시각의 HCM 시간대에 들어간다.
- 판매수량 1위와 금액 1위가 다를 수 있으며 정렬 변경 결과가 SQL fixture와 정확히 일치한다.
- 취소 행, 서비스 제공 메뉴, 직원식, 서비스차지, 물티슈 행은 메뉴 순위에서 제외된다.
- 주문 할인 후 `paying_amount_inc_tax` 합계가 메뉴 판매금액과 일치하고, 콤보 구성품은 중복 집계되지 않는다.
- 환불/void는 미배분 경고로 나타나며 특정 메뉴의 수량/금액을 근거 없이 변경하지 않는다.
- POS 메뉴 상세와 외부/Photo 매출 범위가 화면·Excel에 명시되고 전체 매출과 메뉴 판매금액 차이가 오류처럼 보이지 않는다.
- 권한 없는 매장은 RPC가 실패하고, 허용된 store admin/brand admin/super admin 범위만 조회된다.
- KO/VI/EN, loading/error/empty/partial, phone/tablet/desktop, 큰 글자에서 정보 유실·overflow·색상만의 의미 전달이 없다.
- SQL 계약 테스트, Flutter unit/widget tests, `flutter analyze`, 전체 `flutter test`, `bash scripts/check_repo.sh`, `git diff --check`가 통과한다.
- 운영 반영은 별도 요청에서만 `scripts/deploy_pos_production.sh`를 사용하며 exact pushed head SHA의 필수 GitHub Actions 성공 전에는 release gate PASS로 보고하지 않는다.
