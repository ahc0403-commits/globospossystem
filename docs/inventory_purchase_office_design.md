# 재고 기반 발주 및 Office 경계 설계 문서

> [NEW UI SOURCE OF TRUTH]
> The current inventory purchase UI source of truth is the QSC Manager
> reference screenshot set supplied on 2026-05-15:
> system structure, PC dashboard, stock status, purchase management,
> purchase history/print, supplier management, product management,
> recipe management/registration, consumption analysis, cost analysis,
> physical stock audit, and mobile purchase/audit flow.
> Use [docs/office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md](office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md)
> only for shared operational shell/component discipline.
> Follow the reference screens' dashboard -> work queue/table -> selected
> detail/action model.
> Preserve business logic, permissions, auth, route paths where possible,
> i18n, and data contracts.
> Do not use dashboard-first, KPI-first, card-heavy, panel-heavy, dark-admin,
> browser-like POS, or CRUD-first standards as the baseline.
>
> [BOUNDARY DECISION - 2026-05-15]
> Office approval/return/reject/update is implemented only in the Office app.
> POS/Admin inventory purchase screens may prepare, submit, print/PDF, receive,
> audit, and display Office-owned status, but must not call Office approval
> mutation RPCs or expose approval execution controls.

## 1. 목적

POS의 기존 재고 기능을 매장별 재고 현황, 발주 추천, 발주 실행, 발주서 출력, 거래처 관리, 제품 관리, 레시피 관리, 소진량 분석, 원가 분석, 실재고 실사, 모바일 발주/실사까지 포함하는 재고 기반 발주 시스템으로 확장한다.

Office 시스템은 이 발주 도메인을 조회할 뿐 아니라 승인, 반려, 수정할 수 있어야 한다. 이 승인 실행 기능은 Office 앱 안에만 둔다. POS/Admin 재고/발주 화면은 발주 추천, 수량 조정, 발주 생성, 발주서 출력/PDF, 입고 확정, 실사, 상태 조회를 담당한다. 단, 기존 Office 발주 기능은 별도 기능으로 유지한다. 기존 `office_purchases` 또는 `accounting.purchase_requests`는 일반 구매/요청 도메인으로 남기고, 재고 기반 발주는 새 도메인으로 분리한다.

Office/POS 경계는 데이터 소유권, 권한, 승인 책임, RPC 책임을 분리하기 위한 기준이다. 이 경계는 UI 디자인 언어를 분리하라는 기준이 아니며, 재고/발주/승인 화면은 통합 Toast-style 운영 플랫폼 shell과 component system을 따라야 한다.

## 2. 현재 상태 요약

현재 POS 재고 구현은 다음 범위에 머문다.

- `inventory_items`: 재료/재고 품목의 현재 수량, 재주문 기준, 단가, 공급처 문자열.
- `menu_recipes`: 메뉴별 재료 소진량 매핑.
- `inventory_transactions`: 판매 차감, 입고, 폐기, 실사 조정 이력.
- `inventory_physical_counts`: 날짜별 실재고 입력 결과.
- `InventoryTab`: 재료 관리, 레시피 관리, 실재고, 재고 리포트 4개 탭.

첨부 화면이 요구하는 발주 추천, 발주 확정, 발주서 출력, 거래처별 단가/계약, 제품 이미지/코드, 매장별 통합 대시보드, 원가 분석, 실재고 실사, 모바일 발주/실사는 현재 구현과 차이가 있다. Office 승인/반려/수정 실행은 POS에 넣지 않고 Office 앱 전용 개선 범위로 둔다.

## 3. 설계 원칙

1. POS의 `restaurants` 물리 테이블과 `restaurant_id` 컬럼은 유지한다. `CLAUDE.md`의 Office 결합 규칙을 깨지 않는다.
2. 발주 추천 계산과 발주 상태 변경은 서버 RPC가 소유한다. Flutter와 Office는 같은 계산 결과를 읽는다.
3. 기존 Office 발주는 재사용하지 않는다. 재고 기반 발주는 `inventory_purchase_*` 계열의 별도 테이블과 RPC로 관리한다.
4. 재고 기준 단위와 발주 단위는 분리한다. 재고는 표준 기준 단위로 계산하고, 발주서는 공급처 발주 단위로 출력한다.
5. Office는 승인, 반려, 수정 권한을 갖지만 해당 실행 UI/RPC 호출은 Office 앱에만 둔다. POS는 승인 상태를 조회하고 다음 작업 가능 여부를 표시한다.
6. 모든 테이블은 `restaurant_id` 또는 `brand_id`를 통해 멀티테넌트 범위를 가져야 하며 RLS 또는 SECURITY DEFINER RPC에서 권한을 검증한다.
7. POS와 Office의 업무 책임은 분리하되 visual system, operating shell, navigation, table/list/form/dialog primitives는 통합 Toast-style 기준을 따른다.

## 4. 권장 데이터 모델

### 4.1 기준 테이블

#### `inventory_products`

재고/발주/원가 분석의 기준 품목이다. 기존 `inventory_items`를 즉시 대체하지 않고, 초기에는 호환 관계를 둔다.

주요 컬럼:

- `id`
- `restaurant_id`
- `brand_id`
- `inventory_item_id`
- `product_code`
- `name`
- `category`
- `stock_unit`
- `base_unit`
- `base_unit_factor`
- `image_url`
- `storage_type`
- `shelf_life_days`
- `is_orderable`
- `is_active`
- `created_at`
- `updated_at`

`stock_unit`은 화면에 보여줄 재고 단위다. `base_unit`은 계산 단위다. 예를 들어 고기는 `stock_unit = kg`, `base_unit = g`, `base_unit_factor = 1000`으로 둔다.

#### `inventory_suppliers`

거래처 관리 화면의 기준 테이블이다.

주요 컬럼:

- `id`
- `brand_id`
- `supplier_name`
- `supplier_type`
- `contact_name`
- `phone`
- `email`
- `address`
- `business_registration_no`
- `payment_terms`
- `contract_start_date`
- `contract_end_date`
- `status`
- `memo`
- `created_at`
- `updated_at`

거래처는 브랜드 공통으로 관리하고, 특정 매장에서 제외할 필요가 있으면 별도 매장 매핑 테이블을 둔다.

#### `inventory_supplier_items`

공급처별 품목, 발주 단위, 단가, 최소 발주 수량을 관리한다.

주요 컬럼:

- `id`
- `supplier_id`
- `product_id`
- `supplier_sku`
- `order_unit`
- `order_unit_quantity_base`
- `min_order_quantity`
- `unit_price`
- `tax_rate`
- `lead_time_days`
- `is_preferred`
- `is_active`
- `updated_at`

예시:

- 삼겹살 재고 기준: g
- 화면 재고 단위: kg
- 거래처 발주 단위: 박스
- `order_unit_quantity_base`: 10000g
- 발주 수량 2박스는 재고 기준 20000g으로 계산한다.

### 4.2 발주 테이블

#### `inventory_purchase_orders`

발주 헤더다.

주요 컬럼:

- `id`
- `purchase_order_no`
- `restaurant_id`
- `brand_id`
- `supplier_id`
- `status`
- `order_type`
- `source`
- `requested_delivery_date`
- `ordered_at`
- `submitted_by`
- `office_reviewed_by`
- `office_reviewed_at`
- `office_rejection_reason`
- `total_supply_amount`
- `tax_amount`
- `total_amount`
- `pdf_url`
- `created_at`
- `updated_at`

권장 상태:

- `draft`
- `submitted`
- `office_approved`
- `office_returned`
- `office_rejected`
- `ordered`
- `partially_received`
- `received`
- `cancelled`

`office_approved`는 Office 승인 완료 상태다. 실제 재고 증가는 `received` 또는 입고 라인 확정 시점에만 일어난다.

#### `inventory_purchase_order_lines`

발주 품목 라인이다.

주요 컬럼:

- `id`
- `purchase_order_id`
- `product_id`
- `supplier_item_id`
- `recommended_quantity_base`
- `ordered_quantity_base`
- `ordered_quantity_unit`
- `order_unit`
- `unit_price`
- `supply_amount`
- `tax_amount`
- `memo`
- `recommendation_snapshot`
- `created_at`
- `updated_at`

`recommendation_snapshot`에는 추천 계산 당시의 현재 재고, 일 평균 소진량, 목표 재고일, 예상 소진일을 JSON으로 저장한다. 나중에 추천 근거를 추적하기 위함이다.

#### `inventory_receipts`

입고 헤더다.

주요 컬럼:

- `id`
- `purchase_order_id`
- `restaurant_id`
- `supplier_id`
- `received_at`
- `received_by`
- `status`
- `memo`

#### `inventory_receipt_lines`

입고 품목 라인이다.

주요 컬럼:

- `id`
- `receipt_id`
- `purchase_order_line_id`
- `product_id`
- `received_quantity_base`
- `accepted_quantity_base`
- `rejected_quantity_base`
- `memo`

입고 확정 RPC는 `inventory_receipt_lines.accepted_quantity_base`만큼 `inventory_items.current_stock`을 증가시키고, `inventory_transactions`에 `restock` 이력을 남긴다.

### 4.3 소진량 및 추천 계산 테이블

#### `inventory_daily_consumption`

POS 판매 완료와 레시피를 기준으로 만든 일별 소진량 집계다.

주요 컬럼:

- `id`
- `restaurant_id`
- `product_id`
- `consumption_date`
- `sales_quantity`
- `consumed_quantity_base`
- `consumed_amount`
- `source`
- `created_at`

이 테이블은 결제 완료 또는 일 마감 이후 집계한다. 실시간 추천이 필요하면 최근 판매분을 RPC에서 추가 계산한다.

#### `inventory_recommendation_runs`

추천 계산 실행 이력이다.

주요 컬럼:

- `id`
- `restaurant_id`
- `brand_id`
- `run_date`
- `target_stock_days`
- `created_by`
- `created_at`

#### `inventory_recommendation_lines`

추천 결과 라인이다.

주요 컬럼:

- `id`
- `run_id`
- `product_id`
- `supplier_id`
- `current_stock_base`
- `avg_daily_consumption_base`
- `target_stock_days`
- `recommended_quantity_base`
- `recommended_order_units`
- `estimated_days_remaining`
- `risk_status`
- `created_at`

추천 결과는 발주 생성 전까지 수정 가능하다. 발주 생성 시 `inventory_purchase_order_lines.recommendation_snapshot`에 복사한다.

### 4.4 실재고 실사 테이블

기존 `inventory_physical_counts`는 날짜별 라인 입력에 가깝다. 첨부 화면의 실사 계획, 진행률, 결과, 이력 구조를 위해 세션 테이블을 추가한다.

#### `inventory_stock_audit_sessions`

주요 컬럼:

- `id`
- `restaurant_id`
- `brand_id`
- `audit_no`
- `audit_type`
- `status`
- `planned_date`
- `started_at`
- `completed_at`
- `created_by`
- `assigned_to`
- `memo`

#### `inventory_stock_audit_lines`

주요 컬럼:

- `id`
- `session_id`
- `product_id`
- `theoretical_quantity_base`
- `actual_quantity_base`
- `variance_quantity_base`
- `variance_amount`
- `status`
- `photo_url`
- `memo`
- `updated_at`

모바일 실사는 이 라인에 임시 저장하고, 완료 RPC가 기존 `inventory_physical_counts`, `inventory_transactions`, `inventory_items`에 반영한다.

## 5. 단위 변환 정책

단위 변환은 다음 원칙으로 고정한다.

1. 계산 기준 단위는 `base_unit`이다.
2. 무게는 `g`, 부피는 `ml`, 개수는 `ea`를 기준 단위로 쓴다.
3. 화면 표시 단위는 `stock_unit`이다. kg, L, 팩, 박스 등 사용자가 보는 단위다.
4. 발주 단위는 `inventory_supplier_items.order_unit`이다.
5. 발주 단위 1개가 기준 단위로 몇 개인지는 `order_unit_quantity_base`에 저장한다.
6. 추천 계산은 기준 단위로 수행한 뒤 발주 단위로 올림 처리한다.
7. 소진량은 소수점 둘째 자리까지 저장하고, 발주 수량은 발주 단위 기준 정수로 반올림하지 않고 올림한다.

예시:

- 현재 재고: 5000g
- 최근 4일 평균: 10000g
- 최근 7일 평균: 8000g
- 일 평균 소진량: 9400g
- 목표 재고일: 3일
- 추천 기준 단위: 3 * 9400 - 5000 = 23200g
- 발주 단위: 1박스 = 10000g
- 발주 추천: 3박스

## 6. 추천 발주 계산

첨부 모바일 화면의 공식을 기준으로 서버 RPC에서 계산한다.

일 평균 소진량:

```text
최근 4일 평균 * 0.7 + 최근 7일 평균 * 0.3
```

추천 발주 수량:

```text
목표 재고일 * 일 평균 소진량 - 현재 재고
```

예상 소진일:

```text
(현재 재고 + 발주 수량) / 일 평균 소진량
```

상태 기준:

- `danger`: 0일 이상 2일 미만
- `warning`: 2일 이상 4일 미만
- `normal`: 4일 이상 7일 미만
- `stable`: 7일 이상

추천 계산 RPC:

- `get_inventory_purchase_dashboard`
- `get_inventory_stock_status`
- `run_inventory_purchase_recommendation`
- `create_purchase_orders_from_recommendation`

추천 계산은 매장 단위로 실행하되, 브랜드/Office 화면에서는 여러 매장의 결과를 집계한다.

## 7. Office 연동 설계

Office 앱은 재고 기반 발주 도메인에 대해 다음 작업을 할 수 있다.

- 발주 목록 조회
- 발주 상세 조회
- 발주 수량/납품 요청일/메모 수정
- 승인
- 반려
- 재검토 요청 또는 반환
- 취소

Office가 직접 기존 `office_purchases`를 통해 처리하지 않는다. 재고 발주 전용 RPC를 호출한다.

권장 RPC:

- `office_get_inventory_purchase_orders`
- `office_get_inventory_purchase_order_detail`
- `office_update_inventory_purchase_order`
- `office_approve_inventory_purchase_order`
- `office_return_inventory_purchase_order`
- `office_reject_inventory_purchase_order`
- `office_cancel_inventory_purchase_order`

Office 수정 가능 범위:

- `requested_delivery_date`
- 라인별 `ordered_quantity_base`
- 라인별 `memo`
- 발주 헤더 `memo`
- Office 검토 코멘트

Office 수정 불가 범위:

- `restaurant_id`
- `supplier_id`
- `product_id`
- 추천 계산 스냅샷
- 입고 완료된 발주의 수량
- 이미 재고 반영된 입고 이력

Office 승인 이후 POS 매장은 발주서를 출력하거나 공급처 전송 상태로 넘긴다. Office 반려 또는 반환 시 POS는 Office가 저장한 상태와 사유를 읽고 수정 후 재요청할 수 있다. POS/Admin 재고/발주 화면에는 `office_approve_inventory_purchase_order`, `office_return_inventory_purchase_order`, `office_reject_inventory_purchase_order`, `office_update_inventory_purchase_order` 호출을 넣지 않는다.

## 8. 화면 구조

### 8.1 PC

첨부 화면 기준으로 `재고/발주 관리` 메뉴를 다음 하위 화면으로 구성한다.

1. 대시보드
2. 재고 현황
3. 발주 관리
4. 발주 내역
5. 거래처 관리
6. 제품 관리
7. 레시피 관리
8. 소진량 분석
9. 원가 분석
10. 실재고 실사
11. 신메뉴 등록

기존 `InventoryTab` 하나에 모두 넣지 않는다. `lib/features/inventory_purchase/` 아래에 화면, provider, service를 분리한다.

### 8.2 모바일

모바일은 전체 관리 화면이 아니라 현장 업무 중심으로 구성한다.

- 추천 발주
- 직접 발주
- 발주 내역
- 실재고 실사
- 알림

모바일 실사는 네트워크가 끊겨도 임시 입력을 보존할 수 있어야 한다. 단, 재고 반영은 서버 저장 성공 후에만 완료 처리한다.

## 9. 권한 및 상태 소유

상태의 진실은 Supabase가 가진다. Flutter와 Office는 로컬 계산으로 상태를 결정하지 않는다.

POS 권한:

- 매장 관리자: 추천 실행, 발주 생성, 승인 전 발주 수정/재요청, 발주서 출력/PDF, 입고 등록, 실사 등록.
- 일반 직원: 권한이 있는 경우 모바일 실사 입력.
- Super admin/brand admin: 모든 매장 조회 및 관리.

Office 권한:

- Office admin: 브랜드/매장 범위 내 발주 조회, 수정, 승인, 반려.
- Brand admin: 담당 브랜드 범위 내 발주 조회, 수정, 승인, 반려.
- Read-only Office 사용자: 조회만 가능.

상태 변경은 반드시 RPC에서 수행한다. 직접 table update는 금지한다.

## 10. 주요 업무 흐름

### 10.1 판매 기반 소진

1. POS 주문 결제 완료.
2. `menu_recipes` 기준으로 재료 소진량 계산.
3. `inventory_items.current_stock` 차감.
4. `inventory_transactions`에 `deduct` 기록.
5. 일 마감 또는 배치에서 `inventory_daily_consumption` 집계.

### 10.2 추천 발주

1. 매장 관리자가 추천 실행.
2. RPC가 최근 4일/7일 소진량, 현재 재고, 목표 재고일을 계산.
3. 추천 결과를 `inventory_recommendation_runs`와 `inventory_recommendation_lines`에 저장.
4. 사용자가 수량을 조정한다.
5. 공급처별 `inventory_purchase_orders`를 생성한다.
6. 상태는 `submitted`가 된다.

### 10.3 Office 승인

1. Office가 `submitted` 발주를 조회한다.
2. 필요 시 수량, 납품 요청일, 메모를 수정한다.
3. 승인하면 `office_approved`.
4. 반려하면 `office_rejected`.
5. 반환하면 `office_returned`가 되고 POS에서 수정 후 재요청한다.

### 10.4 입고 및 재고 반영

1. 승인된 발주를 공급처에 전달한다.
2. 입고 시 POS가 실제 입고 수량을 등록한다.
3. 입고 확정 RPC가 `inventory_items.current_stock`을 증가시킨다.
4. `inventory_transactions`에 `restock` 기록을 남긴다.
5. 발주 상태를 `partially_received` 또는 `received`로 갱신한다.

## 11. 기존 기능과의 관계

기존 `office_purchases`와 `accounting.purchase_requests`는 일반 구매 요청으로 유지한다. 재고 기반 발주는 새 테이블을 canonical로 둔다.

기존 `inventory_items`, `menu_recipes`, `inventory_transactions`, `inventory_physical_counts`는 폐기하지 않는다. 초기 구현에서는 새 도메인이 이 테이블을 참조하고, 필요한 경우 점진적으로 제품 마스터를 확장한다.

기존 `restaurants` 테이블은 절대 rename하지 않는다. Office 연결이 이 테이블에 의존한다.

## 12. 구현 단계

### Phase 1. DB 계약

- 새 마이그레이션으로 공급처, 제품, 공급처 품목, 발주, 입고, 추천, 실사 세션 테이블 추가.
- RLS와 권한 검증 RPC 추가.
- Office 조회/승인/반려/수정 RPC 추가.

검증:

- 매장 범위 외 발주 조회 차단.
- Office 권한 없는 사용자의 승인 차단.
- 승인 후 입고 전까지 재고가 증가하지 않는지 확인.

### Phase 2. 추천 계산

- `inventory_daily_consumption` 집계 로직 추가.
- 추천 계산 RPC 추가.
- 추천 결과에서 발주 생성 RPC 추가.

검증:

- 최근 4일/7일 가중 평균 계산.
- 기준 단위와 발주 단위 변환.
- 최소 발주 수량과 발주 단위 올림 처리.

### Phase 3. POS PC 화면

- 재고/발주 대시보드.
- 재고 현황.
- 발주 관리.
- 발주 내역 및 발주서 출력.
- 거래처/제품/레시피 화면 확장.

검증:

- 첨부 화면 기준 핵심 KPI와 테이블이 같은 의미로 표시되는지 확인.
- 매장 필터와 브랜드 필터가 권한 범위에 맞는지 확인.

### Phase 4. Office 전용 승인 연동

- Office에서 새 RPC를 호출하도록 연결.
- 승인/반려/수정 화면 추가.
- 기존 Office 발주 기능과 메뉴/데이터를 분리.

검증:

- 기존 Office 발주가 영향받지 않는지 확인.
- Office 승인 후 POS 발주 상태가 즉시 반영되는지 확인.

### Phase 5. 모바일

- 추천 발주.
- 직접 발주.
- 실재고 실사.
- 임시 저장 및 재시도.

검증:

- 모바일 실사 임시 저장.
- 네트워크 복구 후 서버 반영.
- 실사 완료 전에는 재고가 바뀌지 않는지 확인.

## 13. 결정 사항

- 첨부된 QSC Manager 화면 세트는 현재 재고/발주 PC/모바일 UI의 기준으로 본다.
- Office는 재고 기반 발주를 승인, 반려, 수정할 수 있다.
- Office 승인/반려/수정 실행은 Office 앱에만 넣는다. POS/Admin에는 승인 실행 컨트롤을 넣지 않는다.
- POS/Admin은 나머지 4개 승인 범위인 새 UI 기준 반영, 문서/테스트 충돌 정리, 발주서 출력/PDF, 추천 수량 조정 데이터 모델을 진행한다.
- 기존 Office 발주는 별도 기능으로 유지한다.
- 발주 단위와 재고 단위 변환은 기준 단위 기반 정책으로 설계한다.
- 추천 계산과 상태 변경은 서버 RPC가 소유한다.

## 14. 남은 확인 사항

1. Office 승인 권한을 `office_admin`, `brand_admin` 중 어디까지 줄지 최종 확정해야 한다.
2. 발주서 PDF를 Supabase Storage에 저장할지, 클라이언트에서 즉시 생성할지 결정해야 한다.
3. 공급처 전송 방식은 인쇄/PDF 저장까지만 할지, 메시지 전송까지 포함할지 결정해야 한다.
4. 원가 분석에 인건비와 기타 비용을 어떤 테이블에서 가져올지 확정해야 한다.
